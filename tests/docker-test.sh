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

MINIMAL_CONFIG_FLAG=$2 # Check if --minimal flag is passed

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

# Run container
printf 'Running container with config...\n'
# Determine repository root dynamically to make path resolvable in CI
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE_HOST="$REPO_ROOT/config-samples/config.sample.json"
CONFIG_FILE_CONTAINER=/opt/crontab/config.json
DOCKER_RUN_CMD="docker run -d --name cron-test --cap-add SYS_ADMIN --cap-add SYS_TIME"

# Use minimal config if flag is set
if [ "$MINIMAL_CONFIG_FLAG" = "--minimal" ]; then
  CONFIG_FILE_HOST="$REPO_ROOT/config-samples/config.minimal.json"
  CONFIG_FILE_CONTAINER=/opt/crontab/config.json # Still mount to the same place inside container
  # Override CMD to run crond directly and ensure stdout is captured
  DOCKER_RUN_CMD="docker run --name cron-test --cap-add SYS_ADMIN --cap-add SYS_TIME -v ${CONFIG_FILE_HOST}:${CONFIG_FILE_CONTAINER}"
fi

$DOCKER_RUN_CMD -v "${CONFIG_FILE_HOST}:${CONFIG_FILE_CONTAINER}" -v /var/run/docker.sock:/var/run/docker.sock "$IMAGE"

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

# Wait additional time for crontab to be built
echo "Waiting for crontab to be built..."
sleep 10 # Increased sleep duration

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

# Determine expected number of cron jobs from config
EXPECTED_CRON_JOBS=$(jq -r '. | length' "$REPO_ROOT/config-samples/config.sample.json")
if [ "$MINIMAL_CONFIG_FLAG" = "--minimal" ]; then
  EXPECTED_CRON_JOBS=$(jq -r '. | length' "$REPO_ROOT/config-samples/config.minimal.json")
fi

# Check that the expected number of crontab entries exist (excluding comments)
CRON_ENTRY_COUNT=$(docker exec cron-test grep -c "^[^#]" /etc/crontabs/docker)
echo "Found ${CRON_ENTRY_COUNT} cron entries (excluding comments); expected ${EXPECTED_CRON_JOBS}"

# For debugging, show the crontab content
echo "Actual crontab output from /etc/crontabs/docker:"
docker exec cron-test cat /etc/crontabs/docker

if [ "$CRON_ENTRY_COUNT" -eq "$EXPECTED_CRON_JOBS" ]; then
  echo "✓ All ${EXPECTED_CRON_JOBS} cron jobs are present in the crontab"
else
  echo "✗ Expected ${EXPECTED_CRON_JOBS} cron jobs, found ${CRON_ENTRY_COUNT}"
  exit 1
fi

# Verify that wrapper scripts contain the expected commands
echo ""
echo "Verifying wrapper scripts contain expected commands..."
EXPECTED_COMMANDS=$(jq -r '.[].command' "$CONFIG_FILE_HOST") # Use the correct config file based on flag
JOB_CHECK_PASSED=true

# Get job and project script contents from the container
JOB_SCRIPTS=$(docker exec cron-test sh -c 'cat /opt/crontab/jobs/*.sh' 2>/dev/null || true)
PROJECT_SCRIPTS=$(docker exec cron-test sh -c 'cat /opt/crontab/projects/*.sh' 2>/dev/null || true)
ALL_SCRIPTS="${JOB_SCRIPTS}${PROJECT_SCRIPTS}"

while IFS= read -r CMD; do
  # Extract the core command without quotes for easier matching
  CORE_CMD=$(echo "$CMD" | tr -d "\"")

  # For commands starting with 'sh -c', extract the inner command
  if echo "$CORE_CMD" | grep -q "^sh -c "; then
    # Extract command inside sh -c quotes
    INNER_CMD=$(echo "$CORE_CMD" | sed "s|^sh -c '||;s|'$||")
    # Search for docker run/exec patterns that contain the inner command
    if echo "$ALL_SCRIPTS" | grep -qF "$INNER_CMD"; then
      echo "✓ Found command in script: '$CMD'"
    else
      echo "✗ Command not found in scripts: '$CMD'"
      JOB_CHECK_PASSED=false
    fi
  else
    # For direct commands, search them in the first 4 words (ignoring leading echo)
    if echo "$ALL_SCRIPTS" | grep -qF "$CORE_CMD"; then
      echo "✓ Found command in script: '$CMD'"
    else
      echo "✗ Command not found in scripts: '$CORE_CMD'"
      JOB_CHECK_PASSED=false
    fi
  fi
done <<< "$EXPECTED_COMMANDS"

if [ "$JOB_CHECK_PASSED" = false ]; then
  echo "Cron job verification failed. Some expected jobs or crond loading issue."
  echo "Dumping container logs for debugging..."
  docker logs cron-test || true
  exit 1
else
  echo "Cron job verification passed. Detected expected job commands in crontab."
fi

# Extra concrete verification: ensure the test log write cron actually executed at least once via log file...
echo ""
echo "Verifying that the test log write cron actually executed at least once via container logs..."
LOG_CHECK_TIMEOUT=120 # Increased timeout to ensure cron has time to run and its output is captured
LOG_CHECK_INTERVAL=5
ELAPSED=0
LOG_LINE=""

# Wait for the log file to appear and contain output
while [ $ELAPSED -lt $LOG_CHECK_TIMEOUT ]; do
  CONTAINER_LOGS=$(docker logs cron-test 2>/dev/null || echo "log_capture_failed")
  if echo "$CONTAINER_LOGS" | grep -qE 'cron-output-'; then
    LOG_LINE=$(echo "$CONTAINER_LOGS" | grep 'cron-entry-') # Capture the specific log line
    break
  fi
  sleep $LOG_CHECK_INTERVAL
  ELAPSED=$((ELAPSED+LOG_CHECK_INTERVAL))
done

# Check if log line was found
if echo "$LOG_LINE" | grep -qE 'cron-entry-'; then
  echo "✓ Detected cron output in container logs: $LOG_LINE"
else
  echo "✗ No cron output detected in container logs after waiting ${LOG_CHECK_TIMEOUT}s."
  echo "Container logs:"
  docker logs cron-test 2>/dev/null || echo "Log capture failed."
  exit 1
fi

# Cleanup is handled by trap EXIT
