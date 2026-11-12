#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Write /opt/e2e/BUILD_INFO.json from the pin environment, then (with --apt)
# record the runtime package versions on top of that file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

need() {
  [[ -n "${!1:-}" ]] || { echo "error: ${1} is empty" >&2; exit 1; }
}

require_pins() {
  local v
  for v in DBT_REPO DBT_BRANCH DBT_SPEC DBT_SHA DRIVER_REPO DRIVER_SHA \
    DRIVER_PR_20_SHA DRIVER_PR_19_SHA DRIVER_PR_22_SHA \
    RUST_VERSION RUSTUP_VERSION GO_VERSION UV_VERSION PYTHON_VERSION \
    AWSCLI_VERSION TERRAFORM_VERSION JUST_VERSION \
    DEBIAN_IMAGE UV_IMAGE CARGO_BUILD_JOBS; do
    need "$v"
  done
}

pkg_ver() {
  dpkg-query -W "$1" | awk '{print $2}'
}

write_pins() {
  local out="$1"
  local report="$2"
  local dbt_commit driver_main driver_commit rustc_line go_line uv_line py_line

  [[ -f "$report" ]] || { echo "error: missing merge report ${report}" >&2; exit 1; }
  dbt_commit="$(jq -r '.dbt.commit' "$report")"
  driver_main="$(jq -r '.driver.main' "$report")"
  driver_commit="$(jq -r '.driver.commit' "$report")"
  [[ "$dbt_commit" == "$DBT_SHA" ]] || {
    echo "error: built dbt ${dbt_commit}, pin is ${DBT_SHA}" >&2
    exit 1
  }
  [[ "$driver_main" == "$DRIVER_SHA" ]] || {
    echo "error: driver main ${driver_main}, pin is ${DRIVER_SHA}" >&2
    exit 1
  }

  rustc_line="$(rustc --version)"
  [[ "$rustc_line" == "rustc ${RUST_VERSION} "* ]] || {
    echo "error: ${rustc_line} does not match rust ${RUST_VERSION}" >&2
    exit 1
  }
  go_line="$(go version)"
  [[ "$go_line" == *"go${GO_VERSION} "* ]] || {
    echo "error: ${go_line} does not match Go ${GO_VERSION}" >&2
    exit 1
  }
  uv_line="$(uv --version)"
  [[ "$uv_line" == "uv ${UV_VERSION} "* ]] || {
    echo "error: ${uv_line} does not match uv ${UV_VERSION}" >&2
    exit 1
  }
  py_line="$(uv run --frozen --project "$ROOT" python --version)"
  [[ "$py_line" == "Python ${PYTHON_VERSION}" ]] || {
    echo "error: ${py_line} does not match Python ${PYTHON_VERSION}" >&2
    exit 1
  }

  jq -n \
    --arg dbt_repo "$DBT_REPO" \
    --arg dbt_branch "$DBT_BRANCH" \
    --arg dbt_spec "$DBT_SPEC" \
    --arg dbt_sha "$DBT_SHA" \
    --arg driver_repo "$DRIVER_REPO" \
    --arg driver_sha "$DRIVER_SHA" \
    --arg driver_commit "$driver_commit" \
    --arg sha20 "$DRIVER_PR_20_SHA" \
    --arg sha19 "$DRIVER_PR_19_SHA" \
    --arg sha22 "$DRIVER_PR_22_SHA" \
    --arg rust "$RUST_VERSION" \
    --arg rustup "$RUSTUP_VERSION" \
    --arg go "$GO_VERSION" \
    --arg uv "$UV_VERSION" \
    --arg python "$PYTHON_VERSION" \
    --arg awscli "$AWSCLI_VERSION" \
    --arg terraform "$TERRAFORM_VERSION" \
    --arg just "$JUST_VERSION" \
    --arg debian "$DEBIAN_IMAGE" \
    --arg uv_image "$UV_IMAGE" \
    --argjson jobs "$CARGO_BUILD_JOBS" \
    --arg rustc_line "$rustc_line" \
    --arg go_line "$go_line" \
    --arg uv_line "$uv_line" \
    --arg py_line "$py_line" \
    '{
      dbt: {repo: $dbt_repo, branch: $dbt_branch, spec: $dbt_spec, sha: $dbt_sha},
      driver: {
        repo: $driver_repo,
        base_sha: $driver_sha,
        resolved_sha: $driver_commit,
        prs: [
          {number: 20, sha: $sha20},
          {number: 19, sha: $sha19},
          {number: 22, sha: $sha22}
        ]
      },
      rust: {version: $rust, rustup: $rustup},
      go: {version: $go},
      uv: {version: $uv, image: $uv_image},
      python: {version: $python},
      awscli: {version: $awscli},
      terraform: {version: $terraform},
      just: {version: $just},
      debian_image: $debian,
      cargo_build_jobs: $jobs,
      toolchains: {rustc: $rustc_line, go: $go_line, uv: $uv_line, python: $py_line}
    }' >"$out"
}

record_runtime() {
  local out="$1"
  local tmp aws_line tf_line just_line uv_line py_line
  [[ -f "$out" ]] || { echo "error: missing ${out}" >&2; exit 1; }

  aws_line="$(aws --version 2>&1)"
  [[ "$aws_line" == aws-cli/${AWSCLI_VERSION}* ]] || {
    echo "error: ${aws_line} does not match AWS CLI ${AWSCLI_VERSION}" >&2
    exit 1
  }
  tf_line="$(terraform version -json | jq -r .terraform_version)"
  [[ "$tf_line" == "$TERRAFORM_VERSION" ]] || {
    echo "error: terraform ${tf_line} does not match ${TERRAFORM_VERSION}" >&2
    exit 1
  }
  just_line="$(just --version)"
  [[ "$just_line" == "just ${JUST_VERSION}" ]] || {
    echo "error: ${just_line} does not match just ${JUST_VERSION}" >&2
    exit 1
  }
  uv_line="$(uv --version)"
  [[ "$uv_line" == "uv ${UV_VERSION} "* ]] || {
    echo "error: ${uv_line} does not match uv ${UV_VERSION}" >&2
    exit 1
  }
  py_line="$(uv run --frozen --project "$ROOT" python --version)"
  [[ "$py_line" == "Python ${PYTHON_VERSION}" ]] || {
    echo "error: ${py_line} does not match Python ${PYTHON_VERSION}" >&2
    exit 1
  }

  tmp="$(mktemp)"
  jq \
    --arg aws_line "$aws_line" \
    --arg tf_line "$tf_line" \
    --arg just_line "$just_line" \
    --arg uv_line "$uv_line" \
    --arg py_line "$py_line" \
    --arg jq_v "$(pkg_ver jq)" \
    --arg git_v "$(pkg_ver git)" \
    --arg ca_v "$(pkg_ver ca-certificates)" \
    --arg unzip_v "$(pkg_ver unzip)" \
    --arg curl_v "$(pkg_ver curl)" \
    '.toolchains += {awscli: $aws_line, terraform: $tf_line, just: $just_line, uv: $uv_line, python: $py_line}
     | .apt = {jq: $jq_v, git: $git_v, ca_certificates: $ca_v, unzip: $unzip_v, curl: $curl_v}' \
    "$out" >"$tmp"
  mv "$tmp" "$out"
}

require_pins
if [[ "${1:-}" == "--apt" ]]; then
  record_runtime "${2:?}"
else
  write_pins "${1:?}" "${2:?}"
fi
