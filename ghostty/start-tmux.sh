#!/bin/zsh
# Attach to (or create) a tmux session that follows the cmux workspace name.
# Falls back to session "ai" when running outside cmux (e.g. plain Ghostty).
#
# UUID → session name mapping is persisted in ~/.local/state/cmux-tmux-map.
# On each attach, if the workspace has been renamed the tmux session is renamed
# to match before attaching, so the two stay in sync automatically.

CMUX=/Applications/cmux.app/Contents/Resources/bin/cmux
TMUX_BIN=/opt/homebrew/bin/tmux
MAP_FILE="${HOME}/.local/state/cmux-tmux-map"

# Extract workspace name from `cmux identify --json`.
# Tries several possible field paths; exits 1 if none found.
_ws_name_from_json() {
  python3 - "$1" <<'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
    for fn in [
        lambda d: d["workspace"]["title"],
        lambda d: d["workspace"]["name"],
        lambda d: d["caller"]["workspace"]["title"],
        lambda d: d["caller"]["workspace"]["name"],
        lambda d: d["context"]["workspace"]["title"],
        lambda d: d["context"]["workspace"]["name"],
    ]:
        try:
            v = fn(d)
            if v and str(v).strip():
                print(str(v).strip())
                sys.exit(0)
        except (KeyError, TypeError):
            pass
    sys.exit(1)
except Exception:
    sys.exit(1)
PY
}

# Replace chars not valid in tmux session names with hyphens.
_sanitize() { echo "${1//[^a-zA-Z0-9_-]/-}"; }

# ── main ────────────────────────────────────────────────────────────────────

# Not inside cmux → use shared "ai" session (original Ghostty behaviour).
if [[ -z "${CMUX_WORKSPACE_ID:-}" ]]; then
  exec "$TMUX_BIN" new-session -A -s ai
fi

ws_id="$CMUX_WORKSPACE_ID"

# Trigger orphaned-session cleanup in the background (lazy GC for deleted workspaces).
"${HOME}/.config/ghostty/cmux-session-cleanup.sh" &>/dev/null &

# Resolve workspace name; fall back to 8-char UUID prefix on failure.
ws_json=$("$CMUX" identify --json 2>/dev/null)
ws_name=$(_ws_name_from_json "$ws_json" 2>/dev/null)
[[ -z "$ws_name" ]] && ws_name="${ws_id:0:8}"
target=$(_sanitize "$ws_name")

# Ensure map file exists.
mkdir -p "$(dirname "$MAP_FILE")"
touch "$MAP_FILE"

# Look up any previously recorded session for this workspace UUID.
prev=$( grep "^${ws_id} " "$MAP_FILE" 2>/dev/null | tail -1 | cut -d' ' -f2- )

if [[ -n "$prev" ]] && "$TMUX_BIN" has-session -t "$prev" 2>/dev/null; then
  # Live session found. Rename it if the workspace was renamed, then attach.
  if [[ "$prev" != "$target" ]]; then
    if "$TMUX_BIN" rename-session -t "$prev" "$target" 2>/dev/null; then
      { grep -v "^${ws_id} " "$MAP_FILE"; echo "${ws_id} ${target}"; } \
        > "${MAP_FILE}.tmp" && mv "${MAP_FILE}.tmp" "$MAP_FILE"
    else
      target="$prev"   # rename failed (name clash?); keep old name
    fi
  fi
else
  # No live session for this workspace; record a fresh mapping.
  { grep -v "^${ws_id} " "$MAP_FILE"; echo "${ws_id} ${target}"; } \
    > "${MAP_FILE}.tmp" && mv "${MAP_FILE}.tmp" "$MAP_FILE"
fi

exec "$TMUX_BIN" new-session -A -s "$target"
