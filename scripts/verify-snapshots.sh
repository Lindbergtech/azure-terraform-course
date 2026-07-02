#!/usr/bin/env bash
#
# verify-snapshots.sh — statically validate every checkpoint snapshot.
#
# Each `solutions/<module>-end/` folder is a self-contained end-state of the
# course Terraform that a student copies into their `infra/` to skip ahead or
# recover. A snapshot that doesn't fmt/init/validate is a broken checkpoint, so
# this lint runs the three offline Terraform gates against each one.
#
#   terraform fmt -check -recursive   formatting is canonical
#   terraform init -backend=false     providers resolve without touching a backend
#   terraform validate                config is internally consistent
#
# Real-Azure apply/destroy is out of scope here — that's covered against infra/.
#
# Failures aggregate: every snapshot is checked even after one fails, and the
# script exits non-zero if any did. The `for dir in solutions/*-end/` loop is
# the pattern to copy when, e.g., bumping a provider version across snapshots.
#
# Exit status: 0 if every snapshot passes, 1 if any failed.

set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

shopt -s nullglob
snapshots=(solutions/*-end/)

if [ ${#snapshots[@]} -eq 0 ]; then
  echo "verify-snapshots: no solutions/*-end/ snapshots found — nothing to verify."
  exit 0
fi

failed=()

for dir in "${snapshots[@]}"; do
  dir=${dir%/}
  echo "==> $dir"

  ok=true
  ( cd "$dir" && terraform fmt -check -recursive )           || ok=false
  ( cd "$dir" && terraform init -backend=false -input=false ) || ok=false
  ( cd "$dir" && terraform validate )                        || ok=false

  if $ok; then
    echo "    ok"
  else
    echo "    FAILED"
    failed+=("$dir")
  fi
  echo
done

if [ ${#failed[@]} -ne 0 ]; then
  echo "verify-snapshots: ${#failed[@]} snapshot(s) failed:"
  printf '  - %s\n' "${failed[@]}"
  exit 1
fi

echo "verify-snapshots: all ${#snapshots[@]} snapshot(s) passed."
exit 0
