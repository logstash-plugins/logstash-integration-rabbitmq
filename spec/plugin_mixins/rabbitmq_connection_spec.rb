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

  shared_examples_for 'it sets the addresses correctly' do
    let(:file) { Stud::Temporary.file }
    let(:path) { file.path }
    let(:host) {%w(host01 host02 host03)}

    it "should set addresses to the expected value" do
      host.each_with_index do |each_host, index|
        expect(instance.rabbitmq_settings[:addresses][index]).to eql("#{each_host}:#{port}")
      end
    end

    it "should insert the correct number of address entries" do
      expect(instance.rabbitmq_settings[:addresses].length).to eql(host.count)
    end
  end

  describe "rabbitmq_settings" do
    let(:file) { Stud::Temporary.file }
    let(:path) { file.path }
    after { File.unlink(path)}

    let(:rabbitmq_settings) { super.merge({"connection_timeout" => 123,
                                           "heartbeat" => 456,
                                           "ssl" => true,
                                           "ssl_version" => "TLSv1.1",
                                           "ssl_certificate_path" => path,
                                           "ssl_certificate_password" => "123"}) }

    it "should set the timeout to the expected value" do
      expect(instance.rabbitmq_settings[:timeout]).to eql(rabbitmq_settings["connection_timeout"])
    end

    it "should set heartbeat to the expected value" do
      expect(instance.rabbitmq_settings[:heartbeat]).to eql(rabbitmq_settings["heartbeat"])
    end

    it "should set tls to the expected value" do
      expect(instance.rabbitmq_settings[:tls]).to eql("TLSv1.1")
    end

    it "should set tls_certificate_path to the expected value" do
      expect(instance.rabbitmq_settings[:tls_certificate_path]).to eql(rabbitmq_settings["ssl_certificate_path"])
    end

    it "should set tls_certificate_password to the expected value" do
      expect(instance.rabbitmq_settings[:tls_certificate_password]).to eql(rabbitmq_settings["ssl_certificate_password"])
    end

    it_behaves_like 'it sets the addresses correctly'

    context 'with a custom port' do
      let(:port) { 123 }
      let(:rabbitmq_settings) { super.merge({"port" => port})}

      it_behaves_like 'it sets the addresses correctly'
    end
  end

  describe "ssl enabled, but no verification" do
    let(:rabbitmq_settings) { super.merge({"connection_timeout" => 123,
                                           "heartbeat" => 456,
                                           "ssl" => true}) }

    it "should not have any certificates set" do
      expect(instance.rabbitmq_settings[:tls_certificate_password]).to be nil
      expect(instance.rabbitmq_settings[:tls_certificate_path]).to be nil
    end

  end

  describe "rabbitmq_settings with multiple hosts" do
    it_behaves_like 'it sets the addresses correctly'

    context 'with a custom port'  do
      let(:port) { 999 }
      let(:rabbitmq_settings) { super.merge({"port" => port})}

      it_behaves_like 'it sets the addresses correctly'
    end

    context 'when ports are set in the host definition' do
      let(:host) { %w(host01:4444 host02:4445 host03:4446)}

      it "should set the address correctly" do
        expect(instance.rabbitmq_settings[:addresses][0]).to eql("host01:4444")
        expect(instance.rabbitmq_settings[:addresses][1]).to eql("host02:4445")
        expect(instance.rabbitmq_settings[:addresses][2]).to eql("host03:4446")
      end
    end
  end

  context "when connected" do
    let(:connection) { double("MarchHare Connection") }
    let(:channel) { double("Channel") }

    before do
      allow(instance).to receive(:connect!).and_call_original
      allow(::MarchHare).to receive(:connect).and_return(connection)
      allow(connection).to receive(:create_channel).and_return(channel)
      allow(connection).to receive(:on_blocked)
      allow(connection).to receive(:on_unblocked)
      allow(connection).to receive(:on_shutdown)

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
  # handled by the automatic retry mechanism built-in to MarchHare
  describe "initial connection exceptions" do
    subject { instance }

    before do
      allow(subject).to receive(:sleep_for_retry)


      i = 0
      allow(subject).to receive(:connect) do
        i += 1
        if i == 1
          raise(MarchHare::ConnectionRefused, "Error!")
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
