# -*- coding: utf-8; mode: ruby; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- vim:fenc=utf-8:filetype=ruby:et:sw=2:ts=2:sts=2

require 'yaml'
require 'cgi'
require 'net/smtp'
require 'digest/sha1'

module GitCommitNotifier
  # Represents Git commit hook handler.
  class CommitHook

    class << self
      # Configuration that read from YAML file.
      # @return [Hash] Configuration.
      attr_reader :config

      # Prints error message to $stderr.
      # @param [String] message Message to be printed to $stderr.
      # @return [NilClass] nil
      def show_error(message)
        $stderr.puts "************** GIT NOTIFIER PROBLEM *******************"
        $stderr.puts "\n"
        $stderr.puts message
        $stderr.puts "\n"
        $stderr.puts "************** GIT NOTIFIER PROBLEM *******************"
        nil
      end

      # Prints informational message to $stdout.
      # @param [String] message Message to be printed to $stdout.
      # @return [NilClass] nil
      def info(message)
        $stdout.puts message
        $stdout.flush
        nil
      end

      # Gets logger.
      def logger
        @logger ||= Logger.new(config)
      end

      def email?(email)
        !!(email =~ /@/)
      end

      def add_committer_to_recipient(recipient, committer_email)
        if email?(committer_email) 
          "#{recipient},#{committer_email}"
        else
          recipient
        end
      end

      # Gets list of branches from {config} to include into notifications.
      # @note All branches will be notified about if returned list is nil; otherwise only specified branches will be notifified about.
      # @return [Array(String), NilClass] Array of branches to include into notifications or nil.
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

      # Is merge commit?
      # @param [Hash] commit_info Information about commit.
      def merge_commit?(commit_info)
        ! commit_info[:commit_info][:merge].nil?
      end

      # Gets message subject.
      # @param [Hash] commit_info Commit info.
      # @param [String] template Subject template.
      # @param [Hash] subject_map Map of subject substitutions.
      # @return [String] Message subject.
      def get_subject(commit_info, template, subject_map)
        template.gsub(/\$\{(\w+)\}/) do |m|
          res = subject_map[$1.intern]
          if res.kind_of?(Proc)
            res = res.call(commit_info)
          end
          res
        end
      end

      # Runs comit hook handler using specified arguments.
      # @param [String] config_name Path to the application configuration file in YAML format.
      # @param [String] rev1 First specified revision.
      # @param [String] rev2 Second specified revision.
      # @param [String] ref_name Git reference (usually in "refs/heads/branch" format).
      # @return [NilClass] nil
      # @see config
      def run(config_name, rev1, rev2, ref_name)
      
        if @start_time.nil?
          @start_time = Time.new
          @start_time_offset = 0
        end

        # Load the configuration
        if File.exists?(config_name) 
          @config = YAML::load_file(config_name) 
        else
          GitCommitNotifier::CommitHook.info("Unable to find configuration file: #{config_name}")
          @config = {}
        end

        project_path = Git.git_dir
        repo_name = Git.repo_name
        prefix = config["emailprefix"] || repo_name

        branch_name = if ref_name =~ /^refs\/heads\/(.+)$/
          $1
        else
          ref_name.split("/").last
        end
        slash_branch_name = "/#{branch_name}"
        slash_branch_name = "" if !config["show_master_branch_name"] && slash_branch_name == '/master'

        # Identify email recipients
        recipient = nil
        recipient = Git.mailing_list_address  if config["prefer_git_config_mailinglist"]
        if config["mailinglist"].kind_of?(Hash)
          recipient ||= config["mailinglist"][branch_name] || config["mailinglist"]["default"]
        else
          recipient ||= config["mailinglist"]
        end
        recipient ||= Git.mailing_list_address  unless config["prefer_git_config_mailinglist"]

        # If no recipients specified, bail out gracefully. This is not an error, and might be intentional
        if recipient.nil? || recipient.length == 0
          info("bypassing commit notification; no recipients specified (consider setting git config hooks.mailinglist)")
          return
        end

        # Debug information
        logger.debug('----')
        logger.debug("cwd: #{Dir.pwd}")
        logger.debug("Git Directory: #{project_path}")
        logger.debug("prefix: #{prefix}")
        logger.debug("repo_name: #{repo_name}")
        logger.debug("branch: #{branch_name}")
        logger.debug("slash_branch: #{slash_branch_name}")
        logger.debug("ref_name: #{ref_name}")
        logger.debug("rev1: #{rev1}")
        logger.debug("rev2: #{rev2}")
        logger.debug("included branches: #{include_branches.join(', ')}") unless include_branches.nil?

        unless include_branches.nil? || include_branches.include?(branch_name)
          info("Supressing mail for branch #{branch_name}...")
          return nil
        end

        # Replacements for subject template
        #     prefix
        #     repo_name
        #     branch_name
        #     slash_branch_name
        #     commit_id (hash)
        #     short_commit_id (first few unique digits of the hash)
        #     description ('git describe' tag)
        #     short_message
        #     commit_number
        #     commit_count
        #     commit_count_phrase (1 commit, 2 commits, etc)
        #     commit_count_phrase2 (2 commits:, 3 commits:, etc, or "" if just one)
        subject_words = {
          :prefix => prefix,
          :repo_name => repo_name,
          :branch_name => branch_name,
          :slash_branch_name => slash_branch_name,
          :commit_id => nil,
          :short_commit_id => lambda { |commit_info| Git.short_commit_id(commit_info[:commit]) },
          :description => lambda { |commit_info| Git.describe(commit_info[:commit]) },
          :message => nil,
          :commit_number => nil,
          :commit_count => nil,
          :commit_count_phrase => nil,
          :commit_count_phrase2 => nil
        }

        info("Sending mail...")

        diff2html = DiffToHtml.new(config)
        if config["group_email_by_push"]
          diff2html.diff_between_revisions(rev1, rev2, prefix, ref_name)
          diffresult = diff2html.result
          diff2html.clear_result

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
            :commit_count_phrase => diffresult.size == 1 ? "1 commit" : "#{diffresult.size} commits",
            :commit_count_phrase2 => diffresult.size == 1 ? "" : "#{diffresult.size} commits: "
          })
          subject_template = config['subject'] || "[${prefix}${slash_branch_name}] ${commit_count_phrase2}${message}"
          subject = get_subject(result[:commit_info], subject_template, revised_subject_words)

          emailer = Emailer.new(config,
            :project_path => project_path,
            :recipient => config["send_mail_to_committer"] ? add_committer_to_recipient(recipient, result[:commit_info][:email]) : recipient,
            :from_address => config["from"] || result[:commit_info][:email],
            :from_alias => result[:commit_info][:author],
            :reply_to_address => config["reply_to_author"] ? result[:commit_info][:email] : config["from"] || result[:commit_info][:email],
            :subject => subject,
            :commit_date => result[:commit_info][:date],
            :current_date => Time.new.rfc2822,
            :offset_date => (@start_time + @start_time_offset).rfc2822,
            :text_message => text.join("------------------------------------------\n\n"),
            :html_message => html.join("<hr /><br />"),
            :old_rev => rev1,
            :new_rev => rev2,
            :ref_name => ref_name,
            :repo_name => repo_name
          )
          emailer.send

          # WEBHOOK patch
          unless config['webhook'].nil?
            webhook = Webhook.new(config,
              :committer => result[:commit_info][:author],
              :email => result[:commit_info][:email],
              :message => result[:commit_info][:message],
              :subject => subject,
              :changed => Git.split_status(rev1,rev2),
              :old_rev => rev1,
              :new_rev => rev2,
              :ref_name => ref_name,
              :repo_name => repo_name
            )
            webhook.send
            
            @start_time_offset += 1
          end
        else
          commit_number = 1
          diff2html.diff_between_revisions(rev1, rev2, prefix, ref_name) do |count, result|
            # Form the subject from template
            revised_subject_words = subject_words.merge({
              :commit_id => result[:commit_info][:commit],
              :message => result[:commit_info][:message],
              :commit_number => commit_number,
              :commit_count => count,
              :commit_count_phrase => count == 1 ? "1 commit" : "#{count} commits",
              :commit_count_phrase2 => count == 1 ? "" : "#{count} commits: "
            })
            subject_template = config['subject'] || "[${prefix}${slash_branch_name}][${commit_number}/${commit_count}] ${message}"
            subject = get_subject(result[:commit_info], subject_template, revised_subject_words)

            emailer = Emailer.new(config,
              :project_path => project_path,
              :recipient => config["send_mail_to_committer"] ? add_committer_to_recipient(recipient, result[:commit_info][:email]) : recipient,
              :from_address => config["from"] || result[:commit_info][:email],
              :from_alias => result[:commit_info][:author],
              :reply_to_address => config["reply_to_author"] ? result[:commit_info][:email] : config["from"] || result[:commit_info][:email],
              :subject => subject,
              :commit_date => result[:commit_info][:date],
              :current_date => Time.new.rfc2822,
              :offset_date => (@start_time + @start_time_offset).rfc2822,
              :text_message => result[:text_content],
              :html_message => result[:html_content],
              :old_rev => rev1,
              :new_rev => rev2,
              :ref_name => ref_name,
              :repo_name => repo_name
            )
            emailer.send

            # WEBHOOK patch
            unless config['webhook'].nil?
              webhook = Webhook.new(config,
                :committer => result[:commit_info][:author],
                :email => result[:commit_info][:email],
                :message => result[:commit_info][:message],
                :subject => subject,
                :changed => Git.split_status(rev1,rev2),
                :old_rev => rev1,
                :new_rev => rev2,
                :ref_name => ref_name,
                :repo_name => repo_name
              )
              webhook.send
            end

            commit_number += 1
            
            @start_time_offset += 1
          end
        end
        nil
      end
    end
  end
end
