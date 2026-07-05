#!/bin/zsh
# Kill tmux sessions whose cmux workspace no longer exists.
# Safe: aborts early if cmux is unreachable to avoid false-positive cleanup.

CMUX=/Applications/cmux.app/Contents/Resources/bin/cmux
TMUX_BIN=/opt/homebrew/bin/tmux
MAP_FILE="${HOME}/.local/state/cmux-tmux-map"

[[ ! -f "$MAP_FILE" ]] && exit 0
[[ ! -x "$CMUX" ]] && exit 0

# Bail out if cmux socket is not responding (prevents wiping sessions on crash).
"$CMUX" list-windows >/dev/null 2>&1 || exit 0

tmp=$(mktemp)
while IFS=' ' read -r ws_id session; do
    [[ -z "$ws_id" || -z "$session" ]] && continue
    if "$CMUX" list-panes --workspace "$ws_id" >/dev/null 2>&1; then
        # Workspace still alive: keep the entry.
        echo "${ws_id} ${session}" >> "$tmp"
    else
        # Workspace gone: kill the tmux session.
        "$TMUX_BIN" kill-session -t "$session" 2>/dev/null
    fi
done < "$MAP_FILE"
mv "$tmp" "$MAP_FILE"
