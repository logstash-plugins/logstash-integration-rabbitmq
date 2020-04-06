#!/usr/bin/env bash

# This is intended to be run inside the docker container as the command  of the docker-compose.
# It can also be run in an environment whose bundle includes a full Logstash installation.
set -ex

# runs unit-test specs
jruby -rbundler/setup -S rspec --format=documentation