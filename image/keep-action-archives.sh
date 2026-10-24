#!/usr/bin/env bash
# The runner's job-completed hook (ACTIONS_RUNNER_HOOK_JOB_COMPLETED): keeps the actions the job
# fetched in the action archive cache. Always exits 0: a failing hook would fail the job.
set -uo pipefail
/usr/local/bin/github-runner-action-archives keep /home/runner/_work/_actions "${ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE:-/cache/action-archives}"
exit 0
