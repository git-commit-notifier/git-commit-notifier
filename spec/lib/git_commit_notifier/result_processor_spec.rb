# -*- coding: utf-8; mode: ruby; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- vim:fenc=utf-8:filetype=ruby:et:sw=2:ts=2:sts=2

require File.expand_path('../../../spec_helper', __FILE__)
require 'git_commit_notifier'

describe GitCommitNotifier::ResultProcessor do
  before(:all) do
    create_test_input
  end

  it :processor do
    processor = GitCommitNotifier::ResultProcessor.new(@diff)
    removal, addition = processor.results
    removal.should have(1).line

    removal.first.should be_include('&nbsp;&nbsp;<span class="rr">b</span>')
    removal.first.should be_include('<span class="rr">ton</span>')
    removal.first.split('<span>').should have(1).span # one occurrence (beginning of string)

    addition.should have(1).line
    addition.first.should be_include('&nbsp;&nbsp;<span class="aa">s</span>')
    addition.first.should be_include('<span class="aa">bmi</span>')
    addition.first.split('<span>').should have(1).span # one occurrence (beginning of string)
  end

  it "processor with almost no common part" do
    @diff = [
      { :action => :match, :token => ' ' },
      { :action => :match, :token => ' ' },
      { :action => :discard_a, :token => 'button' },
      { :action => :discard_b, :token => 'submit' },
      { :action => :match, :token => 'x' }
    ]

    processor = GitCommitNotifier::ResultProcessor.new(@diff)
    removal, addition = processor.results

    removal.should have(1).line
    removal.first.should == '&nbsp;&nbsp;buttonx' # no highlight

    addition.should have(1).line
    addition.first.should == '&nbsp;&nbsp;submitx' # no highlight
  end

  it "close span tag when having difference at the end" do
    diff = []
    s1 = "  submit_to_remote 'create_btn', 'Create', :url => { :action => 'cre"
    s2 = "  submit_to_remote 'create_btn', 'Create', :url => { :action => 'sub"

    s1[0..s1.size-6].each_char do |c|
      diff << { :action => :match, :token => c}
    end
    diff << { :action => :discard_a, :token => 'c' }
    diff << { :action => :discard_a, :token => 'r' }
    diff << { :action => :discard_a, :token => 'e' }
    diff << { :action => :discard_b, :token => 's' }
    diff << { :action => :discard_b, :token => 'u' }
    diff << { :action => :discard_b, :token => 'b' }

    processor = GitCommitNotifier::ResultProcessor.new(diff)
    removal, addition = processor.results

    removal.should have(1).line
    removal.first.should be_include('action&nbsp;=&gt;<span class="rr">cre</span>')

    addition.should have(1).line
    addition.first.should be_include('action&nbsp;=&gt;<span class="aa">sub</span>')
  end

  def create_test_input
    s1 = "  button_to_remote 'create_btn', 'Create', :url => { :action => 'create' }"
    s2 = "  submit_to_remote 'create_btn', 'Create', :url => { :action => 'create' }"

    @diff = [
      [ :match,     ' ' ],
      [ :match,     ' ' ],
      [ :discard_a, 'b' ],
      [ :discard_b, 's' ],
      [ :match,     'u' ],
      [ :discard_b, 'b' ],
      [ :discard_b, 'm' ],
      [ :discard_b, 'i' ],
      [ :match,     't' ],
      [ :discard_a, 't' ],
      [ :discard_a, 'o' ],
      [ :discard_a, 'n' ]
    ]
    @diff = @diff.collect { |d| { :action => d.first, :token => d.last}}

    s1[@diff.size..-1].each_char do |c|
      @diff << { :action => :match, :token => c }
    end
  end

  describe :length_in_chars do
    it "should be unicode friendly" do
      processor = GitCommitNotifier::ResultProcessor.new(@diff)
      processor.length_in_chars([{ :token => 'японская мама' }]).should == 13
    end
  end
end

