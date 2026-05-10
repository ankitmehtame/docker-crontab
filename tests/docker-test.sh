#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG=${1:-docker-crontab-test}
IMAGE=${IMAGE_TAG}

cleanup() {
  echo 'Cleaning up...'
  docker rm -f cron-test >/dev/null 2>&1 || true
  docker rmi "$IMAGE" >/dev/null 2>&1 || true
}

trap cleanup EXIT

# Build image
printf 'Building image %s...\n' "$IMAGE"
docker build -t "$IMAGE" .

# Run container in background
printf 'Running container...\n'
docker run -d --name cron-test --cap-add SYS_ADMIN --cap-add SYS_TIME "$IMAGE"

# Give cron some time to start
sleep 3

# Check cron process inside container
if docker exec cron-test sh -lc 'ps -A | grep [c]rond'; then
  echo 'Cron is running inside the container.'
else
  echo 'Cron did not start as expected.'
  exit 1
fi

docker rm -f cron-test >/dev/null 2>&1 || true

docker rmi "$IMAGE" >/dev/null 2>&1 || true

