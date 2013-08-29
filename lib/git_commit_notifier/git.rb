# -*- coding: utf-8; mode: ruby; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- vim:fenc=utf-8:filetype=ruby:et:sw=2:ts=2:sts=2

# Git methods
class GitCommitNotifier::Git
  class << self
    # Runs specified command and gets its output.
    # @return (String) Shell command STDOUT (forced to UTF-8)
    # @raise [ArgumentError] when command exits with nonzero status.
    def from_shell(cmd)
      r = `#{cmd}`
      raise ArgumentError.new("#{cmd} failed")  unless $?.exitstatus.zero?
      r.force_encoding(Encoding::UTF_8) if r.respond_to?(:force_encoding)
      r
    end

    # Runs specified command and gets its output as array of lines.
    # @return (Enumerable(String)) Shell command STDOUT (forced to UTF-8) as enumerable lines.
    # @raise [ArgumentError] when command exits with nonzero status.
    # @see from_shell
    def lines_from_shell(cmd)
      lines = from_shell(cmd)
      # Ruby 1.9 tweak.
      lines = lines.lines  if lines.respond_to?(:lines)
      lines
    end

    # Runs `git show`
    # @note uses "--pretty=fuller" and "-M" option.
    # @return [String] Its output
    # @see from_shell
    # @param [String] rev Revision
    # @param [Hash] opts Options
    # @option opts [String] :ignore_whitespace How whitespaces should be treated
    def show(rev, opts = {})
      gitopt = " --date=rfc2822"
      gitopt += " --pretty=fuller"
      gitopt += " -M#{GitCommitNotifier::CommitHook.config['similarity_detection_threshold'] || "0.5"}"
      gitopt += " -w" if opts[:ignore_whitespace] == 'all'
      gitopt += " -b" if opts[:ignore_whitespace] == 'change'
      from_shell("git show #{rev.strip}#{gitopt}")
    end

    # Runs `git describe'
    # @return [String] Its output
    # @see from_shell
    # @param [String] rev Revision
    def describe(rev)
      from_shell("git describe --always #{rev.strip}").strip
    end

    # Runs `git log`
    # @note uses "--pretty=fuller" option.
    # @return [String] Its output
    # @see from_shell
    # @param [String] rev1 First revision
    # @param [String] rev2 Second revision
    def log(rev1, rev2)
      from_shell("git log --pretty=fuller #{rev1}..#{rev2}").strip
    end

    # Runs `git log` and extract filenames only
    # @note uses "--pretty=oneline" and "--name-status" and "-M" options.
    # @return [Array(String)] File names
    # @see lines_from_shell
    # @param [String] rev1 First revision
    # @param [String] rev2 Second revision
    def changed_files(rev1, rev2)
      lines = lines_from_shell("git log #{rev1}..#{rev2} --name-status --pretty=oneline -M#{GitCommitNotifier::CommitHook.config['similarity_detection_threshold'] || "0.5"}")
      lines = lines.select {|line| line =~ /^\w{1}\s+\w+/} # grep out only filenames
      lines.uniq
    end

    # Returns sha1 of the file after the most recent commit.
    # Runs `git show  #{rev}:#{filename} | git hash-object --stdin` to return the sha of the file.
    # @note It was required as when there is a file which is renamed, and it has a 100% similarity index, its sha is not included in the git-show output.
    # @return [String] sha1 of the file name.
    # @see from_shell
    # @param [String] rev revision where we want to get the sha of the file name
    # @param [String] filename File name whose sha1 we want
    def sha_of_filename(rev, filename)
      lines = from_shell("git show  #{rev}:#{filename} | git hash-object --stdin")
      lines.strip
    end

    # splits the output of changed_files
    # @return [Hash(Array)] file names sorted by status
    # @see changed_files
    # @param [String] rev1 First revision
    # @param [String] rev2 Second revision
    def split_status(rev1, rev2)
      lines = changed_files(rev1, rev2)
      modified = lines.map { |l| l.gsub(/M\s/,'').strip if l[0,1] == 'M' }.select { |l| !l.nil? }
      added = lines.map { |l| l.gsub(/A\s/,'').strip if l[0,1] == 'A' }.select { |l| !l.nil? }
      deleted = lines.map { |l| l.gsub(/D\s/,'').strip if l[0,1] == 'D' }.select { |l| !l.nil? }
      renamed = lines.map { |l| l.gsub(/R\d+\s/,'').strip if l[0,1] == 'R' }.select { |l| !l.nil? }
      { :m => modified, :a => added, :d => deleted , :r => renamed}
    end

    def branch_commits(treeish)
      args = branch_heads - [ branch_head(treeish) ]
      args.map! { |tree| "^#{tree}" }
      args << treeish
      lines = lines_from_shell("git rev-list #{args.join(' ')}")
      lines.to_a.map { |commit| commit.chomp }
    end

    def branch_heads
      lines = lines_from_shell("git rev-parse --branches")
      lines.to_a.map { |head| head.chomp }
    end

    def git_dir
      from_shell("git rev-parse --git-dir").strip
    end

    def toplevel_dir
      from_shell("git rev-parse --show-toplevel").strip
    end

    def rev_parse(param)
      from_shell("git rev-parse '#{param}'").strip
    end

    def short_commit_id(param)
      from_shell("git rev-parse --short '#{param}'").strip
    end

    def branch_head(treeish)
      from_shell("git rev-parse #{treeish}").strip
    end


    # Lists commits between specified rev and closest annotated tag.
    # Uses `git describe` to obtain information.
    # @return [Array] Commit hashes and their messages
    # @param [String] tag_name of the current tag
    # @param [String] rev sha of the commit the tag is associated with
    # @note There have been many complaints about using git describe to obtain this information
    #       but, this looked like the best way to obtain the information here.
    #       Here is a link http://www.xerxesb.com/2010/git-describe-and-the-tale-of-the-wrong-commits/
    #       discussing, the way git-describe handles the problem of finding the nearest commit with a tag.
    #       Looking forward to someone coming up with a better way.
    def list_of_commits_between_current_commit_and_last_tag(tag_name, rev)
      result = Array.new

      lines = from_shell("git describe --abbrev=0 #{rev}^1 2> /dev/null | cat ").strip # the `cat` is used to suppress the error that might arise when handling the case of the first commit
      if lines.length != 1
        previous_tag = lines
        list_of_commits = lines_from_shell("git log #{previous_tag}..#{tag_name} --format='%H::::::%s'")
        list_of_commits.each do |row|
          result << Array.new(row.split("::::::"))
        end
      end
      result
    end

    def new_commits(oldrev, newrev, refname, unique_to_current_branch)
      # We want to get the set of commits (^B1 ^B2 ... ^oldrev newrev)
      # Where B1, B2, ..., are any other branch
      a = Array.new

      # If we want to include only those commits that are
      # unique to this branch, then exclude commits that occur on
      # other branches
      if unique_to_current_branch
        # Make a set of all branches, not'd (^BCURRENT ^B1 ^B2...)
        not_branches = lines_from_shell("git rev-parse --not --branches")
        a = not_branches.map { |l| l.chomp }

        # Remove the current branch (^BCURRENT) from the set
        current_branch = rev_parse(refname)
        a.delete_at a.index("^#{current_branch}") unless a.index("^#{current_branch}").nil?
      end

      # Add not'd oldrev (^oldrev)
      a.push("^#{oldrev}")  unless oldrev =~ /^0+$/

      # Add newrev
      a.push(newrev)

      # We should now have ^B1... ^oldrev newrev

      # Get all the commits that match that specification
      lines = lines_from_shell("git rev-list --reverse #{a.join(' ')}")
      lines.to_a.map { |l| l.chomp }
    end

    def rev_type(rev)
      from_shell("git cat-file -t '#{rev}' 2> /dev/null").strip
    rescue ArgumentError
      nil
    end

    def tag_info(refname)
      fields = [
        ':tagobject => %(*objectname)',
        ':tagtype => %(*objecttype)',
        ':taggername => %(taggername)',
        ':taggeremail => %(taggeremail)',
        ':subject => %(subject)',
        ':contents => %(contents)'
      ]
      joined_fields = fields.join(",")
      hash_script = from_shell("git for-each-ref --shell --format='{ #{joined_fields} }' #{refname}")
      eval(hash_script)
    end

    # Gets repository name.
    # @note Tries to gets human readable repository name through `git config hooks.emailprefix` call.
    #       If it's not specified then returns directory name (except '.git' suffix if exists).
    # @return [String] Human readable repository name.
    def repo_name
      git_prefix = begin
        from_shell("git config hooks.emailprefix").strip
      rescue ArgumentError
        ''
      end
      return git_prefix  unless git_prefix.empty?
      git_path = toplevel_dir
      # In a bare repository, toplevel directory is empty.  Revert to git_dir instead.
      if git_path.empty?
        git_path = git_dir
      end
      File.expand_path(git_path).split("/").last.sub(/\.git$/, '')
    end

    # Gets repository name.
    # @return [String] Repository name.
    def repo_name_real
      git_path = toplevel_dir
      # In a bare repository, toplevel directory is empty.  Revert to git_dir instead.
      if git_path.empty?
        git_path = git_dir
      end
      File.expand_path(git_path).split("/").last
    end

	# Gets repository name.
    # @note Tries to gets human readable repository name through `git config hooks.emailprefix` call.
    #       If it's not specified then returns directory name with parent directory name (except '.git'
	#       suffix if exists).
    # @return [String] Human readable repository name.
    def repo_name_with_parent
      git_prefix = begin
        from_shell("git config hooks.emailprefix").strip
      rescue ArgumentError
        ''
      end
      return git_prefix  unless git_prefix.empty?
      git_path = toplevel_dir
      # In a bare repository, toplevel directory is empty.  Revert to git_dir instead.
      if git_path.empty?
        git_path = git_dir
      end
      name_with_parent = File.expand_path(git_path).scan(/[a-zA-z0-9\-_]+\/[a-zA-Z0-9\-_]+.git$/).first;
      return name_with_parent.sub(/\.git$/, '')  unless name_with_parent.empty?
      File.expand_path(git_path).split("/").last.sub(/\.git$/, '')
    end

    # Gets mailing list address.
    # @note mailing list address retrieved through `git config hooks.mailinglist` call.
    # @return [String] Mailing list address if exists; otherwise nil.
    def mailing_list_address
      from_shell("git config hooks.mailinglist").strip
    rescue ArgumentError
      nil
    end
  end
end

