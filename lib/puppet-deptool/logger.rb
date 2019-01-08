module PuppetDeptool
  module Logger
    def debug_write(message)
      STDOUT.write message if @debug
    end

    def debug(message)
      puts message if @debug
    end

    def info(message)
      puts message if @verbose || @debug
    end

    def warn(message)
      @warnings_encountered = true
      STDERR.puts red message unless @quiet
    end

    # Enable printing red text
    def red(message)
      "\e[31m#{message}\e[0m"
    end
  end
end
