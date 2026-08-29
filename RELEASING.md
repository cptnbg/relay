# Releasing relay

Follow this in order. Nothing here is optional and nothing here is automated:
relay never releases itself, and no script in this repository publishes
anything. A release is a person doing these steps deliberately.

Cut every release from a clean tree on the default branch, with the
second-maintainer rule in `CONTRIBUTING.md` already satisfied for every commit
in it.

## 1. Decide the version

SemVer, with the one addition recorded in `CHANGELOG.md:3-5` and
`SECURITY.md:47-48`: a change that relaxes any commitment in `SECURITY.md` is a
MAJOR bump, and it invalidates recorded user consent. That is not a formality,
and it is no longer only a policy: consent is recorded as a hash of the exact
notice text (`consent.notice_hash`), and doctor refuses to run when the
installed notice no longer matches it — so shipping changed terms makes every
existing user's next run stop at preflight until they re-run `/relay-init` and
re-accept. Say that in the release notes when it applies. A user who approved
relay's behaviour once approved the behaviour those commitments describe;
weakening one means the approval no longer covers what they will be running.

## 2. Bump both manifests in lockstep

Two files carry the version and they must agree:

- `plugins/relay/.claude-plugin/plugin.json` — `.version`
- `.claude-plugin/marketplace.json` — `.plugins[0].version`

CI enforces the agreement: the `lint` job's *plugin and marketplace versions
agree* step in `.github/workflows/ci.yml` reads both with `jq` and exits 1 on a
mismatch. The comment above that step names the reason it exists — the two
drifting apart is the usual cause of "I installed it but I'm on an old
version".

The names are part of the contract too, and they are kebab-case:
`.name` in `plugin.json`, `.name` and `.plugins[0].name` in `marketplace.json`
are all `relay`, and `.plugins[0].source` is the relative path
`./plugins/relay`. Renaming the plugin means renaming the directory, and the
manifests, together.

`plugins/relay/config/defaults.json` is validated as JSON by the same CI step
group. If you touched it, it has to parse.

## 3. Update the changelog

`CHANGELOG.md` is Keep-a-Changelog. Move the accumulated `## [Unreleased]`
entries under a `## [x.y.z] - YYYY-MM-DD` heading and leave a fresh empty
`[Unreleased]` above it. If the release includes a `SECURITY.md` relaxation,
say so in the changelog entry in as many words, not only in the version number.

## 4. Validate both manifests

```
claude plugin validate --strict .claude-plugin/marketplace.json
claude plugin validate --strict plugins/relay/.claude-plugin/plugin.json
```

`test/publish-check.sh:67-72` runs both, but it collapses them into a single
pass/fail line, so run them individually here — you want to know *which*
manifest failed.

## 5. Run everything

```
bash test/lib/test-relay-lib.sh
bash test/lib/test-relay-git.sh
bash test/run.sh
bash test/lint/no-bash4.sh
bash test/lint/no-deps.sh
bash test/publish-check.sh
shellcheck -s bash -S warning \
  plugins/relay/scripts/*.sh \
  plugins/relay/scripts/lib/*.sh \
  plugins/relay/hooks/*.sh \
  test/run.sh test/lib/*.sh test/lint/*.sh test/bin/claude
```

`-S warning` is the CI severity; it is taken verbatim from the `shellcheck`
step in `.github/workflows/ci.yml`, and so is that file list. Running
shellcheck at a laxer severity locally and calling it green is how a release
fails in CI after the tag is already signed.

On macOS, also run the suite under the system bash, which is 3.2.57:

```
/bin/bash test/run.sh
```

CI does this on `macos-latest` for a reason — a bash-4ism passes on the Linux
runner and fails on a user's Mac.

Two things about *where* you run this:

- **Run the suites from a normal shell, not from inside a relay session.** They
  pass in both places now, but the environments differ in ways a release should
  not be certified against: `ps` does not work inside relay's sandbox, so the
  lock takes its age-based fallback path (`lock.ps-unusable` in the journal)
  rather than the pid-liveness path a user's machine will take. Certify against
  the environment users have. This bullet exists because that difference once
  hid a real fail-open bug behind a green suite on the host — see
  `docs/portability.md`'s section on `ps`. Never release on a green suite you
  got by re-running one failing case in isolation.
- **The suites make no API calls.** `test/run.sh` puts a mock `claude`
  (`test/bin/claude`) first on `PATH`; the CI step comment says the same. If a
  release run appears on a billing statement, something is wrong and the release
  stops.

If this release ships against a new Claude Code CLI version, the paid probes
under `test/lint/probe0-*.sh` must be re-run first. See `CONTRIBUTING.md`. Every
claim relay makes about CLI behaviour rests on those probes, and a CLI version
they were never run against is an unverified claim.

The same applies to a release that changes what relay sends in `--settings`,
even on an unchanged CLI. `probe0-sandbox.sh` covers the `enforced` payload and
`probe0-sandbox-off.sh` covers the full-trust one; both are claims about how the
CLI reacts to a payload, and neither is established by the mock suite.

## 6. Tag, signed

```
git tag -s vX.Y.Z -m "relay X.Y.Z"
```

An unsigned tag is not a release. The whole point of the signature is that a
user who installs relay can check they got the maintainer's code and not
someone else's, which they do with:

```
git verify-tag vX.Y.Z
```

The fingerprint users should expect `git verify-tag` to report, recorded here
and in `README.md`:

```
9B62 EB00 8531 00CB FA92  AD72 C12C DEF0 D3BF 983C
```

Signing key `C12CDEF0D3BF983C` (ed25519, sign-only, expires 2028-08-17), set as
`user.signingkey` in this repository's config. Keep both copies of the
fingerprint in step: one recorded in a file the other does not match is how a
user ends up comparing against the wrong value. Never tell users to accept "any
valid signature" — a signature they cannot compare to a known fingerprint
proves nothing.

## 7. The archive and its sha256

**Build a zip.** The marketplace schema's `archive` source takes a zip, not a
tarball (see the shape below), so hash the artifact you are actually going to
publish — a sha256 of a `.tar.gz` that nobody downloads pins nothing:

```
git archive --format=zip --prefix=relay-X.Y.Z/ -o relay-X.Y.Z.zip vX.Y.Z
shasum -a 256 relay-X.Y.Z.zip        # macOS, and anywhere BSD-ish
sha256sum relay-X.Y.Z.zip            # GNU coreutils
```

Publish that sha256 next to the archive. Both hashing commands are fine *here*:
`test/lint/no-deps.sh:30` forbids `sha256sum` in relay's shipped shell, because
it does not exist on stock macOS, but that linter scans `plugins/**/*.sh` only
(`test/lint/no-deps.sh:12-14`). A release command typed by a human on a known
machine is not shipped code. Inside relay's own scripts, hashing goes through
`relay_hash()`, which starts at `git hash-object` and falls back to
`shasum -a 256` — see `docs/portability.md`.

**Where the sha256 goes.** A marketplace entry that offers a downloadable
archive must pin that archive by its sha256, never point at a bare GitHub
source that tracks a mutable branch. A branch source changes underneath an
installed user with no version bump, no diff, and no signature — which is the
exact supply-chain property relay exists to avoid, and it is worth strictly more
than the convenience it buys.

Today this does not apply yet: `.claude-plugin/marketplace.json` ships the
plugin from the relative path `./plugins/relay`, because the marketplace and the
plugin live in one repository and there is no separate archive to pin. The rule
above binds the moment that changes.

The key is `sha256`, a sibling of `url` inside the source object. Taken from
the validator's own schema in the Claude Code 2.1.234 binary rather than
guessed, along with its description: *"SHA-256 digest of the archive. When set,
every download is verified against it and the install is refused on mismatch."*
The shape is:

```json
{
  "source": "archive",
  "url": "https://github.com/cptnbg/relay/releases/download/vX.Y.Z/relay-X.Y.Z.zip",
  "sha256": "<64 lowercase hex characters>"
}
```

Three things the schema says that a release must respect:

- The archive is a **zip**, and the plugin root — the directory holding
  `.claude-plugin/` — may sit at the top of it or one directory deep; a single
  wrapping directory is stripped. That is why the recipe above builds
  `--format=zip` with a `--prefix`: the wrapping `relay-X.Y.Z/` directory is
  stripped on install, and the `.claude-plugin/` inside it is found.
- `sha256` is *optional* in the schema and mandatory by relay's own policy. An
  unpinned archive source tracks whatever is at that URL today, which is the
  supply-chain property this section exists to refuse.
- The digest doubles as version identity when neither `plugin.json` nor the
  marketplace entry declares a `version`. Relay declares one in both, so the
  digest is a check and never the identity — but changing only the digest is
  therefore not, on its own, an update signal to an installed client. Bump the
  version.

Re-confirm this against `claude plugin validate --strict` at release time. It
is the authority, and the schema can move between CLI versions — which is
exactly why relay records the CLI version at doctor time.

## 8. relay never auto-updates

No shipped script fetches, installs, or updates anything. The only install path
in this repository is the `/plugin install relay@relay` line a user types
(`README.md:114`), so upgrading is always a deliberate user action.

Say so in release notes, and tell users to read the diff before they take a new
version:

```
git log --oneline vA..vB
git diff vA..vB -- plugins/relay/scripts plugins/relay/hooks
```

Those two directories are everything relay executes. A user who reads only one
diff should read that one.

## 9. Publishing is a human step

relay never pushes — not a branch, not a tag, not a release. Nothing relay
executes has a code path that reaches a remote; commitment 2 in `SECURITY.md` is
that promise and `Bash(git push:*)` is denied in both sandbox modes. The
repository does have an `origin` now (it is published at
`github.com/cptnbg/relay`), which is exactly why the sentence has to be about
relay's behaviour rather than about the absence of a remote: pushing the signed
tag and uploading the archive and its sha256 are done by a person, outside
relay, on purpose.
