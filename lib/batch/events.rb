class Batch

    # Manages batch event notifications and subscriptions
    class Events

        # Records subscription details
        class Subscription

            attr_reader :source, :callback


            def initialize(source, callback)
                @source = source
                @callback = callback
            end


            def ===(obj)
                @source.nil? || (@source == obj) || (@source === obj) ||
                    (@source.instance_of?(Module) && obj.instance_of?(Class) && obj.include?(@source)) ||
                    (obj.respond_to?(:job) && @source === obj.job)
            end

        end



        class << self

            # @param source [Object] The source of the event
            # @param event [String] The name of the event
            # @return [Boolean] whether there are any subscribers for the specified
            #   event.
            def has_subscribers?(source, event)
                subscribers.has_key?(event) && subscribers[event].size > 0 &&
                    subscribers[event].find{ |sub| sub === source }
            end


            # Setup a subscription for a particular event. When a matching event
            # occurs, the supplied block will be called with the published
            # arguments.
            #
            # @param source [Object] The type of source object from which to
            #   listen for events.
            # @param event [String] The name of the event to subscribe to.
            # @param position [Fixnum] The position within the list to insert
            #   the subscriber. Default is to add to the end of the list.
            # @param callback [Proc] A block to be invoked when the event occurs.
            def subscribe(source, event, position = -1, &callback)
                @log.trace "Adding subscriber for #{source} event '#{event}'" if @log
                subscribers[event].insert(position, Subscription.new(source, callback))
            end


            # Remove a subscriber
            #
            # @param source [Object] The object that is the source of the event
            #   from which to unsubscribe.
            # @param event [String] The name of the event to unsubscribe from.
            def unsubscribe(source, event)
                @log.trace "Removing subscriber(s) for #{source} event '#{event}'" if @log
                subscribers[event].delete_if{ |sub| sub === source }
            end


            # Publishes an event to all registered subscribers.
            #
            # @param source [Object] The source from which the event has been
            #   generated.
            # @param event [String] The name of the event that has occurred.
            # @param payload [*Object] Arguments passed with the event.
            def publish(source, event, *payload)
                @log.trace "Publishing event '#{event}' for #{source}" if @log
                res = true
                count = 0
                if subscribers.has_key?(event)
                    subscribers[event].each do |sub|
                        if sub === source
                            begin
                                r = sub.callback.call(source, *payload)
                                count += 1
                                res &&= r
                            rescue StandardError => ex
                                STDERR.puts "Exception in '#{event}' event listener for #{source}: #{ex}\n" +
                                    "  at: #{ex.backtrace[0...10].join("\n")}"
                            end
                        end
                    end
                    @log.debug "Notified #{count} listeners of '#{event}'" if @log
                end
                res
            end


            # Enable/disable event debugging
            def debug=(dbg)
                @log = dbg ? Batch::LogManager.logger('batch.events') : nil
            end


            # Dumps a list of events and their subscribers to the logger
            def dump_subscribers(show_event = nil, log = @log)
                if log
                    subscribers.each do |event, subs|
                        if show_event.nil? || show_event == event
                            log.info "Subscribers for event '#{event}':"
                            subs.each{ |sub| log.detail sub.inspect }
                        end
                    end
                end
            end


            private

            def subscribers
                @subscribers ||= Hash.new{ |h, k| h[k] = [] }
            end

        end

    end

end
