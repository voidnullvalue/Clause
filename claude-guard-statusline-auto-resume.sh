#!/usr/bin/env bash
# Clause status-line collector. Publishes per-run and shared rate-limit telemetry.

set -uo pipefail

STATE_DIR="${CLAUSE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/clause}"
STATE_FILE="$STATE_DIR/usage.json"
LOCK_FILE="$STATE_DIR/usage.lock"
LOG_FILE="$STATE_DIR/clause.log"
RUN_DIR="${CLAUSE_RUN_DIR:-}"
GENERATION="${CLAUSE_GENERATION:-0}"
PROBE_FILE="${CLAUSE_PROBE_TELEMETRY_FILE:-}"
PROBE_GENERATION="${CLAUSE_PROBE_GENERATION:-0}"
FIVE_HOUR_STOP="${CLAUSE_5H_STOP:-90}"
SEVEN_DAY_STOP="${CLAUSE_7D_STOP:-90}"
HEARTBEAT_STALE_SECONDS=5

mkdir -p "$STATE_DIR"
input="$(cat)"
now="$(date +%s)"

if ! jq -e . >/dev/null 2>&1 <<<"$input"; then
    printf 'clause: waiting for valid telemetry\n'
    exit 0
fi

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
children_of() { pgrep -P "$1" 2>/dev/null || true; }
signal_tree() {
    local sig="$1" pid="$2" child
    while read -r child; do
        [[ -n "$child" ]] && signal_tree "$sig" "$child"
    done < <(children_of "$pid")
    kill "-$sig" "$pid" 2>/dev/null || true
}

# Third-layer fail-closed behavior: if both wrapper processes disappear or the
# supervisor heartbeat stalls, the status line kills the advertised active
# Claude process rather than continuing without enforcement.
if [[ -n "$RUN_DIR" && -s "$RUN_DIR/instance.json" ]]; then
    heartbeat_ok=0
    if [[ -s "$RUN_DIR/supervisor-heartbeat.json" ]] \
        && jq -e . "$RUN_DIR/supervisor-heartbeat.json" >/dev/null 2>&1; then
        supervisor_pid="$(jq -r '.supervisor_pid // 0' "$RUN_DIR/supervisor-heartbeat.json")"
        heartbeat_updated="$(jq -r '.updated_at // 0' "$RUN_DIR/supervisor-heartbeat.json")"
        if is_uint "$supervisor_pid" && (( supervisor_pid > 1 )) \
            && is_uint "$heartbeat_updated" && (( heartbeat_updated > 0 )) \
            && kill -0 "$supervisor_pid" 2>/dev/null \
            && (( now - heartbeat_updated <= HEARTBEAT_STALE_SECONDS )); then
            heartbeat_ok=1
        fi
    fi
    if (( heartbeat_ok == 0 )); then
        active_pid="$(jq -r '.active_pid // 0' "$RUN_DIR/instance.json" 2>/dev/null)"
        if is_uint "$active_pid" && (( active_pid > 1 )) && kill -0 "$active_pid" 2>/dev/null; then
            printf '%s action=statusline_fail_closed active_pid=%s\n' "$(date --iso-8601=seconds)" "$active_pid" >>"$LOG_FILE"
            signal_tree TERM "$active_pid"
            sleep 2
            kill -0 "$active_pid" 2>/dev/null && signal_tree KILL "$active_pid"
        fi
        printf 'clause: FAIL CLOSED — supervisor heartbeat lost\n'
        exit 0
    fi
fi

session_id="$(jq -r '.session_id // "unknown"' <<<"$input")"
session_name="$(jq -r '.session_name // empty' <<<"$input")"
transcript_path="$(jq -r '.transcript_path // empty' <<<"$input")"
project_dir="$(jq -r '.workspace.project_dir // .cwd // empty' <<<"$input")"
model_id="$(jq -r '.model.id // empty' <<<"$input")"
model_name="$(jq -r '.model.display_name // empty' <<<"$input")"
effort="$(jq -r '.effort.level // empty' <<<"$input")"
prompt_id="$(jq -r '.prompt_id // empty' <<<"$input")"
five_pct="$(jq -c '.rate_limits.five_hour.used_percentage // null' <<<"$input")"
five_reset="$(jq -c '.rate_limits.five_hour.resets_at // null' <<<"$input")"
seven_pct="$(jq -c '.rate_limits.seven_day.used_percentage // null' <<<"$input")"
seven_reset="$(jq -c '.rate_limits.seven_day.resets_at // null' <<<"$input")"

write_telemetry() {
    local target="$1" generation="$2" tmp
    tmp="$(mktemp "${target%/*}/.telemetry.XXXXXX")" || return 1
    jq -n \
        --argjson updated_at "$now" \
        --argjson generation "$generation" \
        --arg session_id "$session_id" \
        --arg prompt_id "$prompt_id" \
        --arg model_id "$model_id" \
        --arg model_name "$model_name" \
        --arg effort "$effort" \
        --argjson five_pct "$five_pct" \
        --argjson five_reset "$five_reset" \
        --argjson seven_pct "$seven_pct" \
        --argjson seven_reset "$seven_reset" \
        '{updated_at:$updated_at,generation:$generation,session_id:$session_id,prompt_id:$prompt_id,model:{id:$model_id,name:$model_name},effort:$effort,five_hour:{used_percentage:$five_pct,resets_at:$five_reset},seven_day:{used_percentage:$seven_pct,resets_at:$seven_reset}}' \
        >"$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp"
    mv -f "$tmp" "$target"
}

if [[ -n "$PROBE_FILE" ]]; then
    mkdir -p "${PROBE_FILE%/*}"
    write_telemetry "$PROBE_FILE" "$PROBE_GENERATION" || true
elif [[ -n "$RUN_DIR" ]]; then
    mkdir -p "$RUN_DIR"
    write_telemetry "$RUN_DIR/telemetry.json" "$GENERATION" || true
    session_tmp="$(mktemp "$RUN_DIR/.session.XXXXXX")"
    jq -n \
        --arg session_id "$session_id" \
        --arg session_name "$session_name" \
        --arg transcript_path "$transcript_path" \
        --arg project_dir "$project_dir" \
        --arg model_id "$model_id" \
        --arg model_name "$model_name" \
        --arg effort "$effort" \
        --argjson updated_at "$now" \
        '{session_id:$session_id,session_name:$session_name,transcript_path:$transcript_path,project_dir:$project_dir,model:{id:$model_id,name:$model_name},effort:$effort,updated_at:$updated_at}' \
        >"$session_tmp"
    chmod 600 "$session_tmp"
    mv -f "$session_tmp" "$RUN_DIR/session.json"
fi

# Shared state is account-level. Missing windows are written as null rather than
# retaining stale percentages and falsely presenting them as fresh.
exec 9>"$LOCK_FILE"
flock -x 9
shared_tmp="$(mktemp "$STATE_DIR/.usage.XXXXXX")"
jq -n \
    --argjson updated_at "$now" \
    --arg session_id "$session_id" \
    --arg model_id "$model_id" \
    --arg model_name "$model_name" \
    --argjson five_pct "$five_pct" \
    --argjson five_reset "$five_reset" \
    --argjson seven_pct "$seven_pct" \
    --argjson seven_reset "$seven_reset" \
    '{updated_at:$updated_at,last_session_id:$session_id,last_model:{id:$model_id,name:$model_name},five_hour:{used_percentage:$five_pct,resets_at:$five_reset},seven_day:{used_percentage:$seven_pct,resets_at:$seven_reset}}' \
    >"$shared_tmp"
chmod 600 "$shared_tmp"
mv -f "$shared_tmp" "$STATE_FILE"
flock -u 9

fmt_pct() {
    local value="$1"
    [[ "$value" == null ]] && printf '?' || printf '%.1f' "$value" 2>/dev/null || printf '%s' "$value"
}
fmt_reset() {
    local value="$1"
    if is_uint "$value" && (( value > 0 )); then
        date -d "@$value" '+%a %l:%M%P' 2>/dev/null | sed 's/  */ /g'
    else
        printf '?'
    fi
}

five_display="$(fmt_pct "$five_pct")"
seven_display="$(fmt_pct "$seven_pct")"
if [[ "$five_pct" == null || "$seven_pct" == null ]]; then
    printf 'clause: waiting for both rate-limit windows\n'
elif awk -v f="$five_pct" -v s="$seven_pct" -v ft="$FIVE_HOUR_STOP" -v st="$SEVEN_DAY_STOP" 'BEGIN { exit !((f >= ft) || (s >= st)) }'; then
    printf 'CLAUSE PAUSE | 5h %s%%/%s reset %s | 7d %s%%/%s reset %s\n' \
        "$five_display" "$FIVE_HOUR_STOP" "$(fmt_reset "$five_reset")" \
        "$seven_display" "$SEVEN_DAY_STOP" "$(fmt_reset "$seven_reset")"
else
    printf 'clause | 5h %s%%/%s reset %s | 7d %s%%/%s reset %s\n' \
        "$five_display" "$FIVE_HOUR_STOP" "$(fmt_reset "$five_reset")" \
        "$seven_display" "$SEVEN_DAY_STOP" "$(fmt_reset "$seven_reset")"
fi
