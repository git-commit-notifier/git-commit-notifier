# -*- coding: utf-8; mode: ruby; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- vim:fenc=utf-8:filetype=ruby:et:sw=2:ts=2:sts=2

module GitCommitNotifier::EscapeHelper
		
  def expand_tabs(s, tabWidth)
    delta = 0
    s.gsub(/\t/) do |m|
      add = tabWidth - (delta + $~.offset(0)[0]) % tabWidth
      delta += add - 1
      " " * add
    end
  end

  def escape_content(s)
    expand_tabs(CGI.escapeHTML(s), 4).gsub(" ", "&nbsp;")
  end
end
