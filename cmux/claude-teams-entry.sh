#!/bin/zsh
# Claude Teams entry picker: choose which session to enter, then launch.
#
# claude-teams forwards extra args to claude, so:
#   new session      -> cmux claude-teams
#   pick existing    -> cmux claude-teams --resume   (interactive session picker)
# You can also switch later from inside Claude with /resume.
#
# --settings injection (notification fix):
# Unlike a plain `cmux claude`, `claude-teams` resolves and launches the
# claude binary itself instead of going through cmux-claude-wrapper, so it
# never gets the wrapper's --settings hook injection. Without it the
# supervisor gets no Stop-hook notification when its turn ends. We pass the
# hook config explicitly via --settings; Claude Code additive-merges a
# --settings file with the user's own settings.json, so this doesn't clobber
# anything. claude-cmux-hooks.json is a manual, point-in-time copy of the
# HOOKS_JSON literal from cmux-claude-wrapper (grep -n '^HOOKS_JSON=' in
# /Applications/cmux.app/Contents/Resources/bin/cmux-claude-wrapper) as of
# cmux 0.64.17 -- it can drift when cmux updates, and if claude-teams ever
# gains native hook injection this should be dropped to avoid double-firing
# hooks.
HOOKS_FILE="${0:A:h}/claude-cmux-hooks.json"

# claude-teams (unlike the wrapper) does not deep-merge multiple --settings
# flags -- passing two lets Claude Code silently pick just one, undocumented
# and version-dependent which. So if a caller already forwarded their own
# --settings via "$@" (e.g. someone chaining flags onto this picker), skip
# our injection rather than risk clobbering theirs or being clobbered
# ourselves; that just means no turn-completion notification this run.
CMUX_BIN="${CMUX_BUNDLED_CLI_PATH:-cmux}"
# The hook commands fall back to a bare `cmux` on PATH if this is unset, but
# claude-teams already runs inside a cmux workspace where the bundled cmux
# CLI's absolute path is available, so prefer that over relying on PATH.
export CMUX_CLAUDE_HOOK_CMUX_BIN="${CMUX_CLAUDE_HOOK_CMUX_BIN:-$CMUX_BIN}"

CALLER_HAS_SETTINGS=false
for arg in "$@"; do
  case "$arg" in
    --settings|--settings=*) CALLER_HAS_SETTINGS=true ;;
  esac
done

SETTINGS_ARGS=()
if [[ "$CALLER_HAS_SETTINGS" == true ]]; then
  echo "claude-teams-entry: caller already passed --settings; skipping cmux hook injection to avoid a --settings conflict (no turn-completion notifications)." >&2
elif [[ ! -r "$HOOKS_FILE" ]]; then
  echo "claude-teams-entry: $HOOKS_FILE not found; launching without cmux hook injection (no turn-completion notifications)." >&2
else
  SETTINGS_ARGS=(--settings "$HOOKS_FILE")
fi

echo "Claude Teams — どのセッションに入りますか?"
echo "  [Enter] 新規セッション"
echo "  [r]     既存セッションから選ぶ"
if [[ -t 0 && -t 1 ]]; then
  read -k1 "choice?選択: "
  echo
else
  # Non-interactive stdin/stdout (e.g. scripted invocation): read -k1 would
  # just print "not interactive and can't open terminal" and leave $choice
  # empty anyway, so skip straight to that same default (new session).
  choice=""
fi
case "$choice" in
  r|R) exec "$CMUX_BIN" claude-teams --resume "${SETTINGS_ARGS[@]}" "$@" ;;
  *)   exec "$CMUX_BIN" claude-teams "${SETTINGS_ARGS[@]}" "$@" ;;
esac
