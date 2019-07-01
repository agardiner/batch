require 'set'
require_relative 'events'


class BatchKit

    # Defines a manager for resource types, such as database connections etc.
    # Resource types are registered with this class, which then adds acquisition
    # methods to the ResourceHelper module. These acquisition methods add the
    # acquired objects to a collection managed by the objects of the class that
    # includes the ResourceHelper, and modify the returned resource objects so
    # that they automatically de-register themselves if they are disposed of
    # explicitly.
    class ResourceManager

        class << self

            # Returns an unbound method object that represents the method that
            # should be called to dispose of +rsrc+.
            def disposal_method(rsrc)
                disp_mthd = resource_types[rsrc.class] || resource_types.find{ |rt, _| rt === rsrc }.last rescue nil
                disp_mthd or raise ArgumentError, "No registered resource class matches '#{rsrc.class}'"
            end


            # Register a resource type for automated resource management.
            #
            # @param rsrc_cls [Class] The class of resource to be managed. This
            #   must be the type of the object that will be returned when an
            #   instance of this resource is acquired.
            # @param helper_mthd [Symbol] The name of the resource acquisition
            #   helper method that should be added to the ResourceHelper module.
            # @param options [Hash] An options class.
            # @option options [Symbol] :acquisition_method For cases where an
            #   existing method can be called directly on the +rsrc_cls+ to
            #   obtain a resource (rather than passing in a block containing
            #   resource acquisition steps), the name of that method. Defaults
            #   to :open.
            # @option options [Symbol] :disposal_method The name of the method
            #   to be called on the resource to dispose of it. Defaults to
            #   :close.
            def register(rsrc_cls, helper_mthd, options = {}, &body)
                if ResourceHelper.method_defined?(helper_mthd)
                    raise ArgumentError, "Resource acquisition method #{helper_mthd} is already registered"
                end
                unless body
                    open_mthd = options.fetch(:acquisition_method, :open)
                    body = lambda{ |*args| rsrc_cls.send(open_mthd, *args) }
                end
                disp_mthd = options.fetch(:disposal_method, :close)

                if rsrc_cls.method_defined?(disp_mthd)
                    if (m = resource_types[rsrc_cls]) && m.name != disp_mthd
                        raise ArgumentError, "Resource class #{rsrc_cls} has already been registered" +
                            " with a different disposal method (##{m.name})"
                    else
                        resource_types[rsrc_cls] = rsrc_cls.instance_method(disp_mthd)
                    end
                else
                    raise ArgumentError, "No method named '#{disp_mthd}' is defined on #{rsrc_cls}"
                end

                # Define the helper method on the ResourceHelper module. This is
                # necessary (as opposed to just calling the block from the
                # acquisition methd) in order to ensure that self etc are set
                # correctly
                ResourceHelper.class_eval{ define_method(helper_mthd, &body) }

                # Now wrap an aspect around the method to handle the tracking of
                # resources acquired, and event notifications
                add_aspect(rsrc_cls, helper_mthd, disp_mthd)
                Events.publish(self, 'resource.registered', rsrc_cls, helper_mthd)
            end


            private


            def resource_types
                @resource_types ||= {}
            end


            # Define the helper method to acquire a resource, publish events about
            # the resource lifecycle, and track the usage of the resource to
            # ensure we know about unreleased resources and can clean then up at
            # the appropriate time when the owning object is done with them.
            def add_aspect(rsrc_cls, helper_mthd, disp_mthd)
                mthd = ResourceHelper.instance_method(helper_mthd)
                ResourceHelper.class_eval do
                    define_method helper_mthd do |*args|
                        if Events.publish(rsrc_cls, 'resource.pre_acquire', *args)
                            result = nil
                            begin
                                result = mthd.bind(self).call(*args)
                                unless rsrc_cls === result
                                    raise ArgumentError, "Returned resource is of type #{
                                        result.class.name}, not #{rsrc_cls}"
                                end
                                # Override disposal method on this acquired instance
                                # to call #dispose_resource instead
                                defn = self
                                result.define_singleton_method(disp_mthd) do
                                    defn.dispose_resource(self)
                                end
                                add_resource(result)
                                Events.publish(rsrc_cls, 'resource.acquired', result)
                                result
                            rescue Exception => ex
                                Events.publish(rsrc_cls, 'resource.acquisition_failed', ex)
                                raise
                            end
                        end
                    end
                end
            end

        end

    end



    # A module that can be included in a class to provide resource acquisition
    # with automated resource cleanup.
    #
    # Resources acquired via this module are tracked, and can be disposed of
    # when no longer needed via a call to the #cleanup_resources method.
    #
    # The benefits of including and using ResourceHelper module:
    # - Resource acquisition can be setup to use a common configuration process,
    #   such as obtaining connection details from a shared configuration file.
    # - All resources obtained by an object can be freed when the object is
    #   done with them by calling the #cleanup_resources.
    module ResourceHelper

        # Register a resource for later clean-up
        def add_resource(rsrc)
            # Ensure we know how to dispose of this resource
            ResourceManager.disposal_method(rsrc)
            (@__resources__ ||= Set.new) << rsrc
        end


        # Dispose of a resource.
        #
        # This method will be called automatically whenever a resource is closed
        # manually (via a call to the resources normal disposal method, e.g.
        # #close), or when #cleanup_resources is used to tidy-up all managed
        # resources.
        def dispose_resource(rsrc)
            disp_mthd = ResourceManager.disposal_method(rsrc)
            @__resources__.delete(rsrc)
            if Events.publish(rsrc, 'resource.pre-disposal')
                begin
                    disp_mthd.bind(rsrc).call
                    Events.publish(rsrc, 'resource.disposed')
                rescue Exception => ex
                    Events.publish(rsrc, 'resource.disposal-failed', ex)
                    raise
                end
            end
        end


        # Dispose of all resources managed by this object.
        def cleanup_resources
            if @__resources__
                @__resources__.clone.reverse_each do |rsrc|
                    dispose_resource(rsrc)
                end
                @__resources__ = nil
            end
        end


        # Add automatic disposal of resources on completion of job if included
        # into a job.
        def self.included(cls)
            if (defined?(BatchKit::Job) && BatchKit::Job == cls) ||
                (defined?(BatchKit::ActsAsJob) && cls.include?(BatchKit::ActsAsJob))
                Events.subscribe(BatchKit::Job::Run, 'post-execute') do |run, job_obj, ok|
                    job_obj.cleanup_resources
                end
            end
        end

    end

end
