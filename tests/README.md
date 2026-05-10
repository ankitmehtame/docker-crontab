## docker-crontab tests

What this test verifies
- Builds the Docker image (`docker-crontab-test`) and runs a container with a sample cron config mounted.
- Verifies crond process is running inside the container.
- Verifies all 6 cron jobs from `config.sample.json` are correctly generated in `/etc/crontabs/docker`.
- Validates that expected commands are present in the generated wrapper scripts (`/opt/crontab/jobs/*.sh` and `/opt/crontab/projects/*.sh`).

Files involved
- `tests/docker-test.sh`: The automation test that builds, runs, and validates the cron config.
- `config-samples/config.sample.json`: Sample configuration with 6 cron jobs used by the test.
- `docker-entrypoint`: The entrypoint script that generates crontab from config (also modified in this branch).

How to run locally
- Ensure Docker is running on your machine.
- Run: `bash tests/docker-test.sh`
- The script will:
  1. Build the Docker image
  2. Start a container with config and Docker socket mounted
  3. Wait for crond to start and crontab to be generated
  4. Verify 6 cron entries exist in the crontab
  5. Verify all expected commands are in the wrapper scripts
  6. Clean up container and image on exit

Cron jobs in config.sample.json
1. **cron with triggered commands**: `echo hello` with trigger `echo world` in container
2. **map a volume**: `echo new` with docker volume args
3. **use an ENV from inside a container**: `sh -c 'echo hourly ${FOO}'` with env var
4. **trigger every 2 min**: `echo 2 minute` with trigger
5. **logrotate**: `/usr/sbin/logrotate /etc/logrotate.conf`
6. **Regenerate Certificate**: Complex `dehydrated` command with trigger for nginx reload

Notes
- The test performs presence checks by searching for command strings in the generated wrapper scripts.
- Commands using `project` and `container` fields are wrapped in project scripts under `/opt/crontab/projects/`.
- Commands using `trigger` are appended to the same wrapper script as the main command.
- If you want more thorough schedule-structure verification, the parser can be enhanced to compare exact crontab lines and times.
