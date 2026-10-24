#!/usr/bin/env bash
# The runner's entrypoint. Registers the runner once, with a registration token from the
# repository's Settings (RUNNER_TOKEN, valid for an hour), keeps the runner's own credentials in the
# state volume, and starts every later time without a token. Every start begins with an empty
# workspace. Never prints the token. See README.md.
#
#   RUNNER_REPOSITORY_URL  required  https://github.com/<owner>/<repo> the runner serves
#   RUNNER_NAME            required  its name in the repository's runner list
#   RUNNER_LABELS          optional  comma-separated labels beside self-hosted,linux,x64
#   RUNNER_TOKEN           first start only
#   RUNNER_STATE           the state volume (default /runner-state)
#   ACTION_ARCHIVES        the repository's own action list (default /etc/github-runner/actions.txt)
set -euo pipefail

log() { echo "[github-runner] $*"; }
fail() {
  log "ERROR: $*"
  exit 1
}

repository_url="${RUNNER_REPOSITORY_URL:-}"
runner_name="${RUNNER_NAME:-}"
runner_labels="${RUNNER_LABELS:-}"
state="${RUNNER_STATE:-/runner-state}"
archives="${ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE:-/cache/action-archives}"
runner_home=/home/runner
registration=(.runner .credentials .credentials_rsaparams)

[ -n "$repository_url" ] || fail "RUNNER_REPOSITORY_URL is not set; set it to https://github.com/<owner>/<repo>"
[ -n "$runner_name" ] || fail "RUNNER_NAME is not set; give each runner its own name"

for directory in "$state" /cache; do
  [ -w "$directory" ] || fail "$directory is not writable by uid $(id -u); chown it to $(id -u):$(id -g) on the host"
done
mkdir -p "$archives" /cache/mise /cache/toolcache /cache/yarn

# The image's archives join those the hook kept; none is overwritten.
cp -r --update=none /opt/action-archives/. "$archives/"
# The repository's own actions, each downloaded once: a miss only costs the job a download.
if [ -f "${ACTION_ARCHIVES:-}" ]; then
  github-runner-action-archives seed "$ACTION_ARCHIVES" "$archives" ||
    log "WARNING: some archives of $ACTION_ARCHIVES were not cached; jobs download those, and the hook keeps them"
else
  log "No repository action list at ${ACTION_ARCHIVES:-<unset>}; only the image's archives and the hook's are cached"
fi
log "Action archive cache: $(find "$archives" -name '*.tar.gz' | wc -l) archive(s) in $archives"
log "Limits: open files $(ulimit -Sn) (hard $(ulimit -Hn)), /dev/shm $(df -h /dev/shm | awk 'NR==2 {print $2}'), CPUs $(nproc)"

cd "$runner_home"
log "Emptying the workspace left by the previous start"
rm -rf "$runner_home/_work"
mkdir -p "$runner_home/_work"

# The runner writes .runner with a byte order mark.
runner_field() { sed '1s/^\xEF\xBB\xBF//' "$1" | jq -r "$2"; }

if [ -f "$state/.runner" ]; then
  for file in "${registration[@]}"; do
    [ -f "$state/$file" ] || fail "$state/$file is missing; the registration is incomplete. Empty $state and register again"
  done
  registered_url="$(runner_field "$state/.runner" '.gitHubUrl')"
  if [ "${registered_url%/}" != "${repository_url%/}" ]; then
    fail "$state holds a registration for $registered_url, not $repository_url; empty it to register again"
  fi
  for file in "${registration[@]}"; do cp "$state/$file" "$runner_home/$file"; done
  log "Registered as $(runner_field .runner '.agentName') on $registered_url"
elif [ -n "${RUNNER_TOKEN:-}" ]; then
  log "Registering $runner_name on $repository_url with labels self-hosted,linux,x64${runner_labels:+,$runner_labels}"
  labels=()
  [ -n "$runner_labels" ] && labels=(--labels "$runner_labels")
  ./config.sh --unattended --replace \
    --url "$repository_url" \
    --token "$RUNNER_TOKEN" \
    --name "$runner_name" \
    "${labels[@]}" \
    --work _work
  umask 077
  for file in "${registration[@]}"; do cp "$runner_home/$file" "$state/$file"; done
  log "Registered; the credentials are in $state. Remove RUNNER_TOKEN from the env file now"
else
  fail "not registered yet and no RUNNER_TOKEN; create one in the repository's Settings > Actions >" \
    "Runners > New self-hosted runner, put it in the env file, and start again"
fi

unset RUNNER_TOKEN
log "Listening for jobs"
exec ./run.sh
