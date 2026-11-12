#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Sourced by the docker scripts. Loads versions.env and lets a variable that
# is already set in the environment win over the file.

e2e_load_pins() {
  local root="$1"
  local file="${root}/versions.env"
  local line key
  local -a keys=()
  local -A prior=()

  [[ -f "$file" ]] || { echo "error: missing ${file}" >&2; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^([A-Z0-9_]+)= ]] || continue
    key="${BASH_REMATCH[1]}"
    keys+=("$key")
    if [[ -n "${!key+x}" ]]; then
      prior["$key"]="${!key}"
    fi
  done <"$file"

  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a

  if [[ ${#prior[@]} -gt 0 ]]; then
    for key in "${!prior[@]}"; do
      export "${key}=${prior[$key]}"
    done
  fi
}
