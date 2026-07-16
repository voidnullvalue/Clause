#!/usr/bin/env bash
# Install the fail-closed auto-resuming claude-guard for the current user.

set -euo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
CLAUDE_DIR="${HOME}/.claude"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

for cmd in jq install mktemp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        printf 'Missing required command: %s\n' "$cmd" >&2
        exit 127
    fi
done

for file in claude-guard-auto-resume claude-guard-fail-closed claude-guard-statusline-auto-resume.sh; do
    if [[ ! -f "$SOURCE_DIR/$file" ]]; then
        printf 'Expected %s beside this installer.\n' "$file" >&2
        exit 1
    fi
done

mkdir -p "$BIN_DIR" "$CLAUDE_DIR"
install -m 0755 "$SOURCE_DIR/claude-guard-auto-resume" "$BIN_DIR/claude-guard-core"
install -m 0755 "$SOURCE_DIR/claude-guard-fail-closed" "$BIN_DIR/claude-guard"
install -m 0755 "$SOURCE_DIR/claude-guard-statusline-auto-resume.sh" "$BIN_DIR/claude-guard-statusline.sh"

if [[ -f "$SETTINGS_FILE" ]]; then
    if ! jq -e . "$SETTINGS_FILE" >/dev/null 2>&1; then
        printf '%s is not valid JSON; refusing to modify it.\n' "$SETTINGS_FILE" >&2
        exit 1
    fi
    cp -a "$SETTINGS_FILE" "$SETTINGS_FILE.backup-$TIMESTAMP"
else
    printf '{}\n' >"$SETTINGS_FILE"
fi

tmp="$(mktemp "$CLAUDE_DIR/.settings.XXXXXX")"
jq '
    .statusLine = {
        type: "command",
        command: "~/.local/bin/claude-guard-statusline.sh",
        padding: 0,
        refreshInterval: 1
    }
' "$SETTINGS_FILE" >"$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$SETTINGS_FILE"

cat <<'MSG'
Installed fail-closed Claude Guard:
  ~/.local/bin/claude-guard       (independent supervisor)
  ~/.local/bin/claude-guard-core  (pause/probe/resume core)
  ~/.local/bin/claude-guard-statusline.sh

Run:
  claude-guard

Default behavior:
  - pause at 95% of either the 5-hour or weekly allowance
  - fail closed if telemetry becomes stale or enforcement stops working
  - verify the reset with a cheap Haiku request
  - resume the exact saved session only after verification succeeds

Recommended conservative invocation:
  CLAUDE_GUARD_5H_STOP=90 CLAUDE_GUARD_7D_STOP=90 claude-guard

Disable automatic resume while retaining the hard stop:
  CLAUDE_GUARD_AUTO_RESUME=0 claude-guard

Explicitly bypass both safety layers:
  claude-guard --guard-bypass

After testing:
  alias claude='claude-guard'
MSG
