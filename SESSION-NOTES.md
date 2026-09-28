# Session notes — 2026-09-28

Local record only. Nothing here is pushed. This file is a working note for the
next session; it is not part of the published documentation and is not covered
by the CI guard suite.

## What was done

Made the repository copy-paste runnable for a non-root user, and guarded that
fix so it cannot silently regress.

The stack had been certified entirely as uid 0, so three root-owned path
defaults were never exercised:

| Variable | Default | Root-only? |
|---|---|---|
| `KEYCLOAK_HOME` | `/opt/keycloak` | yes |
| `GRADLE_USER_HOME` | `/root/.cache/davinci-mock/gradle` | yes |
| `VSAC_CACHE_DIR` | `/root/.cache/davinci-mock/vsac-cache` | yes |

`provision.sh` does a bare `mkdir`/`mv` with no privilege handling, so a
normal user following the docs would die at the Keycloak step with a bare
`Permission denied`, then again on the Gradle cache. The documentation had
described the box it was written on, not the box a reader is on.

### Files changed
- `README.md` — non-root step 1b; disk ~2.5 GB → ~3 GB; Playwright install
  added to Quick start; three-path table with defaults and rationale.
- `AGENTS.md` — `id -u` host check; same override block; note that Keycloak
  lives outside the project folder.
- `TEST-FLOW.md` — new non-root prerequisite; disk to ~3 GB; two
  troubleshooting rows for permission denials.
- `CONTRIBUTING.md` — step count 13 → 14; explains the `!!` delete marker.
- `GIT-PLAN.md` — two pre-existing dead anchors fixed.
- `.github/workflows/ci.yml` — new guard: "The non-root install paths are
  documented". It greps the README for the three `export` lines and names
  whichever one is missing. Success is tested by the emptiness of `$missing`,
  not an exit code, so a grep that cannot read the tree fails rather than
  passing — the same bug that made five earlier guards vacuous.
- `bin/ci-selftest.sh` — snapshot/restore instead of `git checkout --`;
  `!!` delete-marker support; case 13 for the new guard.

### Validation (all run, all green)
- `bin/ci-local.sh`: 14/14
- `bin/ci-selftest.sh`: 11/11, scratch tree restored to baseline
- All six services 200: keycloak 8180, test-ehr 8080, crd 8090, pas 9015,
  dtr 3005, crg 3001
- All Markdown cross-references resolve

## The mistake worth remembering

I committed with `user.email=sardar@aidentech.com` from `~/.gitconfig`. That
is exactly the address `scan-allow.txt` documents as *deliberately removed*
when this repository went public — all twelve earlier commits are authored
`Abaabeel@users.noreply.github.com` for that reason, to preserve attribution
without exposing a live work mailbox.

CI caught it. The guard `No fingerprints anywhere in history` fired on the
**author line** of the new commit, because `git log --all -p` prints
`Author: …` and the guard's bracket trick only protects the pattern's own
source line from matching itself.

The exposure was one line: author + committer of the tip commit `0aae7b4`. No
file content anywhere. The commit was already public on GitHub by the time CI
reported it.

Resolution: amended the commit to `Abaabeel@users.noreply.github.com` (tree
byte-identical, verified 14/14) and force-pushed after explicit approval. The
old object `0aae7b4` is not reachable from `master` or any ref, but it still
exists on GitHub's servers and anyone who recorded the SHA may be able to
fetch it for an indeterminate time. **Force-push is not erasure.** This is the
same warning `scan-allow.txt` already carries.

### Two lessons from the force-push
1. `git update-ref refs/remotes/origin/master` — which I used to *simulate*
   the post-push state — broke `--force-with-lease` immediately afterwards,
   because the lease compares against the tracking ref, not the remote. Use
   `--force-with-lease=master:<expected-sha>` when the tracking ref has been
   moved locally, or do not move it.
2. `git -c user.email=… commit --amend` does not work: git parses `-c` as
   taking a commit-ish. Set `GIT_COMMITTER_NAME`/`GIT_COMMITTER_EMAIL` in the
   environment for the amend.

## Public state at the end
- Repository: https://github.com/Abaabeel/davinci-mock
- Branch `master`, tip `e0d7f52`
- CI: completed success on `e0d7f52`
- No run tag published

## Open, deliberately

- **Non-root cold boot is unverified.** The path overrides were derived by
  reading `bin/env.sh`, not by a full fresh provision as a normal user. A real
  clean-room run as non-root would take roughly 20–40 minutes and is the only
  way to turn this from a documented fix into a proven one.
- **The OpenEMR / HIMS integration is a conversation TODO only.** It is
  deliberately absent from every tracked file. If it is ever revived: OpenEMR
  rather than ERPNext, a bridge feeding test-ehr, browser E2E, and the DTR
  issuer is `http://localhost:8080/test-ehr/r4` (not `/fhir`).

## Standing instruction for this session

Save and document locally only. **No further git pushes.** Any future commit
stays local until explicitly told otherwise.
