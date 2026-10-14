#!/usr/bin/env bash
# Self-check for git-status.sh. Builds throwaway repositories covering each
# branch of the "is this repo pending?" decision and asserts the verdict.
#
#   ./core/git-status.test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-status.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email test@example.com
git config --global user.name Test
git config --global init.defaultBranch main

failures=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   $label"
  else
    echo "FAIL $label: expected '$expected', got '$actual'"
    failures=$((failures + 1))
  fi
}

# A repo with one commit, plus a bare "remote" it is already pushed to.
seed() {
  local repo="$WORK/repos/$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  echo seed > "$repo/file"
  git -C "$repo" add file
  git -C "$repo" commit -qm seed
  git init -q --bare "$WORK/remotes/$1.git"
  git -C "$repo" remote add origin "$WORK/remotes/$1.git"
  echo "$repo"
}

verdict() { "$SCRIPT" 3 "$WORK/repos" | jq -r '.state'; }
issues_for() { "$SCRIPT" 3 "$WORK/repos" | jq -r --arg n "$1" '.pending[] | select(.name == $n) | .issues'; }

# No remote at all: nothing to be out of sync with.
repo=$(seed local-only)
git -C "$repo" remote remove origin
check "repo with no remote is synced" synced "$(verdict)"
rm -rf "$WORK/repos" "$WORK/remotes"

# Pushed without -u. No upstream is configured, but HEAD is on the remote, so
# this must NOT be reported — the regression this fallback exists for.
repo=$(seed pushed-no-upstream)
git -C "$repo" push -q origin main
check "pushed without -u is synced" synced "$(verdict)"

# Same repo, now with a commit that never left.
echo more > "$repo/file"
git -C "$repo" commit -qam second
check "unpushed commit without upstream" "unpushed" "$(issues_for pushed-no-upstream)"
rm -rf "$WORK/repos" "$WORK/remotes"

# Tracking branch configured, one commit ahead.
repo=$(seed tracking)
git -C "$repo" push -qu origin main
echo more > "$repo/file"
git -C "$repo" commit -qam second
check "commit ahead of upstream" "1 unpushed commit(s)" "$(issues_for tracking)"

# An untracked file is pending work too, and both issues are reported together.
touch "$repo/scratch"
check "untracked file plus ahead" "uncommitted changes, 1 unpushed commit(s)" "$(issues_for tracking)"
rm -rf "$WORK/repos" "$WORK/remotes"

# Folders that cannot be scanned are reported as watched folders in a
# non-ok state, not as pending repos.
mkdir -p "$WORK/repos"
check "missing folder is reported missing" missing \
  "$("$SCRIPT" 3 "$WORK/gone" | jq -r '.watched[0].state')"
check "folder without repos is reported empty" empty \
  "$("$SCRIPT" 3 "$WORK/repos" | jq -r '.watched[0].state')"

# Per-folder counts are what the panel prints under each folder.
repo=$(seed counted)
touch "$repo/scratch"
clean=$(seed clean-one)
git -C "$clean" push -q origin main
check "folder repo count" 2 "$("$SCRIPT" 3 "$WORK/repos" | jq -r '.watched[0].repos')"
check "folder pending count" 1 "$("$SCRIPT" 3 "$WORK/repos" | jq -r '.watched[0].pending')"

# The panel expands a folder with every repository below it, pending or not,
# each with an absolute path so its menu can act on it without re-resolving.
check "repoList holds every repo of the folder" 2 \
  "$("$SCRIPT" 3 "$WORK/repos" | jq -r '.watched[0].repoList | length')"
check "repoList marks the dirty repo pending" true \
  "$("$SCRIPT" 3 "$WORK/repos" | jq -r '.watched[0].repoList[] | select(.name == "counted") | .pending')"
check "repoList marks the clean repo synced" false \
  "$("$SCRIPT" 3 "$WORK/repos" | jq -r '.watched[0].repoList[] | select(.name == "clean-one") | .pending')"
check "repoList paths are absolute" true \
  "$("$SCRIPT" 3 "$WORK/repos" | jq -r --arg w "$WORK" '.watched[0].repoList[0].path | startswith($w)')"
check "empty folder gets an empty repoList" 0 \
  "$("$SCRIPT" 3 "$WORK/plain" | jq -r '.watched[0].repoList | length')"
check "missing folder gets an empty repoList" 0 \
  "$("$SCRIPT" 3 "$WORK/gone" | jq -r '.watched[0].repoList | length')"

# --- trusted environment -----------------------------------------------------
# A writable directory ahead of the real one in PATH must not get to supply the
# helpers: the script pins its own PATH and calls them by absolute path. This is
# the finding the ceilings and the pinning were both added for.
mkdir -p "$WORK/evil"
printf '#!/bin/sh\ntouch "$WORK/pwned"\n' > "$WORK/evil/git"
chmod +x "$WORK/evil/git"
PATH="$WORK/evil:$PATH" WORK="$WORK" "$SCRIPT" 3 "$WORK/repos" >/dev/null 2>&1
check "a hijacked PATH is ignored" absent \
  "$([ -e "$WORK/pwned" ] && echo present || echo absent)"

# Shape check, not a behaviour one: the traversal cap has to sit in FRONT of
# sort(1), which cannot emit a single line until it has consumed -- and buffered
# or spilled -- everything find produced. Swap the two and the ceiling below
# still passes while the producer runs unbounded again.
check "discovery is capped before it is sorted" present \
  "$(grep -qF '"$HEAD" -n "$((MAX_REPOS_PER_DIR + 1))" | "$SORT"' "$SCRIPT" && echo present || echo absent)"

# --- ceilings ----------------------------------------------------------------
# The watch roots come from user settings, so the caps are the only thing
# between "~/" at depth 8 and a wedged panel. Crossing one must be reported as
# an error, never as a short result the panel would paint green.
error_for() { "$SCRIPT" "$@" | jq -r '.state + ": " + (.error // "")'; }

mkdir -p "$WORK/many"
too_many=()
for i in $(seq 25); do too_many+=("$WORK/many"); done
check "too many watched folders is rejected" \
  "error: too many watched folders (limit 24)" \
  "$(error_for 3 "${too_many[@]}")"

# find(1) only matches on the directory name, so bare .git dirs are enough to
# trip the cardinality cap -- it is checked before any repo is opened.
for i in $(seq 201); do mkdir -p "$WORK/many/r$i/.git"; done
check "too many repos under one folder is rejected" \
  "error: too many repositories under one folder (limit 200)" \
  "$(error_for 3 "$WORK/many")"
rm -rf "$WORK/many"

# maxDepth arrives as a string from the widget settings.
mkdir -p "$WORK/plain"
check "non-numeric depth falls back instead of erroring" synced \
  "$("$SCRIPT" "; rm -rf /" "$WORK/plain" | jq -r '.state')"

# --- supervisor ---------------------------------------------------------------
# A straggler that ignores TERM and outlives its script must still be KILLed,
# by the supervisor from inside the group, whichever way the TERM arrives.
SUPERVISE="$(dirname "$SCRIPT")/supervise.sh"
straggler() { echo "(trap '' TERM; exec sleep 30) & echo \$! > '$WORK/straggler'; wait"; }
alive() { kill -0 "$(cat "$WORK/straggler")" 2>/dev/null && echo alive || echo dead; }

(timeout 1s bash "$SUPERVISE" 1 bash -c "$(straggler)"; :) 2>/dev/null
check "a TERM-proof straggler dies after the deadline" dead "$(alive)"

timeout 30s bash "$SUPERVISE" 1 bash -c "$(straggler)" &
sleep 0.5; kill -TERM $!; wait $! 2>/dev/null
check "a TERM-proof straggler dies after an abort" dead "$(alive)"

check "a clean run keeps its exit code" 3 \
  "$(timeout 5s bash "$SUPERVISE" 1 bash -c 'exit 3'; echo $?)"

[ $failures -eq 0 ] || { echo "$failures check(s) failed"; exit 1; }
echo "all checks passed"
