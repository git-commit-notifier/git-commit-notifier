# -*- coding: utf-8; mode: ruby; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- vim:fenc=utf-8:filetype=ruby:et:sw=2:ts=2:sts=2

require 'cgi'
require 'git_commit_notifier/escape_helper'

module GitCommitNotifier
  class ResultProcessor
    include EscapeHelper
    # input (loaded in @diff) is an array having Hash elements:
    # { :action => action, :token => string }
    # action can be :discard_a, :discard_b or :match

    # output: two formatted html strings, one for the removals and one for the additions

    def results
      close_tags # close last tag
      [array_of_lines(@result[:removal]), array_of_lines(@result[:addition])]
    end

    def length_in_chars(diff)
      diff.inject(0) do |length, s|
        token = s[:token]
        token_length = token.respond_to?(:jlength) ? token.jlength : token.length
        length + token_length
      end
    end

    private

    def initialize(diff)
      @diff = diff
      init
      filter_replaced_lines
      process
    end

    def init
      @result = { :addition => [], :removal => [] }
      @tag_open = { :addition => false, :removal => false}
    end

    def process
      @highlight = !@diff.select { |d| d[:action] == :match}.empty? # highlight only if block contains both matches and differences
      @diff.each do |diff|
        case diff[:action]
        when :match
          match(diff)
        when :discard_a
          discard_a(diff)
        when :discard_b
          discard_b(diff)
        end
      end
    end

    def discard_match(position, token)
      # replace it with 2 changes
      @diff[position][:action] = :discard_a
      @diff.insert(position, { :action => :discard_b, :token => token} )
    end

    def filter_replaced_lines
      # if a block is replaced by an other one, lcs-diff will find even the single common word between the old and the new content
      # no need for intelligent diff in this case, simply show the removed and the added block with no highlighting
      # rule: if less than 33% of a block is not a match, we don't need intelligent diff for that block
      match_length = length_in_chars(@diff.select { |d| d[:action] == :match })
      total_length = length_in_chars(@diff)

      if total_length.to_f / match_length > 3.3
        @diff.each_with_index do |d, i|
          next if d[:action] != :match
          discard_match(i, d[:token])
        end
      end
    end

    def match(diff)
      close_tags
      all_actions do |action|
        close_last_tag(diff)
        @result[action] << escape_content(diff[:token])
      end
    end

    def discard_a(diff)
      open_tag(:removal, diff[:token])
      close_last_tag(diff)
      @result[:removal] << escape_content(diff[:token])
    end

    def discard_b(diff)
      open_tag(:addition, diff[:token])
      close_last_tag(diff)
      @result[:addition] << escape_content(diff[:token])
    end

    def all_actions
      [:addition, :removal].each do |action|
        yield(action)
      end
    end

    def open_tag(action, next_token)
      return if !@highlight || next_token.strip.empty?  # don't open span tag if no highlighting is needed or the first token is empty
      unless @tag_open[action]
        klass = action == :addition ? 'aa' : 'rr'
        @result[action] << "<span class=\"#{klass}\">"
        @tag_open[action] = true
      end
    end

    def close_tags
      return unless @highlight
      all_actions do |action|
        if @tag_open[action]
          @result[action] << "</span>"
          @tag_open[action] = false
        end
      end
    end

    def close_last_tag(diff)
      return unless @highlight
      close_tags if diff[:token] == "\n"
    end

    def array_of_lines(tokens)
      tokens.join('').split("\n")
    end

  end
end
