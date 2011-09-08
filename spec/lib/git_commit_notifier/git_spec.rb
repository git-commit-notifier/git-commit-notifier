require File.expand_path('../../../spec_helper', __FILE__)
require 'git_commit_notifier'

describe GitCommitNotifier::Git do
  SAMPLE_REV = '51b986619d88f7ba98be7d271188785cbbb541a0'.freeze
  SAMPLE_REV_2 = '62b986619d88f7ba98be7d271188785cbbb541b1'.freeze

  describe :from_shell do
    it "should be backtick" do
      GitCommitNotifier::Git.from_shell('pwd').should == `pwd`
    end
  end

  describe :show do
    it "should get data from shell: git show without whitespaces" do
      expected = 'some data from git show'
      mock(GitCommitNotifier::Git).from_shell("git show #{SAMPLE_REV} --pretty=fuller -w") { expected }
      GitCommitNotifier::Git.show(SAMPLE_REV, true).should == expected
    end

    it "should get data from shell: git show with whitespaces" do
      expected = 'some data from git show'
      mock(GitCommitNotifier::Git).from_shell("git show #{SAMPLE_REV} --pretty=fuller") { expected }
      GitCommitNotifier::Git.show(SAMPLE_REV, false).should == expected
    end

    it "should strip given revision" do
      mock(GitCommitNotifier::Git).from_shell("git show #{SAMPLE_REV} --pretty=fuller -w")
      GitCommitNotifier::Git.show("#{SAMPLE_REV}\n", true)
    end
  end

  describe :branch_heads do
    before(:each) do
      mock(GitCommitNotifier::Git).from_shell("git rev-parse --branches") { "some\npopular\ntext\n" }
    end

    it "should get branch heads from shell" do
      lambda { GitCommitNotifier::Git.branch_heads }.should_not raise_error
    end

    it "should return array of lines" do
      GitCommitNotifier::Git.branch_heads.should == %w[ some popular text ]
    end
  end


  describe :repo_name do
    # this spec written because I replaced `pwd` with Dir.pwd
    it "Dir.pwd should be same as `pwd`.chomp" do
      Dir.pwd.should == `pwd`.chomp
    end

    it "should return hooks.emailprefix if it's not empty" do
      expected = "name of repo"
      mock(GitCommitNotifier::Git).from_shell("git config hooks.emailprefix") { expected }
      dont_allow(Dir).pwd
      GitCommitNotifier::Git.repo_name.should == expected
    end

    it "should return folder name if no emailprefix and directory not ended with .git" do
      mock(GitCommitNotifier::Git).from_shell("git config hooks.emailprefix") { " " }
      mock(Dir).pwd { "/home/someuser/repositories/myrepo" }
      GitCommitNotifier::Git.repo_name.should == "myrepo"
    end

    it "should return folder name without extension if no emailprefix and directory ended with .git" do
      mock(GitCommitNotifier::Git).from_shell("git config hooks.emailprefix") { " " }
      mock(Dir).pwd { "/home/someuser/repositories/myrepo.git" }
      GitCommitNotifier::Git.repo_name.should == "myrepo"
    end
  end

  describe :log do
    it "should run git log with given args" do
      mock(GitCommitNotifier::Git).from_shell("git log --pretty=fuller #{SAMPLE_REV}..#{SAMPLE_REV_2}") { " ok " }
      GitCommitNotifier::Git.log(SAMPLE_REV, SAMPLE_REV_2).should == "ok"
    end
  end

  describe :branch_head do
    it "should run git rev-parse with given treeish" do
      mock(GitCommitNotifier::Git).from_shell("git rev-parse #{SAMPLE_REV}") { " ok " }
      GitCommitNotifier::Git.branch_head(SAMPLE_REV).should == "ok"
    end
  end

  describe :mailing_list_address do
    it "should run git config hooks.mailinglist" do
      mock(GitCommitNotifier::Git).from_shell("git config hooks.mailinglist") { " ok " }
      GitCommitNotifier::Git.mailing_list_address.should == "ok"
    end
  end

  describe :changed_files do
    it "should run git log --name-status --oneline with given args and strip out the result" do
      files = ["M       README.rdoc\n",
               "D       git_commit_notifier/Rakefile\n",
               "M       post-receive\n"]
      mock(GitCommitNotifier::Git).from_shell("git log #{SAMPLE_REV}..#{SAMPLE_REV_2} --name-status --oneline" ) { IO.read(FIXTURES_PATH + 'git_log_name_status') }
      GitCommitNotifier::Git.changed_files(SAMPLE_REV, SAMPLE_REV_2).should == files
    end
  end
end
