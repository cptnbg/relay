#!/usr/bin/env bash
# relay-doctor.sh — the gate. Nothing runs unattended until this passes.
#
# Usage: bash relay-doctor.sh <project-dir> [state-dir] [--allow-dirty] [--quiet]
# Exit:  0 all hard checks passed (warnings may still have printed)
#        78 a hard check failed. Same number as the supervisor's EX_PREFLIGHT
#           (relay-supervisor.sh:77), deliberately: doctor runs as the
#           supervisor's first preflight step, so a doctor failure surfaces to
#           the caller as a preflight failure and nothing else.
#
# Design note: doctor prints remedies, it does not apply them. It never
# modifies anything outside relay's own state directory — a preflight tool that
# silently mutates a user's configuration is worse than one that refuses.

set -u
set -o pipefail
umask 077
LC_ALL=C
IFS=$' \t\n'

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$SELF_DIR/relay-git.sh"
# Function definitions only — sourced so the deny-path checks below derive
# from the REAL lists in relay-settings.sh instead of a copy that drifts.
# shellcheck source=/dev/null
. "$SELF_DIR/relay-settings.sh"

PROJECT="${1:-$PWD}"
STATE="${2:-}"
shift 2 2>/dev/null || shift $#
ALLOW_DIRTY=0
QUIET=0
for _a in "$@"; do
  case "$_a" in
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --quiet) QUIET=1 ;;
  esac
done

HARD_FAIL=0
WARNED=0

say()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
pass() { [ "$QUIET" -eq 1 ] || printf '  ok    %s\n' "$*"; }
warn() { WARNED=1; printf '  warn  %s\n' "$*" >&2; }
fail() { HARD_FAIL=1; printf '  FAIL  %s\n' "$*" >&2; }
fixit(){ printf '        fix: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 1. Toolchain: present, new enough, and NOT resolving inside the project.
#
# ./node_modules/.bin and ./bin land on PATH routinely (npm scripts, direnv).
# The supervisor and hooks run OUTSIDE the sandbox, so a repo shipping
# node_modules/.bin/jq would be executed by relay itself.
# ---------------------------------------------------------------------------
say "toolchain"

_resolve() { command -v "$1" 2>/dev/null; }

_verge() { # _verge <have> <min>  -> 0 if have >= min
  printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -1 | grep -qx -- "$2"
}

PROJECT_REAL=$(cd "$PROJECT" 2>/dev/null && pwd) || PROJECT_REAL="$PROJECT"

check_tool() { # name  min_version  version_command
  _n="$1"; _min="$2"; _vc="$3"
  _p=$(_resolve "$_n")
  if [ -z "$_p" ]; then fail "$_n not found on PATH"; fixit "install $_n"; return 1; fi
  # Resolve one level of symlink without readlink -f (absent on stock macOS).
  _target="$_p"
  if [ -L "$_p" ]; then
    _l=$(readlink "$_p")
    case "$_l" in /*) _target="$_l" ;; *) _target="$(cd "$(dirname "$_p")" && pwd)/$_l" ;; esac
  fi
  case "$_target" in
    "$PROJECT_REAL"/*)
      fail "$_n resolves INSIDE the project tree: $_target"
      fixit "a repository must not supply relay's own tooling; fix PATH"
      return 1 ;;
  esac
  _v=$(eval "$_vc" 2>/dev/null | tr -cd '0-9.\n' | grep -m1 -E '^[0-9]+\.[0-9]+' | head -1)
  if [ -n "$_min" ] && [ -n "$_v" ] && ! _verge "$_v" "$_min"; then
    fail "$_n $_v is older than the required $_min"
    return 1
  fi
  pass "$_n ${_v:-?} ($_target)"
  return 0
}

if [ -z "${BASH_VERSINFO+x}" ] || [ "${BASH_VERSINFO[0]}" -lt 3 ]; then
  fail "bash ${BASH_VERSION:-unknown} is too old (need 3.2+)"
else
  pass "bash $BASH_VERSION"
fi
check_tool git   2.20 'git --version'
check_tool jq    1.6  'jq --version'

# claude gets a timeout: a broken install or a hung auth refresh must not stall
# an unattended run at the starting line.
if _cp=$(_resolve claude); then
  _cv=$( ( claude --version 2>/dev/null & _p=$!; ( sleep 10; kill "$_p" 2>/dev/null ) & _w=$!; \
           wait "$_p" 2>/dev/null; kill "$_w" 2>/dev/null ) | head -1 )
  if [ -z "$_cv" ]; then
    fail "claude --version produced nothing within 10s"
    fixit "check the install and that auth is not blocking"
  else
    pass "claude $_cv"
  fi
else
  fail "claude not found on PATH"
fi

# ---------------------------------------------------------------------------
# 2. Repository state.
# ---------------------------------------------------------------------------
say "plugin root"
# CLAUDE_PLUGIN_ROOT is not guaranteed to exist in the Bash-tool environment,
# so SKILL.md resolves the root itself (see "Resolve the plugin root"). What
# doctor can verify is that whatever root is in play actually IS a relay
# install. An unresolvable root is a hard failure: every command the skill
# issues would either run nothing or run the wrong thing.
_root=$(cd "$SELF_DIR/.." 2>/dev/null && pwd)
if [ -z "$_root" ] || [ ! -f "$_root/scripts/relay-supervisor.sh" ]; then
  fail "plugin root does not contain scripts/relay-supervisor.sh: ${_root:-$SELF_DIR/..}"
  fixit "the relay install is broken; reinstall the relay plugin"
else
  pass "plugin root: $_root"
fi
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ ! -f "${CLAUDE_PLUGIN_ROOT}/scripts/relay-supervisor.sh" ]; then
  fail "CLAUDE_PLUGIN_ROOT is set but is not a relay install: ${CLAUDE_PLUGIN_ROOT}"
  fixit "reinstall the relay plugin, or unset CLAUDE_PLUGIN_ROOT; an unresolved"
  fixit "root makes every scripted relay command fail — invisibly when detached"
fi

say "repository"
if ! ( cd "$PROJECT" 2>/dev/null && relay_git rev-parse --is-inside-work-tree >/dev/null 2>&1 ); then
  fail "not inside a git work tree: $PROJECT"
  fixit "git init, or point relay at a repository"
  fixit "git is relay's only trustworthy progress signal; there is no --no-git mode"
else
  pass "git work tree"
  _branch=$( cd "$PROJECT" && relay_git rev-parse --abbrev-ref HEAD 2>/dev/null )
  if [ "$_branch" = "HEAD" ]; then
    fail "HEAD is detached"
    fixit "git switch -c relay/work"
  else
    pass "on branch $_branch"
  fi

  if [ -n "$( cd "$PROJECT" && relay_git ls-files -u 2>/dev/null )" ]; then
    fail "unmerged paths present"
    fixit "resolve the conflict; relay never attempts automatic resolution"
  fi

  _dirty=$( cd "$PROJECT" && relay_git status --porcelain 2>/dev/null | head -5 )
  if [ -n "$_dirty" ]; then
    if [ "$ALLOW_DIRTY" -eq 1 ]; then
      warn "working tree is dirty (--allow-dirty given)"
    else
      fail "working tree is dirty"
      fixit "commit or stash first, or pass --allow-dirty"
      fixit "a clean start is what makes 'git reset --hard <sha>' a real undo"
    fi
  else
    pass "working tree clean"
  fi

  # Repo-controlled execution vectors.
  if ! relay_git_preflight "$PROJECT" 2>/tmp/relay-doctor-git.$$; then
    while IFS= read -r _l; do warn "${_l#relay-git: }"; done < "/tmp/relay-doctor-git.$$"
    fixit "these execute during git operations; review them before running relay"
  fi
  rm -f "/tmp/relay-doctor-git.$$"

  # Symlinks escaping the repo make out-of-tree files look repo-local
  # (`ln -s ~/.ssh secrets` turns Read(./secrets/id_rsa) into a host-key read).
  # Kept as a function rather than a nested command substitution: the quoting
  # inside $( ... while ... case ... ) is a trap, and this has to be right.
  relay_doctor_escaping_symlinks() {
    ( cd "$1" 2>/dev/null || return 0
      find . -type l 2>/dev/null | head -50 | while IFS= read -r _s; do
        # Resolve via the target's PARENT directory. `cd "$(readlink x)"` only
        # works when the link points at a directory; most dangerous links
        # (~/.ssh/id_rsa, ~/.claude/.credentials.json) point at files, and that
        # form silently resolved to nothing.
        _t=$(readlink "$_s") || continue
        case "$_t" in
          /*) _tdir=$(dirname "$_t") ;;
          *)  _tdir="$(dirname "$_s")/$(dirname "$_t")" ;;
        esac
        _d=$( cd "$_tdir" 2>/dev/null && pwd )
        [ -n "$_d" ] || continue
        case "$_d" in
          "$2"|"$2"/*) ;;
          *) printf '%s -> %s/%s\n' "$_s" "$_d" "$(basename "$_t")" ;;
        esac
      done )
  }
  _esc=$(relay_doctor_escaping_symlinks "$PROJECT" "$PROJECT_REAL")
  if [ -n "$_esc" ]; then
    warn "symlinks resolve outside the repo:"
    printf '%s\n' "$_esc" | sed 's/^/          /' >&2
  fi

  # A project INSIDE a deny-listed directory is a run that fights its own
  # permission rules: every Write/Edit tool call into the tree is refused (in
  # both modes — these are permission rules, not sandbox rules), and in
  # enforced mode a denyRead parent makes the project unreadable outright.
  # Warn, not fail: in disabled mode Bash writes still land, so the run
  # degrades into fallback churn rather than dying — a deliberate if odd
  # choice stays the user's to make.
  _dw_dirs=$(relay_settings_default_deny_writes \
    | sed -n 's/^Write(\(~\/[^)]*\)\/\*\*)$/\1/p' | sed "s|^~|$HOME|")
  for _dw in $_dw_dirs; do
    # Canonicalise before comparing: PROJECT_REAL went through `cd && pwd`,
    # and on macOS $HOME itself can be a symlinked path (/var -> /private/var),
    # so a lexical match against the raw expansion silently never fires.
    _dwr=$( cd "$_dw" 2>/dev/null && pwd ); [ -n "$_dwr" ] || _dwr="$_dw"
    case "$PROJECT_REAL" in
      "$_dwr"|"$_dwr"/*)
        warn "project sits under $_dwr, which relay's permission rules deny Write/Edit to"
        fixit "every Write tool call into this project will be REFUSED in both modes;"
        fixit "move the project, or expect sessions to burn turns falling back to Bash"
        ;;
    esac
  done
  _dr_dirs=$(relay_settings_default_denyread)
  for _dr in $_dr_dirs; do
    _drr=$( cd "$_dr" 2>/dev/null && pwd ); [ -n "$_drr" ] || _drr="$_dr"
    case "$PROJECT_REAL" in
      "$_drr"|"$_drr"/*)
        warn "project sits under $_drr, which the sandbox denies READS from in enforced mode"
        fixit "sessions cannot read their own project there; move it, or run full-trust"
        ;;
    esac
  done
  unset _dw_dirs _dw _dwr _dr_dirs _dr _drr
fi

# ---------------------------------------------------------------------------
# 3. Repository-supplied Claude configuration.
#
# VERIFIED CRITICAL (docs/security.md): under `claude -p` the workspace trust
# dialog is skipped, so a repo .claude/settings.json hook EXECUTES and a repo
# .mcp.json LOADS. Relay always passes --setting-sources user and
# --strict-mcp-config, which suppresses both; this check exists so the user
# knows the repository tried.
# ---------------------------------------------------------------------------
say "repository-supplied Claude config"
_found_cfg=0
for _f in .claude/settings.json .claude/settings.local.json .mcp.json; do
  if [ -e "$PROJECT/$_f" ]; then warn "repo ships $_f"; _found_cfg=1; fi
done
for _d in .claude/hooks .claude/agents .claude/skills; do
  if [ -d "$PROJECT/$_d" ]; then warn "repo ships $_d/"; _found_cfg=1; fi
done
if [ "$_found_cfg" -eq 1 ]; then
  fixit "relay suppresses these via --setting-sources user --strict-mcp-config"
  fixit "review them anyway: they would execute under any other headless claude wrapper"
else
  pass "no repo-supplied Claude configuration"
fi

# ---------------------------------------------------------------------------
# 3b. User-scope Claude configuration.
#
# --setting-sources user is a security commitment (it is what excludes a
# hostile repository's config), and it has a flip side relay cannot remove:
# the USER's own hooks load inside every relay session. A PreToolUse guard
# that text-matches commands can deny mid-run — observed on a real machine,
# where a guard blocking any command CONTAINING "git reset --hard" also
# blocked heredocs that merely wrote those words into documentation. Relay's
# job here is visibility, not suppression: the journal's session.denials
# lines say when a run is fighting one.
# ---------------------------------------------------------------------------
say "user-scope claude config"
_usercfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
if [ -f "$_usercfg" ]; then
  _uh=$(jq -r '(.hooks // {}) | to_entries[]
        | select(.key == "PreToolUse" or .key == "PostToolUse")
        | .key as $k | .value[]? | ((.matcher // "*") as $m
        | .hooks[]? | "\($k) matcher=\($m) cmd=\(.command // "?")")' \
        "$_usercfg" 2>/dev/null | head -5)
  if [ -n "$_uh" ]; then
    while IFS= read -r _uhl; do
      _uhc="${_uhl##* cmd=}"
      warn "user-scope hook runs INSIDE relay sessions: ${_uhl%% cmd=*} cmd=${_uhc##*/}"
    done <<RELAY_UH
$_uh
RELAY_UH
    fixit "--setting-sources user is a security commitment and cannot be dropped;"
    fixit "a text-matching guard can deny mid-run — watch journal session.denials lines"
    unset _uhl _uhc
  else
    pass "no user-scope PreToolUse/PostToolUse hooks"
  fi
  unset _uh
fi
unset _usercfg

# ---------------------------------------------------------------------------
# 4. State directory: writable, outside the repo, atomic-write capable.
# ---------------------------------------------------------------------------
say "state"
if [ -z "$STATE" ]; then
  warn "no state dir given; skipping state checks"
else
  case "$STATE" in
    "$PROJECT_REAL"|"$PROJECT_REAL"/*)
      fail "state dir is inside the repository: $STATE"
      fixit "relay keeps state outside the worktree so an attacker-writable"
      fixit "checkout cannot pre-create its files as symlinks" ;;
  esac
  if ! mkdir -p "$STATE" 2>/dev/null; then
    fail "cannot create state dir: $STATE"
  else
    _probe="$STATE/.doctor-probe.$$"
    if printf 'x\n' > "$_probe.tmp" 2>/dev/null && mv -f "$_probe.tmp" "$_probe" 2>/dev/null; then
      pass "state dir writable, atomic rename works"
      rm -f "$_probe"
    else
      fail "atomic write round-trip failed in $STATE"
      rm -f "$_probe.tmp" "$_probe"
    fi
    _free=$(df -k "$STATE" 2>/dev/null | awk 'NR==2 {print $4}')
    case "$_free" in
      ''|*[!0-9]*) warn "could not determine free space" ;;
      *) if [ "$_free" -lt 2097152 ]; then
           fail "less than 2GB free on the state filesystem ($((_free/1024)) MB)"
         else
           pass "$((_free/1048576)) GB free"
         fi ;;
    esac
  fi

  say "consent"
  # SECURITY.md promises that a change to the consent terms invalidates
  # recorded consent. This check is that promise's mechanism: recompute the
  # hash of the consent notice as it reads in the CURRENTLY INSTALLED SKILL.md
  # and refuse to run unless config.json records consent to exactly those
  # bytes. The extraction below is the pinned canonical one from SKILL.md's
  # init step 6: the fenced notice block, from its first line to the line
  # before the closing fence, hashed with `git hash-object --stdin`. If the
  # hash cannot be computed at all, that is unverifiable consent, and
  # unverifiable means refuse — fail closed.
  _skill="$SELF_DIR/../skills/relay/SKILL.md"
  _notice=""
  if [ -f "$_skill" ]; then
    _notice=$(sed -n '/^relay runs Claude Code unattended/,/^```/p' "$_skill" 2>/dev/null \
              | sed '$d' | git hash-object --stdin 2>/dev/null)
  fi
  case "$_notice" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) : ;;
    *) _notice="" ;;
  esac
  _consent=$(jq -r '.consent.notice_hash // empty' "$STATE/config.json" 2>/dev/null)
  if [ -z "$_notice" ]; then
    fail "cannot compute the consent notice hash from $_skill"
    fixit "the relay install is broken (SKILL.md missing or unreadable); reinstall the plugin"
  elif [ -z "$_consent" ]; then
    fail "no recorded consent in $STATE/config.json"
    fixit "run /relay-init: the consent gate records consent.notice_hash there"
  elif [ "$_consent" != "$_notice" ]; then
    fail "the consent notice has changed since consent was recorded"
    fixit "the terms in SKILL.md are no longer the terms that were accepted;"
    fixit "re-run /relay-init and re-accept the current notice"
  else
    pass "recorded consent matches the current notice"
  fi

  # Not a failure — it is a consented, deliberate configuration. But it is the
  # single fact that most changes what a stray session can reach, so doctor
  # says it out loud every time rather than leaving it buried in config.json.
  if [ "$(jq -r '.sandbox_mode // "enforced"' "$STATE/config.json" 2>/dev/null)" = "disabled" ]; then
    warn "sandbox_mode is disabled (FULL TRUST): sessions run with NO sandbox — any host, any readable file, including ~/.ssh"
    _mt=$(jq -r '.model_tier // "opus"' "$STATE/config.json" 2>/dev/null)
    _bps=$(jq -r '.budget_usd_per_session // 2.00' "$STATE/config.json" 2>/dev/null)
    if [ "$_mt" = "opus" ] && printf '%s 5\n' "$_bps" | awk '{exit !($1 < $2)}'; then
      warn "budget_usd_per_session is $_bps with model_tier opus in full-trust mode"
      fixit "a budget-capped session dies mid-step WITHOUT writing a handoff, and"
      fixit "each one costs a recovery session; for long runs set it to 5.00 or higher"
    fi
    unset _mt _bps
  fi

  # Not a failure: relay still verifies COMPLETE via sealed sentinel, clean
  # tree and new commits. But with no acceptance command there is nothing
  # EXECUTABLE standing between "the model says it is done" and EX_OK.
  if ! jq -e '.acceptance_cmd | (type == "array" and length > 0)' "$STATE/exec.json" >/dev/null 2>&1; then
    warn "no acceptance command configured; COMPLETE is gated only on commits + clean tree (set one with /relay-approve)"
  else
    pass "acceptance command configured"
  fi
fi

# ---------------------------------------------------------------------------
# 5. Local credential hygiene.
# ---------------------------------------------------------------------------
say "credentials"
_cred="$HOME/.claude/.credentials.json"
if [ -f "$_cred" ]; then
  # No `stat` — its flags differ between macOS and Linux. ls is portable enough
  # for a permission check.
  _mode=$(ls -l "$_cred" 2>/dev/null | cut -c1-10)
  case "$_mode" in
    -rw-------) pass "credentials file is 0600" ;;
    *) warn "credentials file is $_mode (group/other readable)"
       fixit "chmod 600 $_cred"
       fixit "relay will not modify files outside its own state dir" ;;
  esac
fi
for _v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
  eval "_set=\${$_v:+yes}"
  [ "${_set:-}" = "yes" ] && warn "$_v is set in this environment; it is inherited by every subprocess"
done

# ---------------------------------------------------------------------------
# 6. Relay's own components.
# ---------------------------------------------------------------------------
say "relay components"
for _f in relay-settings.sh relay-git.sh lib/relay-lib.sh; do
  if [ -f "$SELF_DIR/$_f" ]; then pass "$_f"; else fail "missing component: $_f"; fi
done
_hook="$SELF_DIR/../hooks/relay-ctx.sh"
if [ -f "$_hook" ]; then
  pass "context guard present"
  if ! bash -n "$_hook" 2>/dev/null; then fail "context guard has a syntax error"; fi
else
  fail "context guard missing: $_hook"
fi

# ---------------------------------------------------------------------------
# Verdict.
# ---------------------------------------------------------------------------
say ""
if [ "$HARD_FAIL" -ne 0 ]; then
  printf 'relay doctor: FAILED — relay will not start.\n' >&2
  exit 78
fi
if [ "$WARNED" -ne 0 ]; then
  say "relay doctor: passed with warnings."
else
  say "relay doctor: all checks passed."
fi
exit 0
