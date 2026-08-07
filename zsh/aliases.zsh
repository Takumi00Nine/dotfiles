# claude
cc() {
    cd ~/Claude && claude "$@"
}

# claude-teams (cmux) — cmux resolves the claude binary itself for this
# subcommand instead of going through cmux-claude-wrapper, so it never gets
# the wrapper's hook injection (no turn-completion notification). Inject the
# same hooks explicitly via --settings; see
# ~/work/dotfiles/cmux/claude-teams-entry.sh for the full rationale/fallback
# this mirrors.
cct() {
    local hooks="$HOME/work/dotfiles/cmux/claude-cmux-hooks.json"
    local cmux_bin="${CMUX_BUNDLED_CLI_PATH:-cmux}"
    local settings_args=()
    local has_settings=false
    # teammates run in the agent panel (no split panes); the claude-teams
    # wrapper only injects its own `--teammate-mode auto` when the caller
    # passes none, so an explicit `cct --teammate-mode auto` restores panes
    local mode_args=(--teammate-mode in-process)
    for arg in "$@"; do
        case "$arg" in
            --) break ;;
            --settings|--settings=*) has_settings=true ;;
            --teammate-mode|--teammate-mode=*) mode_args=() ;;
        esac
    done
    if [[ "$has_settings" == true ]]; then
        echo "cct: caller already passed --settings; skipping cmux hook injection (no turn-completion notifications)." >&2
    elif [[ ! -r "$hooks" ]]; then
        echo "cct: $hooks not found; launching without cmux hook injection (no turn-completion notifications)." >&2
    else
        settings_args=(--settings "$hooks")
    fi
    cd ~/Claude && CMUX_CLAUDE_HOOK_CMUX_BIN="${CMUX_CLAUDE_HOOK_CMUX_BIN:-$cmux_bin}" \
        "$cmux_bin" claude-teams "${settings_args[@]}" "${mode_args[@]}" "$@"
}
