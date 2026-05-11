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
# Determine repository root dynamically to make path resolvable in CI
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE_HOST="$REPO_ROOT/config-samples/config.sample.json"
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
EXPECTED_COMMANDS=$(jq -r '.[].command' "$REPO_ROOT/config-samples/config.sample.json")
JOB_CHECK_PASSED=true

# Get job and project script contents from the container
JOB_SCRIPTS=$(docker exec cron-test sh -c 'cat /opt/crontab/jobs/*.sh' 2>/dev/null || true)
PROJECT_SCRIPTS=$(docker exec cron-test sh -c 'cat /opt/crontab/projects/*.sh' 2>/dev/null || true)
ALL_SCRIPTS="${JOB_SCRIPTS}${PROJECT_SCRIPTS}"

# Function to ensure docker command is in PATH for docker exec commands within cron jobs
ensure_docker_in_path() {
  echo "Ensure docker is in PATH"
  # This function is executed within the context of `docker exec` in the test script
  # We need to ensure that when cron jobs themselves are executed, `docker` is found.
  # Modifying the PATH for the `docker exec` command itself is not enough.
  # We will ensure the PATH is set correctly when the wrapper scripts are generated.
  # For this test script, we will explicitly call docker with its full path if needed.
  # However, the underlying issue is within the container at runtime for cron jobs.
  # Let's try modifying the script that generates the cron jobs to ensure the PATH is set there.
  # The most robust fix is to ensure PATH is set in the container's profile or entrypoint.
  # For this specific test, we'll try to prepend PATH to docker exec, but this might not be
  # the fundamental fix for cron execution in general.
  echo "Attempting to use full path for docker commands"
}

while IFS= read -r CMD; do
  # Extract the core command without quotes for easier matching
  CORE_CMD=$(echo "$CMD" | tr -d "\"")

  # For commands starting with 'sh -c', extract the inner command
  if echo "$CORE_CMD" | grep -q "^sh -c "; then
    # Extract command inside sh -c quotes
    INNER_CMD=$(echo "$CORE_CMD" | sed "s|^sh -c '||;s|'$||")
    # Search for docker run/exec patterns that contain the inner command
    # Prepend /usr/bin to ensure docker command is found (if it's not in default path)
    if echo "$ALL_SCRIPTS" | grep -qF "/usr/bin/docker exec $INNER_CMD" || echo "$ALL_SCRIPTS" | grep -qF "docker exec $INNER_CMD"; then
      echo "✓ Found command in script: '$CMD'"
    else
      echo "✗ Command not found in scripts: '$CMD'"
      JOB_CHECK_PASSED=false
    fi
  else
    # For direct commands, search them in the first 4 words (ignoring leading echo)
    if echo "$ALL_SCRIPTS" | grep -qF "/usr/bin/$CORE_CMD" || echo "$ALL_SCRIPTS" | grep -qF "$CORE_CMD"; then
      echo "✓ Found command in script: '$CMD'"
    else
      echo "✗ Command not found in scripts: '$CORE_CMD'"
      JOB_CHECK_PASSED=false
    fi
  fi
done <<< "$EXPECTED_COMMANDS"

if [ "$JOB_CHECK_PASSED" = false ]; then
  echo "Cron job verification failed. Some expected jobs or crond loading issue."
  exit 1
else
  echo "Cron job verification passed. Detected expected job commands in crontab."
fi

# Extra concrete verification: ensure the test log write cron actually executed at least once via log file...
echo ""
echo "Verifying that the test log write cron actually executed at least once via log file..."
LOG_CHECK_TIMEOUT=120 # Increased timeout to ensure cron has time to run and its output is captured
LOG_CHECK_INTERVAL=5
ELAPSED=0
LOG_LINE=""

# Wait for the log file to appear and contain output
while [ $ELAPSED -lt $LOG_CHECK_TIMEOUT ]; do
  # Use /usr/bin/docker to ensure we find the docker command
  LOG_CONTENT=$(/usr/bin/docker exec cron-test cat /var/log/crontab/jobs.log 2>/dev/null || echo "file_not_found")
  if echo "$LOG_CONTENT" | grep -qE 'cron-output-'; then
    LOG_LINE=$(echo "$LOG_CONTENT" | grep 'cron-entry-') # Capture the specific log line
    break
  fi
  sleep $LOG_CHECK_INTERVAL
  ELAPSED=$((ELAPSED+LOG_CHECK_INTERVAL))
done

# Check if log line was found
if echo "$LOG_LINE" | grep -qE 'cron-entry-'; then
  echo "✓ Detected cron output in /var/log/crontab/jobs.log: $LOG_LINE"
else
  echo "✗ No cron log entry detected in /var/log/crontab/jobs.log after waiting ${LOG_CHECK_TIMEOUT}s."
  echo "Last known log content:"
  /usr/bin/docker exec cron-test cat /var/log/crontab/jobs.log 2>/dev/null || echo "Log file not found or empty."
  exit 1
fi

# Cleanup is handled by trap EXIT
