# encoding: utf-8
require "logstash/namespace"
require "logstash-integration-rabbitmq_jars"
require "java"
require "stud/interval"

java_import com.rabbitmq.client.ConnectionFactory
java_import com.rabbitmq.client.Address
java_import com.rabbitmq.client.ShutdownListener

# Common functionality for the rabbitmq input/output
module LogStash
  module PluginMixins
    module RabbitMQConnection
      EXCHANGE_TYPES = ["fanout", "direct", "topic", "x-consistent-hash", "x-modulus-hash"]

      HareInfo = Struct.new(:connection, :channel, :exchange, :queue)

      def self.included(base)
        base.extend(self)
        base.setup_rabbitmq_connection_config
      end

      def setup_rabbitmq_connection_config
        # RabbitMQ server address(es)
        # host can either be a single host, or a list of hosts
        # i.e.
        #   host => "localhost"
        # or
        #   host => ["host01", "host02]
        #
        # if multiple hosts are provided on the initial connection and any subsequent
        # recovery attempts of the hosts is chosen at random and connected to.
        # Note that only one host connection is active at a time.
        config :host, :validate => :string, :required => true , :list => true

        # RabbitMQ port to connect on
        config :port, :validate => :number, :default => 5672

        # RabbitMQ username
        config :user, :validate => :string, :default => "guest"

        # RabbitMQ password
        config :password, :validate => :password, :default => "guest"

        # The vhost (virtual host) to use. If you don't know what this
        # is, leave the default. With the exception of the default
        # vhost ("/"), names of vhosts should not begin with a forward
        # slash.
        config :vhost, :validate => :string, :default => "/"

        # Enable or disable SSL.
        # Note that by default remote certificate verification is off.
        # Specify ssl_certificate_path and ssl_certificate_password if you need
        # certificate verification
        config :ssl, :validate => :boolean

        # Version of the SSL protocol to use.
        config :ssl_version, :validate => :string, :default => "TLSv1.2"

        # Path to an SSL certificate in PKCS12 (.p12) format used for verifying the remote host
        config :ssl_certificate_path, :validate => :path

        # Password for the encrypted PKCS12 (.p12) certificate file specified in ssl_certificate_path
        config :ssl_certificate_password, :validate => :password

        # Set this to automatically recover from a broken connection. You almost certainly don't want to override this!!!
        config :automatic_recovery, :validate => :boolean, :default => true

        # Time in seconds to wait before retrying a connection
        config :connect_retry_interval, :validate => :number, :default => 1

        # The default connection timeout in milliseconds. If not specified the timeout is infinite.
        config :connection_timeout, :validate => :number

        # Heartbeat delay in seconds. If unspecified no heartbeats will be sent
        config :heartbeat, :validate => :number

        # Passive queue creation? Useful for checking queue existance without modifying server state
        config :passive, :validate => :boolean, :default => false

        # Extra queue arguments as an array.
        # To make a RabbitMQ queue mirrored, use: `{"x-ha-policy" => "all"}`
        config :arguments, :validate => :array, :default => {}
      end

      def conn_str
        "amqp://#{@user}@#{@host}:#{@port}#{@vhost}"
      end

      def close_connection
        @rabbitmq_connection_stopping = true
        @hare_info.channel.close if channel_open?
        @hare_info.connection.close if connection_open?
      end

      def addresses_from_hosts_and_port(hosts, port)
        hosts.map {|host| host.include?(':') ? host : "#{host}:#{port}"}
      end

      def connect!
        @hare_info = connect() unless @hare_info # Don't duplicate the conn!
      rescue java.io.IOException, java.util.concurrent.TimeoutException, com.rabbitmq.client.ShutdownSignalException => e
        message = if e.message.to_s.empty? && e.is_a?(java.io.IOException)
          # IOException with an empty message is probably an instance of
          # these problems:
          # https://github.com/logstash-plugins/logstash-output-rabbitmq/issues/52
          # https://github.com/rabbitmq/rabbitmq-java-client/issues/100
          #
          # Best guess is to help the user understand that there is probably
          # some kind of configuration problem causing the error, but we
          # can't really offer any more detailed hints :\
          "An unknown RabbitMQ error occurred, maybe this is a configuration error (invalid vhost, for example) - please check the RabbitMQ server logs for clues about this failure"
        else
          "RabbitMQ connection error, will retry"
        end

        @logger.error(message, error_details(e))

        sleep_for_retry
        retry
      end

      def channel_open?
        @hare_info && @hare_info.channel && @hare_info.channel.isOpen
      end

      def connection_open?
        @hare_info && @hare_info.connection && @hare_info.connection.isOpen
      end

      private

      def declare_exchange!(channel, exchange, exchange_type, durable)
        @logger.debug? && @logger.debug("Declaring an exchange", :name => exchange, :type => exchange_type, :durable => durable)
        channel.exchangeDeclare(exchange, exchange_type, durable)
        exchange
      rescue => e
        @logger.error("Could not declare exchange", error_details(e, :exchange => exchange, :type => exchange_type, :durable => durable))
        raise e
      end

      def connect
        @logger.debug? && @logger.debug("Connecting to RabbitMQ", :hosts => @host, :port => @port, :vhost => @vhost)

        factory = ConnectionFactory.new
        factory.setUsername(@user)
        factory.setPassword(@password.value)
        factory.setVirtualHost(@vhost)
        factory.setRequestedHeartbeat(@heartbeat || 0)
        factory.setConnectionTimeout(@connection_timeout || 0)
        factory.setAutomaticRecoveryEnabled(@automatic_recovery)
        factory.setExceptionHandler(com.rabbitmq.client.impl.ForgivingExceptionHandler.new)

        configure_ssl!(factory) if @ssl

        addresses = addresses_from_hosts_and_port(@host, @port).map do |addr|
          parts = addr.split(':')
          Address.new(parts[0], parts[1].to_i)
        end.to_java(Address)

        connection = factory.newConnection(addresses)
        connection.addShutdownListener(proc { |cause|
          @logger.warn("RabbitMQ connection was closed",
                       :url => connection_url(connection),
                       :automatic_recovery => @automatic_recovery,
                       :cause => cause.to_s)
        }.to_java(ShutdownListener))

        @logger.info("Connected to RabbitMQ", :url => connection_url(connection))

        channel = connection.createChannel
        HareInfo.new(connection, channel)
      end

      def configure_ssl!(factory)
        if @ssl_certificate_path
          cert_pass = @ssl_certificate_password.value if @ssl_certificate_password
          raise LogStash::ConfigurationError, "RabbitMQ requires both ssl_certificate_path AND ssl_certificate_password to be set!" unless cert_pass

          key_store = java.security.KeyStore.getInstance("PKCS12")
          java.io.FileInputStream.new(@ssl_certificate_path).tap do |fis|
            key_store.load(fis, cert_pass.to_java.toCharArray)
          end
          kmf = javax.net.ssl.KeyManagerFactory.getInstance("SunX509")
          kmf.init(key_store, cert_pass.to_java.toCharArray)
          ssl_context = javax.net.ssl.SSLContext.getInstance(@ssl_version)
          ssl_context.init(kmf.getKeyManagers, nil, nil)
          factory.useSslProtocol(ssl_context)
        else
          factory.useSslProtocol(@ssl_version)
        end
      end

      def connection_url(connection)
        protocol = @ssl ? "amqps" : "amqp"
        addr = connection.getAddress
        "#{protocol}://#{@user}:XXXXXX@#{addr.getHostName}:#{connection.getPort}#{@vhost}"
      end

      def sleep_for_retry
        Stud.stoppable_sleep(@connect_retry_interval) { @rabbitmq_connection_stopping }
      end

      def error_details(e, info = {})
        details = info.merge(:exception => e.class, :message => e.message)
        if e.is_a?(java.lang.Throwable) && e.cause
          details[:cause] = e.cause
        end
        details[:backtrace] = e.backtrace if @logger.debug? || info[:backtrace] == true
        details
      end

      ##
      # Wraps a raw AMQP delivery (envelope + properties) and the consumer tag into a
      # single object whose interface matches what the input plugin expects.
      class DeliveryInfo
        def initialize(consumer_tag, envelope, properties)
          @consumer_tag = consumer_tag
          @envelope     = envelope
          @properties   = properties
        end

        def delivery_tag;     @envelope.getDeliveryTag;        end
        def exchange;         @envelope.getExchange;           end
        def routing_key;      @envelope.getRoutingKey;         end
        def redeliver;        @envelope.isRedeliver;           end
        def consumer_tag;     @consumer_tag;                   end
        def app_id;           @properties.getAppId;            end
        def cluster_id;       @properties.getClusterId;        end
        def content_encoding; @properties.getContentEncoding;  end
        def content_type;     @properties.getContentType;      end
        def correlation_id;   @properties.getCorrelationId;    end
        def delivery_mode;    @properties.getDeliveryMode;     end
        def expiration;       @properties.getExpiration;       end
        def message_id;       @properties.getMessageId;        end
        def priority;         @properties.getPriority;         end
        def reply_to;         @properties.getReplyTo;          end
        def timestamp;        @properties.getTimestamp;        end  # java.util.Date
        def type;             @properties.getType;             end
        def user_id;          @properties.getUserId;           end

        def headers
          raw = @properties.getHeaders
          return {} unless raw
          raw.each_with_object({}) do |(k, v), acc|
            acc[k] = v.respond_to?(:toString) ? v.toString : v
          end
        end
      end

    end
  end
end
