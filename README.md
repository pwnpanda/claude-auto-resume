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

## Relocating a session to a different directory

`claude --resume <id>` looks for the transcript at
`~/.claude/projects/<encoded-cwd>/<id>.jsonl`, where encoded-cwd comes from
the cwd of the shell that originally launched `claude`. To move a recorded
conversation under a different working directory, use the
[claude-session-organizer](https://github.com/pwnpanda/claude-session-organizer)
companion repo's `move` subcommand:

```
~/.claude/skills/resume-session/scripts/session_registry.py move \
    <session-name> <new-cwd>
```

**Run this AFTER you've exited the live claude session.** A live session
rebinds the transcript to its launch-cwd and recreates the file at the
original path on the very next turn — any move you do mid-session is undone
within seconds. The `move` command enforces an mtime guard (refuses if the
transcript was modified in the last 300 s; override with `--live-mtime-secs`
or `--force`).

## Troubleshooting

**"cannot locate the real 'claude' binary"** — set `CLAUDE_BIN`
explicitly in your shell rc, e.g. `export CLAUDE_BIN=/usr/local/bin/claude`.

**Statusline not updating rate-limit info** — make sure
`~/.claude/settings.json` has `statusLine.command` pointing at
`~/.claude/auto-resume/statusline.sh`. The installer patches this for
you unless you already had a custom statusline.

**Rate limit hits but the wrapper does nothing / just waits** — modern
Claude Code (2.1.x+) shows an interactive `[wait | api key]` menu on a
rate limit instead of exiting; SIGINT is treated as a UI-cancel and
ignored, so the wrapper used to sit idle while claude waited on the
prompt. Current behaviour: when the rate-limit signal is detected the
wrapper tries to auto-pick "wait for limit" by injecting Enter, in
fallback order:

1. **Zellij** — if `$ZELLIJ_PANE_ID` was set at launch, focus that pane
   and `zellij action write 13`. Kernel-independent. This is the path
   your setup uses. Parallel-safe: the focus + write sequence is
   serialized across concurrent wrappers via a per-user flock at
   `${XDG_RUNTIME_DIR:-/tmp/claude-auto-resume-$UID}/zellij.lock`, so 10
   wrappers all hitting the rate limit at the same instant each press
   Enter in the correct pane.
2. **TIOCSTI ioctl** — direct kernel inject into claude's pty. Disabled
   by default on WSL2 + many distros via `dev.tty.legacy_tiocsti=0`
   (security hardening). Enable with `sudo sysctl dev.tty.legacy_tiocsti=1`
   if you want this path on a non-zellij setup.
3. **Force-kill chain** — SIGINT, then SIGTERM after 2 s, then SIGKILL
   after 5 s more. Wrapper takes over with its own countdown +
   `claude --resume <id>` resume. Always works but kills claude's UX.

Set `CLAUDE_AUTO_RESUME_NO_INJECT=1` to skip steps 1–2 and go straight
to the kill chain.

**Custom statusline + rate-limit auto-resume** — if you keep your own
statusline, the wrapper falls back to grepping the JSONL for the
rate-limit banner, which still works but is slower and less robust
than the `~/.claude/.rl_warn` flag-file fast path. To get both your
statusline AND the fast path, append this to your statusline script
(it reads the same stdin JSON Claude Code already passes you, so it
adds no extra cost):

```bash
# --- claude-auto-resume rate-limit flag (paste at the END of your statusline) ---
# Rewinds stdin so this works whether your script consumed $(cat) or not.
RL_WARN_FLAG="${HOME}/.claude/.rl_warn"
WARN_THRESHOLD_PCT=90
if command -v jq >/dev/null 2>&1 && [ -n "${stdin_data:-}" ]; then
    rl5p=$(echo "$stdin_data" | jq -r '.rate_limits.five_hour.used_percentage // empty')
    rl5r=$(echo "$stdin_data" | jq -r '.rate_limits.five_hour.resets_at        // empty')
    rl7p=$(echo "$stdin_data" | jq -r '.rate_limits.seven_day.used_percentage  // empty')
    rl7r=$(echo "$stdin_data" | jq -r '.rate_limits.seven_day.resets_at        // empty')
    if [ -n "$rl5p" ] && { [ "${rl5p%.*}" -ge "$WARN_THRESHOLD_PCT" ] \
                        || [ "${rl7p%.*}" -ge "$WARN_THRESHOLD_PCT" ]; }; then
        tmp="${RL_WARN_FLAG}.tmp.$$"
        printf '5h_pct=%s\n5h_reset=%s\n7d_pct=%s\n7d_reset=%s\nwritten_at=%s\n' \
            "${rl5p%.*}" "${rl5r:-0}" "${rl7p%.*}" "${rl7r:-0}" "$(date +%s)" \
            > "$tmp" && mv -f "$tmp" "$RL_WARN_FLAG"
    else
        rm -f "$RL_WARN_FLAG"
    fi
fi
```

Replace `stdin_data` with whatever variable holds your statusline's
captured JSON input. After adding it, the wrapper picks the wake
epoch directly from `~/.claude/.rl_warn` instead of parsing the JSONL.

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
