# Wire the plugin-layer coherence lint into the discovered suite: commands,
# skill sections, defaults.json/cfg parity, and manifest agreement must hold
# on every run, not only when someone remembers to run the lint by hand.
bash "$ROOT/test/lint/plugin-layer.sh" >"$PWD/lint.out" 2>&1
RC=$?

if [ "$RC" -ne 0 ]; then
  cat "$PWD/lint.out"
fi
assert_rc 0 "$RC" "c005_plugin_layer_clean"

exit 0
