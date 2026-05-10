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

# Wait for container to be Running (60s max)
waited=0
while [ $waited -lt 60 ]; do
  running=$(docker inspect -f '{{.State.Running}}' cron-test 2>/dev/null || echo "false")
  if [ "$running" = "true" ]; then
    break
  fi
  sleep 1
  waited=$((waited+1))
done

if [ "$running" != "true" ]; then
  echo "Container cron-test did not stay running after 60s."
  echo "Dumping logs for debugging..."
  docker logs cron-test || true
  docker inspect cron-test || true
  exit 1
fi

# Check cron process inside container
if docker exec cron-test sh -lc 'ps -eo pid,comm | grep -i crond'; then
  echo 'Cron is running inside the container.'
else
  echo 'Cron did not start as expected.'
  echo 'Attempting extra debug: list /etc/crontabs'
  docker exec cron-test sh -lc 'ls -l /etc/crontabs || true'
  docker exec cron-test sh -lc 'ps -ef | grep -i crond || true'
  docker logs cron-test || true
  exit 1
fi


docker rm -f cron-test >/dev/null 2>&1 || true

docker rmi "$IMAGE" >/dev/null 2>&1 || true
