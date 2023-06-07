# encoding: utf-8
require_relative '../plugin_mixins/rabbitmq_connection'
require 'logstash/inputs/threadable'
require 'logstash/event'

module LogStash
  module Inputs
    # Pull events from a http://www.rabbitmq.com/[RabbitMQ] queue.
    #
    # The default settings will create an entirely transient queue and listen for all messages by default.
    # If you need durability or any other advanced settings, please set the appropriate options
    #
    # This plugin uses the http://rubymarchhare.info/[March Hare] library
    # for interacting with the RabbitMQ server. Most configuration options
    # map directly to standard RabbitMQ and AMQP concepts. The
    # https://www.rabbitmq.com/amqp-0-9-1-reference.html[AMQP 0-9-1 reference guide]
    # and other parts of the RabbitMQ documentation are useful for deeper
    # understanding.
    #
    # The properties of messages received will be stored in the
    # `[@metadata][rabbitmq_properties]` field if the `@metadata_enabled` setting is checked.
    # Note that storing metadata may degrade performance.
    # The following properties may be available (in most cases dependent on whether
    # they were set by the sender):
    #
    # * app-id
    # * cluster-id
    # * consumer-tag
    # * content-encoding
    # * content-type
    # * correlation-id
    # * delivery-mode
    # * exchange
    # * expiration
    # * message-id
    # * priority
    # * redeliver
    # * reply-to
    # * routing-key
    # * timestamp
    # * type
    # * user-id
    #
    # For example, to get the RabbitMQ message's timestamp property
    # into the Logstash event's `@timestamp` field, use the date
    # filter to parse the `[@metadata][rabbitmq_properties][timestamp]`
    # field:
    # [source,ruby]
    #     filter {
    #       if [@metadata][rabbitmq_properties][timestamp] {
    #         date {
    #           match => ["[@metadata][rabbitmq_properties][timestamp]", "UNIX"]
    #         }
    #       }
    #     }
    #
    # Additionally, any message headers will be saved in the
    # `[@metadata][rabbitmq_headers]` field.
    class RabbitMQ < LogStash::Inputs::Threadable

      java_import java.util.concurrent.TimeUnit

      include ::LogStash::PluginMixins::RabbitMQConnection

      # The properties to extract from each message and store in a
      # @metadata field.
      #
      # Technically the exchange, redeliver, and routing-key
      # properties belong to the envelope and not the message but we
      # ignore that distinction here. However, we extract the
      # headers separately via get_headers even though the header
      # table technically is a message property.
      #
      # Freezing all strings so that code modifying the event's
      # @metadata field can't touch them.
      #
      # If updating this list, remember to update the documentation
      # above too.
      MESSAGE_PROPERTIES = [
        "app-id",
        "cluster-id",
        "consumer-tag",
        "content-encoding",
        "content-type",
        "correlation-id",
        "delivery-mode",
        "exchange",
        "expiration",
        "message-id",
        "priority",
        "redeliver",
        "reply-to",
        "routing-key",
        "timestamp",
        "type",
        "user-id",
      ].map { |s| s.freeze }.freeze

      INTERNAL_QUEUE_POISON=[]

      config_name "rabbitmq"

      # The default codec for this plugin is JSON. You can override this to suit your particular needs however.
      default :codec, "json"

      # The name of the queue Logstash will consume events from. If
      # left empty, a transient queue with an randomly chosen name
      # will be created.
      config :queue, :validate => :string, :default => ""

      # Is this queue durable? (aka; Should it survive a broker restart?)
      config :durable, :validate => :boolean, :default => false

      # Should the queue be deleted on the broker when the last consumer
      # disconnects? Set this option to `false` if you want the queue to remain
      # on the broker, queueing up messages until a consumer comes along to
      # consume them.
      config :auto_delete, :validate => :boolean, :default => false

      # Is the queue exclusive? Exclusive queues can only be used by the connection
      # that declared them and will be deleted when it is closed (e.g. due to a Logstash
      # restart).
      config :exclusive, :validate => :boolean, :default => false

      config :arguments, :validate => :array, :default => {}

      # Prefetch count. If acknowledgements are enabled with the `ack`
      # option, specifies the number of outstanding unacknowledged
      # messages allowed.
      config :prefetch_count, :validate => :number, :default => 256

      # Enable message acknowledgements. With acknowledgements
      # messages fetched by Logstash but not yet sent into the
      # Logstash pipeline will be requeued by the server if Logstash
      # shuts down. Acknowledgements will however hurt the message
      # throughput.
      #
      # This will only send an ack back every `prefetch_count` messages.
      # Working in batches provides a performance boost here.
      config :ack, :validate => :boolean, :default => true

      # If true the queue will be passively declared, meaning it must
      # already exist on the server. To have Logstash create the queue
      # if necessary leave this option as false. If actively declaring
      # a queue that already exists, the queue options for this plugin
      # (durable etc) must match those of the existing queue.
      config :passive, :validate => :boolean, :default => false

      # The name of the exchange to bind the queue to. Specify `exchange_type`
      # as well to declare the exchange if it does not exist
      config :exchange, :validate => :string

      # The type of the exchange to bind to. Specifying this will cause this plugin
      # to declare the exchange if it does not exist.
      config :exchange_type, :validate => :string

      # The routing key to use when binding a queue to the exchange.
      # This is only relevant for direct or topic exchanges.
      #
      # * Routing keys are ignored on fanout exchanges.
      # * Wildcards are not valid on direct exchanges.
      config :key, :validate => :string, :default => "logstash"

      # Amount of time in seconds to wait after a failed subscription request
      # before retrying. Subscribes can fail if the server goes away and then comes back.
      config :subscription_retry_interval_seconds, :validate => :number, :required => true, :default => 5

      # Enable the storage of message headers and properties in `@metadata`. This may impact performance
      config :metadata_enabled, :validate => %w(none basic extended false true), :default => "none"

      def register
        @internal_queue = java.util.concurrent.ArrayBlockingQueue.new(@prefetch_count*2)
        @metadata_level = extract_metadata_level(@metadata_enabled)
      end

      attr_reader :metadata_level

      def run(output_queue)
        setup!
        @output_queue = output_queue
        consume!
      rescue => e
        raise(e) unless stop?

        @logger.warn("Ignoring exception thrown during plugin shutdown", error_details(e))
      end

      def setup!
        connect!
        declare_queue!
        bind_exchange!
        @hare_info.channel.prefetch = @prefetch_count
      rescue => e
        # when encountering an exception during shut-down,
        # re-raise the exception instead of retrying
        raise if stop?

        reset!

        @logger.warn("Error while setting up connection, will retry", error_details(e))
        sleep_for_retry
        retry
      end

      # reset a partially-established connection, enabling subsequent
      # call to `RabbitMQ#setup!` to succeed.
      #
      # @api private
      def reset!
        @hare_info.connection && @hare_info.connection.close
      rescue => e
        @logger.debug("Exception while resetting connection", error_details(e))
      ensure
        @hare_info = nil
      end

      def bind_exchange!
        if @exchange
          if @exchange_type # Only declare the exchange if @exchange_type is set!
            @logger.info? && @logger.info("Declaring exchange '#{@exchange}' with type #{@exchange_type}")
            @hare_info.exchange = declare_exchange!(@hare_info.channel, @exchange, @exchange_type, @durable)
          end
          @hare_info.queue.bind(@exchange, :routing_key => @key)
        end
      end

      def declare_queue!
        @hare_info.queue = declare_queue()
      end

      def declare_queue
        @hare_info.channel.queue(@queue,
                                 :durable     => @durable,
                                 :auto_delete => @auto_delete,
                                 :exclusive   => @exclusive,
                                 :passive     => @passive,
                                 :arguments   => @arguments)
      end

      def consume!
        @consumer = @hare_info.queue.build_consumer(:on_cancellation => Proc.new { on_cancellation }) do |metadata, data|
          @internal_queue.put [metadata, data]
        end

        begin
          @hare_info.queue.subscribe_with(@consumer, :manual_ack => @ack)
        rescue => e
          @logger.warn("Could not subscribe to queue, will retry in #{@subscription_retry_interval_seconds} seconds", error_details(e, :queue => @queue))

          sleep @subscription_retry_interval_seconds
          retry
        end

        internal_queue_consume!
      end

      def internal_queue_consume!
        i=0
        last_delivery_tag=nil
        while true
          payload = @internal_queue.poll(10, TimeUnit::MILLISECONDS)
          if !payload  # Nothing in the queue
            if last_delivery_tag # And we have unacked stuff
              @hare_info.channel.ack(last_delivery_tag, true) if @ack
              i=0
              last_delivery_tag = nil
            end
            next
          end

          break if payload == INTERNAL_QUEUE_POISON

          metadata, data = payload
          @codec.decode(data) do |event|
            if event
              decorate(event, metadata, data)

              @output_queue << event
            end
          end

          i += 1

          if i >= @prefetch_count
            @hare_info.channel.ack(metadata.delivery_tag, true) if @ack
            i = 0
            last_delivery_tag = nil
          else
            last_delivery_tag = metadata.delivery_tag
          end
        end
      end

      def decorate(event, metadata, data)
        super(event)

        event.set("[@metadata][rabbitmq_headers]", get_headers(metadata))       if metadata_level.include?(:headers)
        event.set("[@metadata][rabbitmq_properties]", get_properties(metadata)) if metadata_level.include?(:properties)
        event.set("[@metadata][rabbitmq_payload]", data)                        if metadata_level.include?(:payload) && !data.nil?

        nil
      end

      def stop
        @internal_queue.put(INTERNAL_QUEUE_POISON)
        shutdown_consumer
        close_connection
      end

      def shutdown_consumer
        # There are two possible flows to shutdown consumers. When the plugin is the one shutting down, it should send a channel
        # cancellation message by invoking channel.basic_cancel(consumer_tag) and waiting for the consumer to terminate
        # (broker replies with an basic.cancel-ok). This back and forth is handled by MarchHare. On the other hand, when the broker
        # requests the client to shutdown (eg. due to queue deletion). It sends to the client a basic.cancel message, which is handled
        # internally by the client, unregistering the consumer and then invoking the :on_cancellation callback. In that case, the plugin
        # should not do anything as the consumer is already cancelled/unregistered.
        return if !@consumer || @consumer.cancelled? || @consumer.terminated?

        @hare_info.channel.basic_cancel(@consumer.consumer_tag)
        connection = @hare_info.connection
        until @consumer.terminated?
          @logger.info("Waiting for RabbitMQ consumer to terminate before stopping", url: connection_url(connection))
          sleep 1
        end
      end

      def on_cancellation
        if !stop? # If this isn't already part of a regular stop
          connection = @hare_info.connection
          @logger.info("Received cancellation, shutting down", url: connection_url(connection))
          stop
        end
      end

      private
      def get_headers(metadata)
	metadata.headers || {}
      end

      private
      def get_properties(metadata)
        MESSAGE_PROPERTIES.reduce({}) do |acc, name|
          # The method names obviously can't contain hyphens.
          value = metadata.send(name.gsub("-", "_"))
          if value
            # The AMQP 0.9.1 timestamp field only has second resolution
            # so storing milliseconds serves no purpose and might give
            # the incorrect impression of a higher resolution.
            acc[name] = name != "timestamp" ? value : value.getTime / 1000
          end
          acc
        end
      end

      METADATA_NONE     = Set[].freeze
      METADATA_BASIC    = Set[:headers,:properties].freeze
      METADATA_EXTENDED = Set[:headers,:properties,:payload].freeze
      METADATA_DEPRECATION_MAP = { 'true' => 'basic', 'false' => 'none' }

      private
      def extract_metadata_level(metadata_enabled_setting)
        metadata_enabled = metadata_enabled_setting

        if METADATA_DEPRECATION_MAP.include?(metadata_enabled)
          canonical_value = METADATA_DEPRECATION_MAP[metadata_enabled]
          logger.warn("Deprecated value `#{metadata_enabled_setting}` for `metadata_enabled` option; use `#{canonical_value}` instead.")
          metadata_enabled = canonical_value
        end

        case metadata_enabled
        when 'none'     then METADATA_NONE
        when 'basic'    then METADATA_BASIC
        when 'extended' then METADATA_EXTENDED
        end
      end
    end
  end
end
