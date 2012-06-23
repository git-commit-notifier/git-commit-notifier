# -*- coding: utf-8; mode: ruby; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- vim:fenc=utf-8:filetype=ruby:et:sw=2:ts=2:sts=2

require "json"
require "uri"
require "cgi"
require "net/http"

class GitCommitNotifier::Webhook

  PARAMETERS = %w(committer email message subject changed old_rev new_rev ref_name repo_name)
  attr_accessor :config

  def initialize(config, options = {})
    @config = config || {}
    PARAMETERS.each do |name|
      instance_variable_set("@#{name}".to_sym, options[name.to_sym])
    end
  end

  def payload
    pay = {
      'repository' => {
        'name' => @repo_name
      },
      'ref' => @ref_name,
      'before' => @old_rev,
      'after' => @new_rev,
      'commits' => [
        {
          'added' => @changed[:a],
          'modified' => @changed[:m],
          'removed' => @changed[:d],
          'committer' => {
            'name' => @committer,
            'email' => @email
          },
          'message' => CGI::escape(@message)
        }
      ]
    }.to_json
    pay
  end

  def send
    Net::HTTP.post_form(URI.parse(@config['webhook']['url']), { 'payload' => payload })
    nil
  end

end
