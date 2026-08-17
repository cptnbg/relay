#!/usr/bin/env bash
# Unit tests for relay-git.sh. Run: bash test/lib/test-relay-git.sh
set -u
LC_ALL=C
IFS=$' \t\n'

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=/dev/null
. "$ROOT/plugins/relay/scripts/relay-git.sh"

PASS=0; FAIL=0; FAILED=""
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED="$FAILED $1"; printf 'FAIL %s: %s\n' "$1" "${2:-}"; }
check(){ if [ "$1" = "0" ]; then ok "$2"; else bad "$2" "${3:-}"; fi; }

SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT

newrepo() {
  _r="$SB/$1"; rm -rf "$_r"; mkdir -p "$_r"; cd "$_r" || return 1
  relay_git init -q .; relay_git config user.name t; relay_git config user.email t@e
  printf 'hello\n' > README.md
  relay_git add README.md >/dev/null 2>&1
  relay_git commit -q -m init >/dev/null 2>&1
  printf '%s' "$_r"
}

# --- forbidden path matching -------------------------------------------------
for p in .env .env.local src/.env config/id_rsa a/b/credentials.json \
         key.pem cert.p12 .npmrc deep/.aws/creds .claude/settings.local.json; do
  relay_git_path_is_forbidden "$p"; check "$?" "forbidden:$p"
done
for p in src/main.go README.md .github/workflows/ci.yml environment.ts docs/envoy.md; do
  if relay_git_path_is_forbidden "$p"; then bad "allowed:$p" "wrongly forbidden"; else ok "allowed:$p"; fi
done

# --- secret scanning ---------------------------------------------------------
cat > "$SB/clean.txt" <<'EOF'
const timeout = 30;
// api key goes in the environment, not here
EOF
relay_git_scan_text "$SB/clean.txt" >/dev/null; check "$?" "scan:clean-file-passes"

# Assembled at runtime so this test file never itself contains a literal that
# would trip secret scanners in CI or in relay's own repo.
{ printf 'ANTHROPIC_KEY="sk-ant-'; printf 'A%.0s' $(seq 1 30); printf '"\n'; } > "$SB/dirty.txt"
relay_git_scan_text "$SB/dirty.txt" >/dev/null
if [ "$?" -ne 0 ]; then ok "scan:anthropic-key-detected"; else bad "scan:anthropic-key-detected"; fi

{ printf 'token=ghp_'; printf 'b%.0s' $(seq 1 36); printf '\n'; } > "$SB/gh.txt"
relay_git_scan_text "$SB/gh.txt" >/dev/null
if [ "$?" -ne 0 ]; then ok "scan:github-pat-detected"; else bad "scan:github-pat-detected"; fi

printf -- '-----BEGIN RSA PRIVATE KEY-----\nabc\n' > "$SB/pem.txt"
relay_git_scan_text "$SB/pem.txt" >/dev/null
if [ "$?" -ne 0 ]; then ok "scan:pem-detected"; else bad "scan:pem-detected"; fi

# The report must name the location but never echo the secret value.
REPORT=$(relay_git_scan_text "$SB/dirty.txt")
case "$REPORT" in *"sk-ant-AAAA"*) bad "scan:report-withholds-value" "report leaked the secret" ;;
                  *) ok "scan:report-withholds-value" ;; esac

# --- staging filters ---------------------------------------------------------
R=$(newrepo repo1)
cd "$R" || exit 1
mkdir -p src
printf 'ok\n' > src/app.js
printf 'SECRET=x\n' > .env
ln -s /etc/hosts outside-link 2>/dev/null

# Pick a forbidden filename that git itself does NOT already ignore, so we are
# testing relay's filter rather than the user's gitignore. Many developers
# (including this machine) have a global gitignore covering .env / *.pem /
# *.key, which means those never reach relay's filter at all. That is defence
# in depth working as intended, but it makes them useless as a test subject.
FORBIDDEN_PROBE=""
for cand in id_rsa .npmrc .netrc .pypirc; do
  printf 'x\n' > "$cand"
  if relay_git ls-files -o --exclude-standard | grep -qx -- "$cand"; then
    FORBIDDEN_PROBE="$cand"; break
  fi
  rm -f "$cand"
done

LIST=$(relay_git_collect_paths "$R" 2>"$SB/skips" | tr '\0' '\n')
case "$LIST" in *src/app.js*) ok "collect:includes-normal-file" ;; *) bad "collect:includes-normal-file" "got: $LIST" ;; esac
case "$LIST" in *.env*) bad "collect:excludes-dotenv" "dotenv was included" ;; *) ok "collect:excludes-dotenv" ;; esac
case "$LIST" in *outside-link*) bad "collect:excludes-escaping-symlink" ;; *) ok "collect:excludes-escaping-symlink" ;; esac

if [ -n "$FORBIDDEN_PROBE" ]; then
  case "$LIST" in
    *"$FORBIDDEN_PROBE"*) bad "collect:excludes-forbidden-name" "$FORBIDDEN_PROBE was staged" ;;
    *) ok "collect:excludes-forbidden-name" ;;
  esac
  if grep -q "forbidden-name $FORBIDDEN_PROBE" "$SB/skips"; then
    ok "collect:reports-skip-reason"
  else
    bad "collect:reports-skip-reason" "no SKIP line for $FORBIDDEN_PROBE; skips=$(cat "$SB/skips")"
  fi
else
  ok "collect:excludes-forbidden-name (skipped: gitignore covers all probes)"
  ok "collect:reports-skip-reason (skipped: gitignore covers all probes)"
fi

# --- commit path: clean ------------------------------------------------------
R=$(newrepo repo2); cd "$R" || exit 1
mkdir -p src; printf 'fine\n' > src/a.txt
BEFORE=$(relay_git rev-list --count HEAD)
relay_git_commit "$R" "test: clean commit" ""; RC=$?
AFTER=$(relay_git rev-list --count HEAD)
check "$RC" "commit:clean-returns-0"
if [ "$AFTER" -eq $((BEFORE+1)) ]; then ok "commit:clean-created-commit"; else bad "commit:clean-created-commit" "$BEFORE -> $AFTER"; fi
if relay_git status --porcelain | grep -q .; then bad "commit:tree-clean-after"; else ok "commit:tree-clean-after"; fi

# --- commit path: nothing to do ---------------------------------------------
relay_git_commit "$R" "test: noop" ""; check "$?" "commit:noop-returns-0"

# --- commit path: secret blocks ---------------------------------------------
R=$(newrepo repo3); cd "$R" || exit 1
STATE="$SB/state3"; mkdir -p "$STATE"
mkdir -p src
{ printf 'const k = "sk-ant-'; printf 'C%.0s' $(seq 1 30); printf '";\n'; } > src/leak.js
BEFORE=$(relay_git rev-list --count HEAD)
relay_git_commit "$R" "test: should be blocked" "$STATE" 2>/dev/null; RC=$?
AFTER=$(relay_git rev-list --count HEAD)
if [ "$RC" -eq 1 ]; then ok "commit:secret-returns-1"; else bad "commit:secret-returns-1" "rc=$RC"; fi
if [ "$AFTER" -eq "$BEFORE" ]; then ok "commit:secret-created-no-commit"; else bad "commit:secret-created-no-commit"; fi
[ -f "$STATE/BLOCKED.md" ] && ok "commit:secret-wrote-BLOCKED" || bad "commit:secret-wrote-BLOCKED"
grep -q 'relay:sealed' "$STATE/BLOCKED.md" 2>/dev/null && ok "commit:BLOCKED-is-sealed" || bad "commit:BLOCKED-is-sealed"
if grep -q 'sk-ant-CCCC' "$STATE/BLOCKED.md" 2>/dev/null; then bad "commit:BLOCKED-withholds-value"; else ok "commit:BLOCKED-withholds-value"; fi
# index must be reset, not left staged
if relay_git diff --cached --quiet; then ok "commit:index-reset-after-block"; else bad "commit:index-reset-after-block"; fi

# --- preflight detects repo-controlled execution -----------------------------
R=$(newrepo repo4); cd "$R" || exit 1
relay_git_preflight "$R" 2>/dev/null; check "$?" "preflight:clean-repo-passes"

mkdir -p "$R/.git/hooks"; printf '#!/bin/sh\necho x\n' > "$R/.git/hooks/pre-commit"
chmod +x "$R/.git/hooks/pre-commit"
relay_git_preflight "$R" 2>/dev/null
if [ "$?" -ne 0 ]; then ok "preflight:detects-executable-hook"; else bad "preflight:detects-executable-hook"; fi
rm -f "$R/.git/hooks/pre-commit"

relay_git config --local core.fsmonitor "/tmp/evil.sh"
relay_git_preflight "$R" 2>/dev/null
if [ "$?" -ne 0 ]; then ok "preflight:detects-fsmonitor"; else bad "preflight:detects-fsmonitor"; fi
relay_git config --local --unset core.fsmonitor

# A repo hook must NOT run during relay's own commit.
R=$(newrepo repo5); cd "$R" || exit 1
mkdir -p "$R/.git/hooks"
printf '#!/bin/sh\ntouch "%s/HOOK-RAN"\n' "$SB" > "$R/.git/hooks/pre-commit"
chmod +x "$R/.git/hooks/pre-commit"
rm -f "$SB/HOOK-RAN"
printf 'x\n' > file.txt
relay_git_commit "$R" "test: hooks must not run" "" >/dev/null 2>&1
if [ -f "$SB/HOOK-RAN" ]; then bad "commit:repo-hook-neutralised" "the repo pre-commit hook executed"; else ok "commit:repo-hook-neutralised"; fi

# --- env sanitisation --------------------------------------------------------
export GIT_SSH_COMMAND="/tmp/evil"; export GIT_EXTERNAL_DIFF="/tmp/evil2"
export GIT_AUTHOR_NAME="keepme"
relay_git_sanitize_env
[ -z "${GIT_SSH_COMMAND:-}" ] && ok "env:unsets-GIT_SSH_COMMAND" || bad "env:unsets-GIT_SSH_COMMAND"
[ -z "${GIT_EXTERNAL_DIFF:-}" ] && ok "env:unsets-GIT_EXTERNAL_DIFF" || bad "env:unsets-GIT_EXTERNAL_DIFF"
[ "${GIT_AUTHOR_NAME:-}" = "keepme" ] && ok "env:keeps-identity-vars" || bad "env:keeps-identity-vars"

printf '\n--- summary: %s passed, %s failed ---\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { printf 'failed:%s\n' "$FAILED"; exit 1; }
exit 0
