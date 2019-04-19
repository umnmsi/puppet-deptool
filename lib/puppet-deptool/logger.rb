module PuppetDeptool
  module Logger

    class << self; attr_accessor :debug, :verbose, :quiet; end

    def debug_write(message)
      STDOUT.write message if Logger.debug
    end

    def debug(message)
      puts message if Logger.debug
    end

    def info(message)
      puts message if Logger.verbose || Logger.debug
    end

    def warn(message)
      @warnings_encountered = true
      STDERR.puts red message unless Logger.quiet
    end

    # Enable printing red text
    def red(message)
      "\e[31m#{message}\e[0m"
    end
  end
end
