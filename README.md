# dbt v2 Athena end-to-end harness

Repeatable sandbox for the Athena adapter work in [dbt-labs/dbt](https://github.com/dbt-labs/dbt) (the Rust engine, formerly dbt Fusion). From a Linux machine with AWS keys in the environment.

[just](https://github.com/casey/just) is the entry point. Recipes in the `justfile` only call the scripts, which stay the source of truth. The justfile exports `AWS_REGION` and defaults it to `us-east-1`.

```bash
# https://github.com/casey/just#installation
cargo install just
# or a prebuilt binary:
curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to "$HOME/.local/bin"

export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=us-east-1   # optional

just            # list recipes
just build
just up
just test
just down
just cycle      # up, test, down, status; down and status still run if test fails
```

Other recipes: `build-combined`, `test-offline`, `down-dry-run`, `status`, `check`. Extra words are passed through to the script (`just build --merge-only`, `just test --offline`).

The same steps without just:

```bash
export AWS_REGION=us-east-1   # optional; the scripts default to us-east-1
./scripts/build_dbt.sh
./infra/up.sh
./scripts/run_e2e.sh
./infra/down.sh
```

`up` is idempotent. `down` is safe to run twice and exits non-zero if anything tagged `project=dbt-v2-athena-e2e` or named with the harness prefix is still there. `just status` (`./infra/status.sh`) lists what exists. None of the scripts write access keys to disk.

The project under `project/` is synthetic and public: a handful of orders, no employer data, no proprietary names. Every query is a few kilobytes of data.

## What the checks map to

| Check | Pull request |
| --- | --- |
| `dbt parse` accepts `type: athena`, the macro package, and the model configs | [#16274](https://github.com/dbt-labs/dbt/pull/16274), [#16367](https://github.com/dbt-labs/dbt/pull/16367), [#16368](https://github.com/dbt-labs/dbt/pull/16368), [#16369](https://github.com/dbt-labs/dbt/pull/16369) |
| `dbt ls` | [#16367](https://github.com/dbt-labs/dbt/pull/16367), [#16369](https://github.com/dbt-labs/dbt/pull/16369) |
| `dbt init --skip-profile-setup` | [#16375](https://github.com/dbt-labs/dbt/pull/16375), [#16274](https://github.com/dbt-labs/dbt/pull/16274) |
| `dbt debug` loads the driver and reaches Athena | [#16365](https://github.com/dbt-labs/dbt/pull/16365), [#16274](https://github.com/dbt-labs/dbt/pull/16274) |
| `dbt seed` | [#16369](https://github.com/dbt-labs/dbt/pull/16369), [#16376](https://github.com/dbt-labs/dbt/pull/16376) |
| `dbt run` (view, Hive table, Iceberg table, both incrementals) | [#16368](https://github.com/dbt-labs/dbt/pull/16368), [#16369](https://github.com/dbt-labs/dbt/pull/16369), [#16374](https://github.com/dbt-labs/dbt/pull/16374), [#16376](https://github.com/dbt-labs/dbt/pull/16376) |
| Second compile shows `is_incremental()` true | [#16374](https://github.com/dbt-labs/dbt/pull/16374) |
| Second `dbt run` (Iceberg merge) | [#16374](https://github.com/dbt-labs/dbt/pull/16374), [#16376](https://github.com/dbt-labs/dbt/pull/16376) |
| `dbt test`, including the unit test that infers its schema from the fixture query | [#16370](https://github.com/dbt-labs/dbt/pull/16370) |
| `dbt show --inline` and `dbt show` on the merge model | [#16374](https://github.com/dbt-labs/dbt/pull/16374) |
| `dbt compile --write-catalog` | [#16369](https://github.com/dbt-labs/dbt/pull/16369) |

`scripts/run_e2e.sh` writes `results/<timestamp>/summary.md` and `summary.json` with that mapping, plus an Athena cost estimate.

## Cost

Athena is about **US$5 per TB scanned**, where a TB is 10^12 bytes. Each query is rounded up to the next megabyte, with a **10 MB minimum**. Failed queries and DDL are not billed. Twenty tiny queries therefore cost about 200 MB, which is a tenth of a cent. The workgroup sets `BytesScannedCutoffPerQuery` to 1 GB so a mistaken full scan stops there (about half a cent at the cap).

The Glue Data Catalog free tier covers this catalog. S3 storage and requests for a few megabytes, deleted the same day, are cents at most. The bucket lifecycle expires objects and noncurrent versions after one day if `down.sh` is not run.

The estimator in `scripts/cost.sh` applies the 10 MB minimum and the $5/TB rate. When the run can call Athena, it prefers `GetQueryExecution` statistics for the workgroup since the run started. Otherwise it reads `data_scanned_in_bytes` from dbt `run_results.json`. A driver that does not yet report statistics leaves those bytes at 0; the summary says so.

## Credentials

Use a **dedicated IAM user** (or a role you can assume) for this harness. Do not put root access keys in `AWS_ACCESS_KEY_ID`. Root keys can create and delete anything in the account, and dbt debug prints the access key id.

Attach the policy in [`infra/iam-least-privilege.json`](infra/iam-least-privilege.json). Replace `REGION` and `ACCOUNT_ID`. It allows Athena and Glue on the harness prefix, S3 on `aoelvp94-dbt-athena-test-*`, plus `sts:GetCallerIdentity` and `tag:GetResources` so status and the final sweep can see what they created. `s3:CreateBucket` and `s3:ListAllMyBuckets` are on `*` because those APIs do not take a bucket ARN. If a driver call is denied, the error names the missing action; add that action on the same prefix rather than widening to `*`.

A US$5 monthly budget alert, created once in the account, is enough to notice a runaway. Example (replace the account id and email; this is not run by `up.sh`):

```bash
aws budgets create-budget \
  --account-id "$ACCOUNT_ID" \
  --budget '{
    "BudgetName": "dbt-v2-athena-e2e",
    "BudgetLimit": {"Amount": "5", "Unit": "USD"},
    "TimeUnit": "MONTHLY",
    "BudgetType": "COST"
  }' \
  --notifications-with-subscribers '[{
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 80,
      "ThresholdType": "PERCENTAGE"
    },
    "Subscribers": [{
      "SubscriptionType": "EMAIL",
      "Address": "you@example.com"
    }]
  }]'
```

## Infrastructure

Terraform (AWS provider **5.100.0**, Terraform **>= 1.9.8** and **< 2**, validated with 1.9.8) in `infra/terraform/` keeps local state next to the config. State files and `.terraform/` are gitignored. The lock file is committed.

Resources, all tagged `project=dbt-v2-athena-e2e`:

- S3 bucket `aoelvp94-dbt-athena-test-<account-id>-<region>`, public access blocked, versioning on, SSE-S3, lifecycle expiry of one day, `force_destroy`
- Athena workgroup of the same name, enforced configuration, result location `s3://<bucket>/athena-results/`, 1 GB scan cap, `force_destroy`
- Two Glue databases, `..._analytics` (the dbt schema) and `..._scratch` (present so cleanup and catalog listing cover more than one database). Glue names use underscores because hyphens are not legal there.

`infra/up.sh` runs `terraform init` and `apply`, then writes `infra/.state/e2e.env` and `infra/.state/profiles.yml`. The profile uses the default AWS credential chain, `threads: 1`, and `s3_data_naming: schema_table_unique` (Iceberg CTAS requires a unique location). `DBT_ALLOW_EXPERIMENTAL_ADAPTERS=true` is recorded in the env file; Athena stays behind that gate.

`infra/up.sh --dry-run` and `infra/down.sh --dry-run` print the AWS and Terraform calls and run `terraform validate`. They do not contact AWS. `--plan` runs `terraform plan` or `terraform plan -destroy` (read-only AWS calls).

`infra/down.sh` deletes Glue tables dbt created, runs `terraform destroy`, then empties the bucket including versions, deletes the workgroup with `--recursive-delete`, and deletes any remaining prefixed databases. It finishes by listing prefixed and tagged resources and exits non-zero if the list is not empty.

## The dbt project

`project/` exercises:

- seeds `raw_customers` and `raw_orders`
- view `stg_orders`
- Hive table `orders_hive` with `+partitioned_by`, `+table_properties`, and `+force_batch` in `dbt_project.yml`
- Iceberg table `orders_iceberg` with the same keys on the model `config()` block
- Hive `insert_overwrite` incremental and an Iceberg `merge` incremental
- a unit test with row fixtures and no explicit column types (the schema-inference path)
- a singular test that order 99 exists after the second run
- `accepted_values` written as `arguments.values`. Current dbt main rejects a top-level `values:` key on a generic test. Tests that take no arguments (`unique`, `not_null`) stay as names.

The second run is `dbt run --vars '{include_late_order: true}'`. After the first run, `dbt compile` of the incremental models must contain the marker `e2e_is_incremental`, which is only rendered when `is_incremental()` is true.

## Building dbt and the driver

`scripts/build_dbt.sh` clones `dbt-labs/dbt`, fetches each engine PR with `refs/pull/N/head`, and merges onto current `main` in this order:

1. **16274** Part 1, profile schema. Required. [#16375](https://github.com/dbt-labs/dbt/pull/16375) is built on it.
2. **16365** Part 0, `Backend::Athena` entrypoint and `athena.output_location`.
3. **16367** Part 2, parse-path `todo!()` arms.
4. **16368** Part 3, model config keys.
5. **16369** Part 4, vendored dbt-athena 1.11.0 macros.
6. **16374** Part 5, `AthenaMetadataAdapter` and `athena_get_relation`.
7. **16376** Part 6, adapter methods the macros call (`upload_seed_to_s3`, Glue helpers, merge execution). Seed and run need this. `--no-execution` drops it.
8. **16370** Part 8, unit tests.
9. **16375** Part 9, init wizard.

The script also probes each of those PRs onto `main` alone, merges the user-listed set (16365, 16367, 16368, 16369, 16374, 16370, 16375) as its own combo, and merges the stack without 16376. Results go to `build/merge-report.json` (gitignored). A clean merge is `clean`. A conflict that still merges with `-X theirs` (the incoming PR wins the conflicting hunks) is `resolved-theirs`. Anything else is `failed`. Compilation runs only when the selected stack and the driver stack are fully clean, unless you pass `--allow-resolved`.

`--allow-resolved` is a last resort. `-X theirs` keeps the PR's side of each conflicting hunk and can drop a rename that landed on `main` after the PR was opened. On 2026-11-12, against dbt `main` `5e216d75`, only **#16365**, **#16369**, and **#16370** merged cleanly by themselves. The others conflicted (for example #16274 against `crates/dbt-adapter-engine/src/retry/mod.rs`, which `main` had split out of `retry.rs`). The full stack, the user-listed set, and the stack without #16376 all needed `-X theirs` on those files, so this harness did not compile them. Rebase the PRs onto current `main` and re-run `./scripts/build_dbt.sh --merge-only` before trusting a binary.

Driver PRs **#20**, **#19**, and **#22** each merge cleanly onto driver `main` `b147c187` on their own. Stacking #19 onto #20, then #22, conflicts in `go/athena_database.go`, `go/go.mod`, `go/statement.go`, and tests. Same rule: the script records `resolved-theirs` and will not build that tree unless `--allow-resolved` is set. `--stock-driver` builds driver `main` only, which is enough to load the library for #16365's option key and is not enough for the Glue operations in #16376. `cd go/pkg && make` on driver `main` with Go 1.26.10 produces `libadbc_driver_athena.so`.

The Go driver is [dbt-labs/athena](https://github.com/dbt-labs/athena), built with `cd go/pkg && make`, and installed at `lib/libadbc_driver_athena.so` next to the binary. The engine looks for that `lib/` directory by walking up from the executable. `main` of the driver does not yet accept every option the engine sends once 16274 and 16376 are merged, so the default driver build also merges, in order:

- [dbt-labs/athena#20](https://github.com/dbt-labs/athena/pull/20) connection options
- [dbt-labs/athena#19](https://github.com/dbt-labs/athena/pull/19) Glue, S3, and STS operations
- [dbt-labs/athena#22](https://github.com/dbt-labs/athena/pull/22) query statistics on the result schema

`--stock-driver` builds driver `main` only. `--driver-lib PATH` and `--binary PATH` skip the corresponding compile and still place the library next to the binary when the directory is writable.

The engine needs Rust **1.96** (`rust-toolchain.toml`). The script installs that toolchain under `.cache/` without changing the system default. The driver `go.mod` asks for Go **1.26.10**; the script downloads that SDK into the cache when the system Go is older. Build products stay in `.cache/dbt-v2-athena-e2e/`.

To build one already-combined branch, pass `--branch <owner>/<repo>/<branch>` or set `DBT_BRANCH` to that same spec. The branch name may contain slashes. For the combined Athena tree, that spec is `aoelvp94/dbt/local/athena-combined`: the script checks out [aoelvp94/dbt](https://github.com/aoelvp94/dbt) `local/athena-combined` and builds the Go driver from `dbt-labs/athena` `main`, with no driver pull requests:

```bash
just build-combined
# same thing:
just build -- --branch aoelvp94/dbt/local/athena-combined

./scripts/build_dbt.sh --branch aoelvp94/dbt/local/athena-combined
# same thing:
DBT_BRANCH=aoelvp94/dbt/local/athena-combined ./scripts/build_dbt.sh
```

`https://github.com/aoelvp94/dbt/local/athena-combined` and `git@github.com:aoelvp94/dbt.git/local/athena-combined` are accepted too. `--prs`, `--no-execution`, `--allow-resolved`, and `--driver-prs` do not apply in this mode. The report is still `build/merge-report.json`, with `"mode": "branch"` and the checked-out commit.

```bash
just build -- --merge-only           # report only
just build -- --binary /path/to/dbt  # existing engine binary, still build the driver
just build -- --no-execution         # stack without Part 6
just build-combined

./scripts/build_dbt.sh --merge-only          # report only
./scripts/build_dbt.sh --binary /path/to/dbt # existing engine binary, still build the driver
./scripts/build_dbt.sh --no-execution        # stack without Part 6
./scripts/build_dbt.sh --branch aoelvp94/dbt/local/athena-combined
```

`just test-offline` (`./scripts/run_e2e.sh --offline`) runs parse, ls, and init. It needs a binary. Without `infra/up.sh`, live checks are reported as failed and no AWS call is made.

`just check` (`./scripts/check.sh`) runs shellcheck, `terraform fmt -check`, `terraform validate` via the dry-run, and the cost self-test. It does not contact AWS. `just down-dry-run` prints the destroy calls and does not contact AWS.

## Layout

```
justfile                  recipe wrappers; scripts stay the source of truth
infra/up.sh infra/down.sh infra/status.sh
infra/terraform/          local Terraform state, gitignored
infra/iam-least-privilege.json
infra/profiles.yml.example
project/                  the synthetic dbt project
scripts/build_dbt.sh scripts/run_e2e.sh scripts/cost.sh scripts/check.sh
```

## License

Apache License 2.0. See [LICENSE](LICENSE). Copyright 2026 Aldo Escobar.
