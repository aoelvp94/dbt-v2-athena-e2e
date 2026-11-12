# SPDX-License-Identifier: Apache-2.0
# AWS list and delete helpers. Every delete checks the harness prefix first.

# shellcheck shell=bash

e2e_glue_databases() {
  local glue_prefix="$1"
  e2e_assert_glue_prefix "$glue_prefix"
  local token="" page names
  while true; do
    local args=(glue get-databases --max-results 100 --output json)
    if [[ -n "$token" ]]; then
      args+=(--next-token "$token")
    fi
    page="$(aws "${args[@]}")"
    names="$(jq -r --arg p "$glue_prefix" '.DatabaseList[]? | select(.Name | startswith($p)) | .Name' <<<"$page")"
    if [[ -n "$names" ]]; then
      printf '%s\n' "$names"
    fi
    token="$(jq -r '.NextToken // empty' <<<"$page")"
    [[ -n "$token" ]] || break
  done
}

e2e_delete_tables_in_database() {
  local db="$1"
  local glue_prefix="$2"
  e2e_assert_glue_prefix "$glue_prefix"
  [[ "$db" == "$glue_prefix"* ]] || e2e_die "refusing to delete tables in ${db}"

  local token="" page table
  while true; do
    local args=(glue get-tables --database-name "$db" --max-results 100 --output json)
    if [[ -n "$token" ]]; then
      args+=(--next-token "$token")
    fi
    if ! page="$(aws "${args[@]}" 2>/dev/null)"; then
      return 0
    fi
    while IFS= read -r table; do
      [[ -n "$table" ]] || continue
      e2e_log "deleting glue table ${db}.${table}"
      aws glue delete-table --database-name "$db" --name "$table"
    done < <(jq -r '.TableList[]?.Name' <<<"$page")
    token="$(jq -r '.NextToken // empty' <<<"$page")"
    [[ -n "$token" ]] || break
  done
}

e2e_delete_glue_database() {
  local db="$1"
  local glue_prefix="$2"
  e2e_assert_glue_prefix "$glue_prefix"
  [[ "$db" == "$glue_prefix"* ]] || e2e_die "refusing to delete glue database ${db}"
  if aws glue get-database --name "$db" >/dev/null 2>&1; then
    e2e_log "deleting glue database ${db}"
    aws glue delete-database --name "$db"
  fi
}

e2e_workgroup_exists() {
  local name="$1"
  local token="" page found
  while true; do
    local args=(athena list-work-groups --output json)
    if [[ -n "$token" ]]; then
      args+=(--next-token "$token")
    fi
    page="$(aws "${args[@]}")"
    found="$(jq -r --arg n "$name" '.WorkGroups[]? | select(.Name == $n) | .Name' <<<"$page")"
    if [[ "$found" == "$name" ]]; then
      return 0
    fi
    token="$(jq -r '.NextToken // empty' <<<"$page")"
    [[ -n "$token" ]] || return 1
  done
}

e2e_delete_workgroup() {
  local name="$1"
  e2e_assert_name_prefix "$name"
  if e2e_workgroup_exists "$name"; then
    e2e_log "deleting athena workgroup ${name}"
    aws athena delete-work-group --work-group "$name" --recursive-delete
  fi
}

e2e_bucket_exists() {
  local bucket="$1"
  aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1
}

e2e_empty_and_delete_bucket() {
  local bucket="$1"
  e2e_assert_name_prefix "$bucket"
  if ! e2e_bucket_exists "$bucket"; then
    return 0
  fi

  e2e_log "emptying s3 bucket ${bucket} (including versions)"
  local key_marker="" version_marker="" page count payload truncated upload_id key
  while true; do
    local args=(s3api list-object-versions --bucket "$bucket" --max-keys 1000 --output json)
    if [[ -n "$key_marker" ]]; then
      args+=(--key-marker "$key_marker")
    fi
    if [[ -n "$version_marker" ]]; then
      args+=(--version-id-marker "$version_marker")
    fi
    page="$(aws "${args[@]}")"
    count="$(jq '([.Versions[]?, .DeleteMarkers[]?] | length)' <<<"$page")"
    if [[ "$count" -gt 0 ]]; then
      payload="$(jq -c '{
        Objects: (
          [(.Versions // [])[] | {Key: .Key, VersionId: .VersionId}]
          + [(.DeleteMarkers // [])[] | {Key: .Key, VersionId: .VersionId}]
        ),
        Quiet: true
      }' <<<"$page")"
      aws s3api delete-objects --bucket "$bucket" --delete "$payload" >/dev/null
    fi
    truncated="$(jq -r '.IsTruncated' <<<"$page")"
    [[ "$truncated" == "true" ]] || break
    key_marker="$(jq -r '.NextKeyMarker // empty' <<<"$page")"
    version_marker="$(jq -r '.NextVersionIdMarker // empty' <<<"$page")"
    [[ -n "$key_marker" ]] || break
  done

  local uploads
  uploads="$(aws s3api list-multipart-uploads --bucket "$bucket" --output json)"
  while IFS=$'\t' read -r key upload_id; do
    [[ -n "$upload_id" ]] || continue
    aws s3api abort-multipart-upload --bucket "$bucket" --key "$key" --upload-id "$upload_id"
  done < <(jq -r '.Uploads[]? | [.Key, .UploadId] | @tsv' <<<"$uploads")

  e2e_log "deleting s3 bucket ${bucket}"
  aws s3api delete-bucket --bucket "$bucket"
}

# Print one resource per line: kind<TAB>name. Sets nothing.
e2e_list_resources() {
  local prefix="$1"
  local glue_prefix="$2"
  local tag="$3"
  e2e_assert_name_prefix "$prefix"
  e2e_assert_glue_prefix "$glue_prefix"

  local bucket_token="" buckets
  while true; do
    local bucket_args=(s3api list-buckets --output json)
    if [[ -n "$bucket_token" ]]; then
      bucket_args+=(--continuation-token "$bucket_token")
    fi
    buckets="$(aws "${bucket_args[@]}")"
    jq -r --arg p "$prefix" '.Buckets[]? | select(.Name | startswith($p)) | "s3-bucket\t" + .Name' <<<"$buckets"
    bucket_token="$(jq -r '.ContinuationToken // empty' <<<"$buckets")"
    [[ -n "$bucket_token" ]] || break
  done

  local wg_token="" groups
  while true; do
    local wg_args=(athena list-work-groups --output json)
    if [[ -n "$wg_token" ]]; then
      wg_args+=(--next-token "$wg_token")
    fi
    groups="$(aws "${wg_args[@]}")"
    jq -r --arg p "$prefix" '.WorkGroups[]? | select(.Name | startswith($p)) | "athena-workgroup\t" + .Name' <<<"$groups"
    wg_token="$(jq -r '.NextToken // empty' <<<"$groups")"
    [[ -n "$wg_token" ]] || break
  done

  local db
  while IFS= read -r db; do
    [[ -n "$db" ]] || continue
    printf 'glue-database\t%s\n' "$db"
    local token="" page table
    while true; do
      local args=(glue get-tables --database-name "$db" --max-results 100 --output json)
      if [[ -n "$token" ]]; then
        args+=(--next-token "$token")
      fi
      if ! page="$(aws "${args[@]}" 2>/dev/null)"; then
        break
      fi
      while IFS= read -r table; do
        [[ -n "$table" ]] || continue
        printf 'glue-table\t%s.%s\n' "$db" "$table"
      done < <(jq -r '.TableList[]?.Name' <<<"$page")
      token="$(jq -r '.NextToken // empty' <<<"$page")"
      [[ -n "$token" ]] || break
    done
  done < <(e2e_glue_databases "$glue_prefix")

  local tag_token="" tag_page arn
  while true; do
    local tag_args=(resourcegroupstaggingapi get-resources --tag-filters "Key=project,Values=${tag}" --output json)
    if [[ -n "$tag_token" ]]; then
      tag_args+=(--pagination-token "$tag_token")
    fi
    if ! tag_page="$(aws "${tag_args[@]}" 2>/dev/null)"; then
      printf 'tagged-list-error\tresourcegroupstaggingapi get-resources failed\n'
      break
    fi
    while IFS= read -r arn; do
      [[ -n "$arn" ]] || continue
      printf 'tagged\t%s\n' "$arn"
    done < <(jq -r '.ResourceTagMappingList[]?.ResourceARN' <<<"$tag_page")
    tag_token="$(jq -r '.PaginationToken // empty' <<<"$tag_page")"
    [[ -n "$tag_token" ]] || break
  done
}
