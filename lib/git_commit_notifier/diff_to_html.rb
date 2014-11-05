# -*- coding: utf-8; mode: ruby; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- vim:fenc=utf-8:filetype=ruby:et:sw=2:ts=2:sts=2

require 'diff/lcs'
require 'digest/sha1'
require 'time'

require 'git_commit_notifier/escape_helper'

module GitCommitNotifier
  # Translates Git diff to HTML format
  class DiffToHtml
    include EscapeHelper

    # Integration map for commit message keywords to third-party links.
    INTEGRATION_MAP = {
      :mediawiki => { :search_for => /\[\[([^\[\]]+)\]\]/, :replace_with => '#{url}/\1' },
      :redmine => {
        :search_for => lambda do |config|
          keywords = (config['redmine'] && config['redmine']['keywords']) || ["refs", "fixes"]
          /\b(?:#{keywords.join('\b|')})([\s&,]+\#\d+)+/i
        end,
        :replace_with => lambda do |m, url, config|
          # we can provide Proc that gets matched string and configuration url.
          # result should be in form of:
          # { :phrase => 'phrase started with', :links => [ { :title => 'title of url', :url => 'target url' }, ... ] }
          keywords = (config['redmine'] && config['redmine']['keywords']) || ["refs", "fixes"]
          match = m.match(/^(#{keywords.join('\b|')})(.*)$/i)
          return m unless match
          r = { :phrase => match[1] }
          captures = match[2].split(/[\s\&\,]+/).map { |m| (m =~ /(\d+)/) ? $1 : m }.reject { |c| c.empty? }
          r[:links] = captures.map { |mn| { :title => "##{mn}", :url => "#{url}/issues/#{mn}" } }
          r
        end },
      :bugzilla => { :search_for => /\bBUG\s*(\d+)/i, :replace_with => '#{url}/show_bug.cgi?id=\1' },
      :fogbugz => { :search_for => /\bbugzid:\s*(\d+)/i, :replace_with => '#{url}\1' }
    }.freeze
    # Maximum email line length in characters.
    MAX_LINE_LENGTH = 512
    # Number of seconds per day.
    SECS_PER_DAY = 24 * 60 * 60

    attr_accessor :file_prefix, :current_file_name
    attr_reader :result, :oldrev, :newrev, :rev, :ref_name, :config

    def initialize(config = nil)
      @config = config || {}
      @lines_added = 0
      @file_added = false
      @file_removed = false
      @file_renamed = false
      @file_renamed_old_name = false
      @file_renamed_new_name = false
      @file_changes = []
      @binary = false
      unless String.method_defined?(:encode!)
        require 'iconv'
        @ic = Iconv.new('UTF-8', 'UTF-8//IGNORE')
      end
    end

    def to_utf8_strict(str)
      return str  unless str.respond_to?(:force_encoding)
      str = str.force_encoding(Encoding::UTF_8)
      return str  if str.valid_encoding?
      str = str.force_encoding(Encoding::BINARY)
      str.encode("UTF-8", :invalid => :replace, :undef => :replace)
    end

    def range_info(range)
      matches = range.match(/^@@ \-(\S+) \+(\S+)/)
      matches[1..2].map { |m| m.split(',')[0].to_i }
    end

    # Gets HTML class for specified diff line data.
    # @param [Hash] line Diff line data
    def line_class(line)
      case line[:op]
      when :removal;  ' class="r"'
      when :addition; ' class="a"'
      else            ''
      end
    end

    def add_block_to_results(block, escape)
      return if block.empty?
      block.each do |line|
        add_line_to_result(line, escape)
      end
    end

    # Gets lines_per_diff setting from {#config}.
    # @return [Fixnum, NilClass] Lines per diff limit.
    def lines_per_diff
      config['lines_per_diff']
    end

    # Gets ignore_merge setting from {#config}.
    def ignore_merge?
      config['ignore_merge']
    end

    # Gets show_summary setting from {#config}.
    def show_summary?
      config['show_summary']
    end

    # Gets ignore_whitespace setting from {#config}.
    # @return [String] How whitespaces should be treated in diffs (none, all, change)
    def ignore_whitespace
      return 'all' if config['ignore_whitespace'].nil?
      return 'none' if !config['ignore_whitespace']
      (['all', 'change', 'none'].include?(config['ignore_whitespace']) ? config['ignore_whitespace'] : 'all')
    end

    # Adds separator between diff blocks to @diff_result.
    # @return [NilClass] nil
    def add_separator
      @diff_result << '<tr class="sep"><td class="sep" colspan="3" title="Unchanged content skipped between diff. blocks">&hellip;</td></tr>'
      nil
    end

    # Adds notification to @diff_result about skipping of diff tail due to its large size.
    # @return [NilClass] nil
    def add_skip_notification
      @diff_result << '<tr><td colspan="3">Diff too large and stripped&hellip;</td></tr>'
      nil
    end

    def add_line_to_result(line, escape)
      klass = line_class(line)
      content = (escape == :escape) ? escape_content(line[:content]) : line[:content]
      padding = '&nbsp;' if klass != ''
      @diff_result << "<tr#{klass}>\n<td class=\"ln\">#{line[:removed]}</td>\n<td class=\"ln\">#{line[:added]}</td>\n<td>#{padding}#{content}</td></tr>"
    end

    def extract_block_content(block)
      block.collect { |b| b[:content] }.join("\n")
    end

    def lcs_diff(removals, additions)
      # arrays always have at least 1 element
      callback = DiffCallback.new

      s1 = extract_block_content(removals)
      s2 = extract_block_content(additions)

      s1 = tokenize_string(s1)
      s2 = tokenize_string(s2)

      Diff::LCS.traverse_balanced(s1, s2, callback)

      processor = ResultProcessor.new(callback.tags)

      diff_for_removals, diff_for_additions = processor.results
      result = []

      ln_start = removals[0][:removed]
      diff_for_removals.each_with_index do |line, i|
        result << { :removed => ln_start + i, :added => nil, :op => :removal, :content => line}
      end

      ln_start = additions[0][:added]
      diff_for_additions.each_with_index do |line, i|
        result << { :removed => nil, :added => ln_start + i, :op => :addition, :content => line}
      end

      result
    end

    # Gets array of tokens from specified str.
    # @param [String] str Text to be splitted into tokens.
    # @return [Array(String)] Array of tokens.
    def tokenize_string(str)
      # tokenize by non-word characters
      tokens = []
      token = ''
      str.scan(/./mu) do |ch|
        if ch =~ /[^\W_]/u
          token += ch
        else
          unless token.empty?
            tokens << token
            token = ''
          end
          tokens << ch
        end
      end
      tokens << token unless token.empty?
      tokens
    end

    def operation_description
      binary = @binary ? 'binary ' : ''
      op = if @file_removed
        "Deleted"
      elsif @file_added
        "Added"
      elsif @file_renamed
      	"Renamed"
      else
        "Changed"
      end

      file_name = @current_file_name

      # Adjust filenames and hashes in case of file renames
      if @file_renamed
        file_name = @file_renamed_new_name
        @current_sha = Git.sha_of_filename(@current_commit, file_name)
      end

      # TODO: these filenames, etc, should likely be properly html escaped
      file_link = file_name
      if config['link_files'] && !@file_removed
        file_link = generate_file_link(file_name)
      end

      if show_summary?
        @file_changes << {
          :file_name => file_name,
          :text => "#{op} #{binary}file #{file_name}",
        }
      end

      "<a name=\"#{file_name}\"></a><h2>#{op} #{binary}file #{file_link}</h2>\n"
    end

    def generate_file_link(file_name)
      if config['link_files'] && !@file_removed
        file_link = if config["link_files"] == "gitweb" && config["gitweb"]
          "<a href='#{config['gitweb']['path']}?p=#{config['gitweb']['project'] || "#{Git.repo_name}.git"};f=#{file_name};h=#{@current_sha};hb=#{@current_commit}'>#{file_name}</a>"
        elsif config["link_files"] == "gitorious" && config["gitorious"]
          "<a href='#{config['gitorious']['path']}/#{config['gitorious']['project']}/#{config['gitorious']['repository']}/blobs/#{branch_name}/#{file_name}'>#{file_name}</a>"
        elsif config["link_files"] == "trac" && config["trac"]
          if config["trac"]["repository"]
            "<a href='#{config['trac']['path']}/#{@current_commit}/#{config['trac']['repository']}/#{file_name}'>#{file_name}</a>"
          else
            "<a href='#{config['trac']['path']}/#{@current_commit}/#{file_name}'>#{file_name}</a>"
          end
        elsif config["link_files"] == "stash" && config["stash"]
          "<a href='#{config['stash']['path']}/repos/#{config['stash']['repository']}/browse/#{file_name}?at=#{@current_commit}'>#{file_name}</a>"
        elsif config["link_files"] == "cgit" && config["cgit"]
          "<a href='#{config['cgit']['path']}/#{config['cgit']['project'] || "#{Git.repo_name_real}"}/tree/#{file_name}?h=#{branch_name}'>#{file_name}</a>"
        elsif config["link_files"] == "gitlabhq" && config["gitlabhq"]
          if config["gitlabhq"]["version"] && config["gitlabhq"]["version"] < 1.2
            "<a href='#{config['gitlabhq']['path']}/#{Git.repo_name.gsub(".", "_")}/tree/#{@current_commit}/#{file_name}'>#{file_name}</a>"
          elsif config["gitlabhq"]["version"] && config["gitlabhq"]["version"] >= 5.0
            "<a href='#{config['gitlabhq']['path']}/#{Git.repo_name_with_parent.gsub(".", "_")}/blob/#{@current_commit}/#{file_name}'>#{file_name}</a>"
          elsif config["gitlabhq"]["version"] && config["gitlabhq"]["version"] >= 4.0
            "<a href='#{config['gitlabhq']['path']}/#{Git.repo_name_with_parent.gsub(".", "_")}/commit/#{@current_commit}'>#{file_name}</a>"
          else
            "<a href='#{config['gitlabhq']['path']}/#{Git.repo_name.gsub(".", "_")}/#{@current_commit}/tree/#{file_name}'>#{file_name}</a>"
          end
        elsif config["link_files"] == "gitalist" && config["gitalist"]
          "<a href='#{config['gitalist']['path']}/#{config['gitalist']['project'] || Git.repo_name}/#{@current_commit}/blob/#{file_name}'>#{file_name}</a>"
        elsif config["link_files"] == "github" && config["github"]
          "<a href='#{config['github']['path']}/#{config['github']['project']}/#{Git.repo_name}/blob/#{@current_commit}/#{file_name}'>#{file_name}</a>"
        elsif config["link_files"] == "redmine" && config["redmine"]
          "<a href='#{config['redmine']['path']}/projects/#{config['redmine']['project'] || Git.repo_name}/repository/revisions/#{@current_commit}/entry/#{file_name}'>#{file_name}</a>"
        else
          file_name
        end
      end
    end

    # Determines are two lines are sequentially placed in diff (no skipped lines between).
    # @return [Boolean] true if lines are sequential; otherwise false.
    def lines_are_sequential?(first, second)
      result = false
      [:added, :removed].each do |side|
        if !first[side].nil? && !second[side].nil?
          result = true if first[side] == (second[side] - 1)
        end
      end
      result
    end

    def add_changes_to_result
      return if @current_file_name.nil?

      @lines_added = 0
      @diff_result << operation_description

      if (@file_renamed || !@diff_lines.empty?) && (!@too_many_files)
        @diff_result << '<table>'

        ##Adds a ROW in the table for the File Rename Details (if at all present)
        if @file_renamed
          @diff_result << "<tr class='renamed'>\n<td class='ln'>&nbsp;</td><td class='ln'></td><td>&nbsp;<u>#{@file_renamed_old_name}</u> was renamed to <u>#{@file_renamed_new_name}</u></td></tr>"
        end

        removals = []
        additions = []

        lines = if lines_per_diff.nil?
          line_budget = nil
          @diff_lines
        else
          line_budget = lines_per_diff - @lines_added
          @diff_lines.slice(0, line_budget)
        end

        lines.each_with_index do |line, index|
          removals << line if line[:op] == :removal
          additions << line if line[:op] == :addition
          if line[:op] == :unchanged || index == lines.size - 1 # unchanged line or end of block, add prev lines to result
            if removals.size > 0 && additions.size > 0 # block of removed and added lines - perform intelligent diff
              add_block_to_results(lcs_diff(removals, additions), :dont_escape)
            else # some lines removed or added - no need to perform intelligent diff
              add_block_to_results(removals + additions, :escape)
            end
            removals = []
            additions = []
            if index > 0 && index != lines.size - 1
              prev_line = lines[index - 1]
              add_separator unless lines_are_sequential?(prev_line, line)
            end
            add_line_to_result(line, :escape) if line[:op] == :unchanged
          end
          @lines_added += 1
        end

        add_skip_notification if !line_budget.nil? && line_budget < @diff_lines.size

        @diff_result << '</table>'
        @diff_lines = []
      end
      # reset values
      @right_ln = nil
      @left_ln = nil
      @file_added = false
      @file_removed = false
      @file_renamed = false
      @file_renamed_old_name = false
      @file_renamed_new_name = false
      @binary = false
    end

    RE_DIFF_FILE_NAME_ESCAPED = /^diff --git "a\/(.*)" "?b\//
    RE_DIFF_FILE_NAME = /^diff\s\-\-git\sa\/(.*)\sb\//
    RE_DIFF_SHA       = /^index [0-9a-fA-F]+\.\.([0-9a-fA-F]+)/

    def diff_for_revision(content)
      @left_ln = @right_ln = nil

      @diff_result = []
      @diff_lines = []
      @removed_files = []
      @current_file_name = nil
      @current_sha = nil
      @too_many_files = false

      lines = content.split("\n")

      if config['too_many_files'] && config['too_many_files'].to_i > 0
        file_count = lines.inject(0) do |count, line|
          (line =~ RE_DIFF_FILE_NAME) ? (count + 1) : count
        end

        if file_count >= config['too_many_files'].to_i
          @too_many_files = true
        end
      end

      lines.each do |line|
        case line
        when RE_DIFF_FILE_NAME then
          file_name = $1
          add_changes_to_result
          @current_file_name = file_name
        when RE_DIFF_FILE_NAME_ESCAPED then
          file_name = decode_escaped_filename( $1 )
          add_changes_to_result
          @current_file_name = file_name
        when RE_DIFF_SHA then
          @current_sha = $1
        else
          op = line[0, 1]
          if @left_ln.nil? || op == '@'
            process_info_line(line, op)
          else
            process_code_line(line, op)
          end
        end
      end
      add_changes_to_result
      @diff_result.join("\n")
    end

    def process_code_line(line, op)
      if op == '-'
        @diff_lines << { :removed => @left_ln, :added => nil, :op => :removal, :content => line[1..-1] }
        @left_ln += 1
      elsif op == '+'
        @diff_lines << { :added => @right_ln, :removed => nil, :op => :addition, :content => line[1..-1] }
        @right_ln += 1
      else
        @diff_lines << { :added => @right_ln, :removed => @left_ln, :op => :unchanged, :content => line }
        @right_ln += 1
        @left_ln += 1
      end
    end

    def process_info_line(line, op)
      if line =~/^deleted\sfile\s/
        @file_removed = true
      elsif line =~ /^\-\-\-\s/ && line =~ /\/dev\/null/
        @file_added = true
      elsif line =~ /^\+\+\+\s/ && line =~ /\/dev\/null/
        @file_removed = true
      elsif line =~ /^Binary files \/dev\/null/ # Binary files /dev/null and ... differ (addition)
        @binary = true
        @file_added = true
      elsif line =~ /\/dev\/null differ/ # Binary files ... and /dev/null differ (removal)
        @binary = true
        @file_removed = true
      elsif line =~ /^rename from (.*)/
        @file_renamed = true
        @file_renamed_old_name = line.scan(/^rename from (.*)/)[0][0].to_s
      elsif line =~ /^rename to (.*)/
        @file_renamed_new_name = line.scan(/^rename to (.*)/)[0][0].to_s
      elsif op == '@'
        @left_ln, @right_ln = range_info(line)
      end
    end

    def extract_diff_from_git_show_output(content)
      diff = []
      diff_found = false
      content.split("\n").each do |line|
        diff_found = true if line =~ /^diff\s\-\-git/
        next unless diff_found
        diff << line
      end
      diff.join("\n")
    end

    def extract_commit_info_from_git_show_output(content)
      result = {
        :message => [],
        :commit => '',
        :author => '',
        :date => '',
        :email => '',
        :committer => '',
        :commit_date => '',
        :committer_email => ''
      }

      message = []
      content.split("\n").each do |line|
        break  if line =~ /^diff/ # end of commit info

        case line
        when /^commit /
          result[:commit] = line[7..-1]
        when /^Author:/
          result[:author], result[:email] = author_name_and_email(line[12..-1])
        when /^AuthorDate:/
          result[:date] = line[12..-1]
        when /^Commit:/
          result[:committer], result[:commit_email] = author_name_and_email(line[12..-1])
        when /^CommitDate:/
          result[:commit_date] = line[12..-1]
        when /^Merge:/
          result[:merge] = line[7..-1]
        else
          message << line.strip
        end
      end

      # Strip blank lines off top and bottom of message
      while !message.empty? && message.first.empty?
        message.shift
      end
      while !message.empty? && message.last.empty?
        message.pop
      end
      result[:message] = message

      result.each_key do |key|
        result[key] = to_utf8_strict result[key]
      end

      result
    end

    def message_array_as_html(message)
      message_map(message.collect { |m| CGI.escapeHTML(m) }.join('<br />'))
    end

    def author_name_and_email(info)
      # input string format: "autor name <author@email.net>"
      return [$1, $2]  if info =~ /^([^\<]+)\s+\<\s*(.*)\s*\>\s*$/ # normal operation
      # incomplete author info - return it as author name
      [info, '']
    end

    def first_sentence(message_array)
      msg = message_array.first.to_s.strip
      return message_array.first if msg.empty? || msg =~ /^Merge\:/
      msg
    end

    def unique_commits_per_branch?
      ! ! config['unique_commits_per_branch']
    end

    def branch_name
      ref_name.split('/').last
    end

    def old_commit?(commit_info)
      return false if ! config.include?('skip_commits_older_than') || (config['skip_commits_older_than'].to_i <= 0)
      commit_when = Time.parse(commit_info[:date])
      (Time.now - commit_when) > (SECS_PER_DAY * config['skip_commits_older_than'].to_i)
    end

    def merge_commit?(commit_info)
      ! commit_info[:merge].nil?
    end

    def truncate_long_lines(text)
      str = ""
      # Match encoding of output string to that of input string
      str.force_encoding(text.encoding)  if str.respond_to?(:force_encoding)
      StringIO.open(str, "w") do |output|
        input = StringIO.new(text, "r")
        input.each_line "\n" do |line|
          if line.length > MAX_LINE_LENGTH && MAX_LINE_LENGTH >= 9
            # Truncate the line
            line.slice!(MAX_LINE_LENGTH-3..-1)

            # Ruby < 1.9 doesn't know how to slice between
            # characters, so deal specially with that case
            # so that we don't truncate in the middle of a UTF8 sequence,
            # which would be invalid.
            unless line.respond_to?(:force_encoding)
              # If the last remaining character is part of a UTF8 multibyte character,
              # keep truncating until we go past the start of a UTF8 character.
              # This assumes that this is a UTF8 string, which may be a false assumption
              # unless somebody has taken care to check the encoding of the source file.
              # We truncate at most 6 additional bytes, which is the length of the longest
              # UTF8 sequence
              6.times do
                c = line[-1, 1].to_i
                break if (c & 0x80) == 0      # Last character is plain ASCII: don't truncate
                line.slice!(-1, 1)            # Truncate character
                break if (c & 0xc0) == 0xc0   # Last character was the start of a UTF8 sequence, so we can stop now
              end
            end

            # Append three dots to the end of line to indicate it's been truncated
            # (avoiding ellipsis character so as not to introduce more encoding issues)
            line << "...\n"
          end
          output << line
        end
        output.string
      end
    end

    # Commit to link mapping.
    COMMIT_LINK_MAP = {
      :gitweb    => lambda { |config, commit| "<a href='#{config['gitweb']['path']}?p=#{config['gitweb']['project'] || "#{Git.repo_name}.git"};a=commitdiff;h=#{commit}'>#{commit}</a>" },
      :gitorious => lambda { |config, commit| "<a href='#{config['gitorious']['path']}/#{config['gitorious']['project']}/#{config['gitorious']['repository']}/commit/#{commit}'>#{commit}</a>" },
      :trac      => lambda { |config, commit|
        if config['trac']['repository']
          "<a href='#{config['trac']['path']}/#{commit}/#{config['trac']['repository']}'>#{commit}</a>"
        else
          "<a href='#{config['trac']['path']}/#{commit}'>#{commit}</a>"
        end
      },
      :stash     => lambda { |config, commit|
        "<a href='#{config['stash']['path']}/repos/#{config['stash']['repository']}/commits/#{commit}'>#{commit}</a>"
      },
      :cgit      => lambda { |config, commit| "<a href='#{config['cgit']['path']}/#{config['cgit']['project'] || "#{Git.repo_name_real}"}/commit/?id=#{commit}'>#{commit}</a>" },
      :gitlabhq  => lambda { |config, commit|
        if config['gitlabhq']['version'] >= 5.0
          "<a href='#{config['gitlabhq']['path']}/#{Git.repo_name_with_parent.gsub(".", "_")}/commit/#{commit}'>#{commit}</a>"
        elsif config['gitlabhq']['version'] >= 4.0
          "<a href='#{config['gitlabhq']['path']}/#{Git.repo_name_with_parent.gsub(".", "_")}/commits/#{commit}'>#{commit}</a>"
        else
          "<a href='#{config['gitlabhq']['path']}/#{Git.repo_name.gsub(".", "_")}/commits/#{commit}'>#{commit}</a>"
        end
      },
      :gitalist  => lambda { |config, commit| "<a href='#{config['gitalist']['path']}/projects/#{config['gitalist']['project'] || Git.repo_name}/#{commit}/log'>#{commit}</a>" },
      :redmine   => lambda { |config, commit| "<a href='#{config['redmine']['path']}/projects/#{config['redmine']['project'] || Git.repo_name}/repository/revisions/#{commit}'>#{commit}</a>" },
      :github    => lambda { |config, commit| "<a href='#{config['github']['path']}/#{config['github']['project']}/#{Git.repo_name}/commit/#{commit}'>#{commit}</a>" },
      :default   => lambda { |config, commit| commit.to_s }
    }.freeze

    # Gets HTML markup for specified commit.
    # @param [String] commit Unique identifier of commit.
    # @return [String] HTML markup for specified commit.
    # @see COMMIT_LINK_MAP
    def markup_commit_for_html(commit)
      mode = (config["link_files"] || "default").to_sym
      mode = :default  unless config.has_key?(mode.to_s)
      mode = :default  unless COMMIT_LINK_MAP.has_key?(mode)
      COMMIT_LINK_MAP[mode].call(config, commit)
    end

    def extract_link(a_tag)
      return nil  unless a_tag =~ /href\s*=\s*"([^"]+)"/
      $1
    end

    def diff_for_commit(commit)
      @current_commit = commit
      raw_diff = truncate_long_lines(Git.show(commit, :ignore_whitespace => ignore_whitespace))
      raise "git show output is empty" if raw_diff.empty?

      if raw_diff.respond_to?(:encode!)
        unless raw_diff.valid_encoding?
          raw_diff.encode!("UTF-16", "UTF-8", :invalid => :replace, :undef => :replace)
          raw_diff.encode!("UTF-8", "UTF-16")
        end
      else
        raw_diff = @ic.iconv(raw_diff)
      end

      commit_info = extract_commit_info_from_git_show_output(raw_diff)
      return nil  if old_commit?(commit_info)
      changed_files = ""
      if merge_commit?(commit_info)
        changed_file_list = []
        merge_revisions = commit_info[:merge].split
        merge_revisions.map!{|rev| rev.chomp("...")}
        merge_first_parent = merge_revisions.slice!(0)
        merge_revisions.each do |merge_other_parent|
          changed_file_list += Git.changed_files(merge_first_parent, merge_other_parent)
        end
        changed_files = "Changed files:\n\n#{changed_file_list.uniq.join()}\n"
      end

      commit_link = markup_commit_for_html(commit_info[:commit])
      title = "<dl class=\"title\">"
      title += "<dt>Commit</dt><dd>#{commit_link}</dd>\n"
      title += "<dt>Branch</dt><dd>#{CGI.escapeHTML(branch_name)}</dd>\n" if branch_name

      title += "<dt>Author</dt><dd>#{CGI.escapeHTML(commit_info[:author])} &lt;#{commit_info[:email]}&gt;</dd>\n"

      # Show separate committer name/email only if it differs from author
      if commit_info[:author] != commit_info[:committer] || commit_info[:email] != commit_info[:commit_email]
        title += "<dt>Committer</dt><dd>#{CGI.escapeHTML(commit_info[:committer])} &lt;#{commit_info[:commit_email]}&gt;</dd>\n"
      end

      title += "<dt>Date</dt><dd>#{CGI.escapeHTML commit_info[:date]}</dd>\n"

      multi_line_message = commit_info[:message].count > 1
      title += "<dt>Message</dt><dd class='#{multi_line_message ? "multi-line" : ""}'>#{message_array_as_html(commit_info[:message])}</dd>\n"
      title += "</dl>"

      @file_changes = []
      text = ""

      html_diff = diff_for_revision(extract_diff_from_git_show_output(raw_diff))
      message_array = message_array_as_html(changed_files.split("\n"))

      if show_summary?
        title += "<ul>"

        @file_changes.each do |change|
          title += "<li><a href=\"\##{change[:file_name]}\">#{change[:text]}</a></li>"
          text += "#{change[:text]}\n"
        end

        title += "</ul>"
        text += "\n"
      end

      text += "#{raw_diff}"
      text += "#{changed_files}\n\n\n"

      html = title
      html += html_diff
      html += message_array
      html += "<br /><br />"
      commit_info[:message] = first_sentence(commit_info[:message])

      {
        :commit_info  => commit_info,
        :html_content => html,
        :text_content => text,
        :commit_link  => extract_link( commit_link ),
      }
    end

    def diff_for_lightweight_tag(tag, rev, change_type)

      if change_type == :delete
        message = "Remove Lightweight Tag #{tag}"
        commit_link = markup_commit_for_html(rev)

        html = "<dl class='title'>"
        html += "<dt>Tag</dt><dd>#{CGI.escapeHTML(tag)} (removed)</dd>\n"
        html += "<dt>Type</dt><dd>lightweight</dd>\n"
        html += "<dt>Commit</dt><dd>#{commit_link}</dd>\n"
        html += "</dl>"

        text = "Remove Tag: #{tag}\n"
        text += "Type: lightweight\n"
        text += "Commit: #{rev}\n"
      else
        message = "#{change_type == :create ? "Add" : "Update"} Lightweight Tag #{tag}"

        html = "<dl class='title'>"
        html += "<dt>Tag</dt><dd>#{CGI.escapeHTML(tag)} (#{change_type == :create ? "added" : "updated"})</dd>\n"
        html += "<dt>Type</dt><dd>lightweight</dd>\n"
        html += "<dt>Commit</dt><dd>#{markup_commit_for_html(rev)}</dd>\n"
        html += "</dl>"

        text = "Tag: #{tag} (#{change_type == :create ? "added" : "updated"})\n"
        text += "Type: lightweight\n"
        text += "Commit: #{rev}\n"
      end

      commit_info = {
        :commit => rev,
        :message => message
      }

      @result << {
        :commit_info => commit_info,
        :html_content => html,
        :text_content => text,
        :commit_link => extract_link( commit_link )
      }
    end

    def diff_for_annotated_tag(tag, rev, change_type)

      commit_info = {
        :commit => rev
      }

      if change_type == :delete
        message = "Remove Annotated Tag #{tag}"

        html = "<dl class='title'>"
        html += "<dt>Tag</dt><dd>#{CGI.escapeHTML(tag)} (removed)</dd>\n"
        html += "<dt>Type</dt><dd>annotated</dd>\n"
        html += "</dl>"

        text = message
        commit_info[:message] = message
      else
        tag_info = Git.tag_info(ref_name)

        message = tag_info[:subject] || "#{change_type == :create ? "Add" : "Update"} Annotated Tag #{tag}"
        commit_link = markup_commit_for_html(tag_info[:tagobject])

        html = "<dl class='title'>"
        html += "<dt>Tag</dt><dd>#{CGI.escapeHTML(tag)} (#{change_type == :create ? "added" : "updated"})</dd>\n"
        html += "<dt>Type</dt><dd>annotated</dd>\n"
        html += "<dt>Commit</dt><dd>#{commit_link}</dd>\n"
        html += "<dt>Tagger</dt><dd>#{CGI.escapeHTML(tag_info[:taggername])} #{CGI.escapeHTML(tag_info[:taggeremail])}</dd>\n"

        message_array = tag_info[:contents].split("\n")
        multi_line_message = message_array.count > 1
        html += "<dt>Message</dt><dd class='#{multi_line_message ? "multi-line" : ""}'>#{message_array_as_html(message_array)}</dd>\n"

        if config['show_a_shortlog_of_commits_since_the_last_annotated_tag']
          list_of_commits_in_between = Git.list_of_commits_between_current_commit_and_last_tag(ref_name, tag_info[:tagobject])
          if list_of_commits_in_between.length > 0
            html += "<dt><br/>Commits since the last annotated tag</dt><dd><br/><br/><ul>"
            list_of_commits_in_between.each do |commit|
              if config['link_files'].to_s != "none"
                l = markup_commit_for_html(commit[0])
                l = l.gsub(/>.*<\/a>/,">#{commit[1]}</a>") # Replace the link text with the commit message (the original link text is the commit hash)
                html += "<li>#{l}</li>"
              else
                html += "<li>#{commit[1]}</li>"
              end
            end
            html += "</ul></dd>"
          end
        end
        html += "</dl>"

        text = "Tag: #{tag} (#{change_type == :create ? "added" : "updated"})\n"
        text += "Type: annotated\n"
        text += "Commit: #{tag_info[:tagobject]}\n"
        text += "Tagger: #{tag_info[:taggername]} #{tag_info[:taggeremail]}\n"
        text += "Message: #{tag_info[:contents]}\n"

        commit_info[:message] = message
        commit_info[:author], commit_info[:email] = author_name_and_email("#{tag_info[:taggername]} #{tag_info[:taggeremail]}")
      end

      @result << {
        :commit_info  => commit_info,
        :html_content => html,
        :text_content => text,
        :commit_link  => extract_link( commit_link )
      }
    end

    def diff_for_branch(branch, rev, change_type)
      commits = case change_type
      when :delete
        puts "ignoring branch delete"
        []
      when :create, :update
        # Note that "unique_commits_per_branch" really means "consider commits
        # on this branch without regard to whether they occur on other branches"
        # The flag unique_to_current_branch passed to new_commits means the
        # opposite: "consider only commits that are unique to this branch"

       	# Note :: In case of creation of a new branch, the oldrev passed by git
       	# to the post-receive hook is 00000... which causes the git commit notifier
       	# to send out notifications for ALL commits in the repository. Hence we force
       	# the "unique_commits_per_branch" config to "true" in such cases, and in other
       	# cases, we consider the value from the config file
        if oldrev =~ /^0+$/
          Git.new_commits(oldrev, newrev, ref_name, true)
        else
          Git.new_commits(oldrev, newrev, ref_name, !unique_commits_per_branch?)
        end
      end

      # Add each diff to @result
      commits.each do |commit|
          commit_result = diff_for_commit(commit)
          next  if commit_result.nil?
          @result << commit_result
      end
    end

    def clear_result
      @result = []
    end

    def diff_between_revisions(rev1, rev2, repo, ref_name)
      clear_result

      # Cleanup revs
      @oldrev = Git.rev_parse(rev1)
      @newrev = Git.rev_parse(rev2)
      @ref_name = ref_name

      # Establish the type of change
      change_type = if @oldrev =~ /^0+$/
        :create
      elsif @newrev =~ /^0+$/
        :delete
      else
        :update
      end

      # Establish type of the revs
      @oldrev_type = Git.rev_type(@oldrev)
      @newrev_type = Git.rev_type(@newrev)
      if newrev =~ /^0+$/
        @rev_type = @oldrev_type
        @rev = @oldrev
      else
        @rev_type = @newrev_type
        @rev = @newrev
      end

      # Determine what to do based on the ref_name and the rev_type
      case "#{@ref_name},#{@rev_type}"
      when %r!^refs/tags/(.+),commit$!
        # Change to an unannotated tag
        diff_for_lightweight_tag($1, @rev, change_type)
      when %r!^refs/tags/(.+),tag$!
        # Change to a annotated tag
        diff_for_annotated_tag($1, @rev, change_type)
      when %r!^refs/heads/(.+),commit$!
        # Change on a branch
        diff_for_branch($1, @rev, change_type)
      when %r!^refs/remotes/(.+),commit$!
        # Remote branch
        puts "Ignoring #{change_type} on remote branch #{$1}"
      else
        # Something we don't understand
        puts "Unknown change type #{ref_name},#{@rev_type}"
      end

      # Remove merge commits if required
      if ignore_merge?
        @result.reject! { |commit| merge_commit?(commit[:commit_info]) }
      end

      # If a block was given, pass it the results, in turn
      @result.each { |commit| yield @result.size, commit }  if block_given?
    end

    def message_replace!(message, search_for, replace_with)
      if replace_with.kind_of?(Proc)
        message.gsub!(Regexp.new(search_for)) do |m|
          r = replace_with.call(m)
          r[:phrase] + ' ' + r[:links].map { |m| "<a href=\"#{m[:url]}\">#{m[:title]}</a>" }.join(', ')
        end
      else
        full_replace_with = "<a href=\"#{replace_with}\">\\0</a>"
        message.gsub!(Regexp.new(search_for), full_replace_with)
      end
    end

    def do_message_integration(message)
      return message  unless config['message_integration'].respond_to?(:each_pair)
      config['message_integration'].each_pair do |pm, url|
        pm_def = DiffToHtml::INTEGRATION_MAP[pm.to_sym] or next
        search_for = pm_def[:search_for]
        search_for = search_for.kind_of?(Proc) ? search_for.call(@config) : search_for
        replace_with = pm_def[:replace_with]
        replace_with = replace_with.kind_of?(Proc) ? lambda { |m| pm_def[:replace_with].call(m, url, @config) } : replace_with.gsub('#{url}', url)
        message_replace!(message, search_for, replace_with)
      end
      message
    end

    def do_message_map(message)
      return message  unless config['message_map'].respond_to?(:each_pair)
      config['message_map'].each_pair do |search_for, replace_with|
        message_replace!(message, Regexp.new(search_for), replace_with)
      end
      message
    end

    def message_map(message)
      do_message_map(do_message_integration(message))
    end
  end
end
