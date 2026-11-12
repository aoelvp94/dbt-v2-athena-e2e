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
    #!/usr/bin/env bash
    set -euo pipefail
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

# Build the pinned image. versions.env is the pin list; an exported pin overrides it.
docker-build:
    "{{ root }}/scripts/docker_build.sh"

# Create the sandbox in the image. AWS keys are passed through the environment.
docker-up:
    "{{ root }}/scripts/docker_run.sh" /opt/e2e/infra/up.sh

# Run the suite in the image. Extra words go to scripts/run_e2e.sh.
docker-test *args:
    "{{ root }}/scripts/docker_run.sh" /opt/e2e/scripts/run_e2e.sh {{ args }}

# Parse, ls, and init in the image. Does not contact AWS.
docker-test-offline:
    "{{ root }}/scripts/docker_run.sh" just test-offline

# Delete harness resources from the image. Fails if any remain.
docker-down:
    "{{ root }}/scripts/docker_run.sh" /opt/e2e/infra/down.sh

# List harness resources from the image.
docker-status:
    "{{ root }}/scripts/docker_run.sh" /opt/e2e/infra/status.sh

# up, then the suite, then down, then status, in the image. down and status still run when the suite fails.
docker-cycle:
    #!/usr/bin/env bash
    set -euo pipefail
    "{{ root }}/scripts/docker_run.sh" /opt/e2e/infra/up.sh
    test_status=0
    "{{ root }}/scripts/docker_run.sh" /opt/e2e/scripts/run_e2e.sh || test_status=$?
    down_status=0
    "{{ root }}/scripts/docker_run.sh" /opt/e2e/infra/down.sh || down_status=$?
    status_status=0
    "{{ root }}/scripts/docker_run.sh" /opt/e2e/infra/status.sh || status_status=$?
    if [[ "$test_status" -ne 0 ]]; then exit "$test_status"; fi
    if [[ "$down_status" -ne 0 ]]; then exit "$down_status"; fi
    exit "$status_status"
