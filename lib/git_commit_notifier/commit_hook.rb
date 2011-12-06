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

        prefix = config["emailprefix"] || Git.repo_name
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

          emailer = Emailer.new(config,
            :project_path => project_path,
            :recipient => recipient,
            :from_address => config["from"] || result[:commit_info][:email],
            :from_alias => result[:commit_info][:author],
            :subject => "[#{prefix}#{branch_name}] #{diffresult.size > 1 ? "#{diffresult.size} commits: " : ''}#{result[:commit_info][:message]}",
            :text_message => text.join("------------------------------------------\n\n"),
            :html_message => html.join("<hr /><br />"),
            :old_rev => rev1,
            :new_rev => rev2,
            :ref_name => ref_name
          )
          emailer.send
        else
          i = 0
          diff2html.diff_between_revisions(rev1, rev2, prefix, ref_name) do |result|
            next  if config["ignore_merge"] && merge_commit?(result)
            nr = number(i)
            emailer = Emailer.new(config,
              :project_path => project_path,
              :recipient => recipient,
              :from_address => config["from"] || result[:commit_info][:email],
              :from_alias => result[:commit_info][:author],
              :subject => "[#{prefix}#{branch_name}]#{nr} #{result[:commit_info][:message]}",
              :text_message => result[:text_content],
              :html_message => result[:html_content],
              :old_rev => rev1,
              :new_rev => rev2,
              :ref_name => ref_name
            )
            emailer.send
            i += 1
          end
        end
      end

      def number(i)
        "[#{i + 1}]"
      end
    end
  end
end
