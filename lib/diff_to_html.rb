require 'rubygems'
require 'diff/lcs'
require 'digest/sha1'

require File.dirname(__FILE__) + '/result_processor'

def escape_content(s)
  CGI.escapeHTML(s).gsub(" ", "&nbsp;")
end

class DiffToHtml
  INTEGRATION_MAP = {
    :mediawiki => { :search_for => /\[\[([^\[\]]+)\]\]/, :replace_with => '#{url}/\1' },
    :redmine => { :search_for => /\b(?:refs|fixes)\s*\#(\d+)/i, :replace_with => '#{url}/issues/show/\1' },
    :bugzilla => { :search_for => /\bBUG\s*(\d+)/i, :replace_with => '#{url}/show_bug.cgi?id=\1' }
  }.freeze
  MAX_COMMITS_PER_ACTION = 10000
  HANDLED_COMMITS_FILE = 'previously.txt'.freeze
  NEW_HANDLED_COMMITS_FILE = 'previously_new.txt'.freeze
  
  attr_accessor :file_prefix, :current_file_name
  attr_reader :result

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
    return matches[1..2].map { |m| m.split(',')[0].to_i }
  end

  def line_class(line)
    if line[:op] == :removal
      return " class=\"r\""
    elsif line[:op] == :addition
      return " class=\"a\""
    else
      return ''
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

  def add_separator
    return if lines_per_diff && @lines_added >= lines_per_diff
    @diff_result << '<tr class="sep"><td class="sep" colspan="3" title="Unchanged content skipped between diff. blocks">&hellip;</td></tr>'
  end

  def add_line_to_result(line, escape)
    @lines_added += 1
    if lines_per_diff
      if @lines_added == lines_per_diff
        @diff_result << '<tr><td colspan="3">Diff too large and stripped&hellip;</td></tr>'
      end
      if @lines_added >= lines_per_diff
        return
      end
    end
    klass = line_class(line)
    content = escape ? escape_content(line[:content]) : line[:content]
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
    if @file_removed
      op = "Deleted"
    elsif @file_added
      op = "Added"
    else
      op = "Changed"
    end
    
    file_name = @current_file_name
    
    if (@config["link_files"] && @config["link_files"] == "gitweb" && @config["gitweb"])
      file_name = "<a href='#{@config['gitweb']['path']}?p=#{@config['gitweb']['project']};f=#{file_name};hb=HEAD'>#{file_name}</a>"
    elsif (@config["link_files"] && @config["link_files"] == "gitorious" && @config["gitorious"])
      file_name = "<a href='#{@config['gitorious']['path']}/#{@config['gitorious']['project']}/#{@config['gitorious']['repository']}/blobs/HEAD/#{file_name}'>#{file_name}</a>"
    elsif (@config["link_files"] && @config["link_files"] == "cgit" && @config["cgit"])
      file_name = "<a href='#{@config['cgit']['path']}/#{@config['cgit']['project']}/tree/#{file_name}'>#{file_name}</a>"
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
    @diff_result << '<table>'
    unless @diff_lines.empty?
      removals = []
      additions = []
      @diff_lines.each_with_index do |line, index|
        removals << line if line[:op] == :removal
        additions << line if line[:op] == :addition
        if line[:op] == :unchanged || index == @diff_lines.size - 1 # unchanged line or end of block, add prev lines to result
          if removals.size > 0 && additions.size > 0 # block of removed and added lines - perform intelligent diff
            add_block_to_results(lcs_diff(removals, additions), escape = false)
          else # some lines removed or added - no need to perform intelligent diff
            add_block_to_results(removals + additions, escape = true)
          end
          removals = []
          additions = []
          if index > 0 && index != @diff_lines.size - 1
            prev_line = @diff_lines[index - 1]
            add_separator unless lines_are_sequential?(prev_line, line)
          end
          add_line_to_result(line, escape = true) if line[:op] == :unchanged
        end
      end
      @diff_lines = []
      @diff_result << '</table>'
    end
    # reset values
    @right_ln = nil
    @left_ln = nil
    @file_added = false
    @file_removed = false
    @binary = false
  end

  def diff_for_revision(content)
    @left_ln = @right_ln = nil

    @diff_result = []
    @diff_lines = []
    @removed_files = []
    @current_file_name = nil

    content.split("\n").each do |line|
      if line =~ /^diff\s\-\-git/
        line.match(/diff --git a\/(.*)\sb\//)
        file_name = $1
        add_changes_to_result
        @current_file_name = file_name
      end

      op = line[0,1]
      @left_ln.nil? || op == '@' ? process_info_line(line, op) : process_code_line(line, op)
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
      diff_found = true if line =~ /^diff \-\-git/
      next unless diff_found
      diff << line
    end
    diff.join("\n")
  end

  def extract_commit_info_from_git_show_output(content)
    result = { :message => [], :commit => '', :author => '', :date => '', :email => '' }
    content.split("\n").each do |line|
      if line =~ /^diff/ # end of commit info, return results
        return result
      elsif line =~ /^commit/
        result[:commit] = line[7..-1]
      elsif line =~ /^Author/
        result[:author], result[:email] = author_name_and_email(line[8..-1])
      elsif line =~ /^Date/
        result[:date] = line[8..-1]
      elsif line =~ /^Merge/
        result[:merge] = line[8..-1]
      else
        clean_line = line.strip
        result[:message] << clean_line unless clean_line.empty?
      end
    end
    result
  end

  def message_array_as_html(message)
    message_map(message.collect { |m| CGI.escapeHTML(m)}.join("<br />"))
  end

  def author_name_and_email(info)
    # input string format: "autor name <author@email.net>"
    result = info.scan(/(.*)\s<(.*)>/)[0]
    return result if result.is_a?(Array) && result.size == 2 # normal operation
    # incomplete author info - return it as author name
    return [info, ''] if result.nil?
  end

  def first_sentence(message_array)
    msg = message_array.first.to_s.strip
    return message_array.first if msg.empty? || msg =~ /^Merge\:/
    msg
  end

	def unique_commits_per_branch?
		!!@config['unique_commits_per_branch']
	end

  def check_handled_commits(commits, branch)
    return commits if defined?(Spec)
    previous_dir = (!@previous_dir.nil? && File.exists?(@previous_dir)) ? @previous_dir : '/tmp'
		prefix = unique_commits_per_branch? ? "#{Digest.SHA1.hexdigest(branch)}." : ''
		previous_name = "#{prefix}#{HANDLED_COMMITS_FILE}"
		new_name = "#{prefix}#{NEW_HANDLED_COMMITS_FILE}"
    previous_file = File.join(previous_dir, previous_name)
    new_file = File.join(previous_dir, new_name)

    previous_list = File.exists?(previous_file) ? File.read(previous_file).to_a.map(&:chomp).compact.uniq : []
    commits.reject! {|c| c.find { |sha| previous_list.include?(sha) } }

    # if commit list empty there is no need to override list of handled commits
		flatten_commits = commits.flatten
    unless flatten_commits.empty?
      current_list = (previous_list + flatten_commits).last(MAX_COMMITS_PER_ACTION)

      # use new file, unlink and rename to make it more atomic
      File.open(new_file, 'w') { |f| f << current_list.join("\n") }
      File.unlink(previous_file) if File.exists?(previous_file)
      File.rename(new_file, previous_file)
    end
    commits
  end

  def diff_between_revisions(rev1, rev2, repo, branch)
    @result = []
    if rev1 == rev2
      commits = [rev1]
    elsif rev1 =~ /^0+$/
      # creating a new remote branch
      commits = Git.branch_commits(branch)
    elsif rev2 =~ /^0+$/
      # deleting an existing remote branch
      commits = []
    else
      log = Git.log(rev1, rev2)
      commits = log.scan(/^commit\s([a-f0-9]+)/).map { |match| match[0] }
    end

    commits = check_handled_commits(commits, branch)

    commits.each_with_index do |commit, i|
      
      raw_diff = Git.show(commit)
      raise "git show output is empty" if raw_diff.empty?
      @last_raw = raw_diff

      commit_info = extract_commit_info_from_git_show_output(raw_diff)

      title = "<div class=\"title\">"
      title += "<strong>Message:</strong> #{message_array_as_html commit_info[:message]}<br />\n"
      title += "<strong>Commit:</strong> "
      
      if (@config["link_files"] && @config["link_files"] == "gitweb" && @config["gitweb"])
        title += "<a href='#{@config['gitweb']['path']}?p=#{@config['gitweb']['project']};a=commitdiff;h=#{commit_info[:commit]}'>#{commit_info[:commit]}</a>"
      elsif (@config["link_files"] && @config["link_files"] == "gitorious" && @config["gitorious"])
        title += "<a href='#{@config['gitorious']['path']}/#{@config['gitorious']['project']}/#{@config['gitorious']['repository']}/commit/#{commit_info[:commit]}'>#{commit_info[:commit]}</a>"
      elsif (@config["link_files"] && @config["link_files"] == "trac" && @config["trac"])
        title += "<a href='#{@config['trac']['path']}/#{commit_info[:commit]}'>#{commit_info[:commit]}</a>"
      elsif (@config["link_files"] && @config["link_files"] == "cgit" && @config["cgit"])
        title += "<a href='#{@config['cgit']['path']}/#{@config['cgit']['project']}/commit/?id=#{commit_info[:commit]}'>#{commit_info[:commit]}</a>"
      else
        title += " #{commit_info[:commit]}"
      end
      
      title += "<br />\n"
      
      title += "<strong>Branch:</strong> #{branch}\n<br />" unless branch =~ /\/head/
      title += "<strong>Date:</strong> #{CGI.escapeHTML commit_info[:date]}\n<br />"
      title += "<strong>Author:</strong> #{CGI.escapeHTML(commit_info[:author])} &lt;#{commit_info[:email]}&gt;\n</div>"

      text = "#{raw_diff}\n\n\n"

      html = title
      html += diff_for_revision(extract_diff_from_git_show_output(raw_diff))
      html += "<br /><br />"
      commit_info[:message] = first_sentence(commit_info[:message])
      @result << {:commit_info => commit_info, :html_content => html, :text_content => text }
    end
  end

  def message_replace!(message, search_for, replace_with)
    full_replace_with = "<a href=\"#{replace_with}\">\\0</a>"
    message.gsub!(Regexp.new(search_for), full_replace_with)
  end

  def message_map(message)
    if @config.include?('message_integration') && @config['message_integration'].respond_to?(:each_pair)
      @config['message_integration'].each_pair do |pm, url|
        pm_def = DiffToHtml::INTEGRATION_MAP[pm.to_sym] or next
        replace_with = pm_def[:replace_with].gsub('#{url}', url)
        message_replace!(message, pm_def[:search_for], replace_with)
      end
    end
    if @config.include?('message_map') && @config['message_map'].respond_to?(:each_pair)
      @config['message_map'].each_pair do |search_for, replace_with|
        message_replace!(message, Regexp.new(search_for), replace_with)
      end
    end
    message
  end
end

class DiffCallback
  attr_reader :tags

  def initialize
    @tags = []
  end

  def match(event)
    @tags << { :action => :match, :token => event.old_element }
  end

  def discard_b(event)
    @tags << { :action => :discard_b, :token => event.new_element }
  end

  def discard_a(event)
    @tags << { :action => :discard_a, :token => event.old_element }
  end

end

__END__

 vim: tabstop=2:expandtab:shiftwidth=2
