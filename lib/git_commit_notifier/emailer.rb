# -*- coding: utf-8; mode: ruby; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- vim:fenc=utf-8:filetype=ruby:et:sw=2:ts=2:sts=2

require 'premailer'

# Represents email sender.
class GitCommitNotifier::Emailer
  # Default CSS stylesheet file path
  DEFAULT_STYLESHEET_PATH = File.join(File.dirname(__FILE__), *'../../template/styles.css'.split('/')).freeze
  # Default ERB template file path
  TEMPLATE = File.join(File.dirname(__FILE__), *'../../template/email.html.erb'.split('/')).freeze
  # Instance variable names
  PARAMETERS = %w[project_path recipient from_address from_alias reply_to_address commit_date current_date offset_date subject text_message html_message repo_name ref_name old_rev new_rev].freeze

  # Gets config.
  # @return [Hash] Configuration
  # @note Helper that represents class method in instance scope.
  # @see GitCommitNotifier::Emailer.config
  def config
    GitCommitNotifier::Emailer.config
  end

  def initialize(config, options = {})
    GitCommitNotifier::Emailer.config = config || {}
    PARAMETERS.each do |name|
      instance_variable_set("@#{name}".to_sym, options[name.to_sym])
    end
  end

  class << self
    # [Hash] Gets or sets config.
    attr_accessor :config

    # Resets compiled template.
    # @note Useful for tests.
    # @return [NilClass] nil
    def reset_template
      @template = nil
    end

    # Reads template source code from file system.
    # @return [String] Template source code.
    def template_source
      template_file = config['custom_template'] || TEMPLATE
      IO.read(template_file)
    end

    # Gets or reads compiled template.
    # @return [Object] Compiled template.
    # @note Erubis used as template engine if present; ERB otherwise.
    def template
      unless @template
        source = template_source
        begin
          require 'erubis'
           @template = Erubis::Eruby.new(source)
        rescue LoadError
          require 'erb'
          @template = ERB.new(source)
        end
      end
      @template
    end

    # Resets CSS stylesheet source.
    # @note Useful for tests.
    # @return [NilClass] nil
    def reset_stylesheet
      @stylesheet = nil
    end

    # Reads CSS stylesheet source code.
    # @return [String] Stylesheet source code.
    def stylesheet_source
      stylesheet = config['stylesheet'] || DEFAULT_STYLESHEET_PATH
      IO.read(stylesheet)
    end

    # Gets or reads CSS stylesheet.
    # @return [String] Stylesheet source code.
    def stylesheet
      @stylesheet ||= stylesheet_source
    end
  end

  # Gets HTML-formatted message.
  # @return [String] HTML-formatted message.
  def mail_html_message
    html = GitCommitNotifier::Emailer.template.result(binding)
    if config['expand_css'].nil? || config['expand_css']
      premailer = Premailer.new(html, :with_html_string => true, :adapter => :nokogiri)
      html = premailer.to_inline_css
    end
    html
  end

  # Gets stylesheet string.
  # @note This is helper to provide data from class context.
  # @see GitCommitNotifier::Emailer.stylesheet
  # @return [String] Stylesheet source code.
  def stylesheet_string
    GitCommitNotifier::Emailer.stylesheet
  end

  # Gets or creates email part boundary
  # @return [String] Email part boundary.
  def boundary
    return @boundary if @boundary
    srand
    seed = "#{rand(10000)}#{Time.now}"
    @boundary = Digest::SHA1.hexdigest(seed)
  end

  # Performs email delivery in debug mode (to STDOUT).
  # @return [NilClass] nil
  def perform_delivery_debug(content)
    content.each do |line|
      puts line
    end
    nil
  end

  # Performs email delivery through SMTP.
  # @return [NilClass] nil
  def perform_delivery_smtp(content, smtp_settings)
    settings = { }
    %w(address port domain user_name password authentication enable_tls).each do |key|
      val = smtp_settings[key].to_s.empty? ? nil : smtp_settings[key]
      settings.merge!({ key => val})
    end

    main_smtp = Net::SMTP.new settings['address'], settings['port']

    main_smtp.enable_starttls  if settings['enable_tls']
    main_smtp.start( settings['domain'],
                    settings['user_name'], settings['password'], settings['authentication']) do |smtp|

      recipients = @recipient.dup
      recipients.force_encoding('ASCII-8BIT') if recipients.respond_to?(:force_encoding)
      recipients = recipients.split(",").map(&:strip)
      smtp.open_message_stream(@from_address, recipients) do |f|
        content.each do |line|
          line.force_encoding('ASCII-8BIT') if line.respond_to?(:force_encoding)
          f.print(line)
          f.print("\r\n")
        end
      end
    end
    nil
  end

  # Performs email delivery through Sendmail.
  # @return [NilClass] nil
  def perform_delivery_sendmail(content, options = nil)
    sendmail_settings = {
      'location' => "/usr/sbin/sendmail",
      'arguments' => "-i -t"
    }.merge(options || {})
    command = "#{sendmail_settings['location']} #{sendmail_settings['arguments']}"
    IO.popen(command, "w+") do |f|
      content.each do |line|
          f.print(line, "\r\n")
      end
      f.flush
    end
    nil
  end

  # Performs email delivery through NNTP.
  # @return [NilClass] nil
  def perform_delivery_nntp(content, nntp_settings)
    require 'nntp'
    Net::NNTP.start(nntp_settings['address'], nntp_settings['port']) do |nntp|
        nntp.post content
    end
    nil
  end

  # Creates email message and sends it using configured delivery method.
  # @return [NilClass] nil
  def send
    to_tag = config['delivery_method'] == 'nntp' ? 'Newsgroups' : 'To'
    quoted_from_alias = !@from_alias.nil? ? quote_if_necessary("#{@from_alias}",'utf-8') : nil
    from = (@from_alias.nil? || @from_alias.empty?) ? @from_address : "#{quoted_from_alias} <#{@from_address}>"
    reply_to = (@from_alias.nil? || !config['reply_to_author']) ? @reply_to_address : "#{@from_alias} <#{@reply_to_address}>"

    plaintext = if config['add_plaintext'].nil? || config['add_plaintext']
      @text_message
    else
      "Plain text part omitted. Consider setting add_plaintext in configuration."
    end

    content = []
    content << "From: #{from}"  unless from.nil?
    content << "Reply-To: #{reply_to}"  unless reply_to.nil?

    # Setting the email date from the commit date is undesired by those
    # who sort their email by send date instead of receive date.
    # We currently use @offset_date, which starts with the time the notifier was started,
    # and adds a second of time per commit. This should result in the commits arriving
    # in order by their processing sequence, even when they are all processed within the
    # same second
    #date = @commit_date    # Date of the commit
    #date = @current_date   # Date we processed this commit
    date = @offset_date     # Date notifier started, plus 1 second per commit processed
    date = Time.new.rfc2822 if date.nil?    # Fallback to current date if date is nil

    content.concat [
        "#{to_tag}: #{quote_if_necessary(@recipient, 'utf-8')}",
        "Date: #{date}",
        "Subject: #{quote_if_necessary(@subject, 'utf-8')}",
        "X-Mailer: git-commit-notifier",
        "X-Git-Repository: #{@repo_name}",
        "X-Git-Refname: #{@ref_name}",
        "X-Git-Oldrev: #{@old_rev}",
        "X-Git-Newrev: #{@new_rev}",
        "Mime-Version: 1.0",
        "Content-Type: multipart/alternative; boundary=#{boundary}",
        "",
        "--#{boundary}",
        "Content-Type: text/plain; charset=utf-8",
        "Content-Transfer-Encoding: quoted-printable",
        "Content-Disposition: inline",
        "",
        encode_quoted_printable_message(plaintext),
        "--#{boundary}",
        "Content-Type: text/html; charset=utf-8",
        "Content-Transfer-Encoding: quoted-printable",
        "Content-Disposition: inline",
        "",
        encode_quoted_printable_message(mail_html_message),
        "--#{boundary}--"]

    if @recipient.empty?
      puts content.join("\n")
      return
    end

    case config['delivery_method'].to_sym
    when :smtp then perform_delivery_smtp(content, config['smtp_server'])
    when :nntp then perform_delivery_nntp(content, config['nntp_settings'])
    when :debug then perform_delivery_debug(content)
    else # sendmail
      perform_delivery_sendmail(content, config['sendmail_options'])
    end
    nil
  end

  # Convert a message into quoted printable encoding,
  # limiting line length to 76 characters per spec.
  # Encoding messages in this way ensures that they
  # won't violate rules for maximum line length, which
  # can result in the MTA breaking lines at inconvenient points,
  # such as in the middle of UTF8 characters.
  def encode_quoted_printable_message(text)
    str = ''
    # Character encoding of output string can be plain US-ASCII since quoted-printable is plain ASCII
    str.force_encoding("US-ASCII")  if str.respond_to?(:force_encoding)
    StringIO.open(str, "w") do |output|
      line_max = 76
      line_len = 0

      input = StringIO.new(text, "r")
      input.each_byte do |b|
        case (b)
        when 9, 32..60, 62..126
          if line_len >= line_max - 1
            output << "=\r\n"
            line_len = 0
          end
          output << b.chr
          line_len += 1
        else
          if line_len >= line_max - 3
            output << "=\r\n"
            line_len = 0
          end
          output << "=%02X" % b
          line_len += 3
        end
      end

      output << "=\r\n" if line_len > 0
      output.string
    end
  end

  # Convert the given text into quoted printable format, with an instruction
  # that the text be eventually interpreted in the given charset.
  def quoted_printable(text, charset)
    text = text.gsub( /[^a-z ]/i ) { quoted_printable_encode($&) }.
                gsub( / /, "_" )
    "=?#{charset}?Q?#{text}?="
  end

  # Convert the given character to quoted printable format, taking into
  # account multi-byte characters (if executing with $KCODE="u", for instance)
  def quoted_printable_encode(character)
    result = ""
    character.each_byte { |b| result << "=%02X" % b }
    result
  end

  # A quick-and-dirty regexp for determining whether a string contains any
  # characters that need escaping.
  CHARS_NEEDING_QUOTING = /[^\x0a\x0d\x20-\x7e]/

  # Quote the given text if it contains any "illegal" characters
  def quote_if_necessary(text, charset)
    text = text.dup.force_encoding(Encoding::ASCII_8BIT) if text.respond_to?(:force_encoding)

    (text =~ CHARS_NEEDING_QUOTING) ?
      quoted_printable(text, charset) :
      text
  end
end

