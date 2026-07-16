# Clause

Clause is a fail-closed foreground wrapper for Claude Code. It limits token-amplifying behavior, stops work at configured account-usage thresholds, verifies fresh below-threshold telemetry before launch or automatic resume, and preserves the exact guarded session.

## Install

```bash
./install-claude-guard-auto-resume.sh
```

The installer creates:

```text
~/.local/bin/clause
~/.local/libexec/clause/clause-core
~/.local/libexec/clause/clause-statusline.sh
~/.local/libexec/clause/clause-tool-gate.sh
```

It removes the old `claude-guard`, `claude-guard-core`, and `claude-guard-statusline.sh` executables. Update the shell alias after installation:

```bash
alias claude='clause'
```

## Usage

```bash
clause
clause --resume
clause --continue
```

Default thresholds are 90% for both the five-hour and seven-day windows. They can be lowered but not raised above 90:

```bash
CLAUSE_5H_STOP=85 CLAUSE_7D_STOP=85 clause
```

Disable automatic resume while retaining fail-closed stopping:

```bash
CLAUSE_AUTO_RESUME=0 clause
```

Only one Clause session may run at a time. A second invocation fails rather than allowing concurrent sessions to cross the account threshold together.

## Runtime profile

New sessions receive Sonnet with medium effort, automatic compaction, small workflow guidance, and non-verbose output. Resumed sessions retain the session's existing main model and effort.

Clause overrides `Explore` with a read-only Haiku definition limited to `Read`, `Grep`, and `Glob`, capped at eight turns. Background task functionality and experimental agent teams are disabled for every guarded launch. General-purpose and Plan subagents, Opus subagents, isolated subagents, dynamic workflows, monitors, scheduled prompts, remote triggers, background shell tasks, PowerShell, and inter-agent messaging are denied.

Disable only the optional model/compaction defaults:

```bash
CLAUSE_OPTIMIZATION_PROFILE=0 clause
```

Fail-closed supervision, foreground-only execution, the mandatory status line and hooks, background-task disabling, and bounded Haiku subagent controls remain active.

## Verified reset and fail-closed behavior

Clause requires both rate-limit windows to be present and below threshold before starting or resuming work. It launches a tool-disabled, non-persistent Haiku probe and waits for the status-line collector to publish fresh account telemetry. A successful text response alone is not accepted as reset proof.

Clause terminates the active Claude process and does not resume it when:

- guarded-session telemetry is missing, malformed, or stale;
- either rate-limit window is missing;
- a configured threshold is crossed and the core does not stop Claude promptly;
- the core or supervisor exits while Claude remains active;
- the supervisor heartbeat is lost;
- a reset probe times out or cannot produce fresh below-threshold telemetry;
- the mandatory SessionStart or PreToolUse hook layer is unavailable;
- an internal process-state record is malformed;
- a concurrent Clause invocation is attempted.

The mandatory PreToolUse gate also blocks background agents, background Bash calls, shell detachment operators and common daemon/scheduler commands, nested Claude launches, dynamic workflows, monitors, recurring prompts, remote triggers, PowerShell, and agent-team messaging.

The core is installed outside `PATH`, mode `0700`, and refuses execution unless its parent supervisor and per-run nonce match. The status-line collector independently kills the advertised Claude PID if the supervisor heartbeat disappears.

Print mode, background sessions, cloud/remote sessions, safe mode, permission-bypass flags, replacement settings/agent flags, and daemon-managed sessions are refused because they cannot retain Clause's required supervision invariants.

## Explicit bypass

Raw Claude is available only through an explicit flag:

```bash
clause --clause-bypass <claude arguments>
```

No environment-variable bypass exists. The old `claude-guard` executable is removed and no compatibility symlink is installed.

No userspace wrapper can protect against deliberate use of the raw `claude` binary, explicit `--clause-bypass`, deliberate replacement of the installed scripts, simultaneous usage from another machine or client, kernel failure, power loss, or deliberate `SIGKILL` of every enforcement process before any one of them can stop Claude. For normal `clause` execution, the identified software paths stop rather than continue.
