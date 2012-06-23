# -*- coding: utf-8; mode: ruby; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- vim:fenc=utf-8:filetype=ruby:et:sw=2:ts=2:sts=2

require File.expand_path('../../../spec_helper', __FILE__)

require 'git_commit_notifier'

describe GitCommitNotifier::Emailer do
  describe :new do
    it "should assign config if given" do
      GitCommitNotifier::Webhook.new({:a => :b}).config[:a].should == :b
    end

    it "should use empty hash unless config given" do
      cfg = GitCommitNotifier::Webhook.new(false).config
      cfg.should be_kind_of(Hash)
      cfg.should be_empty
    end

    it "should assign parameters from options" do
      options = {}
      GitCommitNotifier::Webhook::PARAMETERS.each do |name|
        options[name.to_sym] = Faker::Lorem.sentence
      end
      webhook = GitCommitNotifier::Webhook.new({}, options)
      options.each_pair do |key, value|
        webhook.instance_variable_get("@#{key}").should == value
      end
    end
  end

  describe :payload do
    it "should produce a valid json payload" do
      options = {}
      GitCommitNotifier::Webhook::PARAMETERS.each do |name|
        options[name.to_sym] = Faker::Lorem.sentence
      end
      options[:changed] = { a: [], m: [], d: [] }
      options[:committer] = "tester"
      webhook = GitCommitNotifier::Webhook.new({}, options)
      payload = JSON.parse(webhook.payload)
      payload['commits'][0]['committer']['name'].should == "tester"
    end
  end

end
