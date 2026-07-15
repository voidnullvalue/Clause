#!/usr/bin/env bash
# Claude Code statusLine collector for claude-guard.
# Reads Claude Code JSON on stdin, stores shared rate-limit state atomically,
# records the exact guarded session ID, and prints a compact status line.

set -uo pipefail

STATE_DIR="${CLAUDE_GUARD_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-guard}"
STATE_FILE="$STATE_DIR/usage.json"
LOCK_FILE="$STATE_DIR/usage.lock"
INSTANCES_DIR="$STATE_DIR/instances"
LOG_FILE="$STATE_DIR/guard.log"
FIVE_HOUR_STOP="${CLAUDE_GUARD_5H_STOP:-95}"
SEVEN_DAY_STOP="${CLAUDE_GUARD_7D_STOP:-95}"
INSTANCE_ID="${CLAUDE_GUARD_INSTANCE_ID:-}"

mkdir -p "$STATE_DIR" "$INSTANCES_DIR"
input="$(cat)"
now="$(date +%s)"

# Never break Claude Code's UI because of malformed or incomplete status data.
if ! jq -e . >/dev/null 2>&1 <<<"$input"; then
    printf 'claude-guard: waiting for valid usage data\n'
    exit 0
fi

session_id="$(jq -r '.session_id // "unknown"' <<<"$input")"
session_name="$(jq -r '.session_name // empty' <<<"$input")"
transcript_path="$(jq -r '.transcript_path // empty' <<<"$input")"
project_dir="$(jq -r '.workspace.project_dir // .cwd // empty' <<<"$input")"
five_pct="$(jq -c '.rate_limits.five_hour.used_percentage // null' <<<"$input")"
five_reset="$(jq -c '.rate_limits.five_hour.resets_at // null' <<<"$input")"
seven_pct="$(jq -c '.rate_limits.seven_day.used_percentage // null' <<<"$input")"
seven_reset="$(jq -c '.rate_limits.seven_day.resets_at // null' <<<"$input")"

# Save per-wrapper session identity before publishing the shared usage update.
# This ordering prevents the watchdog from observing a new block before it can
# learn which exact Claude session must later be resumed.
if [[ -n "$INSTANCE_ID" && "$session_id" != "unknown" ]]; then
    session_file="$INSTANCES_DIR/$INSTANCE_ID.session.json"
    session_lock="$INSTANCES_DIR/$INSTANCE_ID.session.lock"
    exec 8>"$session_lock"
    flock -x 8
    session_tmp="$(mktemp "$INSTANCES_DIR/.session.XXXXXX")"
    jq -n \
        --arg session_id "$session_id" \
        --arg session_name "$session_name" \
        --arg transcript_path "$transcript_path" \
        --arg project_dir "$project_dir" \
        --argjson updated_at "$now" \
        '{session_id:$session_id, session_name:$session_name, transcript_path:$transcript_path, project_dir:$project_dir, updated_at:$updated_at}' \
        >"$session_tmp"
    chmod 600 "$session_tmp"
    mv -f "$session_tmp" "$session_file"
    flock -u 8
fi

# Serialize writers from concurrent Claude sessions, then atomically replace
# shared account-level rate-limit state.
exec 9>"$LOCK_FILE"
flock -x 9

if [[ -s "$STATE_FILE" ]] && jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    old_state="$(cat "$STATE_FILE")"
else
    old_state='{}'
fi

tmp_file="$(mktemp "$STATE_DIR/.usage.XXXXXX")"
jq -n \
    --argjson old "$old_state" \
    --arg session_id "$session_id" \
    --argjson now "$now" \
    --argjson five_pct "$five_pct" \
    --argjson five_reset "$five_reset" \
    --argjson seven_pct "$seven_pct" \
    --argjson seven_reset "$seven_reset" \
    --argjson five_stop "$FIVE_HOUR_STOP" \
    --argjson seven_stop "$SEVEN_DAY_STOP" '
    $old
    | .updated_at = $now
    | .last_session_id = $session_id
    | .thresholds.five_hour = $five_stop
    | .thresholds.seven_day = $seven_stop
    | if $five_pct != null then .five_hour.used_percentage = $five_pct else . end
    | if $five_reset != null then .five_hour.resets_at = $five_reset else . end
    | if $seven_pct != null then .seven_day.used_percentage = $seven_pct else . end
    | if $seven_reset != null then .seven_day.resets_at = $seven_reset else . end
    | .blocked = (
        (((.five_hour.resets_at // 0) > $now)
          and ((.five_hour.used_percentage // 0) >= $five_stop))
        or
        (((.seven_day.resets_at // 0) > $now)
          and ((.seven_day.used_percentage // 0) >= $seven_stop))
      )
    | .block_reason = (
        if (((.five_hour.resets_at // 0) > $now)
            and ((.five_hour.used_percentage // 0) >= $five_stop))
           and (((.seven_day.resets_at // 0) > $now)
            and ((.seven_day.used_percentage // 0) >= $seven_stop))
        then "five_hour+seven_day"
        elif (((.five_hour.resets_at // 0) > $now)
            and ((.five_hour.used_percentage // 0) >= $five_stop))
        then "five_hour"
        elif (((.seven_day.resets_at // 0) > $now)
              and ((.seven_day.used_percentage // 0) >= $seven_stop))
        then "seven_day"
        else null
        end
      )
    | .blocked_until = (
        if .block_reason == "five_hour+seven_day"
        then ([.five_hour.resets_at, .seven_day.resets_at] | max)
        elif .block_reason == "five_hour" then .five_hour.resets_at
        elif .block_reason == "seven_day" then .seven_day.resets_at
        else null
        end
      )
' >"$tmp_file"

chmod 600 "$tmp_file"
mv -f "$tmp_file" "$STATE_FILE"
flock -u 9

blocked="$(jq -r '.blocked // false' "$STATE_FILE")"
reason="$(jq -r '.block_reason // empty' "$STATE_FILE")"
blocked_until="$(jq -r '.blocked_until // 0' "$STATE_FILE")"

if [[ "$blocked" == "true" ]]; then
    printf '%s session=%s action=block reason=%s blocked_until=%s\n' \
        "$(date --iso-8601=seconds)" "$session_id" "$reason" "$blocked_until" >>"$LOG_FILE"
fi

fmt_reset() {
    local epoch="$1"
    if [[ "$epoch" =~ ^[0-9]+$ ]] && (( epoch > 0 )); then
        date -d "@$epoch" '+%a %l:%M%P' 2>/dev/null | sed 's/  */ /g'
    else
        printf '?'
    fi
}

fmt_pct() {
    local value="$1"
    if [[ "$value" == "null" ]]; then
        printf '?'
    else
        printf '%.1f' "$value" 2>/dev/null || printf '%s' "$value"
    fi
}

five_display="$(fmt_pct "$five_pct")"
seven_display="$(fmt_pct "$seven_pct")"

if [[ "$five_pct" == "null" && "$seven_pct" == "null" ]]; then
    printf 'claude-guard: usage data appears after the first API response\n'
elif [[ "$blocked" == "true" ]]; then
    printf 'PAUSE %s | 5h %s%% reset %s | 7d %s%% reset %s\n' \
        "$reason" "$five_display" "$(fmt_reset "$five_reset")" \
        "$seven_display" "$(fmt_reset "$seven_reset")"
else
    printf 'guard 5h %s%%/%s reset %s | 7d %s%%/%s reset %s\n' \
        "$five_display" "$FIVE_HOUR_STOP" "$(fmt_reset "$five_reset")" \
        "$seven_display" "$SEVEN_DAY_STOP" "$(fmt_reset "$seven_reset")"
fi
