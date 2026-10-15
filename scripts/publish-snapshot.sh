#!/usr/bin/env bash
# Package the current checkout, encrypt it with age, and publish one
# parentless commit to the destination branch.
set +x
set +o xtrace
set -euo pipefail

status() {
  printf '%s\n' "$1"
}

fail() {
  status "$1"
  exit 1
}

require() {
  if [[ -z "${!1:-}" ]]; then
    fail "status=setup-failed missing=$1"
  fi
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_DIR=${SOURCE_DIR:-$PWD}
SOURCE_SHA=${SOURCE_SHA:-$(git -C "$SOURCE_DIR" rev-parse HEAD)}
DEST_BRANCH=${DEST_BRANCH:-}
AGE_RECIPIENT=${AGE_RECIPIENT:-}
PUBLIC_CI_TEMPLATE=${PUBLIC_CI_TEMPLATE:-}
SOURCE_REF=${SOURCE_REF:-}

require DEST_BRANCH
require AGE_RECIPIENT
require PUBLIC_CI_TEMPLATE

if [[ ! "$AGE_RECIPIENT" =~ ^age1[0-9a-z]+$ ]]; then
  fail "status=setup-failed reason=age-recipient"
fi

if [[ -n "${SNAPSHOT_DEST_URL:-}" ]]; then
  DEST_URL=$SNAPSHOT_DEST_URL
else
  require DEST_REPO
  if [[ "$DEST_REPO" == *"@"* || "$DEST_REPO" == *"://"* || "$DEST_REPO" != */* ]]; then
    fail "status=setup-failed reason=destination-repository"
  fi
  require DEPLOY_KEY
  DEST_URL="git@github.com:${DEST_REPO}.git"
fi

WRAPPER="${SCRIPT_DIR}/run-public-ci.sh"
if [[ ! -f "$WRAPPER" ]]; then
  fail "status=setup-failed reason=wrapper"
fi
if ! git -C "$SOURCE_DIR" cat-file -e "${SOURCE_SHA}:${PUBLIC_CI_TEMPLATE}" 2>/dev/null; then
  fail "status=setup-failed reason=template"
fi
if ! command -v age >/dev/null 2>&1; then
  fail "status=setup-failed reason=age-missing"
fi

# Official github.com host keys from:
# https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
# Fingerprints are checked before any connection. ssh-keyscan is not used.
install_github_ssh() {
  local ssh_dir known
  ssh_dir=$(mktemp -d)
  chmod 700 "$ssh_dir"
  printf '%s\n' "$DEPLOY_KEY" >"${ssh_dir}/id"
  chmod 600 "${ssh_dir}/id"
  known="${ssh_dir}/known_hosts"
  cat >"$known" <<'EOF'
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
EOF
  chmod 644 "$known"
  local fingerprints
  fingerprints=$(ssh-keygen -lf "$known")
  local expected
  for expected in \
    'SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU' \
    'SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM' \
    'SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s'
  do
    if [[ "$fingerprints" != *"$expected"* ]]; then
      fail "status=setup-failed reason=host-key-fingerprint"
    fi
  done
  # CheckHostIP is off because github.com serves many addresses; the pinned
  # hostname keys above are what we trust.
  export GIT_SSH_COMMAND="ssh -i ${ssh_dir}/id -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${known} -o CheckHostIP=no"
  export SNAPSHOT_SSH_DIR="$ssh_dir"
}

if [[ -z "${SNAPSHOT_DEST_URL:-}" ]]; then
  install_github_ssh
fi

work_root=${SNAPSHOT_WORK_ROOT:-$(mktemp -d)}
mkdir -p "$work_root"
archive="${work_root}/source.tar.gz"
encrypted="${work_root}/snapshot.tar.gz.age"
publish="${work_root}/publish"

cleanup() {
  rm -f "$archive"
  if [[ -n "${SNAPSHOT_SSH_DIR:-}" ]]; then
    rm -rf "$SNAPSHOT_SSH_DIR"
  fi
  if [[ -z "${SNAPSHOT_WORK_ROOT:-}" ]]; then
    rm -rf "$work_root"
  fi
}
trap cleanup EXIT

git -C "$SOURCE_DIR" archive --format=tar.gz --output="$archive" "$SOURCE_SHA"
age -r "$AGE_RECIPIENT" -o "$encrypted" "$archive"
rm -f "$archive"

checksum=$(sha256sum "$encrypted" | awk '{print $1}')
rm -rf "$publish"
mkdir -p "$publish/.github/workflows" "$publish/scripts"
cp "$encrypted" "$publish/snapshot.tar.gz.age"
cp "$WRAPPER" "$publish/scripts/run-public-ci.sh"
chmod 755 "$publish/scripts/run-public-ci.sh"
git -C "$SOURCE_DIR" show "${SOURCE_SHA}:${PUBLIC_CI_TEMPLATE}" \
  >"$publish/.github/workflows/$(basename "$PUBLIC_CI_TEMPLATE")"
python3 - "$SOURCE_SHA" "$checksum" "$publish/manifest.json" <<'PY'
import json
import sys

path = sys.argv[3]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(
        {"source_commit": sys.argv[1], "payload_sha256": sys.argv[2]},
        fh,
        indent=2,
    )
    fh.write("\n")
PY

git -C "$publish" init -q -b publish
git -C "$publish" add --all
git -C "$publish" -c user.name="snapshot publisher" -c user.email="snapshot-publisher@localhost" \
  commit -q -m "encrypted snapshot"

# The private source may have moved while this job was packaging.
# Skip when this commit is no longer the branch head.
if [[ "$SOURCE_REF" == refs/heads/* ]]; then
  remote_url=$(git -C "$SOURCE_DIR" remote get-url origin)
  ls_args=()
  if [[ "$remote_url" == https://* ]]; then
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
      fail "status=source-head-unknown"
    fi
    ls_args=(-c "http.https://github.com/.extraheader=AUTHORIZATION: bearer ${GITHUB_TOKEN}")
  fi
  current=$(git -C "$SOURCE_DIR" "${ls_args[@]}" ls-remote origin "$SOURCE_REF" | awk 'NR==1 {print $1}')
  if [[ -z "$current" ]]; then
    fail "status=source-head-unknown"
  fi
  if [[ "$current" != "$SOURCE_SHA" ]]; then
    status "status=skipped-superseded"
    exit 0
  fi
fi

observed=$(git ls-remote "$DEST_URL" "refs/heads/${DEST_BRANCH}" | awk 'NR==1 {print $1}')

if [[ -n "${SNAPSHOT_BEFORE_PUSH:-}" ]]; then
  bash -c "$SNAPSHOT_BEFORE_PUSH"
fi

push_args=(-c credential.helper=)
if [[ -z "$observed" ]]; then
  git -C "$publish" "${push_args[@]}" push "$DEST_URL" "HEAD:refs/heads/${DEST_BRANCH}"
else
  git -C "$publish" "${push_args[@]}" push \
    --force-with-lease="refs/heads/${DEST_BRANCH}:${observed}" \
    "$DEST_URL" "HEAD:refs/heads/${DEST_BRANCH}"
fi

status "status=published"
status "source_commit=${SOURCE_SHA}"
