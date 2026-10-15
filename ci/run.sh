#!/usr/bin/env bash
# Fixture CI entry point. Prints a fixed status line and never the fixture source.
set +x
set +o xtrace
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
secret_file="${root}/fixture/confidential.txt"
token='CONFIDENTIAL_FIXTURE_7f3a9c2e'

if [[ -f "${root}/fixture/FAIL" ]]; then
  printf '%s\n' "status=fixture-failed"
  exit 1
fi

if [[ ! -f "$secret_file" ]] || ! grep -q -F "$token" "$secret_file"; then
  printf '%s\n' "status=fixture-missing"
  exit 1
fi

printf '%s\n' "status=fixture-ok"
