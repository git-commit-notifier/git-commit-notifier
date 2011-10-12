# parameters: revision1, revision 2, branch

require 'git_commit_notifier'

module GitCommitNotifier
  class Executor
    def self.run!(args)
      case args.length
      when 0
        GitCommitNotifier::CommitHook.show_error("You have to add a path to the config file for git-commit-notifier")
        puts "Usage:  git-commit-notifier config-script [oldrev newrev [ref]]"
      when 1
        stdin = $stdin.gets
        if stdin.nil?
          GitCommitNotifier::CommitHook.show_error("No data given on standard input")
          return
        end
        oldrev, newrev, ref = stdin.strip.split
        GitCommitNotifier::CommitHook.run args.first, oldrev, newrev, ref
      when 2
        GitCommitNotifier::CommitHook.run args.first, args.last, args.last, ""
      when 3
        GitCommitNotifier::CommitHook.run args.first, args[1], args.last, ""
      else
        GitCommitNotifier::CommitHook.run args.first, args[1], args[2], args[3]
      end
    end
  end
end

