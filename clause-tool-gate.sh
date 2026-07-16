#!/usr/bin/env bash
# Mandatory Clause hook: proves hooks are active and blocks detached/token-amplifying tools.

set -uo pipefail

mode="${1:-}"
input="$(cat)"

if ! jq -e . >/dev/null 2>&1 <<<"$input"; then
    # Hook failure must not silently approve a tool call.
    if [[ "$mode" == "--pre-tool-use" ]]; then
        jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"Clause could not validate the tool call."}}'
    fi
    exit 0
fi

case "$mode" in
    --session-start)
        marker="${CLAUSE_HOOK_MARKER_FILE:-}"
        generation="${CLAUSE_GENERATION:-0}"
        run_id="${CLAUSE_RUN_ID:-}"
        [[ -n "$marker" ]] || exit 2
        mkdir -p "${marker%/*}"
        tmp="$(mktemp "${marker%/*}/.hook.XXXXXX")" || exit 2
        jq -n \
            --arg run_id "$run_id" \
            --argjson generation "$generation" \
            --argjson pid "$$" \
            --argjson updated_at "$(date +%s)" \
            '{run_id:$run_id,generation:$generation,hook_pid:$pid,updated_at:$updated_at}' >"$tmp" || exit 2
        chmod 600 "$tmp"
        mv -f "$tmp" "$marker"
        ;;

    --pre-tool-use)
        tool="$(jq -r '.tool_name // empty' <<<"$input")"
        deny_reason=''
        case "$tool" in
            Agent)
                subagent="$(jq -r '.tool_input.subagent_type // empty' <<<"$input")"
                model="$(jq -r '.tool_input.model // empty' <<<"$input")"
                background="$(jq -r '.tool_input.run_in_background // .tool_input.background // false' <<<"$input")"
                if [[ "$subagent" != "Explore" ]]; then
                    deny_reason="Clause permits only the bounded Haiku Explore subagent."
                elif [[ -n "$model" && "$model" != "haiku" ]]; then
                    deny_reason="Clause requires Explore to use Haiku."
                elif [[ "$background" == "true" ]]; then
                    deny_reason="Clause requires Explore to run in the foreground."
                fi
                ;;
            Bash)
                background="$(jq -r '.tool_input.run_in_background // false' <<<"$input")"
                command="$(jq -r '.tool_input.command // empty' <<<"$input")"
                if [[ "$background" == "true" ]]; then
                    deny_reason="Clause blocks background shell tasks because they can outlive supervision."
                elif grep -Eq '(^|[[:space:];|])(nohup|setsid|disown|daemonize|start-stop-daemon|systemd-run|at|batch|crontab|screen|tmux)([[:space:];|]|$)' <<<"$command"; then
                    deny_reason="Clause blocks detached or scheduled shell processes while fail-closed supervision is active."
                elif grep -Eq '(^|[^&>])&([^&]|$)' <<<"$command"; then
                    deny_reason="Clause blocks shell background operators while fail-closed supervision is active."
                elif grep -Eqi '(^|[[:space:];|/])(claude|claude-code|clause|claude-guard)([[:space:];|]|$)|(@anthropic-ai/claude-code|docker[[:space:]]+run[[:space:]]+[^;]*-[^;]*d|podman[[:space:]]+run[[:space:]]+[^;]*-[^;]*d)' <<<"$command"; then
                    deny_reason="Clause blocks nested or detached Claude/process launches from Bash."
                fi
                ;;
            PowerShell)
                deny_reason="Clause disables PowerShell because detached process behavior cannot be bounded portably."
                ;;
            Workflow|Monitor|CronCreate|RemoteTrigger|ScheduleWakeup|SendMessage)
                deny_reason="Clause blocks detached or scheduled tool execution while fail-closed supervision is active."
                ;;
        esac

        if [[ -n "$deny_reason" ]]; then
            jq -n --arg reason "$deny_reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
        fi
        ;;

    *)
        exit 2
        ;;
esac
