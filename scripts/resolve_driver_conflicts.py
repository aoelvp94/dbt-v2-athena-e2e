#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Resolve the known dbt-labs/athena driver PR conflicts.

Default driver stack, merged onto main in order:

  #20 connection options
  #19 Glue / S3 / STS operations
  #22 query statistics

#19 conflicts with #20, and #22 conflicts with that result. -X theirs drops
a side. This step keeps both behaviors:

  README.md, go/athena_database.go
      keep both sides (connection options and catalog operations;
      testSTSClient and testAWS)
  go/go.mod
      #19's Glue, Lake Formation, and S3 requires, with sts v1.51.0
      and smithy-go v1.28.1
  go/statement.go
      keep defaultPollInterval, and waitForQuery returning
      (*types.QueryExecution, error)
  go/driver_test.go
      keep TestIntegration_AthenaEndpointURL and TestIntegration_QueryStatistics

Any other conflict is left untouched and the script exits 1 so the caller
can fall back to -X theirs, which still requires --allow-resolved.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

KEEP_BOTH = {"README.md", "go/athena_database.go"}


def _split_conflicts(text: str) -> tuple[list[tuple[str, str, str]], str]:
    """Return conflict pieces and the text after the last conflict."""
    lines = text.splitlines(keepends=True)
    parts: list[tuple[str, str, str]] = []
    i = 0
    buf: list[str] = []
    while i < len(lines):
        if lines[i].startswith("<<<<<<<"):
            before = "".join(buf)
            buf = []
            i += 1
            ours: list[str] = []
            while i < len(lines) and not lines[i].startswith("======="):
                ours.append(lines[i])
                i += 1
            if i >= len(lines):
                raise ValueError("conflict is missing =======")
            i += 1
            theirs: list[str] = []
            while i < len(lines) and not lines[i].startswith(">>>>>>>"):
                theirs.append(lines[i])
                i += 1
            if i >= len(lines):
                raise ValueError("conflict is missing >>>>>>>")
            i += 1
            parts.append((before, "".join(ours), "".join(theirs)))
        else:
            buf.append(lines[i])
            i += 1
    return parts, "".join(buf)


def _resolve_hunk(path: str, ours: str, theirs: str) -> str:
    if path in KEEP_BOTH:
        return ours + theirs
    if path == "go/go.mod":
        if (
            "service/sts" in ours
            and "service/glue" in theirs
            and "service/lakeformation" in theirs
            and "service/s3" in theirs
            and "v1.51.0" in theirs
        ):
            return theirs if theirs.endswith("\n") else theirs + "\n"
        if "smithy-go" in ours and "smithy-go" in theirs and "v1.28.1" in theirs:
            return theirs if theirs.endswith("\n") else theirs + "\n"
        raise ValueError(f"unrecognized go.mod conflict:\n{ours}---\n{theirs}")
    if path == "go/statement.go":
        if "defaultPollInterval" not in ours or "(*types.QueryExecution, error)" not in theirs:
            raise ValueError("statement.go conflict is not the known waitForQuery hunk")
        kept = [
            line
            for line in ours.splitlines(keepends=True)
            if not line.startswith("func (s *statementImpl) waitForQuery")
        ]
        const_block = "".join(kept).rstrip() + "\n\n"
        return const_block + theirs
    if path == "go/driver_test.go":
        if (
            "TestIntegration_AthenaEndpointURL" not in ours
            or "TestIntegration_QueryStatistics" not in theirs
        ):
            raise ValueError("driver_test.go conflict is not the known integration tests")
        # The shared closing brace sits after the conflict marker.
        return ours.rstrip() + "\n}\n\n" + theirs
    raise ValueError(f"no resolver for {path}")


def resolve_text(path: str, text: str) -> str:
    if "<<<<<<<" not in text:
        return text
    parts, tail = _split_conflicts(text)
    out: list[str] = []
    for before, ours, theirs in parts:
        out.append(before)
        out.append(_resolve_hunk(path, ours, theirs))
    out.append(tail)
    resolved = "".join(out)
    if "<<<<<<<" in resolved or ">>>>>>>" in resolved:
        raise ValueError(f"conflict markers remain in {path}")
    return resolved


def unmerged_files(repo: Path) -> list[str]:
    result = subprocess.run(
        ["git", "diff", "--name-only", "--diff-filter=U"],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    )
    return [line for line in result.stdout.splitlines() if line]


def resolve_repo(repo: Path) -> None:
    files = unmerged_files(repo)
    if not files:
        raise ValueError("no unmerged files")
    allowed = KEEP_BOTH | {"go/go.mod", "go/statement.go", "go/driver_test.go"}
    unknown = [path for path in files if path not in allowed]
    if unknown:
        raise ValueError("unexpected conflict files: " + ", ".join(unknown))
    updated: list[tuple[Path, str]] = []
    for rel in files:
        path = repo / rel
        updated.append((path, resolve_text(rel, path.read_text())))
    for path, text in updated:
        path.write_text(text)


def _self_test() -> None:
    gomod = (
        "require (\n"
        "<<<<<<< HEAD\n"
        "\tgithub.com/aws/aws-sdk-go-v2/service/sts v1.30.4\n"
        "=======\n"
        "\tgithub.com/aws/aws-sdk-go-v2/service/glue v1.160.0\n"
        "\tgithub.com/aws/aws-sdk-go-v2/service/lakeformation v1.55.1\n"
        "\tgithub.com/aws/aws-sdk-go-v2/service/s3 v1.113.1\n"
        "\tgithub.com/aws/aws-sdk-go-v2/service/sts v1.51.0\n"
        ">>>>>>> theirs\n"
        ")\n"
        "<<<<<<< HEAD\n"
        "\tgithub.com/aws/smithy-go v1.22.5 // indirect\n"
        "=======\n"
        "\tgithub.com/aws/smithy-go v1.28.1 // indirect\n"
        ">>>>>>> theirs\n"
    )
    resolved = resolve_text("go/go.mod", gomod)
    if "v1.30.4" in resolved or "v1.22.5" in resolved:
        raise SystemExit("go.mod kept the older modules")
    if "v1.51.0" not in resolved or "v1.28.1" not in resolved or "service/glue" not in resolved:
        raise SystemExit("go.mod dropped #19 requires")

    statement = (
        "<<<<<<< HEAD\n"
        "// defaultPollInterval is the interval between query status checks unless\n"
        "// OptionPollInterval is set.\n"
        "const defaultPollInterval = 500 * time.Millisecond\n"
        "\n"
        "func (s *statementImpl) waitForQuery(ctx context.Context, execID *string) error {\n"
        "=======\n"
        "// waitForQuery polls the query until it finishes and returns its final execution.\n"
        "func (s *statementImpl) waitForQuery(ctx context.Context, execID *string) (*types.QueryExecution, error) {\n"
        ">>>>>>> theirs\n"
    )
    resolved = resolve_text("go/statement.go", statement)
    if "defaultPollInterval" not in resolved or "(*types.QueryExecution, error)" not in resolved:
        raise SystemExit("statement.go lost a required side")
    if "execID *string) error {" in resolved:
        raise SystemExit("statement.go kept the old waitForQuery signature")

    tests = (
        "<<<<<<< HEAD\n"
        "func TestIntegration_AthenaEndpointURL(t *testing.T) {\n"
        "\tconn := integrationConn(t)\n"
        "=======\n"
        "func TestIntegration_QueryStatistics(t *testing.T) {\n"
        "\tconn := integrationConn(t)\n"
        ">>>>>>> theirs\n"
        "}\n"
    )
    resolved = resolve_text("go/driver_test.go", tests)
    if resolved.count("func TestIntegration_") != 2 or resolved.count("\n}") < 2:
        raise SystemExit(f"driver_test.go did not keep both tests:\n{resolved}")

    fields = (
        "<<<<<<< HEAD\n"
        "\ttestSTSClient stscreds.AssumeRoleAPIClient\n"
        "=======\n"
        "\ttestAWS *awsClients\n"
        ">>>>>>> theirs\n"
    )
    resolved = resolve_text("go/athena_database.go", fields)
    if "testSTSClient" not in resolved or "testAWS" not in resolved:
        raise SystemExit("athena_database.go dropped a test client")
    print("driver conflict resolver self-test ok")


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[1] == "--self-test":
        _self_test()
        return 0
    if len(argv) != 2:
        print(f"usage: {argv[0]} <driver-repo> | --self-test", file=sys.stderr)
        return 2
    try:
        resolve_repo(Path(argv[1]))
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"driver conflict resolver: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
