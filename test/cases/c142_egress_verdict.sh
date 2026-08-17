# test/cases/c142_egress_verdict.sh — the acceptance probe's egress half.
#
# The probe itself needs a real API call and cannot run here, so the part that
# decides what the attempt PROVED is a separate pure function, and this is its
# test. It matters because the decision is a refuse-to-run: reading "blocked"
# out of an ambiguous file would start an unattended run on a sandbox nobody
# checked, and reading "reachable" out of a missing one would refuse to start
# on a working machine.
#
# Also covers the host choice, which exists because `allow_domains` is
# user-configurable and probing a host the user deliberately allowlisted would
# convict a sandbox that is working perfectly.
# shellcheck source=/dev/null
. "$ROOT/plugins/relay/scripts/lib/relay-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/plugins/relay/scripts/relay-settings.sh"

v() { relay_settings_egress_verdict "$1"; }

# curl answered: the sandbox is not confining egress. This is the case that
# must refuse the run, so it is the one that must never be reported softly.
printf '200\nrc=0\n' > "$PWD/net-200.txt"
assert_eq "reachable" "$(v "$PWD/net-200.txt")" "c142_http_200_is_reachable"

printf '301\nrc=0\n' > "$PWD/net-301.txt"
assert_eq "reachable" "$(v "$PWD/net-301.txt")" "c142_any_real_status_is_reachable"

# curl's own signature for "never got a response": 000 with a non-zero status.
printf '000\nrc=28\n' > "$PWD/net-000.txt"
assert_eq "blocked" "$(v "$PWD/net-000.txt")" "c142_000_is_blocked"

printf 'curl: (7) Failed to connect to example.com port 443\n000\nrc=7\n' > "$PWD/net-err.txt"
assert_eq "blocked" "$(v "$PWD/net-err.txt")" "c142_connect_failure_is_blocked"

# Everything relay cannot interpret is inconclusive, never "blocked". A missing
# file is the no-curl-on-this-box case; an empty one and a status without an
# exit code are the model-did-not-finish-the-command cases.
assert_eq "inconclusive" "$(v "$PWD/net-absent.txt")" "c142_missing_file_is_inconclusive"

: > "$PWD/net-empty.txt"
assert_eq "inconclusive" "$(v "$PWD/net-empty.txt")" "c142_empty_file_is_inconclusive"

printf '200\n' > "$PWD/net-norc.txt"
assert_eq "inconclusive" "$(v "$PWD/net-norc.txt")" "c142_status_without_rc_is_inconclusive"

# Host selection: default, and the allowlisted-host case.
S_DEFAULT="$(relay_settings_build "$PWD/proj" "$PWD/state" "$PWD/hook.sh" "")"
assert_eq "example.com" "$(relay_settings_egress_host "$S_DEFAULT")" "c142_default_probe_host"

S_ALLOWED="$(relay_settings_build "$PWD/proj" "$PWD/state" "$PWD/hook.sh" "example.com,example.net")"
assert_eq "example.org" "$(relay_settings_egress_host "$S_ALLOWED")" "c142_probe_host_avoids_allowlist"

exit 0
