# Git methods
class GitCommitNotifier::Git
  class << self
    # Runs specified command.
    # @return (String) Shell command STDOUT (forced to UTF-8)
    # @raise [ArgumentError] when command exits with nonzero status.
    def from_shell(cmd)
      r = `#{cmd}`
      raise ArgumentError.new("#{cmd} failed") unless $?.exitstatus.zero?
      r.force_encoding(Encoding::UTF_8) if r.respond_to?(:force_encoding)
      r
    end

    # runs `git show`
    # @note uses "--pretty=fuller" option.
    # @return [String] Its output
    # @see from_shell
    # @param [String] rev Revision
    # @param [Hash] opts Options
    # @option opts [Boolean] :ignore_whitespaces Ignore whitespaces or not
    def show(rev, opts = {})
      gitopt = ""
      gitopt += " --pretty=fuller"
      gitopt += " -w" if opts[:ignore_whitespaces]
      data = from_shell("git show #{rev.strip}#{gitopt}")
      data
    end

    # runs `git log`
    # @note uses "--pretty=fuller" option.
    # @return [String] Its output
    # @see from_shell
    # @param [String] rev1 First revision
    # @param [String] rev2 Second revision
    def log(rev1, rev2)
      data = from_shell("git log --pretty=fuller #{rev1}..#{rev2}").strip
      data
    end

    # runs `git log` and extract filenames only
    # @note uses "--pretty=fuller" and "--name-status" options.
    # @return [Array(String)] File names
    # @see from_shell
    # @param [String] rev1 First revision
    # @param [String] rev2 Second revision
    def changed_files(rev1, rev2)
      output = ""
      lines = from_shell("git log #{rev1}..#{rev2} --name-status --pretty=oneline")
      lines = lines.lines if lines.respond_to?(:lines)
      lines = lines.select {|line| line =~ /^\w{1}\s+\w+/} # grep out only filenames
      lines.uniq
    end

    def branch_commits(treeish)
      args = branch_heads - [ branch_head(treeish) ]
      args.map! { |tree| "^#{tree}" }
      args << treeish
      lines = from_shell("git rev-list #{args.join(' ')}")
      lines = lines.lines if lines.respond_to?(:lines)
      lines.to_a.map { |commit| commit.chomp }
    end

    def branch_heads
      lines = from_shell("git rev-parse --branches")
      lines = lines.lines if lines.respond_to?(:lines)
      lines.to_a.map { |head| head.chomp }
    end

    def git_dir()
      from_shell("git rev-parse --git-dir").strip
    end

    def revparse(param)
      from_shell("git rev-parse '#{param}'").strip
    end

    def branch_head(treeish)
      from_shell("git rev-parse #{treeish}").strip
    end

    def rev_type(rev)
      from_shell("git cat-file -t '#{rev}' 2> /dev/null").strip
    rescue ArgumentError
      nil
    end

    def repo_name
      git_prefix = begin
        from_shell("git config hooks.emailprefix").strip
      rescue ArgumentError
        ''
      end
      return git_prefix unless git_prefix.empty?
      File.expand_path(git_dir).split("/").last.sub(/\.git$/, '')
    end

    def mailing_list_address
      from_shell("git config hooks.mailinglist").strip
    rescue ArgumentError
      nil
    end
  end
end

