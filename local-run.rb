#!/usr/bin/env ruby
# -*- coding: utf-8; mode: ruby; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- vim:fenc=utf-8:filetype=ruby:et:sw=2:ts=2:sts=2

if RUBY_VERSION < '1.9'
  # This is for Unicode support in Ruby 1.8
  $KCODE = 'u';
  require 'jcode'
end

require 'rubygems'
$LOAD_PATH.unshift(File.expand_path('./lib', File.dirname(__FILE__)))

# parameters: revision1, revision 2, branch

require 'git_commit_notifier/executor'

GitCommitNotifier::Executor.run!(ARGV)

