# dbt v2 Athena end-to-end harness

This repo runs the Athena work in dbt v2 through a sandbox Athena workgroup so a reviewer of [dbt-labs/dbt#16252](https://github.com/dbt-labs/dbt/issues/16252) can see the series pass or fail as one sequence. The project under `project/` is a few synthetic orders.

## What is under test

Pins live in [`versions.env`](versions.env). The image checks these commits out and stops if a fetched head differs.

| Piece | Pin |
| --- | --- |
| Engine | [aoelvp94/dbt](https://github.com/aoelvp94/dbt) `local/athena-combined` `e7d7bdc6c659399606965545b8e8f90c9c41dde5` |
| Driver base | [dbt-labs/athena](https://github.com/dbt-labs/athena) `b147c187872fa8b21d8fa3ab0c56d33d9b19d28f` |
| Driver [#20](https://github.com/dbt-labs/athena/pull/20) | `0df20751ea9c509596af181bca9a5b0479e55fa0` |
| Driver [#19](https://github.com/dbt-labs/athena/pull/19) | `0be3f7a8da7da54aa24abd2e73bff769c9eaef28` |
| Driver [#22](https://github.com/dbt-labs/athena/pull/22) | `3acd21d33126d067302b1516b43dc78d36b1e06d` |

The engine commit is the combined branch for [#16365](https://github.com/dbt-labs/dbt/pull/16365), [#16367](https://github.com/dbt-labs/dbt/pull/16367), [#16368](https://github.com/dbt-labs/dbt/pull/16368), [#16369](https://github.com/dbt-labs/dbt/pull/16369), [#16374](https://github.com/dbt-labs/dbt/pull/16374), [#16370](https://github.com/dbt-labs/dbt/pull/16370), and [#16375](https://github.com/dbt-labs/dbt/pull/16375). It also contains the profile schema ([#16274](https://github.com/dbt-labs/dbt/pull/16274)) and the execution methods ([#16376](https://github.com/dbt-labs/dbt/pull/16376)). Driver PRs merge onto the driver base in the order #20, #19, #22.

## Quickstart

The image is `linux/amd64`. `just docker-build` compiles the pinned engine and driver. `CARGO_BUILD_JOBS` is 1. GitHub Actions checks that `versions.env` matches the Dockerfile. Build the image on the machine that will run the suite.

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...   # temporary credentials
export AWS_REGION=us-east-1    # optional; the justfile defaults to us-east-1

just docker-build
just docker-cycle
```

`just docker-cycle` creates the sandbox, runs the twelve checks, tears it down, and lists anything left. Teardown and the leftover check still run when the suite fails. Keys travel only as container environment variables: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_DEFAULT_REGION`, and `AWS_REGION`.

## Checks

`parse`, `ls`, and `init` stay on the machine. The rest call Athena.

| Check | What a pass shows |
| --- | --- |
| `parse` | The project parses with `type: athena`, the macro package, and the model configs ([#16274](https://github.com/dbt-labs/dbt/pull/16274), [#16367](https://github.com/dbt-labs/dbt/pull/16367), [#16368](https://github.com/dbt-labs/dbt/pull/16368), [#16369](https://github.com/dbt-labs/dbt/pull/16369)) |
| `ls` | Seeds and models are listed ([#16367](https://github.com/dbt-labs/dbt/pull/16367), [#16369](https://github.com/dbt-labs/dbt/pull/16369)) |
| `init` | `dbt init --skip-profile-setup` finishes without a prompt ([#16375](https://github.com/dbt-labs/dbt/pull/16375), [#16274](https://github.com/dbt-labs/dbt/pull/16274)) |
| `debug` | The ADBC driver loads and the connection test finishes ([#16365](https://github.com/dbt-labs/dbt/pull/16365), [#16274](https://github.com/dbt-labs/dbt/pull/16274)) |
| `seed` | Seeds load ([#16369](https://github.com/dbt-labs/dbt/pull/16369), [#16376](https://github.com/dbt-labs/dbt/pull/16376)) |
| `run` | The view, the Hive table, the Iceberg table, and both incrementals build ([#16368](https://github.com/dbt-labs/dbt/pull/16368), [#16369](https://github.com/dbt-labs/dbt/pull/16369), [#16374](https://github.com/dbt-labs/dbt/pull/16374), [#16376](https://github.com/dbt-labs/dbt/pull/16376)) |
| `incremental_branch` | A second compile of the incremental models contains `e2e_is_incremental`, so `is_incremental()` is true ([#16374](https://github.com/dbt-labs/dbt/pull/16374)) |
| `run_again` | The incrementals run again, including the Iceberg merge ([#16374](https://github.com/dbt-labs/dbt/pull/16374), [#16376](https://github.com/dbt-labs/dbt/pull/16376)) |
| `test` | Schema tests, the late-order check, and the unit test pass ([#16370](https://github.com/dbt-labs/dbt/pull/16370)) |
| `show_inline` | `dbt show --inline` returns ([#16374](https://github.com/dbt-labs/dbt/pull/16374)) |
| `show_model` | `dbt show` returns rows for the Iceberg merge model ([#16374](https://github.com/dbt-labs/dbt/pull/16374)) |
| `compile_catalog` | `dbt compile --write-catalog` writes a catalog that includes `stg_orders` ([#16369](https://github.com/dbt-labs/dbt/pull/16369)) |

## AWS resources, access, cost, teardown

`up` applies Terraform (AWS provider 5.100.0, Terraform 1.9.8) with local state and creates:

- an S3 bucket `aoelvp94-dbt-athena-test-<account-id>-<region>`, with public access blocked, versioning, SSE-S3, a one-day lifecycle, and `force_destroy`
- an Athena workgroup of the same name, with the result location `s3://<bucket>/athena-results/` enforced and a 1 GB scan cap
- two Glue databases, `aoelvp94_dbt_athena_test_<account-id>_<region>_analytics` and `..._scratch`

Every resource is tagged `project=dbt-v2-athena-e2e`.

Attach [`infra/iam-least-privilege.json`](infra/iam-least-privilege.json) to a dedicated IAM user or role. Replace `REGION` and `ACCOUNT_ID`. The policy covers Athena on the workgroup prefix, Glue on the database prefix, and S3 on the bucket prefix, plus `sts:GetCallerIdentity` and `tag:GetResources`. `s3:CreateBucket` and `s3:ListAllMyBuckets` are granted on `*` because those APIs take no bucket ARN.

Athena is US$5 per TB scanned, where a TB is 10^12 bytes, with a 10 MB minimum on each successful DML query. The estimate leaves out DDL and failed queries. A run of this project is about US$0.003. The workgroup stops a query at 1 GB.

`down` drops Glue tables the run created, runs `terraform destroy`, empties the bucket including versions, and deletes a leftover workgroup or database that still carries the prefix. It then lists prefixed and tagged resources and exits non-zero if any remain. Running it twice is safe. The bucket lifecycle expires objects after one day, which covers a sandbox that outlived the script. `just docker-cycle` runs `down` and then `status` after the suite, including when the suite fails.

## Reading a result

Each run writes `results/<UTC timestamp>/summary.md` and `summary.json` on the host. The markdown file has one row per check (name, pass or fail, pull requests, seconds, detail), then bytes scanned, billed bytes, the estimated cost, and where the bytes came from (`athena-api` from `GetQueryExecution`, or `artifact` from `run_results.json` when that listing is unavailable). `summary.json` has the same fields, plus `build_info`.

`BUILD_INFO.json` in that directory is a copy of `/opt/e2e/BUILD_INFO.json`. `dbt.sha` is the engine commit. `driver.base_sha` is the driver main commit. `driver.prs` lists #20, #19, and #22 with their SHAs. `driver.resolved_sha` is the merge commit produced while building the image. The rest records Rust, Go, uv, Python, the AWS CLI, Terraform, just, and the base image digest. The top of `summary.md` repeats the engine SHA, the driver base SHA, and the uv version.

## Last verified

12 Nov 2026, `us-east-1`. 12/12 checks passed. 95 queries, 15,783 bytes scanned, about US$0.003. Engine `e7d7bdc6c659399606965545b8e8f90c9c41dde5`. Driver base `b147c187872fa8b21d8fa3ab0c56d33d9b19d28f` plus #20, #19, and #22 at the SHAs above.

## Override a pin

`versions.env` supplies the default for each key. Export a key before `just docker-build` to replace that one pin. To try another engine branch, set the spec and the full commit together:

```bash
export DBT_REPO=https://github.com/OWNER/dbt.git
export DBT_BRANCH=BRANCH
export DBT_SPEC=OWNER/dbt/BRANCH
export DBT_SHA=<40-character SHA>
just docker-build
just docker-cycle
```

The build checks out `DBT_SPEC` and stops when that checkout is a different commit from `DBT_SHA`. Driver pins (`DRIVER_SHA`, `DRIVER_PR_20_SHA`, `DRIVER_PR_19_SHA`, `DRIVER_PR_22_SHA`) override the same way. A change committed in `versions.env` also belongs in the matching `ARG` default in the `Dockerfile`. `scripts/check_pins.sh` fails when those two copies drift.

## Without Docker

The scripts are the source of truth. The justfile only calls them.

```bash
just build-combined
just cycle
```

`just build-combined` checks out `aoelvp94/dbt` `local/athena-combined` and merges driver PRs #20, #19, and #22. That host build follows the branch tip and the current PR heads. The image build stops when the checkout differs from `versions.env`.

`just check` runs shellcheck, the pin check, `uv lock --check`, Terraform fmt, and a dry-run, and stays off AWS. `just test-offline` runs parse, ls, and init. Python dependencies are `pyproject.toml` and `uv.lock`, executed with `uv run`. The uv version is the one in `versions.env`.

The same steps as scripts:

```bash
./scripts/build_dbt.sh --branch aoelvp94/dbt/local/athena-combined --driver-prs "20 19 22"
./infra/up.sh
./scripts/run_e2e.sh
./infra/down.sh
```

Apache License 2.0. See [LICENSE](LICENSE).
