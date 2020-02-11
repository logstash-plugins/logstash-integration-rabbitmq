#!/usr/bin/env bash

# This is intended to be run inside the docker container as the command  of the docker-compose.
# It can also be run in an environment whose bundle includes a full Logstash installation.
set -ex

# runs integration tests, assuming that a rabbitmq server is running on ${RABBITMQ_HOST} (if provided) or on localhost.
jruby -rbundler/setup -S rspec --format=documentation --tag integration