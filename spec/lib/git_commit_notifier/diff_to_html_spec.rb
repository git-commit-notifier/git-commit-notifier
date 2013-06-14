# -*- coding: utf-8; mode: ruby; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- vim:fenc=utf-8:filetype=ruby:et:sw=2:ts=2:sts=2

require File.expand_path('../../../spec_helper', __FILE__)
require 'tempfile'
require 'nokogiri'
require 'git_commit_notifier'

describe GitCommitNotifier::DiffToHtml do

  describe :chmod do
    it "should not raise anything and set mode from stats mode" do
      file = Tempfile.new('stattest')
      file.close
      lambda do
        File.chmod(File.stat(file.path).mode, file.path)
      end.should_not raise_error
    end
  end

  describe :lines_are_sequential? do
    before(:all) do
      @diff_to_html = GitCommitNotifier::DiffToHtml.new
    end

    it "should be true if left line numbers are sequential" do
      @diff_to_html.should be_lines_are_sequential({
        :added => 2,
        :removed => 2
      }, {
        :added => 3,
        :removed => 6
      })
    end

    it "should be true if right line numbers are sequential" do
      @diff_to_html.should be_lines_are_sequential({
        :added => 2,
        :removed => 2
      }, {
        :added => 7,
        :removed => 3
      })
    end

    it "should be false unless line numbers are sequential" do
      @diff_to_html.should_not be_lines_are_sequential({
        :added => 2,
        :removed => 2
      }, {
        :added => 4,
        :removed => 6
      })
    end

    it "should be true if left line numbers are sequential (right are nil)" do
      @diff_to_html.should be_lines_are_sequential({
        :added => 2,
        :removed => 2
      }, {
        :added => 3,
        :removed => nil
      })
    end

    it "should be true if right line numbers are sequential (left are nil)" do
      @diff_to_html.should be_lines_are_sequential({
        :added => nil,
        :removed => 2
      }, {
        :added => 7,
        :removed => 3
      })
    end

    it "should be false unless line numbers are sequential (nils)" do
      @diff_to_html.should_not be_lines_are_sequential({
        :added => nil,
        :removed => nil
      }, {
        :added => 4,
        :removed => 6
      })
    end
  end

  describe :unique_commits_per_branch? do
    it "should be false unless specified in config" do
      diff = GitCommitNotifier::DiffToHtml.new
      diff.should_not be_unique_commits_per_branch
    end

    it "should be false if specified as false in config" do
      diff = GitCommitNotifier::DiffToHtml.new({ 'unique_commits_per_branch' => false })
      diff.should_not be_unique_commits_per_branch
    end

    it "should be true if specified as true in config" do
      diff = GitCommitNotifier::DiffToHtml.new({ 'unique_commits_per_branch' => true })
      diff.should be_unique_commits_per_branch
    end
  end

  it "multiple commits" do
    mock(GitCommitNotifier::Git).changed_files('7e4f6b4', '4f13525') { [] }
    mock(GitCommitNotifier::Git).rev_type(REVISIONS.first) { "commit" }
    mock(GitCommitNotifier::Git).rev_type(REVISIONS.last) { "commit" }
    mock(GitCommitNotifier::Git).new_commits(anything, anything, anything, anything) { REVISIONS.reverse }
    REVISIONS.each do |rev|
      mock(GitCommitNotifier::Git).show(rev, :ignore_whitespace => 'all') { IO.read(FIXTURES_PATH + 'git_show_' + rev) }
      dont_allow(GitCommitNotifier::Git).describe(rev) { IO.read(FIXTURES_PATH + 'git_describe_' + rev) }
    end

    diff = GitCommitNotifier::DiffToHtml.new
    diff.diff_between_revisions REVISIONS.first, REVISIONS.last, 'testproject', 'refs/heads/master'

    diff.result.should have(5).commits # one result for each of the commits

    diff.result.each do |html|
      html.should_not be_include('@@') # diff correctly processed
    end

    # second commit - 51b986619d88f7ba98be7d271188785cbbb541a0
    hp = Nokogiri::HTML diff.result[1][:html_content]
    (hp/"table").should have(3).tables # 3 files updated
    (hp/"table"/"tr"/"td").each do |td|
      if td.inner_html =~ /create_btn/
        cols = td.parent.search('td')
        ['405', '408', ''].should be_include(cols[0].inner_text) # line 405 changed
      end
    end

    # third commit - dce6ade4cdc2833b53bd600ef10f9bce83c7102d
    hp = Nokogiri::HTML diff.result[2][:html_content]
    (hp/"h2").should have(6).headers # 6 files in commit
    (hp/"table").should have(4).tables # 4 files updated
    (hp/"h2")[1].inner_text.should == 'Added binary file railties/doc/guides/source/images/icons/callouts/11.png'
    (hp/"h2")[2].inner_text.should == 'Deleted binary file railties/doc/guides/source/icons/up.png'
    (hp/"h2")[3].inner_text.should == 'Deleted file railties/doc/guides/source/icons/README'
    (hp/"h2")[4].inner_text.should == 'Added file railties/doc/guides/source/images/icons/README'

    # fourth commit
    hp = Nokogiri::HTML diff.result[3][:html_content]
    (hp/"table").should have(1).table # 1 file updated

    # fifth commit
    hp = Nokogiri::HTML diff.result[4][:html_content]
    (hp/"table").should have(2).tables # 2 files updated - one table for each of the files
    (hp/"table"/"tr"/"td").each do |td|
      if td.inner_html == "require&nbsp;'iconv'"
        # first added line in changeset a4629e707d80a5769f7a71ca6ed9471015e14dc9
        td.parent.search('td')[0].inner_text.should == '' # left
        td.parent.search('td')[1].inner_text.should == '2' # right
        td.parent.search('td')[2].inner_html.should == "require&nbsp;'iconv'" # change
      end
    end
  end

  it "should get good diff when new branch created" do
    first_rev, last_rev = %w[ 0000000000000000000000000000000000000000 ff037a73fc1094455e7bbf506171a3f3cf873ae6 ]
    mock(GitCommitNotifier::Git).rev_type(first_rev) { "commit" }
    mock(GitCommitNotifier::Git).rev_type(last_rev) { "commit" }
    mock(GitCommitNotifier::Git).new_commits(anything, anything, anything, anything) { [ 'ff037a73fc1094455e7bbf506171a3f3cf873ae6' ] }
    %w[ ff037a73fc1094455e7bbf506171a3f3cf873ae6 ].each do |rev|
      mock(GitCommitNotifier::Git).show(rev, :ignore_whitespace => 'all') { IO.read(FIXTURES_PATH + 'git_show_' + rev) }
      dont_allow(GitCommitNotifier::Git).describe(rev) { IO.read(FIXTURES_PATH + 'git_describe_' + rev) }
    end
    diff = GitCommitNotifier::DiffToHtml.new
    diff.diff_between_revisions(first_rev, last_rev, 'tm-admin', 'refs/heads/rvm')
    diff.result.should have(1).commit
    hp = Nokogiri::HTML diff.result.first[:html_content]
    (hp/"table").should have(1).table
    (hp/"tr.r").should have(1).row
  end

  describe :message_map do
    before(:each) do
      @diff = GitCommitNotifier::DiffToHtml.new
    end

    it "should do message mapping" do
      stub(@diff).do_message_integration("msg") { "msg2" }
      mock(@diff).do_message_map("msg2") { "msg3" }
      @diff.message_map("msg").should == "msg3"
    end

    it "should do message integration" do
      mock(@diff).do_message_integration("msg") { "msg2" }
      stub(@diff).do_message_map("msg2") { "msg3" }
      @diff.message_map("msg").should == "msg3"
    end
  end

  describe :do_message_integration do
    before(:each) do
      @config = Hash.new
      @diff = GitCommitNotifier::DiffToHtml.new(@config)
    end

    it "should do nothing unless message_integration config section exists" do
      mock.proxy(nil).respond_to?(:each_pair)
      dont_allow(@diff).message_replace!
      @diff.do_message_integration('yu').should == 'yu'
    end
    it "should pass MESSAGE_INTEGRATION through message_replace!" do
      @config['message_integration'] = {
        'mediawiki' => 'http://example.com/wiki', # will rework [[text]] to MediaWiki pages
        'redmine' => 'http://redmine.example.com' # will rework refs #123, #125 to Redmine issues
      }
      @diff.do_message_integration("[[text]] refs #123, #125").should == "<a href=\"http://example.com/wiki/text\">[[text]]</a> refs <a href=\"http://redmine.example.com/issues/123\">#123</a>, <a href=\"http://redmine.example.com/issues/125\">#125</a>"
    end
  end

  describe :old_commit? do
    before(:each) do
      @config = Hash.new
      @diff_to_html = GitCommitNotifier::DiffToHtml.new(@config)
    end

    it "should be false unless skip_commits_older_than set" do
      @diff_to_html.old_commit?(Hash.new).should be_false
    end

    it "should be false if skip_commits_older_than less than zero" do
      @config['skip_commits_older_than'] = '-7'
      @diff_to_html.old_commit?(Hash.new).should be_false
    end

    it "should be false if skip_commits_older_than is equal to zero" do
      @config['skip_commits_older_than'] = 0
      @diff_to_html.old_commit?(Hash.new).should be_false
    end

    it "should be false if commit is newer than required by skip_commits_older_than" do
      @config['skip_commits_older_than'] = 1
      @diff_to_html.old_commit?({:date => (Time.now - 1).to_s}).should be_false
    end

    it "should be true if commit is older than required by skip_commits_older_than" do
      @config['skip_commits_older_than'] = 1
      @diff_to_html.old_commit?({:date => (Time.now - 2 * GitCommitNotifier::DiffToHtml::SECS_PER_DAY).to_s}).should be_true
    end
  end
end
