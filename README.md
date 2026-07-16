# Clause: Claude Code usage guard

Clause wraps Claude Code with automatic usage-limit protection and a token-efficient runtime profile.

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

At a configured threshold, Clause stops the active Claude Code process, waits for every blocking reset timestamp, and resumes the exact persisted session with a continuation prompt that first verifies repository state.

Set `CLAUDE_GUARD_AUTO_RESUME=0` to retain hard-stop behavior without automatic waiting or resumption.

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

Existing file-based settings remain loaded. In particular, Clause does not replace the installed status line, hooks, MCP configuration, or unrelated permission rules. Explicit Claude Code command-line flags retain their normal precedence.

For a resumed session, Clause reapplies compaction, workflow, verbosity, permission, and Explore-agent controls but omits model and effort defaults so an in-session `/model` or `/effort` selection survives the resume.

Disable only the optimization profile for one invocation:

```bash
claude-guard --guard-no-profile
```

Or with an environment variable:

```bash
CLAUDE_GUARD_OPTIMIZATION_PROFILE=0 claude-guard
```

Bypass Clause completely while retaining a shell alias from `claude` to `claude-guard`:

```bash
claude --guard-bypass
```

Arguments following `--guard-bypass` are forwarded directly to the real Claude Code executable.

The dynamic-workflow size setting requires Claude Code 2.1.202 or newer.
