# parameters: revision1, revision 2, branch

require 'git_commit_notifier'

# Git commit notifier namespace
module GitCommitNotifier
  # binaries code
  class Executor
    # runs git commit notifier life
    # @param [Array(String)] args Command line arguments
    # @return [nil] Nothing
    def self.run!(args)
      case args.length
      when 0
        GitCommitNotifier::CommitHook.show_error("You have to add a path to the config file for git-commit-notifier")
        puts "Usage:  git-commit-notifier config-script [oldrev newrev [ref]]"
      when 1
        if $stdin.eof?
          GitCommitNotifier::CommitHook.show_error("No data given on standard input")
          return
        end
        
        # Note that there may be multiple lines on stdin, such
        # as in the case of multiple tags being pushed
        $stdin.each_line do |line|
          oldrev, newrev, ref = line.strip.split
          GitCommitNotifier::CommitHook.run args.first, oldrev, newrev, ref
        end

      when 2
        GitCommitNotifier::CommitHook.run args.first, args.last, args.last, ""
      when 3
        GitCommitNotifier::CommitHook.run args.first, args[1], args.last, ""
      else
        GitCommitNotifier::CommitHook.run args.first, args[1], args[2], args[3]
      end
      nil
    end
  end
end

