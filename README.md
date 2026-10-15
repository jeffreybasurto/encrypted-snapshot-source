# Encrypted snapshot publisher

A source repository calls one reusable workflow to archive itself at the triggering commit, encrypt that archive with [age](https://github.com/FiloSottile/age), and publish a single parentless commit to a destination branch. The destination is not a plaintext checkout. Its CI decrypts the snapshot into a temporary directory and runs `ci/run.sh` there.

The private repository keeps its normal Git history. Only the destination branch is replaced on each publish.

## What gets published

The destination branch has exactly one reachable commit, with no parent. That commit contains:

- `snapshot.tar.gz.age` — encrypted `git archive` of the source commit
- `manifest.json` — `source_commit` (the source SHA) and `payload_sha256` (SHA-256 of the encrypted file). The private repository URL and name are not included.
- `.github/workflows/` — the public CI workflow, copied from the source template path
- `scripts/run-public-ci.sh` — the wrapper that decrypts and runs CI

`git archive` does not include `.git`. Submodules and Git LFS are not handled.

Replacing the branch does not make GitHub delete unreachable objects or old workflow references immediately. This does not promise constant storage or an instant purge.

## Caller

`.github/workflows/caller.yml` runs on a push to `main` and calls the reusable workflow. Another repository uses the same workflow without copying it:

```yaml
jobs:
  publish:
    uses: OWNER/THIS_REPO/.github/workflows/publish-encrypted-snapshot.yml@REF
    with:
      destination_repository: OWNER/DESTINATION_REPO
      destination_branch: snapshot
      age_recipient: age1...
      public_ci_template: templates/public-ci.yml
    secrets:
      destination_deploy_key: ${{ secrets.DEST_DEPLOY_KEY }}
```

`REF` is a commit SHA, tag, or branch. Do not use `secrets: inherit`. Pass the deploy key explicitly. The template's `push` branch must be the same name as `destination_branch` (`snapshot` in the template shipped here).

| Input | Meaning |
| --- | --- |
| `destination_repository` | `owner/name` of the public destination |
| `destination_branch` | Branch that is replaced with one new root commit |
| `age_recipient` | age public key (`age1...`) |
| `public_ci_template` | Path in the source repo, for example `templates/public-ci.yml` |

| Secret | Where it lives |
| --- | --- |
| `DEST_DEPLOY_KEY` | Private source repo. OpenSSH private key passed as `destination_deploy_key`. |
| `AGE_PRIVATE_KEY` | Destination repo. age identity used only by the public CI job. |

The publisher job checks out the caller at the triggering commit with `persist-credentials: false`. It loads `scripts/publish-snapshot.sh` from the called workflow repository by parsing `job.workflow_ref` (the called workflow, not a hardcoded name). Immediately before push it checks that this commit is still the source branch head and skips superseded commits. The push is `git push --force-with-lease` against the destination head it just observed. If that branch does not exist yet, the push creates it. Publishes to the same destination repo and branch are serialized (`cancel-in-progress: false`).

## Keys

age, from the destination side or any trusted machine:

```sh
age-keygen -o age-identity.txt
age-keygen -y age-identity.txt
```

The public line (`age1...`) is the caller input `age_recipient`. The identity file is the destination Actions secret `AGE_PRIVATE_KEY`. The publish job never has the private key and never decrypts.

Deploy key, write-enabled, added only to the destination repository:

```sh
ssh-keygen -t ed25519 -f deploy-key -N ""
```

Add `deploy-key.pub` to the destination repository as a deploy key with write access. Store the private key `deploy-key` as the source secret `DEST_DEPLOY_KEY`. The publisher uses it only as an SSH identity for `git@github.com:owner/name.git`. The key is not embedded in a Git URL.

GitHub SSH host keys are pinned in `scripts/publish-snapshot.sh` to the fingerprints published in [GitHub's SSH key fingerprints](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints). The script checks those fingerprints before connecting and does not use `ssh-keyscan`.

age itself is installed from Ubuntu `apt` (`age` 1.1.1 on GitHub-hosted Ubuntu 24.04). No third-party age binary is downloaded.

## Project CI

Keep the build and tests in the source repository's `ci/run.sh`. The fixture here succeeds only when `fixture/confidential.txt` contains its fixture token, and prints `status=fixture-ok`. A `fixture/FAIL` file makes that script exit non-zero with `status=fixture-failed`. Neither path prints the file.

The public workflow checks out the snapshot read-only (`contents: read`, `persist-credentials: false`), then `scripts/run-public-ci.sh` decrypts into a temp directory and runs `ci/run.sh`. The wrapper keeps stdout and stderr of decrypt, extract, and CI in temp files, prints only `status=...` lines, and exits with the CI status. Setup failures do not print those captured streams. The job has no cache, artifact upload, release, or job summary. Its only secret is `AGE_PRIVATE_KEY`.

Point the caller at the destination repository, the age public key, and the template path. That is the adaptation a second project needs.

## Local harness

`scripts/acceptance.sh` uses local bare repositories. It checks:

- archive, encrypt, parentless commit, decrypt, and fixture CI pass
- the manifest records that source commit and the encrypted payload checksum
- a deliberate fixture failure is non-zero and the captured status has no fixture secret
- a missing or wrong age key fails with no plaintext and no key material
- two publishes leave one reachable destination commit
- an older source commit is skipped after a newer commit is the branch head
- `git push --force-with-lease` fails when the observed destination head moves
- published files, the encrypted payload, and the publish directory do not contain the fixture plaintext

```sh
sudo apt-get install age
bash scripts/acceptance.sh
```

GitHub Actions runs the same script from `.github/workflows/acceptance.yml`.

The harness does not prove that a deploy key push triggers the destination workflow. That needs a private source repository and a public destination repository: the source secret `DEST_DEPLOY_KEY`, the destination secret `AGE_PRIVATE_KEY`, and the caller inputs filled in.
