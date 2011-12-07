require 'yaml'
require 'cgi'
require 'net/smtp'
require 'digest/sha1'

module GitCommitNotifier
  class CommitHook

    class << self
      attr_reader :config

      def show_error(message)
        $stderr.puts "************** GIT NOTIFIER PROBLEM *******************"
        $stderr.puts "\n"
        $stderr.puts message
        $stderr.puts "\n"
        $stderr.puts "************** GIT NOTIFIER PROBLEM *******************"
      end

      def info(message)
        $stdout.puts message
        $stdout.flush
      end

      def logger
        @logger ||= Logger.new(config)
      end

      def include_branches
        include_branches = config["include_branches"]
        unless include_branches.nil?
          if include_branches.kind_of?(String) && include_branches =~ /\,/
            include_branches = include_branches.split(/\s*\,\s*/)
          end
          include_branches = Array(include_branches)
        end
        include_branches
      end

      def merge_commit?(result)
        ! result[:commit_info][:merge].nil?
      end

      def run(config_name, rev1, rev2, ref_name)
        @config = File.exists?(config_name) ? YAML::load_file(config_name) : {}

        project_path = Dir.getwd
        recipient = config["mailinglist"] || Git.mailing_list_address

        # If no recipients specified, bail out gracefully. This is not an error, and might be intentional
        if recipient.nil? || recipient.length == 0
          info("bypassing commit notification; no recipients specified (consider setting git config hooks.mailinglist)")
          return
        end

        logger.debug('----')
        logger.debug("pwd: #{Dir.pwd}")
        logger.debug("ref_name: #{ref_name}")
        logger.debug("rev1: #{rev1}")
        logger.debug("rev2: #{rev2}")
        logger.debug("included branches: #{include_branches.join(', ')}") unless include_branches.nil?

        repo_name = Git.repo_name
        prefix = config["emailprefix"] || repo_name
        
        branch_name = if ref_name =~ /^refs\/heads\/(.+)$/
          $1
        else
          ref_name.split("/").last
        end

        logger.debug("prefix: #{prefix}")
        logger.debug("branch: #{branch_name}")

        unless include_branches.nil? || include_branches.include?(branch_name)
          info("Supressing mail for branch #{branch_name}...")
          return
        end
        
        branch_name = "/#{branch_name}"
        branch_name = "" if !config["show_master_branch_name"] && branch_name == '/master'
        
        # Replacements for subject template
        #     prefix
        #     repo_name
        #     branch_name
        #     commit_id (hash)
        #     short_message
        #     commit_number
        #     commit_count
        #     commit_count_phrase (1 commit, 2 commits, etc)
        subject_words = {
          :prefix => prefix,
          :repo_name => repo_name,
          :branch_name => branch_name,
          :commit_id => nil,
          :message => nil,
          :commit_number => nil,
          :commit_count => nil,
          :commit_count_phrase => nil
        }
        
        info("Sending mail...")

        diff2html = DiffToHtml.new(Dir.pwd, config)
        if config["group_email_by_push"]
          diff2html.diff_between_revisions(rev1, rev2, prefix, ref_name)
          diffresult = diff2html.result
          diff2html.clear_result

          if config["ignore_merge"]
            diffresult.reject! do |result|
              merge_commit?(result)
            end
          end

          text, html = [], []
          result = diffresult.first
          return if result.nil? || !result[:commit_info]

          diffresult.each_with_index do |result, i|
            text << result[:text_content]
            html << result[:html_content]
          end
          
          # Form the subject from template
          revised_subject_words = subject_words.merge({
            :commit_id => result[:commit_info][:commit],
            :message => result[:commit_info][:message],
            :commit_number => 1,
            :commit_count => diffresult.size,
            :commit_count_phrase => diffresult.size == 1 ? "#{diffresult.size} commit" : "#{diffresult.size} commits"
          })
          subject_template = config['subject'] || "[${prefix}${branch_name}] ${commit_count_phrase}: ${message}"
          subject = subject_template.gsub(/\$\{(\w+)\}/) { |m| revised_subject_words[$1.intern] }

          emailer = Emailer.new(config,
            :project_path => project_path,
            :recipient => recipient,
            :from_address => config["from"] || result[:commit_info][:email],
            :from_alias => result[:commit_info][:author],
            :subject => subject,
            :text_message => text.join("------------------------------------------\n\n"),
            :html_message => html.join("<hr /><br />"),
            :old_rev => rev1,
            :new_rev => rev2,
            :ref_name => ref_name,
            :repo_name => repo_name
          )
          emailer.send
        else
          commit_number = 1
          diff2html.diff_between_revisions(rev1, rev2, prefix, ref_name) do |result|
            next if config["ignore_merge"] && merge_commit?(result)
            
            # Form the subject from template
            revised_subject_words = subject_words.merge({
              :commit_id => result[:commit_info][:commit],
              :message => result[:commit_info][:message],
              :commit_number => commit_number,
              :commit_count => 1,
              :commit_count_phrase => "1 commit"
            })
            subject_template = config['subject'] || "[${prefix}${branch_name}][${commit_number}] ${message}"
            subject = subject_template.gsub(/\$\{(\w+)\}/) { |m| revised_subject_words[$1.intern] }
            
            emailer = Emailer.new(config,
              :project_path => project_path,
              :recipient => recipient,
              :from_address => config["from"] || result[:commit_info][:email],
              :from_alias => result[:commit_info][:author],
              :subject => subject,
              :text_message => result[:text_content],
              :html_message => result[:html_content],
              :old_rev => rev1,
              :new_rev => rev2,
              :ref_name => ref_name,
              :repo_name => repo_name
            )
            emailer.send
            commit_number += 1
          end
        end
      end

      def number(i)
        "[#{i + 1}]"
      end
    end
  end
end
