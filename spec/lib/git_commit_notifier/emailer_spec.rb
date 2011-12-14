# -*- coding: utf-8; mode: ruby; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- vim:fenc=utf-8:filetype=ruby:et:sw=2:ts=2:sts=2

require File.expand_path('../../../spec_helper', __FILE__)

require 'git_commit_notifier'

describe GitCommitNotifier::Emailer do
  describe :new do
    it "should assign config if given" do
      GitCommitNotifier::Emailer.new({:a => :b}).config[:a].should == :b
    end

    it "should use empty hash unless config given" do
      cfg = GitCommitNotifier::Emailer.new(false).config
      cfg.should be_kind_of(Hash)
      cfg.should be_empty
    end

    it "should assign parameters from options" do
      options = {}
      GitCommitNotifier::Emailer::PARAMETERS.each do |name|
        options[name.to_sym] = Faker::Lorem.sentence
      end
      emailer = GitCommitNotifier::Emailer.new({}, options)
      options.each_pair do |key, value|
        emailer.instance_variable_get("@#{key}").should == value
      end
    end
  end

  describe :stylesheet_string do
    it "should return default stylesheet if custom is not provided" do
      emailer = GitCommitNotifier::Emailer.new({})
      mock(IO).read(GitCommitNotifier::Emailer::DEFAULT_STYLESHEET_PATH) { 'ok' }
      emailer.stylesheet_string.should == 'ok'
    end

    it "should return custom stylesheet if custom is provided" do
      emailer = GitCommitNotifier::Emailer.new({'stylesheet' => '/path/to/custom/stylesheet'})
      mock(IO).read('/path/to/custom/stylesheet') { 'ok' }
      dont_allow(IO).read(GitCommitNotifier::Emailer::DEFAULT_STYLESHEET_PATH)
      emailer.stylesheet_string.should == 'ok'
    end
  end

  describe :mail_html_message do
    it "should form inline html" do
      options = {}
      GitCommitNotifier::Emailer::PARAMETERS.each do |name|
        options[name.to_sym] = Faker::Lorem.sentence
      end
      emailer = GitCommitNotifier::Emailer.new({}, options)
      emailer.mail_html_message.should match(/html/)
    end
  end

  describe :template do
    before(:each) do
      GitCommitNotifier::Emailer.reset_template
      mock(IO).read(GitCommitNotifier::Emailer::TEMPLATE) { 'erb' }
    end

    it "should respond to result" do
      GitCommitNotifier::Emailer.template.should respond_to(:result)
    end

    it "should return Erubis template if Erubis installed" do
      mock(GitCommitNotifier::Emailer).require('erubis')
      dont_allow(GitCommitNotifier::Emailer).require('erb')
      unless defined?(Erubis)
        module Erubis
          class Eruby
            def initialize(erb)
            end
          end
        end
      end
      mock.proxy(Erubis::Eruby).new('erb')
      GitCommitNotifier::Emailer.template.should be_kind_of(Erubis::Eruby)
    end

    it "should return ERB template unless Erubis installed" do
      require 'erb'
      mock(GitCommitNotifier::Emailer).require('erubis') { raise LoadError.new('erubis') }
      mock(GitCommitNotifier::Emailer).require('erb')
      mock.proxy(ERB).new('erb')

      GitCommitNotifier::Emailer.template.should be_kind_of(ERB)
    end
  end

  describe :template_source do
    it "should return custom template if custom is provided" do
      emailer = GitCommitNotifier::Emailer.new({'custom_template' => '/path/to/custom/template'})
      mock(IO).read('/path/to/custom/template') { 'custom templated text' }
      dont_allow(IO).read(GitCommitNotifier::Emailer::TEMPLATE)
      GitCommitNotifier::Emailer.template_source.should == 'custom templated text'
    end

    it "should return the default template if custom_template is not provided" do
      emailer = GitCommitNotifier::Emailer.new({})
      mock(IO).read(GitCommitNotifier::Emailer::TEMPLATE) { 'default templated text' }
      GitCommitNotifier::Emailer.template_source.should == 'default templated text'
    end
  end
end
