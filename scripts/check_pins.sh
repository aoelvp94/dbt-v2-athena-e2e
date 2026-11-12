#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Fail when versions.env and the Dockerfile ARG defaults disagree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
file="${ROOT}/versions.env"
dockerfile="${ROOT}/Dockerfile"

declare -A envp=()
declare -A args=()

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue
  [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]] || {
    echo "error: bad pin line: ${line}" >&2
    exit 1
  }
  key="${BASH_REMATCH[1]}"
  val="${BASH_REMATCH[2]}"
  if [[ "$val" == \"*\" ]]; then
    val="${val#\"}"
    val="${val%\"}"
  fi
  [[ -n "$val" ]] || { echo "error: empty pin ${key}" >&2; exit 1; }
  envp["$key"]="$val"
done <"$file"

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^ARG[[:space:]]+([A-Z0-9_]+)=(.*)$ ]] || continue
  key="${BASH_REMATCH[1]}"
  val="${BASH_REMATCH[2]}"
  val="${val%"${val##*[![:space:]]}"}"
  if [[ "$val" == \"*\" ]]; then
    val="${val#\"}"
    val="${val%\"}"
  fi
  if [[ -n "${args[$key]:-}" && "${args[$key]}" != "$val" ]]; then
    echo "error: Dockerfile ARG ${key} has two different defaults" >&2
    exit 1
  fi
  args["$key"]="$val"
done <"$dockerfile"

for key in "${!args[@]}"; do
  if [[ -z "${envp[$key]:-}" ]]; then
    echo "error: Dockerfile ARG ${key} is missing from versions.env" >&2
    exit 1
  fi
  if [[ "${envp[$key]}" != "${args[$key]}" ]]; then
    echo "error: ${key} differs" >&2
    echo "  versions.env: ${envp[$key]}" >&2
    echo "  Dockerfile:   ${args[$key]}" >&2
    exit 1
  fi
done

for key in "${!envp[@]}"; do
  if [[ "$key" == "IMAGE_REF" ]]; then
    continue
  fi
  if [[ -z "${args[$key]:-}" ]]; then
    echo "error: versions.env ${key} has no Dockerfile ARG default" >&2
    exit 1
  fi
done

[[ -n "${envp[IMAGE_REF]:-}" ]] || { echo "error: IMAGE_REF is missing from versions.env" >&2; exit 1; }

py="$(tr -d '[:space:]' <"${ROOT}/.python-version")"
[[ "$py" == "${envp[PYTHON_VERSION]}" ]] || {
  echo "error: .python-version is ${py}, PYTHON_VERSION is ${envp[PYTHON_VERSION]}" >&2
  exit 1
}

spec_path="${envp[DBT_REPO]#https://github.com/}"
spec_path="${spec_path%.git}/${envp[DBT_BRANCH]}"
[[ "$spec_path" == "${envp[DBT_SPEC]}" ]] || {
  echo "error: DBT_SPEC is ${envp[DBT_SPEC]}, expected ${spec_path}" >&2
  exit 1
}

[[ "${envp[DRIVER_PRS]}" == "20 19 22" ]] || {
  echo "error: DRIVER_PRS is ${envp[DRIVER_PRS]}. The Dockerfile pins PRs 20, 19, and 22." >&2
  exit 1
}

for n in 20 19 22; do
  grep -q -- "--expect-driver-pr \"${n}:\${DRIVER_PR_${n}_SHA}\"" "$dockerfile" || {
    echo "error: Dockerfile is missing the pin for driver PR ${n}" >&2
    exit 1
  }
done

for key in "${!envp[@]}"; do
  if [[ "$key" == *_SHA256 ]]; then
    [[ "${envp[$key]}" =~ ^[0-9a-f]{64}$ ]] || {
      echo "error: ${key} is not a 64-character sha256" >&2
      exit 1
    }
  elif [[ "$key" == *_SHA ]]; then
    [[ "${envp[$key]}" =~ ^[0-9a-f]{40}$ ]] || {
      echo "error: ${key} is not a 40-character sha" >&2
      exit 1
    }
  fi
done

for key in DEBIAN_IMAGE UV_IMAGE; do
  [[ "${envp[$key]}" =~ @sha256:[0-9a-f]{64}$ ]] || {
    echo "error: ${key} is not pinned to an image digest" >&2
    exit 1
  }
done

[[ -s "${ROOT}/uv.lock" ]] || { echo "error: uv.lock is missing" >&2; exit 1; }
[[ -f "${ROOT}/pyproject.toml" ]] || { echo "error: pyproject.toml is missing" >&2; exit 1; }

if grep -nE '(^|[^[:alnum:]_])(pip3?[[:space:]]+install|python3?[[:space:]]+-m[[:space:]]+pip)' \
  "$dockerfile" "${ROOT}"/scripts/*.sh "${ROOT}/justfile"; then
  echo "error: install Python tools with uv" >&2
  exit 1
fi

echo "pins match Dockerfile defaults"
