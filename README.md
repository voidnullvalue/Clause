# Claude Guard: automatic usage pause and resume

Install:

```bash
./install-claude-guard-auto-resume.sh
```

Run:

```bash
CLAUDE_GUARD_5H_STOP=90 CLAUDE_GUARD_7D_STOP=90 claude-guard
```

At the threshold, the wrapper exits the active Claude Code process, waits for all blocking reset timestamps, and resumes the exact persisted session with a continuation prompt that first verifies repository state.

Set `CLAUDE_GUARD_AUTO_RESUME=0` to retain hard-stop behavior without automatic waiting/resumption.
