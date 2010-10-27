require File.expand_path('../../spec_helper', __FILE__)
require 'emailer'

describe Emailer do

  describe :new do
    it "should assign config if given" do
      Emailer.new({:a => :b}).config[:a].should == :b
    end

    it "should use empty hash unless config given" do
      cfg = Emailer.new(false).config
      cfg.should be_kind_of(Hash)
      cfg.should be_empty
    end

    it "should not generate message from template" do
      any_instance_of(Emailer) do |emailer|
        dont_allow(emailer).generate_message
      end
      Emailer.new({})
    end

    it "should assign parameters from options" do
      options = {}
      Emailer::PARAMETERS.each do |name|
        options[name.to_sym] = Faker::Lorem.sentence
      end
      emailer = Emailer.new({}, options)
      options.each_pair do |key, value|
        emailer.instance_variable_get("@#{key}").should == value
      end
    end
  end

  describe :stylesheet_string do
    it "should return default stylesheet if custom is not provided" do
      emailer = Emailer.new({})
      mock(IO).read(Emailer::DEFAULT_STYLESHEET_PATH) { 'ok' }
      emailer.stylesheet_string.should == 'ok'
    end

    it "should return custom stylesheet if custom is provided" do
      emailer = Emailer.new({'stylesheet' => '/path/to/custom/stylesheet'})
      mock(IO).read('/path/to/custom/stylesheet') { 'ok' }
      dont_allow(IO).read(Emailer::DEFAULT_STYLESHEET_PATH)
      emailer.stylesheet_string.should == 'ok'
    end
  end
end

