#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Build a dbt v2 binary from dbt-labs/dbt main plus the Athena pull requests,
# and build the dbt-labs/athena Go ADBC driver (cd go/pkg && make).
#
# Merge order for the engine (each head is refs/pull/N/head):
#   16274  Part 1  AthenaDbConfig profile schema (required; #16375 is built on it)
#   16365  Part 0  Backend::Athena entrypoint and athena.output_location
#   16367  Part 2  parse-path todo!() arms
#   16368  Part 3  partitioned_by / table_properties / force_batch
#   16369  Part 4  vendored dbt-athena 1.11.0 macros
#   16374  Part 5  AthenaMetadataAdapter and athena_get_relation
#   16376  Part 6  adapter methods the macros call (omit with --no-execution)
#   16370  Part 8  unit tests on Athena
#   16375  Part 9  dbt init wizard (its branch already contains #16274)
#
# The driver on main does not yet accept the options and operations those
# engine PRs send. Driver PRs, merged in this order unless --stock-driver
# or --driver-branch:
#   20  connection options (assume role, retries, poll interval)
#   19  Glue / S3 / STS operations
#   22  query statistics in the result schema
# Those three conflict with each other. scripts/resolve_driver_conflicts.py
# keeps both sides (resolved-patch) and compilation continues. Anything else
# falls back to -X theirs (resolved-theirs) and compilation waits for
# --allow-resolved. An engine stack uses the same -X theirs rule.
#
# --branch <remote>/<branch> (or DBT_BRANCH) skips the engine merge and
# checks out that ref. The intended tree is aoelvp94/dbt local/athena-combined.
# The driver default in that mode is still PRs 20, 19, and 22 on
# dbt-labs/athena main. --driver-prs overrides the list. --driver-branch
# checks out a pre-resolved driver ref instead. --stock-driver builds main.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DBT_REPO="${DBT_REPO:-https://github.com/dbt-labs/dbt.git}"
DRIVER_REPO="${DRIVER_REPO:-https://github.com/dbt-labs/athena.git}"
CACHE_DIR="${CACHE_DIR:-${ROOT}/.cache/dbt-v2-athena-e2e}"

DEFAULT_DBT_PRS=(16274 16365 16367 16368 16369 16374 16376 16370 16375)
USER_LISTED_PRS=(16365 16367 16368 16369 16374 16370 16375)
DEFAULT_DRIVER_PRS=(20 19 22)

merge_only=0
allow_resolved=0
no_execution=0
stock_driver=0
force=0
skip_driver=0
binary_path=""
driver_lib=""
custom_prs=""
driver_prs_explicit=0
self_test=0
build_mode="pull-requests"
# Same value as --branch. Example: aoelvp94/dbt/local/athena-combined
dbt_branch_spec="${DBT_BRANCH:-}"
# Same value as --driver-branch. Example: aoelvp94/athena/local/driver-combined
driver_branch_spec="${DRIVER_BRANCH:-}"

usage() {
  cat <<'EOF'
usage: scripts/build_dbt.sh [options]

  --merge-only       Fetch and merge, write the report, do not compile
  --allow-resolved   Compile even if a merge needed -X theirs
  --no-execution     Drop engine PR 16376 (Part 6) from the default stack
  --prs "N N ..."    Engine PR numbers, in merge order, instead of the default
  --branch SPEC      Build this engine ref instead of merging engine pull requests
                     SPEC is <owner>/<repo>/<branch> (branch may contain
                     slashes) or an https/git URL with the branch after the
                     repo. Example: aoelvp94/dbt/local/athena-combined
                     Env: DBT_BRANCH. The driver still merges #20 #19 #22
                     unless --stock-driver, --driver-prs, or --driver-branch.
  --stock-driver     Build the driver from main, with no driver PRs
  --driver-prs "N.." Driver PR numbers to merge onto the driver main.
                     Allowed together with --branch.
  --driver-branch SPEC
                     Build this driver ref instead of merging driver PRs.
                     Same SPEC shape as --branch. Env: DRIVER_BRANCH.
  --binary PATH      Use this dbt binary and skip the Rust build
  --driver-lib PATH  Use this libadbc_driver_athena.so and skip the Go build
  --cache-dir PATH   Default: .cache/dbt-v2-athena-e2e
  --force            Re-merge and rebuild even when the stamp matches
  --self-test        Check --branch parsing and exit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --merge-only) merge_only=1; shift ;;
    --allow-resolved) allow_resolved=1; shift ;;
    --no-execution) no_execution=1; shift ;;
    --stock-driver) stock_driver=1; shift ;;
    --force) force=1; shift ;;
    --skip-driver) skip_driver=1; shift ;;
    --binary)
      [[ $# -ge 2 ]] || { echo "error: --binary needs a path" >&2; exit 1; }
      binary_path="$2"; shift 2 ;;
    --driver-lib)
      [[ $# -ge 2 ]] || { echo "error: --driver-lib needs a path" >&2; exit 1; }
      driver_lib="$2"; shift 2 ;;
    --prs)
      [[ $# -ge 2 ]] || { echo "error: --prs needs a list" >&2; exit 1; }
      custom_prs="$2"; shift 2 ;;
    --driver-prs)
      [[ $# -ge 2 ]] || { echo "error: --driver-prs needs a list" >&2; exit 1; }
      driver_prs_explicit=1
      # shellcheck disable=SC2206
      DEFAULT_DRIVER_PRS=($2); shift 2 ;;
    --branch)
      [[ $# -ge 2 ]] || { echo "error: --branch needs <remote>/<branch>" >&2; exit 1; }
      dbt_branch_spec="$2"; shift 2 ;;
    --driver-branch)
      [[ $# -ge 2 ]] || { echo "error: --driver-branch needs <remote>/<branch>" >&2; exit 1; }
      driver_branch_spec="$2"; shift 2 ;;
    --self-test) self_test=1; shift ;;
    --cache-dir)
      [[ $# -ge 2 ]] || { echo "error: --cache-dir needs a path" >&2; exit 1; }
      CACHE_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -n "$custom_prs" ]]; then
  # shellcheck disable=SC2206
  DBT_PRS=($custom_prs)
elif [[ "$no_execution" -eq 1 ]]; then
  DBT_PRS=(16274 16365 16367 16368 16369 16374 16370 16375)
else
  DBT_PRS=("${DEFAULT_DBT_PRS[@]}")
fi
if [[ -n "$dbt_branch_spec" ]]; then
  if [[ -n "$custom_prs" || "$no_execution" -eq 1 ]]; then
    echo "error: --branch checks out that engine ref and does not merge engine PRs. Drop --prs and --no-execution." >&2
    exit 1
  fi
  build_mode="branch"
fi
if [[ -n "$driver_branch_spec" && ( "$driver_prs_explicit" -eq 1 || "$stock_driver" -eq 1 ) ]]; then
  echo "error: --driver-branch checks out that driver ref. Drop --driver-prs and --stock-driver." >&2
  exit 1
fi
if [[ "$stock_driver" -eq 1 || -n "$driver_branch_spec" ]]; then
  DRIVER_PRS=()
else
  DRIVER_PRS=("${DEFAULT_DRIVER_PRS[@]}")
fi

mkdir -p "$CACHE_DIR" "${ROOT}/build"
REPORT="${ROOT}/build/merge-report.json"
DIST="${CACHE_DIR}/dist"
DBT_SRC="${CACHE_DIR}/dbt-src"
DRIVER_SRC="${CACHE_DIR}/athena-src"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: required command not found: $1" >&2; exit 1; }
}

need_cmd git
need_cmd jq

gitc() {
  local dir="$1"
  shift
  git -C "$dir" -c user.name='dbt-v2-athena-e2e' -c user.email='aoelvp94@gmail.com' "$@"
}

json_list() {
  local pr status files="$3"
  pr="$1"
  status="$2"
  jq -nc --arg pr "$pr" --arg status "$status" --arg files "$files" \
    '{pr: ($pr | tonumber), status: $status, files: (if $files == "" then [] else ($files | split(",")) end)}'
}

# Merge one ref. Prints a JSON object. Leaves the worktree on the merge result
# when the merge is kept. mode=probe aborts on conflict. mode=stack retries
# with -X theirs. mode=driver tries scripts/resolve_driver_conflicts.py first
# and only then -X theirs.
merge_ref() {
  local dir="$1"
  local ref="$2"
  local pr="$3"
  local mode="$4"
  local files=""

  if gitc "$dir" merge-base --is-ancestor "$ref" HEAD; then
    json_list "$pr" "already-present" ""
    return 0
  fi
  if gitc "$dir" merge --no-ff --no-edit "$ref" >/dev/null 2>&1; then
    json_list "$pr" "clean" ""
    return 0
  fi
  files="$(gitc "$dir" diff --name-only --diff-filter=U | paste -sd, - || true)"
  if [[ "$mode" == "driver" ]]; then
    if python3 "${SCRIPT_DIR}/resolve_driver_conflicts.py" "$dir"; then
      gitc "$dir" add -u
      gitc "$dir" commit --no-edit >/dev/null
      json_list "$pr" "resolved-patch" "$files"
      return 0
    fi
    echo "driver PR ${pr}: checked-in resolver did not match; retrying with -X theirs" >&2
  fi
  gitc "$dir" merge --abort >/dev/null 2>&1 || gitc "$dir" reset --hard HEAD >/dev/null
  if [[ "$mode" == "stack" || "$mode" == "driver" ]]; then
    if gitc "$dir" merge -X theirs --no-ff --no-edit "$ref" >/dev/null 2>&1; then
      json_list "$pr" "resolved-theirs" "$files"
      return 0
    fi
    gitc "$dir" merge --abort >/dev/null 2>&1 || gitc "$dir" reset --hard HEAD >/dev/null
  fi
  json_list "$pr" "failed" "$files"
  return 0
}

prepare_repo() {
  local dir="$1"
  local url="$2"
  if [[ ! -d "${dir}/.git" ]]; then
    git clone --filter=blob:none --no-tags "$url" "$dir"
  else
    gitc "$dir" remote set-url origin "$url"
  fi
  gitc "$dir" fetch --no-tags origin main
  gitc "$dir" checkout --force -B e2e-base origin/main
}

# path is owner/repo[.git]/branch (branch may contain slashes). Prints
# owner, repo, branch on three lines.
split_owner_repo_branch() {
  local path="${1%/}"
  local owner repo branch rest
  if [[ "$path" != */*/* ]]; then
    return 1
  fi
  owner="${path%%/*}"
  rest="${path#*/}"
  repo="${rest%%/*}"
  branch="${rest#*/}"
  repo="${repo%.git}"
  if [[ -z "$owner" || -z "$repo" || -z "$branch" ]]; then
    return 1
  fi
  printf '%s\n%s\n%s\n' "$owner" "$repo" "$branch"
}

# Prints JSON: {"url","remote","branch"}. remote is owner/repo.
parse_branch_spec() {
  local spec="$1"
  local host path parsed owner repo branch url
  if [[ -z "$spec" || "$spec" == *" "* ]]; then
    echo "error: --branch expects <owner>/<repo>/<branch> or <url>/<branch>" >&2
    return 1
  fi
  if [[ "$spec" =~ ^https?:// ]]; then
    local without="${spec#*://}"
    host="${without%%/*}"
    path="${without#*/}"
    if [[ -z "$host" || "$host" == "$without" ]]; then
      echo "error: --branch URL is missing a repository path: ${spec}" >&2
      return 1
    fi
    parsed="$(split_owner_repo_branch "$path")" || {
      echo "error: --branch URL must be <url>/<owner>/<repo>/<branch>: ${spec}" >&2
      return 1
    }
    {
      read -r owner
      read -r repo
      read -r branch
    } <<<"$parsed"
    url="https://${host}/${owner}/${repo}.git"
  elif [[ "$spec" == git@* ]]; then
    local hostpath="${spec#git@}"
    host="${hostpath%%:*}"
    path="${hostpath#*:}"
    if [[ -z "$host" || "$host" == "$hostpath" ]]; then
      echo "error: --branch git URL is missing a repository path: ${spec}" >&2
      return 1
    fi
    parsed="$(split_owner_repo_branch "$path")" || {
      echo "error: --branch git URL must be git@host:owner/repo/<branch>: ${spec}" >&2
      return 1
    }
    {
      read -r owner
      read -r repo
      read -r branch
    } <<<"$parsed"
    url="git@${host}:${owner}/${repo}.git"
  else
    parsed="$(split_owner_repo_branch "$spec")" || {
      echo "error: --branch expects <owner>/<repo>/<branch> (the branch may contain slashes). Example: aoelvp94/dbt/local/athena-combined" >&2
      return 1
    }
    {
      read -r owner
      read -r repo
      read -r branch
    } <<<"$parsed"
    url="https://github.com/${owner}/${repo}.git"
  fi
  jq -nc --arg url "$url" --arg remote "${owner}/${repo}" --arg branch "$branch" \
    '{url: $url, remote: $remote, branch: $branch}'
}

assert_branch_spec() {
  local spec="$1" want_url="$2" want_remote="$3" want_branch="$4" got
  got="$(parse_branch_spec "$spec")"
  jq -e --arg url "$want_url" --arg remote "$want_remote" --arg branch "$want_branch" \
    '.url == $url and .remote == $remote and .branch == $branch' >/dev/null <<<"$got" || {
    echo "error: branch spec parsed wrong: ${spec} -> ${got}" >&2
    return 1
  }
}

assert_branch_spec_rejects() {
  local spec="$1"
  if parse_branch_spec "$spec" >/dev/null 2>&1; then
    echo "error: branch spec should have been rejected: ${spec}" >&2
    return 1
  fi
}

branch_self_test() {
  local url="https://github.com/aoelvp94/dbt.git"
  local remote="aoelvp94/dbt"
  local branch="local/athena-combined"
  assert_branch_spec "aoelvp94/dbt/local/athena-combined" "$url" "$remote" "$branch"
  assert_branch_spec "https://github.com/aoelvp94/dbt/local/athena-combined" "$url" "$remote" "$branch"
  assert_branch_spec "https://github.com/aoelvp94/dbt.git/local/athena-combined" "$url" "$remote" "$branch"
  assert_branch_spec "git@github.com:aoelvp94/dbt.git/local/athena-combined" \
    "git@github.com:aoelvp94/dbt.git" "$remote" "$branch"
  assert_branch_spec "git@github.com:aoelvp94/dbt/local/athena-combined" \
    "git@github.com:aoelvp94/dbt.git" "$remote" "$branch"
  assert_branch_spec_rejects "local/athena-combined"
  assert_branch_spec_rejects "aoelvp94/dbt"
  assert_branch_spec_rejects "https://github.com/aoelvp94/dbt"
  assert_branch_spec_rejects ""
  echo "branch spec self-test ok"
  python3 "${SCRIPT_DIR}/resolve_driver_conflicts.py" --self-test
}

checkout_remote_branch() {
  local dir="$1"
  local url="$2"
  local branch="$3"
  if [[ ! -d "${dir}/.git" ]]; then
    git clone --filter=blob:none --no-tags "$url" "$dir"
  fi
  gitc "$dir" remote set-url origin "$url"
  echo "fetching ${url} branch ${branch}"
  if ! gitc "$dir" fetch --no-tags origin "refs/heads/${branch}:refs/remotes/origin/${branch}"; then
    echo "error: could not fetch ${url} refs/heads/${branch}" >&2
    exit 1
  fi
  gitc "$dir" checkout --force -B e2e-branch "refs/remotes/origin/${branch}"
}

fetch_prs() {
  local dir="$1"
  shift
  local pr
  for pr in "$@"; do
    gitc "$dir" fetch --no-tags origin "refs/pull/${pr}/head:refs/pullheads/${pr}"
  done
}

# Run a series of merges from origin/main. Prints a JSON array.
merge_series() {
  local dir="$1"
  local mode="$2"
  shift 2
  gitc "$dir" merge --abort >/dev/null 2>&1 || true
  gitc "$dir" checkout --force -B e2e-series origin/main >/dev/null
  local pr item array="[]"
  for pr in "$@"; do
    item="$(merge_ref "$dir" "refs/pullheads/${pr}" "$pr" "$mode")"
    array="$(jq -c --argjson item "$item" '. += [$item]' <<<"$array")"
  done
  printf '%s\n' "$array"
}

series_needs_attention() {
  local json="$1"
  jq -e 'map(select(.status != "clean" and .status != "already-present" and .status != "resolved-patch")) | length > 0' >/dev/null <<<"$json"
}

ensure_dbt_repo() {
  prepare_repo "$DBT_SRC" "$DBT_REPO"
  fetch_prs "$DBT_SRC" "${DBT_PRS[@]}" "${USER_LISTED_PRS[@]}" 16376 16274
}

ensure_driver_repo() {
  prepare_repo "$DRIVER_SRC" "$DRIVER_REPO"
  if [[ ${#DRIVER_PRS[@]} -gt 0 ]]; then
    fetch_prs "$DRIVER_SRC" "${DRIVER_PRS[@]}"
  fi
}

if [[ "$self_test" -eq 1 ]]; then
  branch_self_test
  exit 0
fi

BRANCH_URL=""
BRANCH_REMOTE=""
BRANCH_NAME=""
dbt_commit=""
onto_items="[]"
stack_json="[]"
user_json="[]"
noexec_json="[]"
pr=""

if [[ "$build_mode" == "branch" ]]; then
  parsed="$(parse_branch_spec "$dbt_branch_spec")" || exit 1
  BRANCH_URL="$(jq -r '.url' <<<"$parsed")"
  BRANCH_REMOTE="$(jq -r '.remote' <<<"$parsed")"
  BRANCH_NAME="$(jq -r '.branch' <<<"$parsed")"
  echo "checking out ${BRANCH_REMOTE} branch ${BRANCH_NAME}"
  checkout_remote_branch "$DBT_SRC" "$BRANCH_URL" "$BRANCH_NAME"
  dbt_commit="$(gitc "$DBT_SRC" rev-parse HEAD)"
else
  echo "fetching dbt-labs/dbt and pull heads"
  ensure_dbt_repo

  for pr in "${DBT_PRS[@]}"; do
    echo "probe engine PR ${pr} onto main"
    item="$(merge_series "$DBT_SRC" probe "$pr")"
    # merge_series returns an array of one object
    onto_items="$(jq -c --argjson item "$item" '. += $item' <<<"$onto_items")"
  done

  echo "merging engine stack: ${DBT_PRS[*]}"
  stack_json="$(merge_series "$DBT_SRC" stack "${DBT_PRS[@]}")"
  # Keep the stack checkout. merge_series leaves e2e-series on the result.
  gitc "$DBT_SRC" branch -f e2e-stack HEAD

  echo "merging the user-listed PR set onto main"
  user_json="$(merge_series "$DBT_SRC" stack "${USER_LISTED_PRS[@]}")"

  without_exec=(16274 16365 16367 16368 16369 16374 16370 16375)
  echo "merging the stack without Part 6 (#16376)"
  noexec_json="$(merge_series "$DBT_SRC" stack "${without_exec[@]}")"

  # Restore the default stack for a possible compile.
  gitc "$DBT_SRC" checkout --force e2e-stack >/dev/null
fi

driver_onto="[]"
driver_stack="[]"
driver_main=""
driver_source="main"
driver_url=""
driver_branch_name=""
driver_commit=""
driver_note="not built"
if [[ "$skip_driver" -eq 0 && -n "$driver_branch_spec" ]]; then
  parsed="$(parse_branch_spec "$driver_branch_spec")" || exit 1
  driver_url="$(jq -r '.url' <<<"$parsed")"
  driver_remote="$(jq -r '.remote' <<<"$parsed")"
  driver_branch_name="$(jq -r '.branch' <<<"$parsed")"
  echo "checking out driver ${driver_remote} branch ${driver_branch_name}"
  checkout_remote_branch "$DRIVER_SRC" "$driver_url" "$driver_branch_name"
  driver_commit="$(gitc "$DRIVER_SRC" rev-parse HEAD)"
  driver_main="$driver_commit"
  driver_source="branch"
  driver_note="branch ${driver_remote} ${driver_branch_name} at ${driver_commit}"
elif [[ "$skip_driver" -eq 0 ]]; then
  echo "fetching dbt-labs/athena"
  ensure_driver_repo
  driver_main="$(gitc "$DRIVER_SRC" rev-parse origin/main)"
  if [[ ${#DRIVER_PRS[@]} -gt 0 ]]; then
    for pr in "${DRIVER_PRS[@]}"; do
      echo "probe driver PR ${pr} onto main"
      item="$(merge_series "$DRIVER_SRC" probe "$pr")"
      driver_onto="$(jq -c --argjson item "$item" '. += $item' <<<"$driver_onto")"
    done
    echo "merging driver stack: ${DRIVER_PRS[*]}"
    driver_stack="$(merge_series "$DRIVER_SRC" driver "${DRIVER_PRS[@]}")"
    gitc "$DRIVER_SRC" branch -f e2e-stack HEAD
    driver_commit="$(gitc "$DRIVER_SRC" rev-parse HEAD)"
    driver_source="pull-requests"
    driver_note="main ${driver_main} plus PRs ${DRIVER_PRS[*]}"
  else
    driver_stack="[]"
    gitc "$DRIVER_SRC" checkout --force -B e2e-stack origin/main >/dev/null
    driver_commit="$driver_main"
    driver_note="main ${driver_main}"
  fi
fi

if [[ "$build_mode" == "branch" ]]; then
  jq -n \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg url "$BRANCH_URL" \
    --arg remote "$BRANCH_REMOTE" \
    --arg branch "$BRANCH_NAME" \
    --arg commit "$dbt_commit" \
    --arg driver_main "$driver_main" \
    --arg driver_source "$driver_source" \
    --arg driver_url "$driver_url" \
    --arg driver_branch_name "$driver_branch_name" \
    --arg driver_commit "$driver_commit" \
    --arg driver_note "$driver_note" \
    --argjson driver_onto "$driver_onto" \
    --argjson driver_stack "$driver_stack" \
    '{
      generated_at: $generated_at,
      mode: "branch",
      dbt: {
        repo: $remote,
        url: $url,
        branch: $branch,
        commit: $commit
      },
      driver: {
        repo: "dbt-labs/athena",
        main: $driver_main,
        source: $driver_source,
        url: $driver_url,
        branch: $driver_branch_name,
        commit: $driver_commit,
        note: $driver_note,
        onto_main: $driver_onto,
        stack: $driver_stack
      }
    }' >"$REPORT"
else
  dbt_main="$(gitc "$DBT_SRC" rev-parse origin/main)"
  jq -n \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg dbt_main "$dbt_main" \
    --arg driver_main "$driver_main" \
    --arg driver_source "$driver_source" \
    --arg driver_url "$driver_url" \
    --arg driver_branch_name "$driver_branch_name" \
    --arg driver_commit "$driver_commit" \
    --arg driver_note "$driver_note" \
    --argjson dbt_prs "$(printf '%s\n' "${DBT_PRS[@]}" | jq -R . | jq -s 'map(tonumber)')" \
    --argjson onto "$onto_items" \
    --argjson stack "$stack_json" \
    --argjson user_listed "$user_json" \
    --argjson without_execution "$noexec_json" \
    --argjson driver_onto "$driver_onto" \
    --argjson driver_stack "$driver_stack" \
    '{
      generated_at: $generated_at,
      mode: "pull-requests",
      dbt: {
        repo: "dbt-labs/dbt",
        main: $dbt_main,
        merge_order: $dbt_prs,
        onto_main: $onto,
        stack: $stack,
        user_listed_stack: $user_listed,
        stack_without_execution: $without_execution
      },
      driver: {
        repo: "dbt-labs/athena",
        main: $driver_main,
        source: $driver_source,
        url: $driver_url,
        branch: $driver_branch_name,
        commit: $driver_commit,
        note: $driver_note,
        onto_main: $driver_onto,
        stack: $driver_stack
      }
    }' >"$REPORT"
fi
echo "wrote ${REPORT}"

stack_bad=0
if series_needs_attention "$stack_json"; then
  stack_bad=1
fi
driver_bad=0
if [[ "$driver_stack" != "[]" ]] && series_needs_attention "$driver_stack"; then
  driver_bad=1
fi

if [[ "$merge_only" -eq 1 ]]; then
  if [[ "$stack_bad" -eq 1 || "$driver_bad" -eq 1 ]]; then
    echo "merge report has conflicts or -X theirs resolutions; not compiling (--merge-only)" >&2
    exit 2
  fi
  if [[ "$build_mode" == "branch" ]]; then
    echo "checked out ${BRANCH_REMOTE} ${BRANCH_NAME} at ${dbt_commit}; driver ${driver_note}"
  else
    echo "merges are clean"
  fi
  exit 0
fi

if [[ "$stack_bad" -eq 1 || "$driver_bad" -eq 1 ]]; then
  if [[ "$allow_resolved" -eq 0 ]]; then
    echo "error: a merge failed or needed -X theirs. See ${REPORT}. A checked-in driver resolution is status resolved-patch and does not need this flag. Re-run with --allow-resolved to compile a -X theirs tree anyway." >&2
    exit 2
  fi
  echo "warning: compiling a tree that needed conflict resolution"
fi

if [[ "$force" -eq 0 && -z "$binary_path" && -x "${DIST}/dbt" && -f "${DIST}/lib/libadbc_driver_athena.so" && -f "${DIST}/lib/dbt/libadbc_driver_athena.so" ]]; then
  echo "cached binary and driver are present; pass --force to rebuild"
  echo "dbt: ${DIST}/dbt"
  echo "driver: ${DIST}/lib/libadbc_driver_athena.so"
  echo "driver: ${DIST}/lib/dbt/libadbc_driver_athena.so"
  exit 0
fi
echo "building (force=${force})"

mkdir -p "${DIST}/lib/dbt"

# The engine walks up from the binary and looks in lib/ and lib/dbt/.
stage_driver_lib() {
  local so="$1"
  local root="$2"
  mkdir -p "${root}/lib/dbt"
  cp "$so" "${root}/lib/libadbc_driver_athena.so"
  cp "$so" "${root}/lib/dbt/libadbc_driver_athena.so"
  echo "driver installed at ${root}/lib/libadbc_driver_athena.so"
  echo "driver installed at ${root}/lib/dbt/libadbc_driver_athena.so"
}

install_driver_next_to() {
  local bin="$1"
  local so="$2"
  stage_driver_lib "$so" "$(cd "$(dirname "$bin")" && pwd)"
}

if [[ -n "$binary_path" ]]; then
  [[ -x "$binary_path" ]] || { echo "error: binary is not executable: ${binary_path}" >&2; exit 1; }
  cp "$binary_path" "${DIST}/dbt"
  chmod +x "${DIST}/dbt"
  echo "using existing binary ${binary_path}"
else
  need_cmd curl
  export RUSTUP_HOME="${CACHE_DIR}/rustup"
  export CARGO_HOME="${CACHE_DIR}/cargo"
  if [[ ! -x "${CARGO_HOME}/bin/rustup" ]]; then
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain 1.96.0 --profile minimal --no-modify-path
  fi
  # shellcheck disable=SC1091
  source "${CARGO_HOME}/env"
  rustup toolchain install 1.96.0 --profile minimal -c rustfmt -c clippy
  # Release LTO of dbt-schemas OOMs when cargo schedules many jobs on a 15 GiB host.
  if [[ -z "${CARGO_BUILD_JOBS:-}" ]]; then
    export CARGO_BUILD_JOBS=1
  fi
  echo "compiling dbt (CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS} cargo build --release -p dbt-sa-cli --bin dbt)"
  cargo build --manifest-path "${DBT_SRC}/Cargo.toml" --release -p dbt-sa-cli --bin dbt
  cp "${DBT_SRC}/target/release/dbt" "${DIST}/dbt"
  chmod +x "${DIST}/dbt"
fi

if [[ -n "$driver_lib" ]]; then
  [[ -f "$driver_lib" ]] || { echo "error: driver library not found: ${driver_lib}" >&2; exit 1; }
  stage_driver_lib "$driver_lib" "$DIST"
elif [[ "$skip_driver" -eq 0 ]]; then
  need_cmd curl
  gomod="${DRIVER_SRC}/go/go.mod"
  go_need="$(sed -n 's/^go //p' "$gomod" | head -n 1)"
  if ! command -v go >/dev/null 2>&1 || ! go version | grep -q "go${go_need}"; then
    sdk="${CACHE_DIR}/go-sdk"
    tarball="${CACHE_DIR}/go${go_need}.linux-amd64.tar.gz"
    if [[ ! -x "${sdk}/bin/go" ]] || ! "${sdk}/bin/go" version | grep -q "go${go_need}"; then
      echo "downloading Go ${go_need}"
      curl -fsSL -o "$tarball" "https://go.dev/dl/go${go_need}.linux-amd64.tar.gz"
      rm -rf "$sdk" "${CACHE_DIR}/go"
      tar -C "${CACHE_DIR}" -xzf "$tarball"
      mv "${CACHE_DIR}/go" "$sdk"
    fi
    export PATH="${sdk}/bin:${PATH}"
  fi
  need_cmd gcc
  echo "building libadbc_driver_athena.so (cd go/pkg && make)"
  make -C "${DRIVER_SRC}/go/pkg"
  stage_driver_lib "${DRIVER_SRC}/go/pkg/libadbc_driver_athena.so" "$DIST"
fi

if [[ -n "$binary_path" && -f "${DIST}/lib/libadbc_driver_athena.so" ]]; then
  install_driver_next_to "$binary_path" "${DIST}/lib/libadbc_driver_athena.so" || {
    echo "could not write next to ${binary_path}; the built library is ${DIST}/lib/libadbc_driver_athena.so" >&2
    exit 1
  }
fi

cat >"${DIST}/README.txt" <<EOF
dbt binary: ${DIST}/dbt
driver:     ${DIST}/lib/libadbc_driver_athena.so
driver:     ${DIST}/lib/dbt/libadbc_driver_athena.so
The loader walks up from the executable and looks in lib/ and lib/dbt/.
EOF

echo "dbt: ${DIST}/dbt"
echo "driver: ${DIST}/lib/libadbc_driver_athena.so"
echo "driver: ${DIST}/lib/dbt/libadbc_driver_athena.so"
