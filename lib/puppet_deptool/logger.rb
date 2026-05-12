# frozen_string_literal: true

module PuppetDeptool
  module Logger
    class << self
      attr_writer :level

      def level
        @level ||= 1
      end
    end

    def trace_write(message)
      $stdout.write message if Logger.level >= 4
    end

    def trace(message)
      puts message if Logger.level >= 4
    end

    def debug(message)
      puts message if Logger.level >= 3
    end

    def info(message)
      puts message if Logger.level >= 2
    end

    def warn(message)
      @warnings_encountered = true
      warn red message if Logger.level >= 1
    end

    # Enable printing red text
    def red(message)
      "\e[31m#{message}\e[0m"
    end
  end
end
