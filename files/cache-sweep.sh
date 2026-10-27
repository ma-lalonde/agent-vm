#!/bin/bash
# Daily cache sweep for the agent VM: no regenerable cache keeps anything
# older than MAX_AGE_DAYS (default 7).
#
# - Caches whose entries stand alone (content-addressed stores, logs) lose
#   only the files older than the limit.
# - Caches whose entries depend on each other are wiped whole, with their
#   own tool where it has one, once their oldest file passes the limit.
# - Docker drops unused images and build cache older than the limit.
#   Volumes are data and are never touched.
# - A cache whose tool is running right now is left for the next run.
#
# A file's age is its ctime, the time it landed on this VM: unpacked
# archives (Go modules, uv) keep the mtimes stored inside the archive.
set -uo pipefail

MAX_AGE_DAYS="${MAX_AGE_DAYS:-7}"
MAX_AGE_MIN=$((MAX_AGE_DAYS * 1440))
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"

# busy <process name>; "-" means the cache has no tool to wait for.
busy() {
  [ "$1" != "-" ] && pgrep -u "$(id -u)" -x "$1" >/dev/null
}

has_old_files() {
  [ -d "$1" ] && [ -n "$(find "$1" -xdev -type f -cmin +"$MAX_AGE_MIN" -print -quit 2>/dev/null)" ]
}

prune_old_files() {
  [ -d "$1" ] || return 0
  find "$1" -xdev -type f -cmin +"$MAX_AGE_MIN" -delete 2>/dev/null
  find "$1" -xdev -mindepth 1 -type d -empty -delete 2>/dev/null
  return 0
}

# wipe_when_old <dir> <tool process name> <wipe command...>
wipe_when_old() {
  local dir="$1" tool="$2"
  shift 2
  has_old_files "$dir" || return 0
  if busy "$tool"; then
    echo "skip $dir: $tool is running"
    return 0
  fi
  echo "wipe $dir (holds files older than $MAX_AGE_DAYS days)"
  "$@" || echo "wipe of $dir failed"
}

echo "before: $(df -h --output=avail / | tail -1) free on /"

prune_old_files "$CACHE/go-build"
prune_old_files "$CACHE/pip"
prune_old_files "$HOME/.npm/_cacache"
prune_old_files "$HOME/.npm/_logs"
prune_old_files "$CACHE/claude-cli-nodejs"
prune_old_files "$CACHE/restic"

wipe_when_old "$HOME/go/pkg/mod" go go clean -modcache
wipe_when_old "$CACHE/uv" uv uv cache clean
wipe_when_old "$CACHE/pre-commit" pre-commit pre-commit clean
wipe_when_old "$CACHE/trivy" trivy rm -rf "$CACHE/trivy"
wipe_when_old "$CACHE/scanctl" scanctl rm -rf "$CACHE/scanctl"
wipe_when_old "$CACHE/node-gyp" - rm -rf "$CACHE/node-gyp"
wipe_when_old "$CACHE/typescript" - rm -rf "$CACHE/typescript"

# Any other cache directory follows the XDG rule (regenerable data) and
# loses its old files.
for d in "$CACHE"/*/; do
  case "$(basename "$d")" in
    go-build|pip|claude-cli-nodejs|restic|uv|pre-commit|trivy|scanctl|node-gyp|typescript) ;;
    *) prune_old_files "$d" ;;
  esac
done

if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  docker builder prune -f --filter "until=$((MAX_AGE_DAYS * 24))h" >/dev/null
  docker image prune -a -f --filter "until=$((MAX_AGE_DAYS * 24))h" >/dev/null
fi

echo "after: $(df -h --output=avail / | tail -1) free on /"
