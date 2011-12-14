# -*- coding: utf-8; mode: ruby; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- vim:fenc=utf-8:filetype=ruby:et:sw=2:ts=2:sts=2

if RUBY_VERSION < '1.9'
  # This is for Unicode support in Ruby 1.8
  $KCODE = 'u';
  require 'jcode'
end

if RUBY_VERSION >= '1.9'
  Encoding.default_external = "utf-8"
  Encoding.default_internal = "utf-8"
end

require 'rubygems'
require 'faker'
require 'rspec/core'

RSpec.configure do |conf|
  conf.mock_with :rr
end

unless defined? REVISIONS
  REVISIONS = ['e28ad77bba0574241e6eb64dfd0c1291b221effe', # 2 files updated
             'a4629e707d80a5769f7a71ca6ed9471015e14dc9', # 1 file updated
             'dce6ade4cdc2833b53bd600ef10f9bce83c7102d', # 6 files updated
             '51b986619d88f7ba98be7d271188785cbbb541a0', # 3 files updated
             '055850e7d925110322b8db4e17c3b840d76e144c'] # Empty merge message

  FIXTURES_PATH = (File.dirname(__FILE__) + '/fixtures/').freeze
end

