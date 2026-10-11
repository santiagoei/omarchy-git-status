#!/usr/bin/env bash
# Portable git repository sync indicator.
#
# Walks every git repository under the directories given on the command line
# and reports which ones have work "pending to sync":
#   - uncommitted changes (dirty working tree or untracked files).
#   - local commits ahead of the upstream tracking branch.
#   - HEAD not reachable from any remote tracking ref (when no upstream is
#     configured but at least one remote exists).
#
# Usage: git-status.sh <max_depth> <dir> [dir...]
#        `~` at the start of a dir expands to $HOME.
#
# Emits a single JSON object on stdout:
#
#   {
#     "state": "synced" | "unsynced",
#     "scanned": 12,
#     "pending": [{"name": "foo", "path": "/home/me/code/foo",
#                  "dir": "~/code", "issues": "uncommitted changes"}],
#     "watched": [{"path": "~/code", "state": "ok", "repos": 12, "pending": 1}]
#   }
#
# A watched folder's state is "ok", "missing" (not a directory) or "empty" (no
# repositories below it).
#
# The watch roots come from user settings, so any of them may be enormous. Every
# limit below is a hard ceiling: crossing one aborts the whole scan with
#
#   {"state": "error", "error": "<reason>", "scanned": 0, "pending": [],
#    "watched": []}
#
# rather than returning a truncated result -- a partial scan that says "synced"
# is a lie, and the panel would paint it green.
#
# Rendering (icons, colors, layout) belongs to the caller. Deps: bash, git, jq.

set -uo pipefail

# --- trusted environment -----------------------------------------------------
# This runs from a bar widget that lives for the whole session and re-scans on a
# timer, so resolving helpers through an inherited PATH would re-execute
# whatever `git` or `jq` sits earliest in it, forever. Resolve each one once from
# a PATH we control and call it by absolute path from here on. The unsets close
# the other inherited-environment doors into those same binaries.
export PATH=/usr/bin:/bin
export LC_ALL=C
unset -v BASH_ENV ENV CDPATH GLOBIGNORE LD_PRELOAD LD_LIBRARY_PATH IFS

# jq may be the thing that is missing, so this error object is written by hand.
die() {
  printf '{"state":"error","error":"%s","scanned":0,"pending":[],"watched":[]}\n' "$1"
  exit 1
}

FIND=$(type -P find) || true
SORT=$(type -P sort) || true
GIT=$(type -P git) || true
JQ=$(type -P jq) || true
HEAD=$(type -P head) || true
for bin in "$FIND" "$SORT" "$GIT" "$JQ" "$HEAD"; do
  [ -n "$bin" ] && [ -x "$bin" ] || die "a required helper is missing from $PATH"
done

# --- ceilings ----------------------------------------------------------------
MAX_WATCH_DIRS=24       # watch roots accepted per run
MAX_REPOS_PER_DIR=200   # repositories found below one root
MAX_REPOS_TOTAL=500     # repositories across all roots
MAX_GIT_BYTES=4096      # bytes read from any single git invocation
MAX_STRING=256          # characters kept from any name, path or issue list
MAX_OUTPUT_BYTES=524288 # size of the JSON object we are willing to emit
DEADLINE_SEC=20         # wall clock for the whole job; the caller also wraps
                        # this script in `timeout` and supervise.sh, which kill
                        # find/git if they wedge below the point of no return

# The watch roots are stored with `~` in them, so there is nothing to scan
# without it. Says so, rather than dying on `set -u` halfway down.
[ -n "${HOME:-}" ] || die "HOME is not set"

MAX_DEPTH="${1:-4}"
shift || true
case "$MAX_DEPTH" in ''|*[!0-9]*) MAX_DEPTH=4 ;; esac
[ "$MAX_DEPTH" -ge 1 ] || MAX_DEPTH=1
[ "$MAX_DEPTH" -le 8 ] || MAX_DEPTH=8

[ $# -gt 0 ] || set -- "$HOME/code"
[ $# -le "$MAX_WATCH_DIRS" ] || die "too many watched folders (limit $MAX_WATCH_DIRS)"

scanned=0
pending_json="[]"
watched_json="[]"

# ponytail: one jq per pending repo, re-serializing the array each time. O(n^2)
# with a hard n of MAX_REPOS_TOTAL, so the ceiling is bounded; build the array in
# a single jq pass if that limit ever needs raising.
add_pending() {
  pending_json=$("$JQ" -c \
    --arg name "${1:0:MAX_STRING}" --arg path "${2:0:MAX_STRING}" \
    --arg dir "${3:0:MAX_STRING}" --arg issues "${4:0:MAX_STRING}" \
    '. + [{name: $name, path: $path, dir: $dir, issues: $issues}]' \
    <<<"$pending_json")
}

add_watched() {
  watched_json=$("$JQ" -c \
    --arg path "${1:0:MAX_STRING}" --arg state "$2" \
    --argjson repos "$3" --argjson pending "$4" \
    '. + [{path: $path, state: $state, repos: $repos, pending: $pending}]' \
    <<<"$watched_json")
}

# Bounded read. A repository with a million dirty files would otherwise land in
# a shell variable in full, and every caller here only needs the first bytes.
# --no-optional-locks keeps the scan from writing into repos it is only looking
# at; core.fsmonitor= refuses to run the hook a scanned repo's own config asks
# for -- these roots are not necessarily the user's own code.
git_out() {
  local repo="$1"
  shift
  "$GIT" -C "$repo" --no-optional-locks -c core.fsmonitor= "$@" 2>/dev/null \
    | "$HEAD" -c "$MAX_GIT_BYTES"
}

for watch_dir in "$@"; do
  [ "$SECONDS" -lt "$DEADLINE_SEC" ] || die "scan deadline reached (${DEADLINE_SEC}s)"

  watch_dir="${watch_dir/#\~/$HOME}"
  watch_dir="${watch_dir%/}"
  display_dir="${watch_dir/#$HOME/\~}"

  if [ ! -d "$watch_dir" ]; then
    add_watched "$display_dir" missing 0 0
    continue
  fi

  # head(1) comes before sort(1), not after. sort cannot emit anything until it
  # has read -- and buffered, or spilled to disk -- every path find produced, so
  # a cap behind it is no cap at all: the traversal bound has to be on the
  # producer. head closes the pipe on entry 201, which SIGPIPEs find mid-walk;
  # sorting is then left to the 201 that survive. One line past the limit is all
  # it takes to know the limit was crossed.
  mapfile -t git_dirs < <(
    "$FIND" "$watch_dir" -maxdepth "$MAX_DEPTH" -type d -name .git -prune 2>/dev/null \
      | "$HEAD" -n "$((MAX_REPOS_PER_DIR + 1))" | "$SORT"
  )

  [ ${#git_dirs[@]} -le "$MAX_REPOS_PER_DIR" ] \
    || die "too many repositories under one folder (limit $MAX_REPOS_PER_DIR)"

  if [ ${#git_dirs[@]} -eq 0 ]; then
    add_watched "$display_dir" empty 0 0
    continue
  fi

  dir_pending=0

  for git_dir in "${git_dirs[@]}"; do
    [ "$SECONDS" -lt "$DEADLINE_SEC" ] || die "scan deadline reached (${DEADLINE_SEC}s)"

    repo="${git_dir%/.git}"
    scanned=$((scanned + 1))
    [ "$scanned" -le "$MAX_REPOS_TOTAL" ] \
      || die "too many repositories in total (limit $MAX_REPOS_TOTAL)"
    issues=()

    if [ -n "$(git_out "$repo" status --porcelain)" ]; then
      issues+=("uncommitted changes")
    fi

    if git_out "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
      ahead=$(git_out "$repo" rev-list --count '@{u}..HEAD')
      case "$ahead" in ''|*[!0-9]*) ahead=0 ;; esac
      if [ "$ahead" -gt 0 ]; then
        issues+=("$ahead unpushed commit(s)")
      fi
    elif git_out "$repo" rev-parse HEAD >/dev/null 2>&1; then
      # No upstream configured. `git push origin main` still puts the commits on
      # the remote, so only flag HEAD that no remote tracking ref contains.
      if [ -n "$(git_out "$repo" remote)" ] \
         && [ -z "$(git_out "$repo" branch -r --contains HEAD)" ]; then
        issues+=("unpushed")
      fi
    fi

    if [ ${#issues[@]} -gt 0 ]; then
      # ${issues[*]} with IFS=', ' joins on the comma alone -- bash only uses
      # the first character of IFS -- so build the list explicitly.
      joined=$(printf '%s, ' "${issues[@]}")
      add_pending "${repo#$watch_dir/}" "$repo" "$display_dir" "${joined%, }"
      dir_pending=$((dir_pending + 1))
    fi
  done

  add_watched "$display_dir" ok "${#git_dirs[@]}" "$dir_pending"
done

out=$("$JQ" -cn \
  --argjson pending "$pending_json" \
  --argjson watched "$watched_json" \
  --argjson scanned "$scanned" \
  '{state: (if ($pending | length) > 0 then "unsynced" else "synced" end),
    scanned: $scanned, pending: $pending, watched: $watched}')

# LC_ALL=C above makes this a byte count, which is what the reader budgets for.
[ ${#out} -le "$MAX_OUTPUT_BYTES" ] || die "output too large (limit $MAX_OUTPUT_BYTES bytes)"
printf '%s\n' "$out"
