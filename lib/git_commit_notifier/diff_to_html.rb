# -*- coding: utf-8; mode: ruby; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- vim:fenc=utf-8:filetype=ruby:et:sw=2:ts=2:sts=2

require 'diff/lcs'
require 'digest/sha1'
require 'time'

require 'git_commit_notifier/escape_helper'

module GitCommitNotifier
  class DiffToHtml
    include EscapeHelper

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
          r[:links] = captures.map { |mn| { :title => "##{mn}", :url => "#{url}/issues/show/#{mn}" } }
          r
        end },
      :bugzilla => { :search_for => /\bBUG\s*(\d+)/i, :replace_with => '#{url}/show_bug.cgi?id=\1' },
      :fogbugz => { :search_for => /\bbugzid:\s*(\d+)/i, :replace_with => '#{url}\1' }
    }.freeze
    MAX_LINE_LENGTH = 512
    MAX_COMMITS_PER_ACTION = 10000
    HANDLED_COMMITS_FILE = 'previously.txt'.freeze
    NEW_HANDLED_COMMITS_FILE = 'previously_new.txt'.freeze
    GIT_CONFIG_FILE = File.join('.git', 'config').freeze
    SECS_PER_DAY = 24 * 60 * 60

    attr_accessor :file_prefix, :current_file_name
    attr_reader :result, :oldrev, :newrev, :rev, :ref_name, :config

    def initialize(config = nil)
      @config = config || {}
      @lines_added = 0
      @file_added = false
      @file_removed = false
      @binary = false
    end

    def range_info(range)
      matches = range.match(/^@@ \-(\S+) \+(\S+)/)
      matches[1..2].map { |m| m.split(',')[0].to_i }
    end

    def line_class(line)
      case line[:op]
      when :removal  then ' class="r"'
      when :addition then ' class="a"'
      else                ''
      end
    end

    def add_block_to_results(block, escape)
      return if block.empty?
      block.each do |line|
        add_line_to_result(line, escape)
      end
    end

    def lines_per_diff
      @config['lines_per_diff']
    end

    def ignore_whitespaces?
      @config['ignore_whitespace'].nil? || @config['ignore_whitespace']
    end

    def add_separator
      @diff_result << '<tr class="sep"><td class="sep" colspan="3" title="Unchanged content skipped between diff. blocks">&hellip;</td></tr>'
    end

    def add_skip_notification
      @diff_result << '<tr><td colspan="3">Diff too large and stripped&hellip;</td></tr>'
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
      else
        "Changed"
      end

      file_name = @current_file_name
      
      # TODO: these filenames, etc, should likely be properly html escaped
      if config['link_files']
        file_name = if config["link_files"] == "gitweb" && config["gitweb"]
          "<a href='#{config['gitweb']['path']}?p=#{config['gitweb']['project']}.git;f=#{file_name};h=#{@current_sha};hb=#{@current_commit}'>#{file_name}</a>"
        elsif config["link_files"] == "gitorious" && config["gitorious"]
          "<a href='#{config['gitorious']['path']}/#{config['gitorious']['project']}/#{config['gitorious']['repository']}/blobs/#{branch_name}/#{file_name}'>#{file_name}</a>"
        elsif config["link_files"] == "cgit" && config["cgit"]
          "<a href='#{config['cgit']['path']}/#{config['cgit']['project']}/tree/#{file_name}'>#{file_name}</a>"
        elsif config["link_files"] == "gitlabhq" && config["gitlabhq"]
          if config["gitlabhq"]["version"] && config["gitlabhq"]["version"] < 1.2
            "<a href='#{config['gitlabhq']['path']}/#{Git.repo_name.gsub(".", "_")}/tree/#{@current_commit}/#{file_name}'>#{file_name}</a>"
          else
            "<a href='#{config['gitlabhq']['path']}/#{Git.repo_name.gsub(".", "_")}/#{@current_commit}/tree/#{file_name}'>#{file_name}</a>"
          end
        elsif config["link_files"] == "redmine" && config["redmine"]
          "<a href='#{config['redmine']['path']}/projects/#{config['redmine']['project'] || Git.repo_name}/repository/revisions/#{@current_commit}/entry/#{file_name}'>#{file_name}</a>"
        else
          file_name
        end
      end

      header = "#{op} #{binary}file #{file_name}"
      "<h2>#{header}</h2>\n"
    end

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
      if !@diff_lines.empty? && !@too_many_files
        @diff_result << '<table>'
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
      @binary = false
    end

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
      result = { :message => [], :commit => '', :author => '', :date => '', :email => '',
      :committer => '', :commit_date => '', :committer_email => ''}
      
      message = []
      content.split("\n").each do |line|
        if line =~ /^diff/ # end of commit info
          break
        elsif line =~ /^commit /
          result[:commit] = line[7..-1]
        elsif line =~ /^Author:/
          result[:author], result[:email] = author_name_and_email(line[12..-1])
        elsif line =~ /^AuthorDate:/
          result[:date] = line[12..-1]
        elsif line =~ /^Commit:/
          result[:committer], result[:commit_email] = author_name_and_email(line[12..-1])
        elsif line =~ /^CommitDate:/
          result[:commit_date] = line[12..-1]
        elsif line =~ /^Merge:/
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
      
      result
    end

    def message_array_as_html(message)
      message_map(message.collect { |m| CGI.escapeHTML(m) }.join('<br />'))
    end

    def author_name_and_email(info)
      # input string format: "autor name <author@email.net>"
      return [$1, $2] if info =~ /^([^\<]+)\s+\<\s*(.*)\s*\>\s*$/ # normal operation
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
      StringIO.open("", "w") do |output|
        # Match encoding of output string to that of input string
        output.string.force_encoding(text.encoding) if output.string.respond_to?(:force_encoding)

        input = StringIO.new(text, "r")
        input.each_line "\n" do |line|
          if line.length > MAX_LINE_LENGTH && MAX_LINE_LENGTH >= 9
            # Truncate the line
            line.slice!(MAX_LINE_LENGTH-3..-1)

            # Ruby < 1.9 doesn't know how to slice between
            # characters, so deal specially with that case
            # so that we don't truncate in the middle of a UTF8 sequence,
            # which would be invalid.
            if !line.respond_to?(:force_encoding)
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
    
    def markup_commit_for_html(commit)
      commit = if config["link_files"]
        if config["link_files"] == "gitweb" && config["gitweb"]
          "<a href='#{config['gitweb']['path']}?p=#{Git.repo_name}.git;a=commitdiff;h=#{commit}'>#{commit}</a>"
        elsif config["link_files"] == "gitorious" && config["gitorious"]
          "<a href='#{config['gitorious']['path']}/#{config['gitorious']['project']}/#{config['gitorious']['repository']}/commit/#{commit}'>#{commit}</a>"
        elsif config["link_files"] == "trac" && config["trac"]
          "<a href='#{config['trac']['path']}/#{commit}'>#{commit}</a>"
        elsif config["link_files"] == "cgit" && config["cgit"]
          "<a href='#{config['cgit']['path']}/#{config['cgit']['project']}/commit/?id=#{commit}'>#{commit}</a>"
        elsif config["link_files"] == "gitlabhq" && config["gitlabhq"]
          "<a href='#{config['gitlabhq']['path']}/#{Git.repo_name.gsub(".", "_")}/commits/#{commit}'>#{commit}</a>"
        elsif config["link_files"] == "redmine" && config["redmine"]
          "<a href='#{config['redmine']['path']}/projects/#{config['redmine']['project'] || Git.repo_name}/repository/revisions/#{commit}'>#{commit}</a>"
        else
          "#{commit}"
        end
      else
        "#{commit}"
      end
    end
    
    def diff_for_commit(commit)
      @current_commit = commit
      raw_diff = truncate_long_lines(Git.show(commit, :ignore_whitespaces => ignore_whitespaces?))
      raise "git show output is empty" if raw_diff.empty?

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

      title = "<dl class=\"title\">"
      title += "<dt>Commit</dt><dd>#{markup_commit_for_html(commit_info[:commit])}</dd>\n"
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

      text = "#{raw_diff}"
      text += "#{changed_files}\n\n\n"

      html = title
      html += diff_for_revision(extract_diff_from_git_show_output(raw_diff))
      html += message_array_as_html(changed_files.split("\n"))
      html += "<br /><br />"
      commit_info[:message] = first_sentence(commit_info[:message])

      {
        :commit_info  => commit_info,
        :html_content => html,
        :text_content => text
      }
    end

    def diff_for_lightweight_tag(tag, rev, change_type)
    
      if change_type == :delete
        message = "Remove Lightweight Tag #{tag}"
        
        html = "<dl class='title'>"
        html += "<dt>Tag</dt><dd>#{CGI.escapeHTML(tag)} (removed)</dd>\n"
        html += "<dt>Type</dt><dd>lightweight</dd>\n"
        html += "<dt>Commit</dt><dd>#{markup_commit_for_html(rev)}</dd>\n"
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
        :text_content => text
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
        
        html = "<dl class='title'>"
        html += "<dt>Tag</dt><dd>#{CGI.escapeHTML(tag)} (#{change_type == :create ? "added" : "updated"})</dd>\n"
        html += "<dt>Type</dt><dd>annotated</dd>\n"
        html += "<dt>Commit</dt><dd>#{markup_commit_for_html(tag_info[:tagobject])}</dd>\n"
        html += "<dt>Tagger</dt><dd>#{CGI.escapeHTML(tag_info[:taggername])} #{CGI.escapeHTML(tag_info[:taggeremail])}</dd>\n"

        message_array = tag_info[:contents].split("\n")
        multi_line_message = message_array.count > 1
        html += "<dt>Message</dt><dd class='#{multi_line_message ? "multi-line" : ""}'>#{message_array_as_html(message_array)}</dd>\n"
        html += "</dl>"
        
        text = "Tag:</strong> #{tag} (#{change_type == :create ? "added" : "updated"})\n"
        text += "Type: annotated\n"
        text += "Commit: #{tag_info[:tagobject]}\n"
        text += "Tagger: tag_info[:taggername] tag_info[:taggeremail]\n"
        text += "Message: #{tag_info[:contents]}\n"
        
        commit_info[:message] = message
        commit_info[:author], commit_info[:email] = author_name_and_email("#{tag_info[:taggername]} #{tag_info[:taggeremail]}")
      end
      
      @result << {
        :commit_info => commit_info,
        :html_content => html,
        :text_content => text
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
        Git.new_commits(oldrev, newrev, ref_name, !unique_commits_per_branch?)
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
      
      # If a block was given, pass it the results, in turn
      @result.each { |result| yield result }  if block_given?
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
      return message unless config['message_integration'].respond_to?(:each_pair)
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
      return message unless config['message_map'].respond_to?(:each_pair)
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
