#!/usr/bin/env bash
# relay-git.sh — every git operation relay performs on the user's repository.
#
# Two jobs, both security-critical:
#
#   1. NEVER `git add -A`. Relay never pushes, but the user does — a week
#      later, without re-reading the diff. A token the agent wrote into a
#      fixture while debugging an auth failure would be in history by then.
#      (This is not hypothetical: during relay's own construction a broad
#      `git add -A` swept a subagent's half-written files into a commit.)
#
#   2. Neutralise repository-controlled git execution. A delivered .git/config
#      or an archive-shipped .git/hooks turns any `git commit` into arbitrary
#      code execution. core.fsmonitor is the sharp one: it runs on EVERY git
#      invocation, not just commit.
#
# bash 3.2 compatible. No `set -e` — predicates here return non-zero as an
# answer.

set -u
set -o pipefail
umask 077
LC_ALL=C
IFS=$' \t\n'

# ---------------------------------------------------------------------------
# relay_git — the ONLY way relay may invoke git.
#
# Repo-controlled execution vectors closed here:
#   core.hooksPath   -> an empty dir, so .git/hooks and any configured hooks
#                       path are both inert
#   core.fsmonitor   -> false; a delivered .git/config can otherwise run a
#                       command on every single git call
#   protocol.ext     -> never; `ext::sh -c payload` in a URL is direct RCE
#   protocol.file    -> never
#   commit.gpgsign   -> false; signing can block on a passphrase prompt in an
#                       unattended run
#   core.pager       -> cat, core.editor -> true; never block on a pager or an
#                       editor with no terminal attached
# GIT_* environment variables are unset by relay_git_sanitize_env before any
# call: GIT_SSH_COMMAND, GIT_EXTERNAL_DIFF, GIT_PROXY_COMMAND and friends are
# all command-execution vectors, and .envrc/direnv or the agent itself can set
# them.
# ---------------------------------------------------------------------------
RELAY_GIT_EMPTY_HOOKS="${TMPDIR:-/tmp}/relay-empty-hooks"

relay_git() {
  mkdir -p "$RELAY_GIT_EMPTY_HOOKS" 2>/dev/null
  command git \
    -c "core.hooksPath=$RELAY_GIT_EMPTY_HOOKS" \
    -c core.fsmonitor=false \
    -c protocol.ext.allow=never \
    -c protocol.file.allow=never \
    -c commit.gpgsign=false \
    -c core.pager=cat \
    -c core.editor=true \
    -c advice.detachedHead=false \
    "$@"
}

relay_git_sanitize_env() {
  # Unset by prefix rather than by allowlist: the GIT_* surface is large and
  # grows between git releases, so enumerate what is actually set.
  for _v in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do
    case "$_v" in
      GIT_AUTHOR_NAME|GIT_AUTHOR_EMAIL|GIT_COMMITTER_NAME|GIT_COMMITTER_EMAIL) ;;
      *) unset "$_v" 2>/dev/null ;;
    esac
  done
  return 0
}

# ---------------------------------------------------------------------------
# Paths relay refuses to stage, ever. Matched against the repo-relative path.
#
# This is the SECOND filter, not the first. `git ls-files -o --exclude-standard`
# has already dropped anything the user's .gitignore or global excludesFile
# covers, and many developers globally ignore .env / *.pem / *.key — so those
# frequently never reach this function at all. Relay does not rely on that:
# gitignore is the user's policy and can be edited by the agent, negated by a
# repo-supplied pattern, or bypassed with `git add -f`. This list is relay's
# own, and it is enforced on every path that does reach it.
#
# NOTE on hooks: relay_git overrides core.hooksPath, so a user's *global* hooks
# (e.g. a commit-message linter installed at ~/.config/git/hooks) do not run on
# relay's commits either. That is deliberate — an unattended run must not block
# on an interactive or opinionated hook — but it means relay's commit messages
# are not subject to the user's usual local checks.
# ---------------------------------------------------------------------------
relay_git_path_is_forbidden() {
  case "$1" in
    .env|.env.*|*/.env|*/.env.*) return 0 ;;
    *.pem|*.key|*.p12|*.pfx|*.keystore|*.jks) return 0 ;;
    id_rsa|id_rsa.*|*/id_rsa|*/id_rsa.*) return 0 ;;
    id_ed25519|id_ed25519.*|*/id_ed25519|*/id_ed25519.*) return 0 ;;
    id_dsa|id_ecdsa|*/id_dsa|*/id_ecdsa) return 0 ;;
    .npmrc|*/.npmrc|.netrc|*/.netrc|.pypirc|*/.pypirc) return 0 ;;
    credentials|credentials.*|*/credentials|*/credentials.*) return 0 ;;
    .aws/*|*/.aws/*|.ssh/*|*/.ssh/*|.gnupg/*|*/.gnupg/*) return 0 ;;
    *.kdbx|*service-account*.json|*serviceaccount*.json) return 0 ;;
    .claude/settings.local.json|*/.claude/settings.local.json) return 0 ;;
  esac
  return 1
}

# High-confidence credential patterns. Deliberately NOT a broad-entropy net:
# a false positive halts an overnight run, so each pattern here is one that
# essentially cannot appear by accident.
relay_git_secret_patterns() {
  cat <<'EOF'
sk-ant-[A-Za-z0-9_-]{20,}
sk-[A-Za-z0-9]{32,}
(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}
github_pat_[A-Za-z0-9_]{22,}
A(KIA|SIA)[0-9A-Z]{16}
-----BEGIN [A-Z ]*PRIVATE KEY-----
xox[baprs]-[A-Za-z0-9-]{10,}
AIza[0-9A-Za-z_-]{35}
glpat-[A-Za-z0-9_-]{20}
postgres(ql)?://[^:@/[:space:]]+:[^@/[:space:]]+@
mysql://[^:@/[:space:]]+:[^@/[:space:]]+@
mongodb(\+srv)?://[^:@/[:space:]]+:[^@/[:space:]]+@
EOF
}

# ---------------------------------------------------------------------------
# relay_git_scan_text <file> -> 0 if clean, 1 if a secret was found
# Prints "pattern<TAB>file:line" for each hit. Used both before relay writes
# its own files and against the staged diff.
# ---------------------------------------------------------------------------
relay_git_scan_text() {
  _target="${1:?file required}"
  [ -f "$_target" ] || return 0
  _found=1
  while IFS= read -r _pat; do
    [ -n "$_pat" ] || continue
    _hits=$(grep -nEo -- "$_pat" "$_target" 2>/dev/null | head -3)
    if [ -n "$_hits" ]; then
      _found=0
      # Print the pattern and location, never the matched secret itself.
      printf '%s\n' "$_hits" | while IFS= read -r _h; do
        printf '%s\t%s:%s\n' "$_pat" "$_target" "${_h%%:*}"
      done
    fi
  done <<EOF
$(relay_git_secret_patterns)
EOF
  [ "$_found" -eq 0 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
# relay_git_collect_paths <repo>
# Emit, NUL-separated, the repo-relative paths relay is willing to stage:
# modified/deleted tracked files plus untracked non-ignored files, minus
# anything forbidden, minus anything whose realpath escapes the repo, minus
# symlinks pointing outside the repo.
#
# Rejected paths are reported on stderr as "SKIP <reason> <path>".
# ---------------------------------------------------------------------------
relay_git_collect_paths() {
  _repo="${1:?repo required}"
  _root=$(cd "$_repo" 2>/dev/null && relay_git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$_root" ] || return 1

  {
    ( cd "$_root" && relay_git diff --name-only -z --diff-filter=ACMRTD )
    ( cd "$_root" && relay_git ls-files -o --exclude-standard -z )
  } | (
    cd "$_root" || exit 1
    while IFS= read -r -d '' _p; do
      [ -n "$_p" ] || continue

      if relay_git_path_is_forbidden "$_p"; then
        printf 'SKIP forbidden-name %s\n' "$_p" >&2
        continue
      fi

      # A symlink is only safe if it resolves inside the repo. `ln -s ~/.ssh
      # secrets` would otherwise make host keys look repo-local.
      if [ -L "$_p" ]; then
        _dest=$( cd "$(dirname "$_p")" 2>/dev/null && cd "$(readlink "$_p")" 2>/dev/null && pwd )
        case "$_dest" in
          "$_root"|"$_root"/*) : ;;
          *) printf 'SKIP symlink-escapes-repo %s\n' "$_p" >&2; continue ;;
        esac
      fi

      printf '%s\0' "$_p"
    done
  )
}

# ---------------------------------------------------------------------------
# relay_git_commit <repo> <message> [state_dir]
#
# Returns:
#   0  committed (or nothing to commit)
#   1  refused: a secret was detected in the staged diff. Nothing is committed,
#      the index is reset, and if state_dir is given a BLOCKED.md is written.
#   2  operational failure
#
# On a secret hit relay deliberately does NOT auto-redact and commit: that
# silently mutates the user's source and leaves the plaintext in the working
# tree regardless. Halting and telling a human is the honest outcome.
# ---------------------------------------------------------------------------
relay_git_commit() {
  _repo="${1:?repo required}"
  _msg="${2:?message required}"
  _state="${3:-}"

  relay_git_sanitize_env

  _root=$(cd "$_repo" 2>/dev/null && relay_git rev-parse --show-toplevel 2>/dev/null) || return 2
  cd "$_root" || return 2

  # Refuse to operate on a conflicted tree; never attempt automatic resolution.
  if [ -n "$(relay_git ls-files -u 2>/dev/null)" ]; then
    printf 'relay-git: unmerged paths present; refusing to commit\n' >&2
    return 2
  fi

  _staged=0
  _tmplist="${TMPDIR:-/tmp}/relay-stage.$$"
  relay_git_collect_paths "$_root" > "$_tmplist" 2>"$_tmplist.skip"
  if [ -s "$_tmplist.skip" ]; then
    cat "$_tmplist.skip" >&2
  fi

  if [ -s "$_tmplist" ]; then
    # Explicit pathspec from stdin. Never `git add -A`, never `git add .`.
    if relay_git add --pathspec-from-file="$_tmplist" --pathspec-file-nul 2>/dev/null; then
      _staged=1
    else
      printf 'relay-git: staging failed\n' >&2
      rm -f "$_tmplist" "$_tmplist.skip"
      return 2
    fi
  fi
  rm -f "$_tmplist" "$_tmplist.skip"

  if [ "$_staged" -eq 0 ] || relay_git diff --cached --quiet 2>/dev/null; then
    return 0   # nothing to commit
  fi

  # Scan what is actually about to enter history.
  _diff="${TMPDIR:-/tmp}/relay-staged.$$"
  relay_git diff --cached > "$_diff" 2>/dev/null
  _report=$(relay_git_scan_text "$_diff")
  _scan_rc=$?
  rm -f "$_diff"

  if [ "$_scan_rc" -ne 0 ]; then
    relay_git reset -q 2>/dev/null
    printf 'relay-git: SECRET DETECTED in staged changes; nothing committed\n' >&2
    printf '%s\n' "$_report" >&2
    if [ -n "$_state" ] && [ -d "$_state" ]; then
      {
        printf '# BLOCKED — possible credential in staged changes\n\n'
        printf 'Relay halted before committing. A high-confidence credential\n'
        printf 'pattern was found in the staged diff.\n\n'
        printf '## What matched (locations only, values withheld)\n\n'
        printf '%s\n' "$_report"
        printf '\n## What to do\n\n'
        printf '1. Inspect the files above and remove the credential.\n'
        printf '2. If it is a false positive, re-run with the path added to\n'
        printf '   the run configuration exclusions.\n'
        printf '3. Then: relay resume\n\n'
        printf 'Nothing was committed. The working tree is untouched.\n'
        printf '\n<!-- relay:sealed -->\n'
      } > "$_state/BLOCKED.md" 2>/dev/null
    fi
    return 1
  fi

  # --no-verify because repo pre-commit hooks may be slow, interactive, or
  # hostile; core.hooksPath already neutralises them, this is belt and braces.
  if relay_git commit --no-verify -q -m "$_msg" 2>/dev/null; then
    return 0
  fi
  printf 'relay-git: commit failed\n' >&2
  return 2
}

# ---------------------------------------------------------------------------
# relay_git_preflight <repo>
# Report repository-controlled execution vectors. Non-zero if any found; the
# caller decides whether to refuse or require an acknowledgement.
# ---------------------------------------------------------------------------
relay_git_preflight() {
  _repo="${1:?repo required}"
  _root=$(cd "$_repo" 2>/dev/null && relay_git rev-parse --show-toplevel 2>/dev/null) || {
    printf 'relay-git: not a git repository: %s\n' "$_repo" >&2; return 1; }
  cd "$_root" || return 1
  _bad=0

  # .git/hooks is not carried by `git clone`, but IS carried by a tarball or
  # zip download — a normal way to obtain a project.
  if [ -d "$_root/.git/hooks" ]; then
    for _h in "$_root"/.git/hooks/*; do
      case "$_h" in *.sample) continue ;; esac
      if [ -f "$_h" ] && [ -x "$_h" ]; then
        printf 'relay-git: executable repo hook present: %s\n' "$_h" >&2
        _bad=1
      fi
    done
  fi

  for _k in core.hooksPath core.fsmonitor; do
    _v=$(relay_git config --local --get "$_k" 2>/dev/null)
    if [ -n "$_v" ]; then
      printf 'relay-git: repo sets %s=%s (executes on git operations)\n' "$_k" "$_v" >&2
      _bad=1
    fi
  done

  if relay_git config --local --name-only --get-regexp '^filter\..*\.(clean|smudge)$' >/dev/null 2>&1; then
    printf 'relay-git: repo configures filter.*.clean/smudge (runs on checkout/commit)\n' >&2
    _bad=1
  fi

  if [ -f "$_root/.gitattributes" ] && grep -qE '(^|[[:space:]])(filter|diff)=' "$_root/.gitattributes" 2>/dev/null; then
    printf 'relay-git: .gitattributes declares filter=/diff= drivers\n' >&2
    _bad=1
  fi

  if [ "$(relay_git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "HEAD" ]; then
    printf 'relay-git: HEAD is detached\n' >&2
    _bad=1
  fi

  return "$_bad"
}
