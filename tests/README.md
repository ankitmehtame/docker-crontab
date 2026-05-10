## docker-crontab tests

What this test verifies
- Builds the Docker image and runs a container with a sample cron config mounted.
- Verifies crond starts inside the container.
- Lists the loaded cron jobs via crontab -l and validates the jobs defined in config.sample.json are present.

Files involved
- tests/docker-test.sh: The automation test that builds, runs, and validates the cron config.

How to run locally
- Ensure you're on branch feat/test-docker-ci-main.
- Run: bash tests/docker-test.sh docker-crontab-test
- The script mounts config-samples/config.sample.json to /opt/crontab/config.json inside the container and uses the Docker socket if available.

Cron jobs in config.sample.json (high-level)
- cron with triggered commands: schedule "* * * * *" command "echo hello" and trigger "echo world" in container crontab_myapp_1
- map a volume: schedule "* * * * *" command "echo new" with dockerargs
- hourly job, etc...
- The test will print and verify presence of these commands in the crontab output.

Notes
- The test currently performs a basic presence check (the commands exist in crontab). If you want more thorough schedule-structure verification, we can enhance the parser to compare exact crontab lines and times.
