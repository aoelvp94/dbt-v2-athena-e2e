#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build the linux/amd64 image. Pins come from versions.env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=pins.sh
source "${SCRIPT_DIR}/pins.sh"
e2e_load_pins "$ROOT"

command -v docker >/dev/null 2>&1 || { echo "error: docker is required" >&2; exit 1; }
export DOCKER_BUILDKIT=1

build_args=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^([A-Z0-9_]+)= ]] || continue
  key="${BASH_REMATCH[1]}"
  [[ "$key" == "IMAGE_REF" ]] && continue
  build_args+=(--build-arg "${key}=${!key}")
done <"${ROOT}/versions.env"

exec docker build \
  --platform linux/amd64 \
  --progress=plain \
  --pull \
  "${build_args[@]}" \
  -t "${IMAGE_REF}" \
  "$ROOT"
