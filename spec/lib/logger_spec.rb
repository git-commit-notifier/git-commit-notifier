require File.expand_path('../spec_helper.rb', File.dirname(__FILE__))
require 'logger'

describe Logger do

  describe :debug? do
    it "should be false unless debug section exists" do
      logger = Logger.new({})
      logger.should_not be_debug
    end

    it "should be false unless debug/enabled" do
      logger = Logger.new("debug" => { "enabled" => false })
      logger.should_not be_debug
    end

    it "should be true if debug/enabled" do
      logger = Logger.new("debug" => { "enabled" => true })
      logger.should be_debug
    end
  end

  describe :log_directory do
    it "should be nil unless debug?" do
      logger = Logger.new({})
      logger.should_not be_debug
      logger.log_directory.should be_nil
    end

    it "should be custom if debug and custom directory specified" do
      expected = Faker::Lorem.sentence
      logger = Logger.new("debug" => { "enabled" => true, "log_directory" => expected})
      logger.log_directory.should == expected
    end

    it "should be default log directory if debug and custom directory not specified" do
      logger = Logger.new("debug" => { "enabled" => true })
      logger.log_directory.should == Logger::DEFAULT_LOG_DIRECTORY
    end
  end

  describe :log_path do
    it "should be nil unless debug?" do
      logger = Logger.new({})
      mock(logger).debug? { false }
      logger.log_path.should be_nil
    end

    it "should be path in log_directory if debug?" do
      logger = Logger.new("debug" => { "enabled" => true })
      File.dirname(logger.log_path).should == logger.log_directory
    end

    it "should points to LOG_NAME if debug?" do
      logger = Logger.new("debug" => { "enabled" => true })
      File.basename(logger.log_path).should == Logger::LOG_NAME
    end
  end
end

__END__

 vim: tabstop=2 expandtab shiftwidth=2
