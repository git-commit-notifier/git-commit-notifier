require 'diff/lcs'
require 'digest/sha1'
require 'time'

require 'git_commit_notifier/escape_helper'

module GitCommitNotifier
  class DiffToHtml
    include EscapeHelper

    INTEGRATION_MAP = {
      :mediawiki => { :search_for => /\[\[([^\[\]]+)\]\]/, :replace_with => '#{url}/\1' },
      :redmine => { :search_for => /\b(?:refs|fixes)([\s&,]+\#\d+)+/i, :replace_with => lambda do |m, url|
        # we can provide Proc that gets matched string and configuration url.
        # result should be in form of:
        # { :phrase => 'phrase started with', :links => [ { :title => 'title of url', :url => 'target url' }, ... ] }
        match = m.match(/^(refs|fixes)(.*)$/i)
        return m unless match
        r = { :phrase => match[1] }
        captures = match[2].split(/[\s\&\,]+/).map { |m| (m =~ /(\d+)/) ? $1 : m }.reject { |c| c.empty? }
        r[:links] = captures.map { |mn| { :title => "##{mn}", :url => "#{url}/issues/show/#{mn}" } }
        r
      end },
      :bugzilla => { :search_for => /\bBUG\s*(\d+)/i, :replace_with => '#{url}/show_bug.cgi?id=\1' },
      :fogbugz => { :search_for => /\bbugzid:\s*(\d+)/i, :replace_with => '#{url}\1' }
    }.freeze
    MAX_COMMITS_PER_ACTION = 10000
    HANDLED_COMMITS_FILE = 'previously.txt'.freeze
    NEW_HANDLED_COMMITS_FILE = 'previously_new.txt'.freeze
    GIT_CONFIG_FILE = File.join('.git', 'config').freeze
    DEFAULT_NEW_FILE_RIGHTS = 0664
    SECS_PER_DAY = 24 * 60 * 60

    attr_accessor :file_prefix, :current_file_name
    attr_reader :result, :branch, :config

    def initialize(previous_dir = nil, config = nil)
      @previous_dir = previous_dir
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
      config['lines_per_diff']
    end

    def ignore_whitespace?
      @config['ignore_whitespace'].nil? || @config['ignore_whitespace']
    end

    def skip_lines?
      lines_per_diff && (@lines_added >= lines_per_diff)
    end

    def add_separator
      @diff_result << '<tr class="sep"><td class="sep" colspan="3" title="Unchanged content skipped between diff. blocks">&hellip;</td></tr>'
    end

    def add_skip_notification
      @diff_result << '<tr><td colspan="3">Diff too large and stripped&hellip;</td></tr>'
    end

    def add_line_to_result(line, escape)
      @lines_added += 1
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

      if config['link_files']
        file_name = if config["link_files"] == "gitweb" && config["gitweb"]
          "<a href='#{config['gitweb']['path']}?p=#{Git.repo_name}.git;f=#{file_name};h=#{@current_sha};hb=#{@current_commit}'>#{file_name}</a>"
        elsif config["link_files"] == "gitorious" && config["gitorious"]
          "<a href='#{config['gitorious']['path']}/#{config['gitorious']['project']}/#{config['gitorious']['repository']}/blobs/#{branch_name}/#{file_name}'>#{file_name}</a>"
        elsif config["link_files"] == "cgit" && config["cgit"]
          "<a href='#{config['cgit']['path']}/#{config['cgit']['project']}/tree/#{file_name}'>#{file_name}</a>"
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
      @diff_result << operation_description
      if !@diff_lines.empty? && !@too_many_files
        @diff_result << '<table>'
        removals = []
        additions = []
        @diff_lines.each_with_index do |line, index|
          if skip_lines?
            add_skip_notification
            break
          end
          removals << line if line[:op] == :removal
          additions << line if line[:op] == :addition
          if line[:op] == :unchanged || index == @diff_lines.size - 1 # unchanged line or end of block, add prev lines to result
            if removals.size > 0 && additions.size > 0 # block of removed and added lines - perform intelligent diff
              add_block_to_results(lcs_diff(removals, additions), :dont_escape)
            else # some lines removed or added - no need to perform intelligent diff
              add_block_to_results(removals + additions, :escape)
            end
            removals = []
            additions = []
            if index > 0 && index != @diff_lines.size - 1
              prev_line = @diff_lines[index - 1]
              add_separator unless lines_are_sequential?(prev_line, line)
            end
            add_line_to_result(line, :escape) if line[:op] == :unchanged
          end

        end
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
      content.split("\n").each do |line|
        if line =~ /^diff/ # end of commit info, return results
          return result
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
          clean_line = line.strip
          result[:message] << clean_line unless clean_line.empty?
        end
      end
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

    def get_previous_commits(previous_file)
      return [] unless File.exists?(previous_file)
      lines = IO.read(previous_file)
      lines = lines.lines if lines.respond_to?(:lines) # Ruby 1.9 tweak
      lines.to_a.map { |s| s.chomp }.compact.uniq
    end

    def previous_dir
      (!@previous_dir.nil? && File.exists?(@previous_dir)) ? @previous_dir : '/tmp'
    end

    def previous_prefix
      unique_commits_per_branch? ? "#{Digest::SHA1.hexdigest(branch)}." : ''
    end

    def previous_file_path
      previous_name = "#{previous_prefix}#{HANDLED_COMMITS_FILE}"
      File.join(previous_dir, previous_name)
    end

    def new_file_path
      new_name = "#{previous_prefix}#{NEW_HANDLED_COMMITS_FILE}"
      File.join(previous_dir, new_name)
    end

    def new_file_rights
      git_config_path = File.expand_path(GIT_CONFIG_FILE, '.')
      # we should copy rights from git config if possible
      File.stat(git_config_path).mode
    rescue
      DEFAULT_NEW_FILE_RIGHTS
    end

    def save_handled_commits(previous_list, flatten_commits)
      return if flatten_commits.empty?
      current_list = (previous_list + flatten_commits).last(MAX_COMMITS_PER_ACTION)

      # use new file, unlink and rename to make it more atomic
      File.open(new_file_path, 'w') { |f| f << current_list.join("\n") }
      File.chmod(new_file_rights, new_file_path) rescue nil
      File.unlink(previous_file_path) if File.exists?(previous_file_path)
      File.rename(new_file_path, previous_file_path)
    end

    def check_handled_commits(commits)
      previous_list = get_previous_commits(previous_file_path)
      commits.reject! {|c| (c.respond_to?(:lines) ? c.lines : c).find { |sha| previous_list.include?(sha) } }
      save_handled_commits(previous_list, commits.flatten)

      commits
    end

    def branch_name
      branch.split('/').last
    end

    def old_commit?(commit_info)
      return false if ! config.include?('skip_commits_older_than') || (config['skip_commits_older_than'].to_i <= 0)
      commit_when = Time.parse(commit_info[:date])
      (Time.now - commit_when) > (SECS_PER_DAY * config['skip_commits_older_than'].to_i)
    end

    def merge_commit?(commit_info)
      ! commit_info[:merge].nil?
    end

    def diff_for_commit(commit)
      @current_commit = commit
      raw_diff = Git.show(commit, ignore_whitespace?)
      raise "git show output is empty" if raw_diff.empty?

      commit_info = extract_commit_info_from_git_show_output(raw_diff)
      return nil  if old_commit?(commit_info)
      changed_files = ""
      if merge_commit?(commit_info)
        merge_revisions = commit_info[:merge].split
        changed_files += "Changed files:\n\n#{Git.changed_files(*merge_revisions)}\n"
      end

      title = "<div class=\"title\">"
      title += "<strong>Message:</strong> #{message_array_as_html(commit_info[:message])}<br />\n"
      title += "<strong>Commit:</strong> "

      title += if config["link_files"]
        if config["link_files"] == "gitweb" && config["gitweb"]
          "<a href='#{config['gitweb']['path']}?p=#{Git.repo_name}.git;a=commitdiff;h=#{commit_info[:commit]}'>#{commit_info[:commit]}</a>"
        elsif config["link_files"] == "gitorious" && config["gitorious"]
          "<a href='#{config['gitorious']['path']}/#{config['gitorious']['project']}/#{config['gitorious']['repository']}/commit/#{commit_info[:commit]}'>#{commit_info[:commit]}</a>"
        elsif config["link_files"] == "trac" && config["trac"]
          "<a href='#{config['trac']['path']}/#{commit_info[:commit]}'>#{commit_info[:commit]}</a>"
        elsif config["link_files"] == "cgit" && config["cgit"]
          "<a href='#{config['cgit']['path']}/#{config['cgit']['project']}/commit/?id=#{commit_info[:commit]}'>#{commit_info[:commit]}</a>"
        else
          " #{commit_info[:commit]}"
        end
      else
        " #{commit_info[:commit]}"
      end

      title += "<br />\n"

      title += "<strong>Branch:</strong> #{CGI.escapeHTML(branch_name)}\n<br />"
      title += "<strong>Date:</strong> #{CGI.escapeHTML commit_info[:date]}\n<br />"
      title += "<strong>Author:</strong> #{CGI.escapeHTML(commit_info[:author])} &lt;#{commit_info[:email]}&gt;\n<br />"
      title += "<strong>Committer:</strong> #{CGI.escapeHTML(commit_info[:committer])} &lt;#{commit_info[:commit_email]}&gt;\n</div>"

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

    def clear_result
      @result = []
    end

    def diff_between_revisions(rev1, rev2, repo, branch)
      @branch = branch
      @result = []
      commits = if rev1 == rev2
        [ rev1 ]
      elsif rev1 =~ /^0+$/
        # creating a new remote branch
        Git.branch_commits(branch)
      elsif rev2 =~ /^0+$/
        # deleting an existing remote branch
        []
      else
        log = Git.log(rev1, rev2)
        log.scan(/^commit\s([a-f0-9]+)/).map { |a| a.first }
      end

      commits = check_handled_commits(commits)

      commits.each do |commit|
        @lines_added = 0  unless config["group_email_by_push"]
        begin
          commit_result = diff_for_commit(commit)
          next  if commit_result.nil?
          if block_given?
            yield commit_result
          else
            @result << commit_result
          end
        end
      end
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
        replace_with = pm_def[:replace_with]
        replace_with = replace_with.kind_of?(Proc) ? lambda { |m| pm_def[:replace_with].call(m, url) } : replace_with.gsub('#{url}', url)
        message_replace!(message, pm_def[:search_for], replace_with)
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
