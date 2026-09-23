# encoding: utf-8
require "logstash/devutils/rspec/spec_helper"
require "logstash/pipeline"
require "logstash/plugin_mixins/rabbitmq_connection"
require "stud/temporary"

class TestPlugin < LogStash::Outputs::Base
  include LogStash::PluginMixins::RabbitMQConnection

  def register
    connect!
  end
end

describe LogStash::PluginMixins::RabbitMQConnection do
  let(:klass) { TestPlugin }
  let(:default_port) { 5672 }
  let(:host) { "localhost" }
  let(:port) { default_port }
  let(:rabbitmq_settings) {
    {
      "host" => host
    }
  }
  let(:instance) {
    klass.new(rabbitmq_settings)
  }
  let(:hare_info) { instance.instance_variable_get(:@hare_info) }

  describe "addresses_from_hosts_and_port" do
    let(:hosts) { %w(host01 host02 host03) }

    it "should append the port to each host" do
      result = instance.addresses_from_hosts_and_port(hosts, 5672)
      expect(result).to eql(%w(host01:5672 host02:5672 host03:5672))
    end

    it "should insert the correct number of address entries" do
      result = instance.addresses_from_hosts_and_port(hosts, 5672)
      expect(result.length).to eql(hosts.count)
    end

    it "should not append port when host already contains a port" do
      hosts_with_port = %w(host01:4444 host02:4445 host03:4446)
      result = instance.addresses_from_hosts_and_port(hosts_with_port, 5672)
      expect(result).to eql(%w(host01:4444 host02:4445 host03:4446))
    end

    context 'with a custom port' do
      let(:port) { 123 }

      it "should use the custom port" do
        result = instance.addresses_from_hosts_and_port(hosts, port)
        hosts.each_with_index do |each_host, index|
          expect(result[index]).to eql("#{each_host}:#{port}")
        end
      end
    end
  end

  context "when connected" do
    let(:factory)    { double("ConnectionFactory") }
    let(:connection) { double("AMQP Connection") }
    let(:channel)    { double("Channel") }
    let(:address)    { double("InetAddress") }

    before do
      allow(instance).to receive(:connect!).and_call_original
      allow(ConnectionFactory).to receive(:new).and_return(factory)
      allow(factory).to receive(:setUsername)
      allow(factory).to receive(:setPassword)
      allow(factory).to receive(:setVirtualHost)
      allow(factory).to receive(:setRequestedHeartbeat)
      allow(factory).to receive(:setConnectionTimeout)
      allow(factory).to receive(:setAutomaticRecoveryEnabled)
      allow(factory).to receive(:setExceptionHandler)
      allow(factory).to receive(:newConnection).and_return(connection)
      allow(connection).to receive(:createChannel).and_return(channel)
      allow(connection).to receive(:addShutdownListener)
      allow(connection).to receive(:isOpen).and_return(true)
      allow(connection).to receive(:getAddress).and_return(address)
      allow(connection).to receive(:getPort).and_return(port)
      allow(address).to receive(:getHostName).and_return(host)

      instance.register
    end

    describe "#register" do
      subject { instance }

      it "should create cleanly" do
        expect(subject).to be_a(klass)
      end

      it "should connect" do
        expect(subject).to have_received(:connect!).once
      end
    end

    describe "#connect!" do
      subject { hare_info }

      it "should set @hare_info correctly" do
        expect(subject).to be_a(LogStash::PluginMixins::RabbitMQConnection::HareInfo)
      end

      it "should set @connection correctly" do
        expect(subject.connection).to eql(connection)
      end

      it "should set the channel correctly" do
        expect(subject.channel).to eql(channel)
      end
    end
  end

  # If the connection encounters an exception during its initial
  # connection attempt we must handle that. Subsequent errors should be
  # handled by the automatic retry mechanism built-in to the Java client.
  describe "initial connection exceptions" do
    subject { instance }

    before do
      allow(subject).to receive(:sleep_for_retry)

      i = 0
      allow(subject).to receive(:connect) do
        i += 1
        if i == 1
          raise(java.io.IOException, "Error!")
        else
          double("connection")
        end
      end

      subject.send(:connect!)
    end

    it "should retry its connection when conn fails" do
      expect(subject).to have_received(:connect).twice
    end

    it "should sleep between retries" do
      expect(subject).to have_received(:sleep_for_retry).once
    end
  end
end
