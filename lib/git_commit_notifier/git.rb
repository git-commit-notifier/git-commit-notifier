class GitCommitNotifier::Git
  class << self
    def from_shell(cmd)
      r = `#{cmd}`
      raise ArgumentError.new("#{cmd} failed") unless $?.exitstatus.zero?
      r.force_encoding(Encoding::UTF_8) if r.respond_to?(:force_encoding)
      r
    end

    def show(rev, ignore_whitespace)
      gitopt = ""
      gitopt += " --pretty=fuller"
      gitopt += " -w" if ignore_whitespace
      data = from_shell("git show #{rev.strip}#{gitopt}")
      data
    end

    def log(rev1, rev2)
      data = from_shell("git log --pretty=fuller #{rev1}..#{rev2}").strip
      data
    end

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

    def branch_head(treeish)
      from_shell("git rev-parse #{treeish}").strip
    end

    def repo_name
      git_prefix = begin
        from_shell("git config hooks.emailprefix").strip
      rescue ArgumentError
        ''
      end
      return git_prefix unless git_prefix.empty?
      Dir.pwd.split("/").last.sub(/\.git$/, '')
    end

    def mailing_list_address
      from_shell("git config hooks.mailinglist").strip
    end
  end
end

