#!/usr/bin/env bash
# Decrypt the published snapshot in a temp directory and run ci/run.sh.
# Stdout and stderr from those steps stay in temp files. This script prints
# only fixed status lines and exits with the CI command's status.
set +x
set +o xtrace
set -u

status() {
  printf '%s\n' "$1"
}

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

WORK=$(mktemp -d)
OUT="${WORK}/stdout.txt"
ERR="${WORK}/stderr.txt"
KEY="${WORK}/age.key"
ARCHIVE="${WORK}/snapshot.tar.gz"
EXTRACT="${WORK}/src"
trap 'rm -rf "$WORK"' EXIT

if [[ -z "${AGE_PRIVATE_KEY:-}" || ! -f "${ROOT}/snapshot.tar.gz.age" ]]; then
  status "status=setup-failed"
  exit 1
fi

umask 077
printf '%s\n' "$AGE_PRIVATE_KEY" >"$KEY"
mkdir -p "$EXTRACT"

if ! age --decrypt -i "$KEY" -o "$ARCHIVE" "${ROOT}/snapshot.tar.gz.age" >"$OUT" 2>"$ERR"; then
  status "status=decrypt-failed"
  exit 1
fi

if ! tar -xzf "$ARCHIVE" -C "$EXTRACT" >"$OUT" 2>"$ERR"; then
  status "status=extract-failed"
  exit 1
fi

if [[ ! -f "${EXTRACT}/ci/run.sh" ]]; then
  status "status=setup-failed"
  exit 1
fi

set +e
bash "${EXTRACT}/ci/run.sh" >"$OUT" 2>"$ERR"
code=$?
set -e

if [[ "$code" -eq 0 ]]; then
  status "status=ci-passed"
else
  status "status=ci-failed"
fi
exit "$code"
