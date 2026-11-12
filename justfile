# SPDX-License-Identifier: Apache-2.0
# Wrappers around the harness scripts. The scripts stay the source of truth.

export AWS_REGION := env('AWS_REGION', 'us-east-1')

set shell := ["bash", "-euo", "pipefail", "-c"]

root := justfile_directory()

# List recipes.
default:
    @just --list

# Build dbt and the Athena driver. Extra words go to scripts/build_dbt.sh.
build *args:
    "{{ root }}/scripts/build_dbt.sh" {{ args }}

# Build aoelvp94/dbt local/athena-combined plus driver main with #20, #19, and #22.
build-combined:
    "{{ root }}/scripts/build_dbt.sh" --branch aoelvp94/dbt/local/athena-combined --driver-prs "20 19 22"

# Create the sandbox and write profiles.yml.
up:
    "{{ root }}/infra/up.sh"

# Run the end-to-end checks. Extra words go to scripts/run_e2e.sh.
test *args:
    "{{ root }}/scripts/run_e2e.sh" {{ args }}

# Parse, ls, and init only. Does not contact AWS.
test-offline:
    "{{ root }}/scripts/run_e2e.sh" --offline

# Delete harness resources and fail if any remain.
down:
    "{{ root }}/infra/down.sh"

# Print the destroy calls. Does not contact AWS.
down-dry-run:
    "{{ root }}/infra/down.sh" --dry-run

# List harness resources in this account and region.
status:
    "{{ root }}/infra/status.sh"

# Offline checks. Does not contact AWS.
check:
    "{{ root }}/scripts/check.sh"

# up, then the suite, then down, then status. down and status still run when the suite fails.
cycle:
    "{{ root }}/infra/up.sh"
    test_status=0
    "{{ root }}/scripts/run_e2e.sh" || test_status=$?
    down_status=0
    "{{ root }}/infra/down.sh" || down_status=$?
    status_status=0
    "{{ root }}/infra/status.sh" || status_status=$?
    if [[ "$test_status" -ne 0 ]]; then exit "$test_status"; fi
    if [[ "$down_status" -ne 0 ]]; then exit "$down_status"; fi
    exit "$status_status"
