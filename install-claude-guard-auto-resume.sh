#!/usr/bin/env bash
# Install Clause for the current user.

set -euo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
LIBEXEC_DIR="$HOME/.local/libexec/clause"
CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
CLAUSE_STATE_DIR="$STATE_HOME/clause"
OLD_STATE_DIR="$STATE_HOME/claude-guard"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

for cmd in jq install mktemp rm mkdir flock pgrep date awk od tr grep sed; do
    command -v "$cmd" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$cmd" >&2
        exit 127
    }
done

for file in claude-guard-fail-closed claude-guard-auto-resume claude-guard-statusline-auto-resume.sh clause-tool-gate.sh; do
    [[ -f "$SOURCE_DIR/$file" ]] || {
        printf 'Expected %s beside this installer.\n' "$file" >&2
        exit 1
    }
done

mkdir -p "$BIN_DIR" "$LIBEXEC_DIR" "$CLAUDE_DIR" "$CLAUSE_STATE_DIR"
chmod 700 "$LIBEXEC_DIR" "$CLAUSE_STATE_DIR" 2>/dev/null || true
install -m 0755 "$SOURCE_DIR/claude-guard-fail-closed" "$BIN_DIR/clause"

# Claude Code permits --no-session-persistence only with --print. Clause's
# preflight is intentionally interactive because it relies on status-line
# telemetry, so remove the incompatible flag from the installed core.
core_tmp="$(mktemp "$LIBEXEC_DIR/.clause-core.XXXXXX")"
sed 's/ --no-session-persistence \\/ \\/' \
    "$SOURCE_DIR/claude-guard-auto-resume" >"$core_tmp"
if grep -q -- '--no-session-persistence' "$core_tmp"; then
    printf 'Failed to remove invalid preflight flag from Clause core.\n' >&2
    rm -f "$core_tmp"
    exit 1
fi
chmod 700 "$core_tmp"
mv -f "$core_tmp" "$LIBEXEC_DIR/clause-core"

install -m 0700 "$SOURCE_DIR/claude-guard-statusline-auto-resume.sh" "$LIBEXEC_DIR/clause-statusline.sh"
install -m 0700 "$SOURCE_DIR/clause-tool-gate.sh" "$LIBEXEC_DIR/clause-tool-gate.sh"

# Remove every old public/internal executable name. No compatibility symlink is
# left because that would preserve an alternate entrypoint around Clause.
rm -f \
    "$BIN_DIR/claude-guard" \
    "$BIN_DIR/claude-guard-core" \
    "$BIN_DIR/claude-guard-statusline.sh"

# Preserve last-known telemetry during the rename. The new core still requires
# fresh below-threshold telemetry or performs a guarded preflight probe.
if [[ ! -s "$CLAUSE_STATE_DIR/usage.json" && -s "$OLD_STATE_DIR/usage.json" ]] \
    && jq -e . "$OLD_STATE_DIR/usage.json" >/dev/null 2>&1; then
    install -m 0600 "$OLD_STATE_DIR/usage.json" "$CLAUSE_STATE_DIR/usage.json"
fi

if [[ -f "$SETTINGS_FILE" ]]; then
    jq -e . "$SETTINGS_FILE" >/dev/null 2>&1 || {
        printf '%s is not valid JSON; refusing to modify it.\n' "$SETTINGS_FILE" >&2
        exit 1
    }
    cp -a "$SETTINGS_FILE" "$SETTINGS_FILE.backup-$TIMESTAMP"
else
    printf '{}\n' >"$SETTINGS_FILE"
fi

settings_tmp="$(mktemp "$CLAUDE_DIR/.settings.XXXXXX")"
jq '
    .statusLine = {
        type: "command",
        command: "~/.local/libexec/clause/clause-statusline.sh",
        padding: 0,
        refreshInterval: 1
    }
' "$SETTINGS_FILE" >"$settings_tmp"
chmod 600 "$settings_tmp"
mv -f "$settings_tmp" "$SETTINGS_FILE"

cat <<'MSG'
Installed Clause:
  ~/.local/bin/clause
  ~/.local/libexec/clause/clause-core
  ~/.local/libexec/clause/clause-statusline.sh
  ~/.local/libexec/clause/clause-tool-gate.sh

The old claude-guard executables were removed.

Use:
  clause
  clause --resume

Recommended shell alias:
  alias claude='clause'

Explicit raw-Claude bypass:
  clause --clause-bypass

Default hard-stop thresholds are 90% for both windows. They may be lowered,
but Clause rejects values above 90:
  CLAUSE_5H_STOP=85 CLAUSE_7D_STOP=85 clause
MSG
