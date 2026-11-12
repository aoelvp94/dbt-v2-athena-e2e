#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Run a command in the image. AWS credentials are forwarded with -e and are
# not written to a file. State, the dbt project, and results are host mounts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=pins.sh
source "${SCRIPT_DIR}/pins.sh"
e2e_load_pins "$ROOT"

if [[ $# -lt 1 ]]; then
  echo "usage: scripts/docker_run.sh <command> [args...]" >&2
  exit 1
fi
command -v docker >/dev/null 2>&1 || { echo "error: docker is required" >&2; exit 1; }

if [[ -z "${AWS_DEFAULT_REGION:-}" && -n "${AWS_REGION:-}" ]]; then
  export AWS_DEFAULT_REGION="$AWS_REGION"
fi

mkdir -p "${ROOT}/results" "${ROOT}/infra/.state"

env_args=()
for v in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_REGION AWS_REGION; do
  if [[ -n "${!v:-}" ]]; then
    env_args+=(-e "$v")
  fi
done

docker_args=(
  docker run --rm
  --platform linux/amd64
  -u "$(id -u):$(id -g)"
  -e HOME=/tmp/e2e-home
  -e UV_CACHE_DIR=/tmp/uv-cache
  -w /opt/e2e
)
if [[ ${#env_args[@]} -gt 0 ]]; then
  docker_args+=("${env_args[@]}")
fi
docker_args+=(
  -v "${ROOT}/results:/opt/e2e/results"
  -v "${ROOT}/infra/terraform:/opt/e2e/infra/terraform"
  -v "${ROOT}/infra/.state:/opt/e2e/infra/.state"
  -v "${ROOT}/project:/opt/e2e/project"
  "${IMAGE_REF}"
  "$@"
)
exec "${docker_args[@]}"
