require File.expand_path('../spec_helper.rb', File.dirname(__FILE__))
require 'commit_hook'

describe CommitHook do

  it "should ignore merge" do
    # 4 commits, one email for each of them, without merge
    run_with_config('spec/fixtures/git-notifier-ignore-merge.yml', 4)
  end

  it "should hook with merge" do
    # 5 commits, one email for each of them, with merge mail
    run_with_config('spec/fixtures/git-notifier-with-merge.yml', 5)
  end

  it "should hook group email by push" do
    # 1 commit for the push, all commits in the one message
    run_with_config('spec/fixtures/git-notifier-group-email-by-push.yml', 1)
  end

  def run_with_config(config, times)
    expect_repository_access

    emailer = mock!.send.times(times).subject
    mock(Emailer).new(anything, anything) { emailer }.times(times)

    mock(CommitHook).info(/Sending mail/)

    any_instance_of(DiffToHtml, :check_handled_commits => lambda { |commits, branch| commits })
    CommitHook.run config, REVISIONS.first, REVISIONS.last, 'refs/heads/master'
  end

  def test_commit_from
    # 1 commit with a from: adress
    expect_repository_access
    emailer = mock!.send.subject
    mock(Emailer).new(anything, hash_including(:from_address => "max@example.com")) { emailer }
    
    CommitHook.run 'spec/fixtures/git-notifier-group-email-by-push.yml', REVISIONS.first, REVISIONS.last, 'refs/heads/master'
   end

  def expect_repository_access
    path = File.dirname(__FILE__) + '/../fixtures/'
    mock(Git).log(REVISIONS.first, REVISIONS.last) { IO.read(path + 'git_log') }
    mock(Git).mailing_list_address { 'recipient@test.com' }
    REVISIONS.each do |rev|
      mock(Git).show(rev) { IO.read(path + "git_show_#{rev}") }
    end
  end

  describe :logger do
    it "should be nstance of logger" do
			mock(CommitHook).config { {} }
			CommitHook.logger.should be_kind_of(Logger)
		end
	end
end

__END__

 vim: tabstop=2 expandtab shiftwidth=2

