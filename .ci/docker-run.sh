#!/usr/bin/env bash

 # This is intended to be run after docker-setup.sh has been used to setup the docker container(s)
set -ex

# TEST_MODE should be one of "unit" or "integration" (defaults to "unit" unless INTEGRATION=true)
: "${TEST_MODE:=$([[ "${INTEGRATION}" = "true" ]] && echo "integration" || echo "unit")}"
export TEST_MODE

docker-compose -f ".ci/common/docker-compose.yml" -f ".ci/${TEST_MODE}/docker-compose.override.yml" up --exit-code-from logstash
