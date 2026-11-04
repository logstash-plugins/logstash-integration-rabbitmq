# encoding: UTF-8
require "logstash/devutils/rspec/spec_helper"
require "logstash/outputs/rabbitmq"

describe LogStash::Outputs::RabbitMQ do
  let(:klass) { LogStash::Outputs::RabbitMQ }
  let(:host) { "localhost" }
  let(:port) { 5672 }
  let(:exchange_type) { "topic" }
  let(:exchange) { "myexchange" }
  let(:key) { "mykey" }
  let(:persistent) { true }
  let(:rabbitmq_settings) {
    {
      "host" => host,
      "port" => port,
      "exchange_type" => exchange_type,
      "exchange" => exchange,
      "key" => key,
      "persistent" => persistent
    }
  }
  let(:instance) { klass.new(rabbitmq_settings) }
  let(:hare_info) { instance.instance_variable_get(:@hare_info) }

  # march_hare converts AlreadyClosedException inside a rescue, so the Java exception becomes the `cause`
  def channel_already_closed(hard:)
    signal = com.rabbitmq.client.ShutdownSignalException.new(hard, false, nil, nil)
    begin
      raise com.rabbitmq.client.AlreadyClosedException.new(signal)
    rescue java.lang.Exception
      raise MarchHare::ChannelAlreadyClosed, "channel is already closed"
    end
  end

  shared_examples 'recovers from exception gracefully' do
    it 'should execute publish twice due to a retry' do
      expect(exchange).to have_received(:publish).twice
    end

    it 'should sleep for the retry' do
      expect(instance).to have_received(:sleep_for_retry).once
    end

    it 'should send the correct message (twice)' do
      expect(exchange).to have_received(:publish).with(encoded_event, anything).twice
    end

    it 'should send the correct metadata (twice)' do
      expected_metadata = {:routing_key => event.sprintf(key), :properties => {:persistent => persistent }}
      expect(exchange).to have_received(:publish).with(anything, expected_metadata).twice
    end
  end

  it "should register as an output plugin" do
    expect(LogStash::Plugin.lookup("output", "rabbitmq")).to eql(LogStash::Outputs::RabbitMQ)
  end

  context "when connected" do
    let(:connection) { double("MarchHare Connection") }
    let(:channel) { double("Channel") }
    let(:exchange) { double("Exchange") }

    before do
      allow(instance).to receive(:connect!).and_call_original
      allow(::MarchHare).to receive(:connect).and_return(connection)
      allow(connection).to receive(:create_channel).and_return(channel)
      allow(connection).to receive(:on_blocked)
      allow(connection).to receive(:on_unblocked)
      allow(connection).to receive(:on_shutdown)
      allow(connection).to receive(:on_recovery_start)
      allow(connection).to receive(:on_recovery)
      allow(connection).to receive(:host).and_return host
      allow(connection).to receive(:port).and_return port
      allow(connection).to receive(:vhost).and_return nil
      allow(connection).to receive(:user).and_return 'guest'
      allow(channel).to receive(:exchange).and_return(exchange)

      instance.register
    end

    describe "#connect!" do
      subject { hare_info }

      it "should set the exchange correctly" do
        expect(subject.exchange).to eql(exchange)
      end
    end

    describe "#publish_encoded" do
      let(:event) { LogStash::Event.new("foo" => "bar") }
      let(:sprinted_key) { double("sprinted key") }
      let(:encoded_event) { LogStash::Json.dump(event) }

      describe "issuing the publish" do
        before do
          allow(exchange).to receive(:publish).with(any_args)
          allow(event).to receive(:sprintf).with(key).and_return(sprinted_key)
        end

        it "should send the correct message" do
          instance.send(:publish, event, encoded_event)
          expect(exchange).to have_received(:publish).with(encoded_event, anything)
        end

        it "should send the correct metadata" do
          expected_metadata = {:routing_key => sprinted_key, :properties => {:persistent => persistent }}

          instance.send(:publish, event, encoded_event)

          expect(exchange).to have_received(:publish).with(anything, expected_metadata)
        end

        context 'with message_properties' do
          let(:rabbitmq_settings) { super().merge("message_properties" => message_properties) }
          let(:message_properties) { Hash.new }
          context 'priority' do
            let(:message_properties) { super().merge("priority" => priority) }
            context 'as literal Integer value' do
              let(:priority) { 3 }
              it 'publishes with the constant-value priority' do
                instance.send(:publish, event, encoded_event)
                expect(exchange).to have_received(:publish).with(anything, hash_including(:properties => hash_including(:priority => 3)))
              end
            end

            context 'as literal String value' do
              let(:priority) { "7" }
              it 'publishes with the constant-value priority' do
                instance.send(:publish, event, encoded_event)
                expect(exchange).to have_received(:publish).with(anything, hash_including(:properties => hash_including(:priority => 7)))
              end
            end

            context 'as template value' do
              let(:priority) { "%{[@metadata][priority]}" }
              context 'when event expands template value' do
                before do
                  expect(event).to receive(:sprintf).with(priority).and_return("31")
                end

                it 'publishes with the priority extracted from the event' do
                 instance.send(:publish, event, encoded_event)
                 expect(exchange).to have_received(:publish).with(anything, hash_including(:properties => hash_including(:priority => 31)))
                end
              end
              context 'when event cannot expand template value' do
                before do
                  expect(event).to receive(:sprintf).with(priority).and_return(priority)
                end

                it 'publishes with the priority of zero (`0`)' do
                 instance.send(:publish, event, encoded_event)
                 expect(exchange).to have_received(:publish).with(anything, hash_including(:properties => hash_including(:priority => 0)))
                end
              end
            end
          end
        end
      end

      context 'when an exception is encountered' do
        let(:exception) { nil }

        before do
          i = 0
          allow(instance).to receive(:connect!)
          allow(instance).to receive(:sleep_for_retry)
          allow(connection).to receive(:unregister_channel)
          allow(exchange).to receive(:publish).with(any_args) do
            i += 1
            if i == 1
              exception.is_a?(Proc) ? exception.call : raise(exception)
            end
          end

          instance.send(:publish, event, encoded_event)
        end

        context 'when it is a MarchHare exception' do
          let(:exception) { MarchHare::Exception }
          it_behaves_like 'recovers from exception gracefully'

          it 'should reuse the existing channel' do
            # once on register, once for the publishing thread
            expect(connection).to have_received(:create_channel).twice
          end
        end

        context 'when it is a MarchHare::ChannelAlreadyClosed without a cause' do
          let(:exception) { MarchHare::ChannelAlreadyClosed }
          it_behaves_like 'recovers from exception gracefully'
        end

        context 'when it is a MarchHare::ChannelAlreadyClosed caused by a connection close' do
          let(:exception) { -> { channel_already_closed(hard: true) } }
          it_behaves_like 'recovers from exception gracefully'

          it 'should leave the channel to automatic recovery' do
            expect(connection).not_to have_received(:unregister_channel)
          end
        end

        context 'when it is a TimeoutException' do
          let(:exception) { java.util.concurrent.TimeoutException.new }
          it_behaves_like 'recovers from exception gracefully'
        end
      end

      context 'when the broker closed the channel' do
        let(:stale_channel) { double("Stale channel") }
        let(:stale_exchange) { double("Stale exchange") }
        let(:stale_open) { false }
        let(:stale_close_error) { nil }
        let(:confirm_channel) { double("Confirm channel", confirm_select: nil, open?: true, close: nil) }
        let(:confirm_exchange) { double("Confirm exchange", publish: nil) }
        let(:fresh_channel) { double("Fresh channel") }
        let(:fresh_exchange) { double("Fresh exchange", publish: nil) }
        # outcome of each confirmed attempt: true (ack), false (nack) or a raised error
        let(:confirm_results) { [proc { true }] }

        before do
          allow(instance).to receive(:sleep_for_retry)
          allow(connection).to receive(:unregister_channel)
          allow(stale_channel).to receive(:exchange).and_return(stale_exchange)
          allow(stale_channel).to receive(:open?).and_return(stale_open)
          allow(stale_channel).to receive(:close) { raise stale_close_error if stale_close_error }
          allow(stale_exchange).to receive(:publish) { channel_already_closed(hard: false) }
          allow(confirm_channel).to receive(:exchange).and_return(confirm_exchange)
          allow(confirm_channel).to receive(:wait_for_confirms).and_invoke(*confirm_results)
          allow(fresh_channel).to receive(:exchange).and_return(fresh_exchange)
          confirm_channels = [confirm_channel] * confirm_results.size
          allow(connection).to receive(:create_channel).and_return(stale_channel, *confirm_channels, fresh_channel)

          instance.send(:publish, event, encoded_event)
        end

        it 'should not publish to the closed exchange again' do
          expect(stale_exchange).to have_received(:publish).once
        end

        it 'should unregister the closed channel so recovery cannot reopen it' do
          expect(connection).to have_received(:unregister_channel).with(stale_channel)
        end

        it 'should not close a channel that is already closed' do
          expect(stale_channel).not_to have_received(:close)
        end

        it 'should retry the message on a channel in confirm mode' do
          expect(confirm_channel).to have_received(:confirm_select).once
          expect(confirm_channel).to have_received(:exchange).once
          expect(confirm_exchange).to have_received(:publish).with(encoded_event, anything).once
          expect(confirm_channel).to have_received(:wait_for_confirms).with(10_000)
        end

        it 'should close and unregister the confirm channel' do
          expect(confirm_channel).to have_received(:close).once
          expect(connection).to have_received(:unregister_channel).with(confirm_channel)
        end

        it 'should publish the next event on a new regular channel' do
          instance.send(:publish, event, encoded_event)

          expect(fresh_channel).to have_received(:exchange)
          expect(fresh_exchange).to have_received(:publish).with(encoded_event, anything).once
          expect(confirm_channel).to have_received(:confirm_select).once
        end

        context 'and the broker nacks the confirmed retry' do
          let(:confirm_results) { [proc { false }, proc { true }] }

          it 'should keep retrying with confirms until the message is acked' do
            expect(confirm_exchange).to have_received(:publish).with(encoded_event, anything).twice
            expect(instance).to have_received(:sleep_for_retry).twice
          end

          it 'should discard every confirm channel' do
            expect(confirm_channel).to have_received(:close).twice
            expect(connection).to have_received(:unregister_channel).with(confirm_channel).twice
          end
        end

        context 'and the broker also closes the confirm channel' do
          let(:confirm_results) { [proc { channel_already_closed(hard: false) }, proc { true }] }

          it 'should keep retrying with confirms until the message is acked' do
            expect(stale_exchange).to have_received(:publish).once
            expect(confirm_exchange).to have_received(:publish).with(encoded_event, anything).twice
            expect(instance).to have_received(:sleep_for_retry).twice
          end
        end

        context 'and the closed channel still reports being open' do
          let(:stale_open) { true }
          let(:stale_close_error) { java.io.IOException.new("channel is already closed") }

          it 'should ignore the error when closing it and still unregister it' do
            expect(stale_channel).to have_received(:close)
            expect(connection).to have_received(:unregister_channel).with(stale_channel)
            expect(confirm_exchange).to have_received(:publish).with(encoded_event, anything).once
          end
        end
      end

      context 'when the connection was closed' do
        let(:stale_exchange) { double("Stale exchange") }
        let(:fresh_channel) { double("Fresh channel") }
        let(:fresh_exchange) { double("Fresh exchange", publish: nil) }

        before do
          allow(instance).to receive(:sleep_for_retry)
          allow(connection).to receive(:unregister_channel)
          allow(fresh_channel).to receive(:exchange).and_return(fresh_exchange)
        end

        context 'while publishing' do
          before do
            i = 0
            allow(exchange).to receive(:publish) do
              i += 1
              channel_already_closed(hard: true) if i == 1
            end

            instance.send(:publish, event, encoded_event)
          end

          it 'should retry on the same channel once it is recovered' do
            expect(exchange).to have_received(:publish).with(encoded_event, anything).twice
            # once on register, once for the publishing thread
            expect(connection).to have_received(:create_channel).twice
          end

          it 'should not discard the channel' do
            expect(connection).not_to have_received(:unregister_channel)
          end
        end

        context 'while creating the channel' do
          # create_channel is a plain Java call, so it raises the unconverted Java exception
          let(:connection_closed) do
            com.rabbitmq.client.AlreadyClosedException.new(
              com.rabbitmq.client.ShutdownSignalException.new(true, false, nil, nil)
            )
          end

          before do
            allow(connection).to receive(:create_channel).and_invoke(
              -> { raise connection_closed },
              -> { fresh_channel }
            )

            instance.send(:publish, event, encoded_event)
          end

          it 'should retry until the channel can be created' do
            expect(instance).to have_received(:sleep_for_retry).once
          end

          it 'should send the message once the connection is back' do
            expect(fresh_exchange).to have_received(:publish).with(encoded_event, anything).once
          end
        end
      end
    end
  end
end


describe "LogStash::Outputs::RabbitMQ with a live server", :integration => true do
  let(:rabbitmq_host) { ENV["RABBITMQ_HOST"] || "127.0.0.1" }
  let(:klass) { LogStash::Outputs::RabbitMQ }
  let(:exchange) { "myexchange" }
  let(:exchange_type) { "topic" }
  let(:priority) { 34 }
  let(:default_plugin_config) {
    {
      "host" => rabbitmq_host,
      "exchange" => exchange,
      "exchange_type" => exchange_type,
      "key" => "foo",
      "message_properties" => {
          "priority" => priority
      }
    }
  }
  let(:config) { default_plugin_config }
  let(:instance) { klass.new(config) }
  let(:hare_info) { instance.instance_variable_get(:@hare_info) }

  # Spawn a connection in the bg and wait up (n) seconds
  def spawn_and_wait(instance)
    instance.register

    20.times do
      instance.send(:connection_open?) ? break : sleep(0.1)
    end

    # Extra time to make sure the output can attach
    sleep 1
  end
  let(:message) { LogStash::Event.new("message" => "Foo Message", "extra_field" => "Blah") }
  let(:encoded) { message.to_json }
  let(:test_connection) { MarchHare.connect(instance.send(:rabbitmq_settings)) }
  let(:test_channel) { test_connection.create_channel }
  let(:test_queue) {
    test_channel.queue("testq", :auto_delete => true).bind(exchange, :key => config["key"])
  }

  before do
    # Materialize the instance in the current thread to prevent dupes
    # If you use multiple threads with lazy evaluation weird stuff happens
    instance
    spawn_and_wait(instance)

    test_channel # Start up the test client as well
    test_queue
  end

  after do
    instance.close()
    test_channel.close
    test_connection.close
  end

  context "using defaults" do
    it "should start, connect, and stop cleanly" do
      expect(instance.send(:connection_open?)).to be_truthy
    end

    it "should close cleanly" do
      instance.close
      expect(instance.send(:connection_open?)).to be_falsey
    end

    it 'applies per message settings' do
      instance.multi_receive_encoded([[message, encoded]])
      sleep 1.0

      message, payload = test_queue.pop
      expect(message.properties.to_s).to include("priority=#{priority}")
    end
  end

  describe "sending a message with an exchange specified" do
    let(:message) { LogStash::Event.new("message" => "Foo Message", "extra_field" => "Blah") }

    before do
      @received = nil
      test_queue.subscribe do |metadata,payload|
        @received = payload
      end

      instance.multi_receive_encoded([[message, encoded]])

      until @received
        sleep 1
      end

      @decoded = LogStash::Json.load(@received)
    end

    it "should process the message fully using the default (JSON) codec" do
      expect(@decoded).to eql(LogStash::Json.load(LogStash::Json.dump(message)))
    end
  end
end
