# claude-auto-resume

A foreground wrapper around `claude` that detects rate-limit exits, waits
until the reset time, and resumes the same session automatically — built
to be safe when running 10+ concurrent Claude Code sessions in parallel
tmux panes / terminals.

This is a multi-instance-safe fork of [karthiknitt/smart_resume](https://github.com/karthiknitt/smart_resume).

## What's different from smart_resume

| Concern | smart_resume | claude-auto-resume |
|---|---|---|
| `claude` binary path | Hardcoded to `/home/karthik/.local/bin/claude` | Auto-detected; honors `$CLAUDE_BIN` |
| Session pinning | Latest-mtime `.jsonl` in cwd | Diff of `*.jsonl` set before/after launch — exact UUID, race-free for two wrappers in the same cwd |
| Per-session visibility | None | `~/.claude/auto-resume/sessions/<uuid>.json` updated on every state change |
| Status command | None | `claude-resume-status` with table / `-w` watch / `--gc` / `--json` modes |
| Strictness | Mixed | `set -euo pipefail` |
| Naming collisions | Possible (date + cwd-slug) | Suffixed with first 6 chars of session UUID |
| `--dangerously-skip-permissions` | User must add manually | Injected by default; opt out with `CLAUDE_AUTO_RESUME_SAFE=1` |

What was kept as-is from upstream because it works:

- The `.rl_warn` flag-file fast path. Rate-limit values are account-global,
  so concurrent statusline ticks don't fight over the file's contents.
- The "claude in foreground, watcher in background" model — avoids the
  job-control gymnastics that backgrounded `claude` would need.
- The `tail | grep 'resets …('` JSONL detector. Reliable, cheap, terminator-free.

## Architecture

```
~/.claude/
  settings.json                     ← statusLine hook → statusline.sh
  .rl_warn                          ← shared, account-global, written by statusline
  auto-resume/                      ← install dir (symlinks → repo bin/)
    claude-auto-resume.sh
    statusline.sh
    claude-resume-status
    sessions/<uuid>.json            ← one file per active wrapper
  projects/<encoded-cwd>/<uuid>.jsonl   ← Claude Code's session transcripts
```

Per-wrapper lifecycle:

1. `claude-auto-resume.sh` snapshots the set of `*.jsonl` files in the
   current cwd's projects dir.
2. Launches `claude` in the foreground with a background watcher.
3. The watcher waits for `claude`'s PID to appear, then polls the
   *new* `.jsonl` file (the one that wasn't in the snapshot) every 5 s.
4. When it spots a `resets …(timestamp)` line, it sends `SIGINT` to claude.
5. Wrapper computes wake epoch from `.rl_warn` (fast path) or the JSONL
   line itself (fallback), writes `sessions/<uuid>.json`, sleeps until
   the reset, then re-execs `claude --resume <uuid>` with a continue
   prompt. Loop.
6. On exit (EXIT trap), the per-session state file is removed.

## Install

```bash
git clone git@github.com:pwnpanda/claude-auto-resume.git ~/git/priv/claude-auto-resume
cd ~/git/priv/claude-auto-resume
./install.sh

# Add to ~/.bashrc, ~/.zshrc, or ~/.zsh_alias:
alias claude="$HOME/.claude/auto-resume/claude-auto-resume.sh"
alias claude-safe="CLAUDE_AUTO_RESUME_SAFE=1 $HOME/.claude/auto-resume/claude-auto-resume.sh"
export PATH="$HOME/.claude/auto-resume:$PATH"
```

Reload your shell, then `claude` is the wrapped version.

## Usage

Run `claude` as usual — the wrapper is a drop-in. All flags pass through
(`-c`, `--resume <id>`, `-p "..."`, …).

Check status of all your concurrent sessions:

```
$ claude-resume-status
STATUS    ETA       NAME                              PID         CWD
------------------------------------------------------------------------------------------------
running   —         ar-2026-05-09-priv-thing-9f1e30   12345       ~/git/priv/some-repo
waiting   +00:42:18 ar-2026-05-09-cve-foo-a47c20      12389       ~/Hacking/CVE/Foo
resuming  —         ar-2026-05-09-bb-bar-b81d05       12612       ~/Hacking/Bugbounty/Bar
exited    —         ar-2026-05-09-priv-baz-c30f99     12707       ~/git/priv/baz
```

`claude-resume-status -w` watches; `--gc` cleans up state files for
wrappers whose PIDs are gone; `--json` dumps raw JSONL for piping.

## Troubleshooting

**"cannot locate the real 'claude' binary"** — set `CLAUDE_BIN`
explicitly in your shell rc, e.g. `export CLAUDE_BIN=/usr/local/bin/claude`.

**Statusline not updating rate-limit info** — make sure
`~/.claude/settings.json` has `statusLine.command` pointing at
`~/.claude/auto-resume/statusline.sh`. The installer patches this for
you unless you already had a custom statusline.

**A waiting wrapper never resumed** — check that the wake epoch in
`~/.claude/auto-resume/sessions/<uuid>.json` is sane. If your system
clock or the timezone parsing was off, the countdown may have completed
silently. Run `claude-resume-status --gc` to clear, then start fresh.

**Two terminals in the same project resumed the wrong sessions** — that
was the upstream bug this fork fixes. If you still see it, run with
`bash -x ~/.claude/auto-resume/claude-auto-resume.sh` and check the
diff-snapshot output: `snapshot_jsonl` should show the pre-launch set,
and the new `.jsonl` post-launch should be unambiguous.

## License

MIT. Original work © Karthikeyan N (smart_resume).
