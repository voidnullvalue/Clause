# Clause: Claude Code usage guard

Clause wraps Claude Code with automatic usage-limit protection, verified post-reset resumption, a token-efficient runtime profile, and an independent fail-closed supervisor.

## Install

```bash
./install-claude-guard-auto-resume.sh
```

After testing, the installer recommends:

```bash
alias claude='claude-guard'
```

## Run

```bash
CLAUDE_GUARD_5H_STOP=90 CLAUDE_GUARD_7D_STOP=90 claude-guard
```

At a configured threshold, Clause stops the active Claude Code process and waits until every blocking reset timestamp has passed. It then makes one non-persistent Haiku request to verify that Anthropic is actually accepting requests again. Only after that probe succeeds does it resume the exact persisted session.

A failed or timed-out reset probe does not resume the saved session. Clause retries with exponential backoff, starting at 30 seconds and capping at five minutes.

## Fail-closed supervision

The installed `claude-guard` command is an independent supervisor. The pause/probe/resume implementation is installed separately as `claude-guard-core`.

The supervisor terminates the guarded process tree and does **not** auto-resume when any of these occur:

- Status-line telemetry is missing or becomes stale.
- Rate-limit percentages never become available.
- Usage reaches a configured threshold but the core does not stop Claude promptly.
- The core crashes or exits while its Claude child remains alive.
- The supervisor itself receives a termination signal while guarded work is active.

Default supervisor tolerances:

```bash
CLAUDE_GUARD_TELEMETRY_STARTUP_GRACE_SECONDS=60
CLAUDE_GUARD_TELEMETRY_STALE_SECONDS=30
CLAUDE_GUARD_USAGE_DATA_GRACE_SECONDS=180
CLAUDE_GUARD_BLOCK_HANDLING_GRACE_SECONDS=15
```

Set `CLAUDE_GUARD_AUTO_RESUME=0` to retain the hard stop without automatic waiting or resumption.

Optional reset-probe controls:

```bash
CLAUDE_GUARD_RESET_PROBE_MODEL=haiku
CLAUDE_GUARD_RESET_PROBE_INITIAL_SECONDS=30
CLAUDE_GUARD_RESET_PROBE_MAX_SECONDS=300
CLAUDE_GUARD_RESET_PROBE_TIMEOUT_SECONDS=90
```

## Token-efficient runtime profile

Clause enables this session-only profile by default without modifying `~/.claude/settings.json`:

```json
{
  "model": "sonnet",
  "effortLevel": "medium",
  "autoCompactEnabled": true,
  "workflowSizeGuideline": "small",
  "verbose": false,
  "permissions": {
    "deny": [
      "Agent(general-purpose)"
    ]
  }
}
```

It also overrides the `Explore` subagent for the session with a narrowly scoped, read-only Haiku agent using low effort and only `Read`, `Grep`, and `Glob`.

Existing file-based settings remain loaded. Clause does not replace the installed status line, hooks, MCP configuration, or unrelated permission rules. For a resumed session, Clause omits model and effort defaults so an in-session `/model` or `/effort` selection survives.

Disable only the optimization profile:

```bash
claude-guard --guard-no-profile
```

Explicitly bypass both safety layers:

```bash
claude --guard-bypass
```

The dynamic-workflow size setting requires Claude Code 2.1.202 or newer.
