# encoding: UTF-8
require "logstash/pipeline"
require_relative '../plugin_mixins/rabbitmq_connection'

require 'back_pressure'

# Push events to a RabbitMQ exchange. Requires RabbitMQ 2.x
# or later version (3.x is recommended).
#
# Relevant links:
#
# * http://www.rabbitmq.com/[RabbitMQ]
module LogStash
  module Outputs
    class RabbitMQ < LogStash::Outputs::Base

      java_import java.util.concurrent.TimeoutException
      java_import com.rabbitmq.client.AlreadyClosedException
      java_import com.rabbitmq.client.ShutdownSignalException
      java_import com.rabbitmq.client.AMQP

      include LogStash::PluginMixins::RabbitMQConnection

      config_name "rabbitmq"

      concurrency :shared

      # The default codec for this plugin is JSON. You can override this to suit your particular needs however.
      default :codec, "json"

      # Key to route to by default. Defaults to 'logstash'
      #
      # * Routing keys are ignored on fanout exchanges.
      config :key, :validate => :string, :default => "logstash"

      # The name of the exchange
      config :exchange, :validate => :string, :required => true

      # The exchange type (fanout, topic, direct)
      config :exchange_type, :validate => EXCHANGE_TYPES, :required => true

      # Is this exchange durable? (aka; Should it survive a broker restart?)
      config :durable, :validate => :boolean, :default => true

      # Should RabbitMQ persist messages to disk?
      config :persistent, :validate => :boolean, :default => true

      # Properties to be passed along with the message
      config :message_properties, :validate => :hash, :default => {}

      def register
        @message_properties_template = MessagePropertiesTemplate.new(symbolize(@message_properties).merge(:persistent => @persistent))

        connect!
        @hare_info.exchange = declare_exchange!(@hare_info.channel, @exchange, @exchange_type, @durable)
        # The connection close should close all channels, so it is safe to store thread locals here without closing them
        @thread_local_channel = java.lang.ThreadLocal.new

        @gated_executor = back_pressure_provider_for_connection(@hare_info.connection)
      end

      def symbolize(myhash)
        Hash[myhash.map{|(k,v)| [k.to_sym,v]}]
      end

      def multi_receive_encoded(events_and_data)
        events_and_data.each do |event, data|
          publish(event, data)
        end
      end

      def publish(event, message)
        raise ArgumentError, "No exchange set in HareInfo!!!" unless @hare_info.exchange
        routing_key = event.sprintf(@key)
        message_properties = @message_properties_template.build(event)
        @gated_executor.execute do
          local_channel.basicPublish(@hare_info.exchange, routing_key,
                                     build_amqp_properties(message_properties),
                                     message.to_java_bytes)
        end
      rescue ShutdownSignalException, AlreadyClosedException, TimeoutException, IOError, java.io.IOException => e
        @logger.error("Error while publishing, will retry", error_details(e, backtrace: true))

        sleep_for_retry
        retry
      end

      def local_channel
        channel = @thread_local_channel.get
        unless channel
          channel = @hare_info.connection.createChannel
          @thread_local_channel.set(channel)
        end
        channel
      end

      def close
        close_connection
      end

      private

      # Implements com.rabbitmq.client.BlockedListener to hook connection-blocked
      # notifications into a BackPressure::GatedExecutor.
      class BlockedListenerImpl
        include Java::ComRabbitmqClient::BlockedListener

        def initialize(on_blocked, on_unblocked)
          @on_blocked   = on_blocked
          @on_unblocked = on_unblocked
        end

        def handleBlocked(reason)
          @on_blocked.call(reason)
        end

        def handleUnblocked
          @on_unblocked.call
        end
      end

      # Implements com.rabbitmq.client.RecoveryListener to hook automatic-recovery
      # notifications into a BackPressure::GatedExecutor.
      class RecoveryListenerImpl
        include Java::ComRabbitmqClient::RecoveryListener

        def initialize(on_recovery_started, on_recovery)
          @on_recovery_started = on_recovery_started
          @on_recovery         = on_recovery
        end

        def handleRecoveryStarted(recoverable)
          @on_recovery_started.call
        end

        def handleRecovery(recoverable)
          @on_recovery.call
        end
      end

      # When the other end of a RabbitMQ connection is either unwilling or unable to continue reading bytes from
      # its underlying TCP stream, the connection is flagged as "blocked", but attempts to publish onto exchanges
      # using the connection will not block in the client.
      #
      # Here we hook into notifications of connection-blocked state to set up a `BackPressure::GatedExecutor`,
      # which is used elsewhere to prevent runaway writes when publishing to an exchange on a blocked connection.
      def back_pressure_provider_for_connection(connection)
        BackPressure::GatedExecutor.new(description: "RabbitMQ[#{self.id}]", logger: logger).tap do |executor|
          connection.addBlockedListener(BlockedListenerImpl.new(
            proc { |reason| executor.engage_back_pressure("connection flagged as blocked: `#{reason}`") },
            proc { executor.remove_back_pressure('connection flagged as unblocked') }
          ))
          if @automatic_recovery && connection.is_a?(Java::ComRabbitmqClient::Recoverable)
            connection.addRecoveryListener(RecoveryListenerImpl.new(
              proc { executor.engage_back_pressure("connection is being recovered") },
              proc { executor.remove_back_pressure('connection recovered') }
            ))
          end
        end
      end

      def build_amqp_properties(props)
        builder = AMQP::BasicProperties::Builder.new
        builder.deliveryMode(props[:persistent] ? 2 : 1) if props.key?(:persistent)
        builder.priority(props[:priority].to_i)          if props.key?(:priority)
        builder.contentType(props[:content_type])        if props.key?(:content_type)
        builder.contentEncoding(props[:content_encoding]) if props.key?(:content_encoding)
        builder.correlationId(props[:correlation_id].to_s) if props.key?(:correlation_id)
        builder.replyTo(props[:reply_to])                if props.key?(:reply_to)
        builder.expiration(props[:expiration].to_s)      if props.key?(:expiration)
        builder.messageId(props[:message_id].to_s)       if props.key?(:message_id)
        builder.type(props[:type])                       if props.key?(:type)
        builder.userId(props[:user_id])                  if props.key?(:user_id)
        builder.appId(props[:app_id])                    if props.key?(:app_id)
        builder.build
      end

      ##
      # A `MessagePropertiesTemplate` efficiently produces per-event message properties from the
      # provided template Hash.
      #
      # In order to efficiently reuse constant-value objects, returned values may be frozen.
      class MessagePropertiesTemplate
        ##
        # Creates a new `MessagePropertiesTemplate` from the provided `template`
        # @param template [Hash{Symbol=>Object}]
        def initialize(template)
          constant_properties = template.reject { |_,v| templated?(v) }
          variable_properties = template.select { |_,v| templated?(v) }

          @constant_properties = normalize(constant_properties).freeze
          @variable_properties = variable_properties
        end

        ##
        # Builds a property mapping for the given `event`, including templated values.
        #
        # @param event [LogStash::Event]: the event with which to populated templated values, if any.
        # @return [Hash{Symbol=>Object}] a possibly-frozen properties hash for the provided `event`.
        def build(event)
          return @constant_properties if @variable_properties.empty?

          properties = @variable_properties.each_with_object(@constant_properties.dup) do |(k,v), memo|
            memo.store(k, event.sprintf(v))
          end

          return normalize(properties)
        end

        private

        ##
        # Normalize the provided property mapping with respect to the value types the underlying
        # client expects.
        #
        # @api private
        # @param properties [Hash{Symbol=>Object}]: a possibly-frozen Hash whose values may need type-coercion.
        # @return [Hash{Symbol=>Object}]
        def normalize(properties)
          if properties[:priority] && properties[:priority].kind_of?(String)
            properties = properties.merge(:priority => properties[:priority].to_i)
          end

          properties
        end

        ##
        # @api private
        # @param [Object]: an object, which may or may not be a template `String`
        # @return [Boolean]: returns `true` IFF `value` is a template `String`
        def templated?(value)
          value.kind_of?(String) && value.include?('%{')
        end
      end
    end
  end
end
