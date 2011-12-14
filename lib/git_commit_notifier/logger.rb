# -*- coding: utf-8; mode: ruby; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- vim:fenc=utf-8:filetype=ruby:et:sw=2:ts=2:sts=2

require 'tmpdir'

class GitCommitNotifier::Logger
  DEFAULT_LOG_DIRECTORY = Dir.tmpdir.freeze
  LOG_NAME = 'git-commit-notifier.log'.freeze

  attr_reader :log_directory

  def initialize(config)
    @enabled = !!(config['debug'] && config['debug']['enabled'])
    @log_directory = debug? ? (config['debug']['log_directory'] || DEFAULT_LOG_DIRECTORY) : nil
  end

  def debug?
    @enabled
  end

  def log_path
    return nil unless debug?
    File.join(log_directory, LOG_NAME)
  end

  def debug(msg)
    return unless debug?
    File.open(log_path, 'a') do |f|
      f.puts msg
    end
  end

  def file(file_path)
    return unless debug?
    orig_dest_name = File.join(log_directory, File.basename(file_path))
    dest_name = orig_dest_name
    counter = 1
    while File.exists?(dest_name)
      counter += 1
      dest_name = "#{orig_dest_name}.#{counter}"
    end
    debug("Save file #{file_path} for debugging purposes to #{dest_name}")
    File.copy(file_path, dest_name)
  end

end

__END__

 vim: tabstop=2:expandtab:shiftwidth=2

