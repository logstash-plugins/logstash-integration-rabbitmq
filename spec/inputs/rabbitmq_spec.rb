# encoding: utf-8
require "logstash/devutils/rspec/spec_helper"
require "logstash/inputs/rabbitmq"
require "thread"
require 'logstash/event'

Thread.abort_on_exception = true

describe LogStash::Inputs::RabbitMQ do
  let(:klass) { LogStash::Inputs::RabbitMQ }
  let(:host) { "localhost" }
  let(:port) { 5672 }
  let(:exchange_type) { "topic" }
  let(:exchange) { "myexchange" }
  let(:queue) { "myqueue" }
  let(:rabbitmq_settings) {
    {
      "host" => host,
      "port" => port,
      "queue" => queue,
      "prefetch_count" => 123
    }
  }
  subject(:instance) { klass.new(rabbitmq_settings) }
  let(:hare_info) { instance.instance_variable_get(:@hare_info) }
  let(:instance_logger) { double("Logger").as_null_object }

  before do
    allow_any_instance_of(klass).to receive(:logger).and_return(instance_logger)
  end

  context "when connected" do
    let(:connection) { double("MarchHare Connection") }
    let(:channel) { double("Channel") }
    let(:exchange) { double("Exchange") }
    let(:channel) { double("Channel") }
    let(:queue) { double("queue") }

    # Doing this in a before block doesn't give us enough control over scope
    before do
      allow(instance).to receive(:connect!).and_call_original
      allow(::MarchHare).to receive(:connect).and_return(connection)
      allow(connection).to receive(:create_channel).and_return(channel)
      allow(connection).to receive(:on_shutdown)
      allow(connection).to receive(:on_blocked)
      allow(connection).to receive(:on_unblocked)
      allow(connection).to receive(:close)
      allow(connection).to receive(:host).and_return host
      allow(connection).to receive(:port).and_return port
      allow(channel).to receive(:exchange).and_return(exchange)
      allow(channel).to receive(:queue).and_return(queue)
      allow(channel).to receive(:prefetch=)

      allow(queue).to receive(:build_consumer).with(:on_cancellation => anything)
      allow(queue).to receive(:subscribe_with).with(any_args)
      allow(queue).to receive(:bind).with(any_args)
    end

    it "should default the codec to JSON" do
      expect(instance.codec).to_not be_nil
      expect(instance.codec.config_name).to eq "json"
    end

    describe "#connect!" do
      subject { hare_info }

      context "without an exchange declared" do
        before do
          instance.register
          instance.setup!
        end

        it "should set the queue correctly" do
          expect(subject.queue).to eql(queue)
        end

        it "should set the prefetch value correctly" do
          expect(channel).to have_received(:prefetch=).with(123)
        end
      end

      context "with an exchange declared" do
        let(:exchange) { "exchange" }
        let(:key) { "routing key" }
        let(:rabbitmq_settings) { super().merge("exchange" => exchange, "key" => key, "exchange_type" => "fanout") }

        before do
          allow(instance).to receive(:declare_exchange!)
        end

        context "on run" do
          before do
            instance.register
            instance.setup!
          end

          it "should bind to the exchange" do
            expect(queue).to have_received(:bind).with(exchange, :routing_key => key)
          end

          it "should declare the exchange" do
            expect(instance).to have_received(:declare_exchange!)
          end
        end

        context "but not immediately available" do
          before do
            i = 0
            allow(queue).to receive(:bind).with(any_args) do
              i += 1
              raise "foo" if i == 1
            end
          end

          it "should reconnect" do
            instance.register
            instance.setup!
            expect(queue).to have_received(:bind).with(any_args).twice()
          end
        end

        context "initially unable to subscribe" do
          before do
            i = 0
            allow(queue).to receive(:subscribe_with).with(any_args) do
              i += 1
              raise "sub error" if i == 1
            end

            it "should retry the subscribe" do
              expect(queue).to have_receive(:subscribe_with).twice()
            end
          end
        end
      end
    end
  end

  context '#register' do
    let(:rabbitmq_settings) { super().merge(metadata_enabled_override) }
    let(:metadata_enabled_override) { { "metadata_enabled" => metadata_enabled } }
    before do
      instance.register
    end

    shared_examples('`metadata_enabled => none`') do
      context 'metadata_level' do
        subject(:metadata_level) { instance.metadata_level }
        it { is_expected.to be_empty }
        it { is_expected.to be_frozen }
      end
    end

    shared_examples('`metadata_enabled => basic`') do
      context 'metadata_level' do
        subject(:metadata_level) { instance.metadata_level }
        it { is_expected.to include :headers }
        it { is_expected.to include :properties }
        it { is_expected.to_not include :payload }
        it { is_expected.to be_frozen }
      end
    end

    shared_examples("deprecated `metadata_enabled` setting") do |deprecated_value|
      context 'the logger' do
        subject(:logger) { instance_logger }
        it 'receives a useful deprecation warning' do
          expect(logger).to have_received(:warn).with(/Deprecated value `#{Regexp.escape(deprecated_value)}`/)
        end
      end
    end

    context 'when `metadata_enabled` is `true`' do
      let(:metadata_enabled) { "true" }
      it_behaves_like '`metadata_enabled => basic`'
      include_examples "deprecated `metadata_enabled` setting", "true"
    end

    context 'when `metadata_enabled` is `false`' do
      let(:metadata_enabled) { "false" }
      it_behaves_like '`metadata_enabled => none`'
      include_examples "deprecated `metadata_enabled` setting", "false"
    end

    context 'when `metadata_enabled` is not provided' do
      let(:metadata_enabled_override) { Hash.new }
      it_behaves_like '`metadata_enabled => none`'
    end

    context 'when `metadata_enabled` is `basic`' do
      let(:metadata_enabled) { "basic" }
      include_examples '`metadata_enabled => basic`'
    end

    context 'when `metadata_enabled` is `none`' do
      let(:metadata_enabled) { "none" }
      include_examples '`metadata_enabled => none`'
    end

    context 'when `metadata_enabled` is `extended`' do
      let(:metadata_enabled) { "extended" }
      context 'metadata_level' do
        subject(:metadata_level) { instance.metadata_level }
        it { is_expected.to include :headers }
        it { is_expected.to include :properties }
        it { is_expected.to include :payload }
        it { is_expected.to be_frozen }
      end
    end
  end

  describe "#decorate(event, metadata, data)" do
    let(:rabbitmq_settings) do
      super().merge("metadata_enabled" => metadata_enabled)
    end
    before(:each) { instance.register }

    let(:metadata) { double("METADATA") }
    let(:headers) { Hash("header_key"=>"header_value") }
    let(:properties) { Hash("property_key"=>"property_value") }

    let(:data) { %Q({"message"=>"fubar"}\n) }

    before do
      allow(instance).to receive(:get_headers).with(metadata).and_return(headers)
      allow(instance).to receive(:get_properties).with(metadata).and_return(properties)
    end

    describe 'the decorated event' do
      subject(:decorated_event) do
        LogStash::Event.new("message"=>"fubar").tap do |e|
          instance.decorate(e, metadata, data)
        end
      end

      matcher :include_field do |fieldref|
        match do |event|
          # setting `@actual` makes failure messages clearer
          @actual = event.to_hash_with_metadata

          break false unless event.include?(fieldref)
          break true unless @specific_value

          values_match?(@expected_value, event.get(fieldref))
        end
        chain :with_value do |expected_value|
          @specific_value = true
          @expected_value = expected_value
        end
        description do
          desc = "include field `#{fieldref}`"
          desc += " with value matching `#{@expected_value.inspect}`" if @specific_value
          desc
        end
      end

      shared_examples('core decoration features') do
        let(:rabbitmq_settings) do
          super().merge("type" => "decorated_type",
                        "add_field" => {"added_field" => "field_value"})
        end
        it 'has been decorated with core decoration features' do
          expect(decorated_event).to include_field("added_field").with_value("field_value")
          expect(decorated_event).to include_field("type").with_value("decorated_type")
        end
      end

      let(:headers_fieldref) { "[@metadata][rabbitmq_headers]" }
      let(:properties_fieldref) { "[@metadata][rabbitmq_properties]" }
      let(:payload_fieldref) { "[@metadata][rabbitmq_payload]" }

      shared_examples('`metadata_enabled => none`') do
        it { is_expected.to_not include_field(headers_fieldref) }
        it { is_expected.to_not include_field(properties_fieldref) }
        it { is_expected.to_not include_field(payload_fieldref) }

        include_examples 'core decoration features'
      end

      shared_examples('`metadata_enabled => basic`') do
        it { is_expected.to include_field(headers_fieldref).with_value(headers) }
        it { is_expected.to include_field(properties_fieldref).with_value(properties) }
        it { is_expected.to_not include_field(payload_fieldref) }

        include_examples 'core decoration features'
      end

      context "with `metadata_enabled => none`" do
        let(:metadata_enabled) { "none" }
        include_examples '`metadata_enabled => none`'
      end

      context "with `metadata_enabled => basic`" do
        let(:metadata_enabled) { "basic" }
        include_examples '`metadata_enabled => basic`'
      end

      context 'with `metadata_enabled => extended`' do
        let(:metadata_enabled) { "extended" }
        it { is_expected.to include_field(headers_fieldref).with_value(headers) }
        it { is_expected.to include_field(properties_fieldref).with_value(properties) }
        it { is_expected.to include_field(payload_fieldref).with_value(data) }
        include_examples 'core decoration features'
      end

      # Deprecated alias: false -> none
      context "with `metadata_enabled => false`" do
        let(:metadata_enabled) { "false" }
        it_behaves_like '`metadata_enabled => none`'
      end

      # Deprecated alias: true -> basic
      context "with `metadata_enabled => true`" do
        let(:metadata_enabled) { "true" }
        it_behaves_like '`metadata_enabled => basic`'
      end
    end
  end
end

describe "LogStash::Inputs::RabbitMQ with a live server", :integration => true do
  let(:klass) { LogStash::Inputs::RabbitMQ }
  let(:rabbitmq_host) { ENV["RABBITMQ_HOST"] || "127.0.0.1" }
  let(:config) { {"host" => rabbitmq_host, "auto_delete" => true, "codec" => "plain", "add_field" => {"[@metadata][foo]" => "bar"} } }
  let(:instance) { klass.new(config) }
  let(:hare_info) { instance.instance_variable_get(:@hare_info) }
  let(:output_queue) { Queue.new }

  # Spawn a connection in the bg and wait up (n) seconds
  def spawn_and_wait(instance)
    instance.register

    output_queue # materialize in this thread

    Thread.new {
      instance.run(output_queue)
    }

    20.times do
      instance.send(:connection_open?) ? break : sleep(0.1)
    end

    # Extra time to make sure the consumer can attach
    # Without this there's a chance the shutdown code will execute
    # before consumption begins. This is tricky to do more elegantly
    sleep 4
  end

  let(:test_connection) { MarchHare.connect(instance.send(:rabbitmq_settings)) }
  let(:test_channel) { test_connection.create_channel }

  before do
    # Materialize the instance in the current thread to prevent dupes
    # If you use multiple threads with lazy evaluation weird stuff happens
    instance
    spawn_and_wait(instance)

    test_channel # Start up the test client as well
  end

  after do
    instance.stop()
    test_channel.close
    test_connection.close
  end

  context "using defaults" do
    it "should start, connect, and stop cleanly" do
      expect(instance.send(:connection_open?)).to be_truthy
    end
  end

  it "should have the correct prefetch value" do
    expect(instance.instance_variable_get(:@hare_info).channel.prefetch).to eql(256)
  end

  describe "receiving a message with a queue + exchange specified" do
    let(:config) { super().merge("queue" => queue_name, "exchange" => exchange_name, "exchange_type" => "fanout", "metadata_enabled" => "true") }
    let(:event) { output_queue.pop }
    let(:exchange) { test_channel.exchange(exchange_name, :type => "fanout") }
    let(:exchange_name) { "logstash-input-rabbitmq-#{rand(0xFFFFFFFF)}" }
    #let(:queue) { test_channel.queue(queue_name, :auto_delete => true) }
    let(:queue_name) { "logstash-input-rabbitmq-#{rand(0xFFFFFFFF)}" }

    after do
      exchange.delete
    end

    context "when the message has a payload but no message headers" do
      before do
        exchange.publish(message)
      end

      let(:message) { "Foo Message" }

      it "should process the message and store the payload" do
        expect(event.get("message")).to eql(message)
      end

      it "should save an empty message header hash" do
        expect(event).to include("@metadata")
        expect(event.get("@metadata")).to include("rabbitmq_headers")
        expect(event.get("[@metadata][rabbitmq_headers]")).to eq({})
      end
    end

    context "when message properties are available" do
      before do
        # Don't test every single property but select a few with
        # different characteristics to get sufficient coverage.
        exchange.publish("",
                      :properties => {
                        :app_id    => app_id,
                        :timestamp => Java::JavaUtil::Date.new(epoch * 1000),
                        :priority  => priority,
                      })
      end

      let(:app_id) { "myapplication" }
      # Randomize the epoch we test with but limit its range to signed
      # ints to not assume all protocols and libraries involved use
      # unsigned ints for epoch values.
      let(:epoch) { rand(0x7FFFFFFF) }
      let(:priority) { 5 }

      it "should save message properties into a @metadata field" do
        expect(event).to include("@metadata")
        expect(event.get("@metadata")).to include("rabbitmq_properties")

        props = event.get("[@metadata][rabbitmq_properties]")
        expect(props["app-id"]).to eq(app_id)
        expect(props["delivery-mode"]).to eq(1)
        expect(props["exchange"]).to eq(exchange_name)
        expect(props["priority"]).to eq(priority)
        expect(props["routing-key"]).to eq("")
        expect(props["timestamp"]).to eq(epoch)
      end
    end

    context "when message headers are available" do
      before do
        exchange.publish("", :properties => { :headers => headers })
      end

      let (:headers) {
        {
          "arrayvalue"  => [true, 123, "foo"],
          "boolvalue"   => true,
          "intvalue"    => 123,
          "stringvalue" => "foo",
        }
      }

      it "should save message headers into a @metadata field" do
        expect(event).to include("@metadata")
        expect(event.get("@metadata")).to include("rabbitmq_headers")
        expect(event.get("[@metadata][rabbitmq_headers]")).to include(headers)
      end

      it "should properly decorate the event" do
        expect(event.get("[@metadata][foo]")).to eq("bar")
      end
    end
  end

  describe LogStash::Inputs::RabbitMQ do
    require "logstash/devutils/rspec/shared_examples"
    it_behaves_like "an interruptible input plugin"
  end
end
