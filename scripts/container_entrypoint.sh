#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
mkdir -p "${HOME:-/tmp/e2e-home}" /tmp/uv-cache
exec "$@"
