#!/usr/bin/env bash
# The runner's action archive cache (ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE): the runner takes
# <cache>/<owner>_<repo>/<sha>.tar.gz instead of downloading the action from codeload.github.com,
# which answers a busy address HTTP 429 and fails the job in "Set up job".
#
#   action-archives.sh seed <actions.txt> <cache>   download each listed owner/repo@sha the cache
#                                                   lacks (image build, and the entrypoint for a
#                                                   repository's own list)
#   action-archives.sh keep <_actions dir> <cache>  archive every action a job fetched that the cache
#                                                   lacks (the job-completed hook), so a new pin is
#                                                   downloaded once, not per job
#
# See README.md, "Action archives".
set -euo pipefail

log() { echo "[action-archives] $*"; }

# The archive's path in the cache, as the runner looks it up.
archive_path() { echo "$1/${2//\//_}/$3.tar.gz"; }

seed() {
  local list="$1" cache="$2" line repository sha target
  # GITHUB_TOKEN_FILE, when it names a readable file, authenticates the API call; curl drops the
  # header on the redirect to codeload, another host.
  local auth=()
  if [ -r "${GITHUB_TOKEN_FILE:-}" ] && [ -s "${GITHUB_TOKEN_FILE}" ]; then
    auth=(-H "Authorization: Bearer $(cat "$GITHUB_TOKEN_FILE")")
    log "authenticated with the build's GitHub token"
  else
    log "anonymous: no GitHub token; the API allows 60 requests an hour per address"
  fi
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [ -z "$line" ] && continue
    repository="${line%@*}"
    sha="${line#*@}"
    if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      log "ERROR: $line is not pinned to a full commit"
      return 1
    fi
    target="$(archive_path "$cache" "$repository" "$sha")"
    if [ -f "$target" ]; then
      log "has $repository@$sha"
      continue
    fi
    mkdir -p "$(dirname "$target")"
    # The API's tarball redirects to a signed codeload URL; codeload's plain one is throttled per IP.
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 "${auth[@]}" -o "$target.partial" \
      "https://api.github.com/repos/$repository/tarball/$sha"
    gzip -t "$target.partial"
    mv "$target.partial" "$target"
    log "cached $repository@$sha ($(stat -c %s "$target") bytes)"
  done <"$list"
}

# Never fails the job: the cache only spares downloads, so a miss is logged and the job goes on.
keep() {
  local actions="$1" cache="$2" directory owner repository sha target kept=0
  [ -d "$actions" ] || { log "no actions fetched in $actions"; return 0; }
  for directory in "$actions"/*/*/*/; do
    directory="${directory%/}"
    sha="$(basename "$directory")"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || continue
    repository="$(basename "$(dirname "$directory")")"
    owner="$(basename "$(dirname "$(dirname "$directory")")")"
    target="$(archive_path "$cache" "$owner/$repository" "$sha")"
    [ -f "$target" ] && continue
    mkdir -p "$(dirname "$target")"
    # The runner unpacks an archive's one top-level folder, as in GitHub's own archives.
    if tar -czf "$target.partial" -C "$(dirname "$directory")" --transform "s|^$sha|$repository-$sha|" "$sha" \
      && mv "$target.partial" "$target"; then
      log "kept $owner/$repository@$sha"
      kept=$((kept + 1))
    else
      rm -f "$target.partial"
      log "WARNING: could not archive $owner/$repository@$sha; the next job downloads it again"
    fi
  done
  log "kept $kept new action archive(s) in $cache"
}

case "${1:-}" in
  seed) seed "$2" "$3" ;;
  keep) keep "$2" "$3" || log "WARNING: keeping the action archives failed; the job is unaffected" ;;
  *)
    echo "usage: $0 seed <actions.txt> <cache> | keep <_actions dir> <cache>" >&2
    exit 2
    ;;
esac
