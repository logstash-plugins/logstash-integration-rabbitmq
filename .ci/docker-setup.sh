#!/usr/bin/env bash

# This is intended to be run from the plugin's root directory. `.ci/docker-test.sh`
# Ensure you have Docker installed locally and set the ELASTIC_STACK_VERSION environment variable.
# - ELASTIC_STACK_VERSION: an exact version (e.g., "7.5.1"), or a MAJOR.x branch specifier (e.g., "7.x")
# - SNAPSHOT: (optional) when $ELASTIC_STACK_VERSION is MAJOR.x, selects an unreleased snapshot from that branch
# - TEST_MODE: (optional) a valid test mode for this plugin (default: "unit", unless overridden by $INTEGRATION)
# - INTEGRATION: (optional) a value of "true" changes the default value of $TEST_MODE to "integration"
set -e

pull_docker_snapshot() {
  project="${1?project name required}"
  local docker_image="docker.elastic.co/${project}/${project}${DISTRIBUTION_SUFFIX}:${ELASTIC_STACK_VERSION}"
  echo "Pulling $docker_image"
  docker pull "$docker_image"
}

# TEST_MODE should be one of "unit" or "integration" (defaults to "unit" unless INTEGRATION=true)
: "${TEST_MODE:=$([[ "${INTEGRATION}" = "true" ]] && echo "integration" || echo "unit")}"
export TEST_MODE

VERSION_URL="https://raw.githubusercontent.com/elastic/logstash/master/ci/logstash_releases.json"

if [ -z "${ELASTIC_STACK_VERSION}" ]; then
    echo "Please set the ELASTIC_STACK_VERSION environment variable"
    echo "For example: export ELASTIC_STACK_VERSION=7.x"
    exit 1
fi

echo "Fetching versions from $VERSION_URL"
VERSIONS=$(curl $VERSION_URL)

if [[ "$SNAPSHOT" = "true" ]]; then
  ELASTIC_STACK_RETRIEVED_VERSION=$(echo $VERSIONS | jq '.snapshots."'"$ELASTIC_STACK_VERSION"'"')
  echo $ELASTIC_STACK_RETRIEVED_VERSION
else
  ELASTIC_STACK_RETRIEVED_VERSION=$(echo $VERSIONS | jq '.releases."'"$ELASTIC_STACK_VERSION"'"')
fi

if [[ "$ELASTIC_STACK_RETRIEVED_VERSION" != "null" ]]; then
  # remove starting and trailing double quotes
  ELASTIC_STACK_RETRIEVED_VERSION="${ELASTIC_STACK_RETRIEVED_VERSION%\"}"
  ELASTIC_STACK_RETRIEVED_VERSION="${ELASTIC_STACK_RETRIEVED_VERSION#\"}"
  echo "Translated $ELASTIC_STACK_VERSION to ${ELASTIC_STACK_RETRIEVED_VERSION}"
  export ELASTIC_STACK_VERSION=$ELASTIC_STACK_RETRIEVED_VERSION
fi

case "${DISTRIBUTION}" in
  default) DISTRIBUTION_SUFFIX="" ;; # empty string when explicit "default" is given
        *) DISTRIBUTION_SUFFIX="${DISTRIBUTION/*/-}${DISTRIBUTION}" ;;
esac
export DISTRIBUTION_SUFFIX

echo "Testing against version: $ELASTIC_STACK_VERSION (distribution: ${DISTRIBUTION:-"default"})"

if [[ "$ELASTIC_STACK_VERSION" = *"-SNAPSHOT" ]]; then
    pull_docker_snapshot "logstash"
fi

if [ -f Gemfile.lock ]; then
    rm Gemfile.lock
fi

CURRENT_DIR=$(dirname "${BASH_SOURCE[0]}")

cd .ci

docker-compose --file ".ci/common/docker-compose.yml" --file ".ci/${TEST_MODE}/docker-compose.override.yml" down
docker-compose --file ".ci/common/docker-compose.yml" --file ".ci/${TEST_MODE}/docker-compose.override.yml" --verbose build
