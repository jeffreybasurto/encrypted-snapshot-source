#!/usr/bin/env bash
# Local stand-in for the destination repo. Proves archive, encrypt, orphan
# publish, decrypt, skip, and force-with-lease behavior without GitHub.
set +x
set +o xtrace
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TOKEN='CONFIDENTIAL_FIXTURE_7f3a9c2e'
BRANCH=snapshot
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf '%s\n' "acceptance-failed: $1" >&2
  exit 1
}

assert_absent() {
  local label=$1
  shift
  if grep -a -F -q "$TOKEN" "$@"; then
    fail "${label} contains the fixture secret"
  fi
}

new_source() {
  local dir=$1
  mkdir -p "${dir}/ci" "${dir}/fixture" "${dir}/templates" "${dir}/scripts"
  cp "${ROOT}/ci/run.sh" "${dir}/ci/run.sh"
  cp "${ROOT}/fixture/confidential.txt" "${dir}/fixture/confidential.txt"
  cp "${ROOT}/templates/public-ci.yml" "${dir}/templates/public-ci.yml"
  chmod 755 "${dir}/ci/run.sh"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "fixture"
  git -C "$dir" config user.email "fixture@localhost"
}

commit_all() {
  local dir=$1
  local message=$2
  git -C "$dir" add --all
  git -C "$dir" commit -q -m "$message"
}

publish() {
  local dir=$1
  local sha=$2
  local work=$3
  shift 3
  mkdir -p "$work"
  (
    cd "$dir"
    SOURCE_DIR="$dir" \
      SOURCE_SHA="$sha" \
      SOURCE_REF="refs/heads/main" \
      DEST_BRANCH="$BRANCH" \
      AGE_RECIPIENT="$RECIPIENT" \
      PUBLIC_CI_TEMPLATE="templates/public-ci.yml" \
      SNAPSHOT_DEST_URL="$DEST" \
      SNAPSHOT_WORK_ROOT="$work" \
      "$@" \
      bash "${ROOT}/scripts/publish-snapshot.sh"
  )
}

run_public() {
  local checkout=$1
  local key=$2
  local out=$3
  local err=$4
  set +e
  AGE_PRIVATE_KEY="$key" bash "${checkout}/scripts/run-public-ci.sh" >"$out" 2>"$err"
  local code=$?
  set -e
  printf '%s' "$code"
}

echo "acceptance: prepare repos"
SRC="${TMP}/src"
ORIGIN="${TMP}/origin.git"
DEST="${TMP}/dest.git"
new_source "$SRC"
git init -q --bare "$ORIGIN"
git init -q --bare "$DEST"
git -C "$SRC" remote add origin "$ORIGIN"
commit_all "$SRC" "commit A"
git -C "$SRC" push -q origin main
SHA_A=$(git -C "$SRC" rev-parse HEAD)

KEY_DIR="${TMP}/age"
mkdir -p "$KEY_DIR"
age-keygen -o "${KEY_DIR}/key.txt" >/dev/null 2>&1
RECIPIENT=$(age-keygen -y "${KEY_DIR}/key.txt")
PRIVATE=$(cat "${KEY_DIR}/key.txt")
age-keygen -o "${KEY_DIR}/wrong.txt" >/dev/null 2>&1
WRONG=$(cat "${KEY_DIR}/wrong.txt")

echo "acceptance: publish A and run public CI"
OUT_A=$(publish "$SRC" "$SHA_A" "${TMP}/work-a")
printf '%s\n' "$OUT_A" | grep -q 'status=published' || fail "publish A did not publish"
grep -q "source_commit=${SHA_A}" <<<"$OUT_A" || fail "publish A did not report its commit"

git clone -q --branch "$BRANCH" "$DEST" "${TMP}/pub-a"
MANIFEST_A=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_commit"])' "${TMP}/pub-a/manifest.json")
[[ "$MANIFEST_A" == "$SHA_A" ]] || fail "manifest is not commit A"
SUM_A=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["payload_sha256"])' "${TMP}/pub-a/manifest.json")
ACTUAL_A=$(sha256sum "${TMP}/pub-a/snapshot.tar.gz.age" | awk '{print $1}')
[[ "$SUM_A" == "$ACTUAL_A" ]] || fail "payload checksum mismatch"

LOG_A="${TMP}/public-a.out"
ERR_A="${TMP}/public-a.err"
CODE_A=$(run_public "${TMP}/pub-a" "$PRIVATE" "$LOG_A" "$ERR_A")
[[ "$CODE_A" == "0" ]] || fail "public CI should pass (exit ${CODE_A})"
grep -q '^status=ci-passed$' "$LOG_A" || fail "missing ci-passed status"
assert_absent "public status" "$LOG_A" "$ERR_A"
assert_absent "published tree" "${TMP}/pub-a/manifest.json" "${TMP}/pub-a/.github/workflows/public-ci.yml" "${TMP}/pub-a/scripts/run-public-ci.sh" "${TMP}/pub-a/snapshot.tar.gz.age"
if [[ -e "${TMP}/work-a/source.tar.gz" || -d "${TMP}/work-a/publish/src" || -f "${TMP}/work-a/publish/ci/run.sh" ]]; then
  fail "publish work contained decrypted source"
fi
if grep -a -R -F -q "$TOKEN" "${TMP}/work-a/publish"; then
  fail "publish worktree contains the fixture secret"
fi

echo "acceptance: superseded commit A is skipped once B is head"
echo "second" >"${SRC}/fixture/marker.txt"
commit_all "$SRC" "commit B"
git -C "$SRC" push -q origin main
SHA_B=$(git -C "$SRC" rev-parse HEAD)
OUT_SKIP=$(publish "$SRC" "$SHA_A" "${TMP}/work-skip")
printf '%s\n' "$OUT_SKIP" | grep -q 'status=skipped-superseded' || fail "older commit was not skipped"
MANIFEST_STILL=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_commit"])' "${TMP}/pub-a/manifest.json")
# pub-a is the old clone; re-read the bare repo
git --git-dir="$DEST" show "refs/heads/${BRANCH}:manifest.json" >"${TMP}/manifest-after-skip.json"
MANIFEST_STILL=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_commit"])' "${TMP}/manifest-after-skip.json")
[[ "$MANIFEST_STILL" == "$SHA_A" ]] || fail "skipped publish changed the destination"

echo "acceptance: second publish leaves one reachable commit"
OUT_B=$(publish "$SRC" "$SHA_B" "${TMP}/work-b")
printf '%s\n' "$OUT_B" | grep -q 'status=published' || fail "publish B did not publish"
COUNT=$(git --git-dir="$DEST" rev-list --count "refs/heads/${BRANCH}")
[[ "$COUNT" == "1" ]] || fail "destination has ${COUNT} reachable commits"
if git --git-dir="$DEST" rev-parse --verify "refs/heads/${BRANCH}^" >/dev/null 2>&1; then
  fail "destination commit has a parent"
fi
git --git-dir="$DEST" show "refs/heads/${BRANCH}:manifest.json" >"${TMP}/manifest-b.json"
MANIFEST_B=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_commit"])' "${TMP}/manifest-b.json")
[[ "$MANIFEST_B" == "$SHA_B" ]] || fail "final manifest is not commit B"

echo "acceptance: deliberate CI failure stays quiet"
: >"${SRC}/fixture/FAIL"
commit_all "$SRC" "commit C fail"
git -C "$SRC" push -q origin main
SHA_C=$(git -C "$SRC" rev-parse HEAD)
publish "$SRC" "$SHA_C" "${TMP}/work-c" >/dev/null
rm -rf "${TMP}/pub-c"
git clone -q --branch "$BRANCH" "$DEST" "${TMP}/pub-c"
LOG_C="${TMP}/public-c.out"
ERR_C="${TMP}/public-c.err"
CODE_C=$(run_public "${TMP}/pub-c" "$PRIVATE" "$LOG_C" "$ERR_C")
[[ "$CODE_C" != "0" ]] || fail "deliberate failure should be non-zero"
grep -q '^status=ci-failed$' "$LOG_C" || fail "missing ci-failed status"
assert_absent "failure status" "$LOG_C" "$ERR_C"
if grep -q 'fixture-ok' "$LOG_C" "$ERR_C"; then
  fail "failure status leaked fixture output"
fi

echo "acceptance: wrong age key fails closed"
LOG_W="${TMP}/wrong.out"
ERR_W="${TMP}/wrong.err"
CODE_W=$(run_public "${TMP}/pub-c" "$WRONG" "$LOG_W" "$ERR_W")
[[ "$CODE_W" != "0" ]] || fail "wrong key should fail"
grep -q '^status=decrypt-failed$' "$LOG_W" || fail "missing decrypt-failed status"
assert_absent "wrong-key status" "$LOG_W" "$ERR_W"
if grep -q 'AGE-SECRET-KEY' "$LOG_W" "$ERR_W"; then
  fail "wrong-key status leaked key material"
fi

echo "acceptance: missing age key fails closed"
LOG_M="${TMP}/missing.out"
ERR_M="${TMP}/missing.err"
CODE_M=$(run_public "${TMP}/pub-c" "" "$LOG_M" "$ERR_M")
[[ "$CODE_M" != "0" ]] || fail "missing key should fail"
grep -q '^status=setup-failed$' "$LOG_M" || fail "missing key should be setup-failed"
assert_absent "missing-key status" "$LOG_M" "$ERR_M"

echo "acceptance: stale destination head is rejected"
BEFORE=$(git --git-dir="$DEST" rev-parse "refs/heads/${BRANCH}")
export DEST_BARE="$DEST"
export BEFORE
set +e
STALE_OUT=$(
  SNAPSHOT_BEFORE_PUSH='new=$(git --git-dir="$DEST_BARE" commit-tree "${BEFORE}^{tree}" -m decoy) && git --git-dir="$DEST_BARE" update-ref refs/heads/snapshot "$new"' \
    publish "$SRC" "$SHA_C" "${TMP}/work-stale"
)
STALE_CODE=$?
set -e
[[ "$STALE_CODE" != "0" ]] || fail "stale force-with-lease should fail"
AFTER=$(git --git-dir="$DEST" rev-parse "refs/heads/${BRANCH}")
[[ "$AFTER" != "$BEFORE" ]] || fail "stale test did not move the destination first"
git --git-dir="$DEST" cat-file -p "$AFTER" | grep -q 'decoy' || fail "destination head is not the stale-test decoy"
if printf '%s\n' "$STALE_OUT" | grep -q 'status=published'; then
  fail "stale push reported published"
fi

if grep -n -E 'age[[:space:]]+(-d|--decrypt)' "${ROOT}/scripts/publish-snapshot.sh" >/dev/null; then
  fail "publisher script decrypts"
fi

echo "acceptance: passed"
