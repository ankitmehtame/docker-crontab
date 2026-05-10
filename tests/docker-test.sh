#!/usr/bin/env bash
set -euo pipefail

# Explicitly set Docker host to ensure the docker client can find the daemon socket
if [ -S "/var/run/docker.sock" ]; then
  export DOCKER_HOST="unix:///var/run/docker.sock"
else
  echo "Docker socket /var/run/docker.sock not found; using default Docker host"
fi

IMAGE_TAG=${1:-docker-crontab-test}
IMAGE=${IMAGE_TAG}

cleanup() {
  echo 'Cleaning up...'
  # Ensure container is removed even if it failed to start or is stuck
  docker rm -f cron-test >/dev/null 2>&1 || true
  docker rmi "$IMAGE" >/dev/null 2>&1 || true
  echo 'Cleanup complete.'
}

trap cleanup EXIT

# Initial cleanup before build and run to avoid name conflicts
echo 'Running initial cleanup...'
docker rm -f cron-test >/dev/null 2>&1 || true
# Add a small sleep to allow Docker daemon to fully process the removal
sleep 2

# Build image
printf 'Building image %s...\n' "$IMAGE"
docker build -t "$IMAGE" .

# Run container in background with sample config mounted AND docker socket mounted
printf 'Running container with config...\n'
CONFIG_FILE_HOST=$(pwd)/config-samples/config.sample.json
CONFIG_FILE_CONTAINER=/opt/crontab/config.json
docker run -d --name cron-test --cap-add SYS_ADMIN --cap-add SYS_TIME -v "${CONFIG_FILE_HOST}:${CONFIG_FILE_CONTAINER}" -v /var/run/docker.sock:/var/run/docker.sock "$IMAGE"

# Wait for container to be Running (60s max)
waited=0
running="false" # Initialize running state
echo "Waiting for container to become running..."
while [ $waited -lt 60 ]; do
  container_status=$(docker inspect --format '{{.State.Status}}' cron-test 2>/dev/null || echo "not_found")
  if [ "$container_status" = "running" ]; then
    running="true"
    break
  fi
  sleep 1
  waited=$((waited+1))
done

if [ "$running" != "true" ]; then
  echo "Container cron-test did not become running within 60 seconds."
  echo "Dumping logs for debugging..."
  docker logs cron-test || true
  docker inspect cron-test || true
  exit 1
fi

# Verify config file exists inside the container
echo "Verifying config file exists at ${CONFIG_FILE_CONTAINER}..."
if docker exec cron-test test -f "${CONFIG_FILE_CONTAINER}"; then
  echo "Config file ${CONFIG_FILE_CONTAINER} exists inside the container."
else
  echo "Error: Config file ${CONFIG_FILE_CONTAINER} not found inside the container."
  docker logs cron-test || true
  exit 1
fi

# Check cron process inside container
echo "Checking for crond process..."
if docker exec cron-test sh -lc 'ps -eo pid,comm,args | grep -i crond'; then
  echo 'Cron process is running inside the container.'
else
  echo 'Cron process did not start as expected.'
  echo 'Attempting extra debug: list /etc/crontabs'
  docker exec cron-test sh -lc 'ls -l /etc/crontabs || true'
  docker exec cron-test sh -lc 'ps -eo pid,comm,args | grep -i crond || true'
  docker logs cron-test || true
  exit 1
fi

# Verify cron jobs are loaded from config
echo "Verifying cron jobs by listing crontab entries..."
# Extract just the commands for checking presence in crontab output
EXPECTED_COMMANDS=$(jq -c '.[] | .command' /Users/ankit/dev/docker-crontab/config-samples/config.sample.json)

CRON_OUTPUT=$(docker exec cron-test crontab -l || echo "crontab: no crontab for root")

echo "Expected commands from config:"
echo "$EXPECTED_JOBS" # This should now be EXPECTED_COMMANDS
echo ""
echo "Actual crontab output:"
echo "$CRON_OUTPUT"
echo ""

JOB_CHECK_PASSED=true
if echo "$CRON_OUTPUT" | grep -q "crontab: no crontab for root"; then
    echo "Error: crontab -l reported no crontab for root, but we expected jobs."
    JOB_CHECK_PASSED=false
else
    while IFS= read -r COMMAND; do
        # Remove quotes from command for a cleaner grep
        CLEAN_COMMAND=$(echo "$COMMAND" | tr -d '"')
        if echo "$CRON_OUTPUT" | grep -q "$CLEAN_COMMAND"; then
            echo "Found job containing command: '$CLEAN_COMMAND'"
        else
            echo "Missing job command: '$CLEAN_COMMAND'"
            JOB_CHECK_PASSED=false
        fi
    done <<< "$EXPECTED_COMMANDS"
fi

if [ "$JOB_CHECK_PASSED" = false ]; then
  echo "Cron job verification failed. Some expected jobs or crond loading issue."
  exit 1
else
  echo "Cron job verification passed. Detected expected job commands in crontab."
fi

# Cleanup is handled by trap EXIT
