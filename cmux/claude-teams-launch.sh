#!/bin/zsh
# Launch cmux and start a Claude Code Agent Teams supervisor workspace.
#
# Primary daily flow is cmux's built-in session restore (quit with the
# supervisor running and it resumes on relaunch). Use this script when you
# want a FRESH supervisor conversation instead.
#
# Symlinked to ~/.local/bin/cmux-teams by install.sh.

CMUX="$(command -v cmux || echo /Applications/cmux.app/Contents/Resources/bin/cmux)"
WS_NAME="Supervisor"
WS_CWD="${HOME}/Claude"

open -a cmux

# Wait for the cmux control socket (app cold start takes a few seconds).
for _ in {1..60}; do
  "$CMUX" ping >/dev/null 2>&1 && break
  sleep 0.5
done
if ! "$CMUX" ping >/dev/null 2>&1; then
  echo "cmux socket did not come up; open cmux and run: cmux claude-teams" >&2
  exit 1
fi

# Don't stack a second supervisor if session restore already brought one back.
if "$CMUX" list-workspaces 2>/dev/null | grep -q "$WS_NAME"; then
  echo "workspace '$WS_NAME' already exists; not creating another."
  exit 0
fi

# Entry picker (new vs existing session) lives next to this script.
ENTRY="${0:A:h}/claude-teams-entry.sh"
exec "$CMUX" new-workspace --name "$WS_NAME" --cwd "$WS_CWD" --command "$ENTRY"
