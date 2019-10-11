# TLS Testing notes

Currently all TLS integration style testing is manual. This fixture may be used to help test. 

* client - has the key store with client public/private key and the server public key
* server - has the key store with server public/private key and the client public key
* client_untrusted - has a keystore with public/private key that is self signed

logstash config
---------
```
input {
  rabbitmq {
    host => "localhost"
    port => 5671
    queue => "hello"
    codec => plain
    ssl => true
    ssl_certificate_path => "/Users/jake/workspace/plugins/logstash-mixin-rabbitmq_connection/spec/fixtures/client/keycert.p12"
    ssl_certificate_password => "MySecretPassword"
  }
}

output{ stdout { codec => rubydebug } }
```

rabbit mq install
--------
(mac) 

```
brew install rabbitmq
export PATH=$PATH:/usr/local/sbin
vim /usr/local/etc/rabbitmq/rabbitmq.config

```
```
[
  {rabbit, [
     {ssl_listeners, [5671]},
     {ssl_options, [{cacertfile,"/Users/jake/workspace/plugins/logstash-mixin-rabbitmq_connection/spec/fixtures/testca/cacert.pem"},
                    {certfile,"/Users/jake/workspace/plugins/logstash-mixin-rabbitmq_connection/spec/fixtures/server/cert.pem"},
                    {keyfile,"/Users/jake/workspace/plugins/logstash-mixin-rabbitmq_connection/spec/fixtures/server/key.pem"},
                    {verify,verify_peer},
                    {fail_if_no_peer_cert,false}]}
   ]}
].
```
```
export PATH=$PATH:/usr/local/sbin
rabbitmq-server
tail -f /usr/local/var/log/rabbitmq/rabbit@localhost.log
```

sending a test message with ruby
----------
https://www.rabbitmq.com/tutorials/tutorial-one-ruby.html

```
gem install bunny --version ">= 2.6.4"
```
Create a file called send.rb
```
#!/usr/bin/env ruby
# encoding: utf-8

require "bunny"

conn = Bunny.new(:automatically_recover => false)
conn.start

ch   = conn.create_channel
q    = ch.queue("hello")

ch.default_exchange.publish("Test message", :routing_key => q.name)
puts "Message sent'"

conn.close
```
Send the message with Logstash running as the consumer
``` 
ruby send.rb 
```

password for all files
--------
MySecretPassword

start from testca dir
---------
```
cd testca
```

client
-------
```
openssl genrsa -out ../client/key.pem 2048
openssl req -config openssl.cnf  -key ../client/key.pem  -new -sha256 -out ../client/req.pem
# for hostname use localhost, O=client
openssl ca -config openssl.cnf  -in ../client/req.pem -out ../client/cert.pem
openssl x509 -in ../client/cert.pem -text -noout
openssl pkcs12 -export -out ../client/keycert.p12 -inkey ../client/key.pem -in ../client/cert.pem
```

server
-------
```
openssl genrsa -out ../server/key.pem 2048
openssl req -config openssl.cnf  -key ../server/key.pem  -new -sha256 -out ../server/req.pem
# for hostname use localhost, O=server
openssl ca -config openssl.cnf  -in ../server/req.pem -out ../server/cert.pem
openssl x509 -in ../server/cert.pem -text -noout
openssl pkcs12 -export -out ../server/keycert.p12 -inkey ../server/key.pem -in ../server/cert.pem
```

establish trust
----------
```
cd server
keytool -import -file ../client/cert.pem  -alias client_cert -keystore keycert.p12
cd client
keytool -import -file ../server/cert.pem  -alias server_cert -keystore keycert.p12
```

reading
-----------
```
openssl x509 -in cert.pem -text -noout
keytool -list -v -keystore keycert.p12
```

self signed cert (untrusted)
-------
 ```
openssl req -x509  -batch -nodes -newkey rsa:2048 -keyout key.pem -out cert.pem -subj "/CN=localhost, O=client" -days 10000
openssl pkcs12 -export -out keycert.p12 -inkey key.pem -in cert.pem

```

Issue [44](https://github.com/logstash-plugins/logstash-mixin-rabbitmq_connection/issues/44) validation
---------
configure Logstash to the untrusted cert :`ssl_certificate_path => "/Users/jake/workspace/plugins/logstash-mixin-rabbitmq_connection/spec/fixtures/client_untrusted/keycert.p12"`

This _SHOULD_ fail an error like the following:
```
Using TLS/SSL version TLSv1.2
[2017-12-19T12:47:12,891][ERROR][logstash.inputs.rabbitmq ] RabbitMQ connection error, will retry. {:error_message=>"sun.security.validator.ValidatorException: PKIX path building failed: sun.security.provider.certpath.SunCertPathBuilderException: unable to find valid certification path to requested target", :exception=>"Java::JavaxNetSsl::SSLHandshakeException"}
```
There should _NOT_ be any warnings about a NullTrustManager or disabling verification, and you should _NOT_ be able to send messages.