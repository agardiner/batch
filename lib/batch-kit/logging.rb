require 'fileutils'


class BatchKit

    module Logging

        # Log levels available
        LEVELS = [:error, :warning, :info, :config, :detail, :trace, :debug]

        # Supported logging frameworks
        FRAMEWORKS = [
            :null,
            :stdout,
            :log4r,
            :java_util_logging
        ]

        # Method aliasing needed to provide log methods corresponding to levels
        FRAMEWORK_INIT = {
            null: lambda{
                require_relative 'logging/null_logger'
            },
            stdout: lambda{
                require_relative 'logging/stdout_logger'
            },
            java_util_logging: lambda{
                require_relative 'logging/java_util_logger'
            },
            log4r: lambda{
                require_relative 'logging/log4r_logger'
            }
        }

    end


    # Used for setting the log framework to use, and retrieving a logger
    # from the current framework.
    class LogManager

        class << self

            def configure(options = {})
                self.log_framework = options[:log_framework] if options[:log_framework]
                if options.fetch(:log_color, true)
                    case self.log_framework
                    when :log4r
                        require 'color_console/log4r_logger'
                        Console.replace_console_logger(logger: 'batch-kit')
                    when :java_util_logging
                        require 'color_console/java_util_logger'
                        Console.replace_console_logger(
                            level: Java::JavaUtilLogging::Level::FINE,
                            level_labels: {
                                Java::JavaUtilLogging::Level::FINE => 'DETAIL',
                                Java::JavaUtilLogging::Level::FINER => 'TRACE'
                            })
                    else
                        require 'color_console'
                    end
                end
            end


            # Returns a symbol identifying which logging framework is being used.
            def log_framework
                unless @log_framework
                    if RUBY_PLATFORM == 'java'
                        LogManager.log_framework = :java_util_logging
                    else
                        begin
                            require 'log4r'
                            LogManager.log_framework = :log4r
                        rescue LoadError
                            LogManager.log_framework = :stdout
                        end
                    end
                end
                @log_framework
            end


            # Sets the logging framework
            def log_framework=(framework)
                unless Logging::FRAMEWORKS.include?(framework)
                    raise ArgumentError, "Unknown logging framework #{framework.inspect}"
                end
                if @log_framework
                    lvl = self.level
                end
                @log_framework = framework
                if init_proc = Logging::FRAMEWORK_INIT[@log_framework]
                    init_proc.call
                end
                self.level = lvl if lvl
                logger.trace "Log framework is #{@log_framework}"
            end


            # Returns the current root log level
            def level
                logger.level
            end


            # Sets the log level
            def level=(level)
                case log_framework
                when :log4r
                    lvl = Log4r::LNAMES.index(level.to_s.upcase)
                    Log4r::Logger.each_logger{ |l| l.level = lvl }
                else
                    logger.level = level
                end
            end


            # Returns a logger with a given name, which must be under the 'batch-kit'
            # namespace. If name is omitted, the logger is named 'batch-kit'. If a
            # name is specified that is not under 'batch-kit', then it is prepended
            # with 'batch-kit'.
            #
            # @return [Logger] a logger object that can be used for generating
            #   log messages. The type of logger returned will depend on the
            #   log framework being used, but the logger is guaranteed to
            #   implement the following log methods:
            #   - error
            #   - warning
            #   - info
            #   - config
            #   - detail
            #   - trace
            #   - debug
            def logger(name = nil)
                case name
                when NilClass, ''
                    name = 'batch-kit'
                when /^batch-kit/
                when /\./
                when String
                    name = "batch-kit.#{name}"
                end
                case log_framework
                when :stdout
                    BatchKit::Logging::StdOutLogger.logger(name)
                when :java_util_logging
                    BatchKit::Logging::JavaLogFacade.new(Java::JavaUtilLogging::Logger.getLogger(name))
                when :log4r
                    log4r_name = name.gsub('.', '::')
                    BatchKit::Logging::Log4rFacade.new(Log4r::Logger[log4r_name] ||
                                                    Log4r::Logger.new(log4r_name))
                else BatchKit::Logging::NullLogger.instance
                end
            end

        end


        if defined?(Events) && defined?(Configurable)
            Events.subscribe(Configurable, 'post-configure') do |src, cfg|
                LogManager.configure(cfg)
            end
        end

    end

end

