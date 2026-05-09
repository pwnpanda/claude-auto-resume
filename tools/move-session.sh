#!/usr/bin/env bash
# move-session.sh — relocate a Claude Code session's transcript to a new cwd.
#
# Why this exists:
#   `claude --resume <id>` looks for the transcript at
#   ~/.claude/projects/<encoded-cwd>/<id>.jsonl, where encoded-cwd is derived
#   from the cwd of the SHELL that originally launched `claude`. To move a
#   recorded conversation under a different working directory, the JSONL has
#   to be rewritten under that directory's encoded path.
#
#   Doing this on a LIVE session is unsafe: the running claude rebinds the
#   transcript to its launch-cwd and recreates the file at the original path
#   on the next turn. Run this only AFTER you have exited the session.
#
# Usage:
#   tools/move-session.sh <session-name> <new-cwd>
#   tools/move-session.sh Claude-auto-resume /home/robin/git/priv/claude-auto-resume
#
# What it does:
#   1. Looks up the session in ~/.claude/session-names/index.json by name.
#   2. Confirms the live transcript is at the OLD encoded-cwd.
#   3. Moves the JSONL to the NEW encoded-cwd dir (creates if missing).
#   4. Rewrites the embedded "cwd" fields so resume-cmd shows the new path.
#   5. Re-registers the session under the new cwd.
#
# Idempotent: re-running on an already-migrated session is a no-op + warning.

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <session-name> <new-cwd>" >&2
    exit 2
fi

NAME="$1"
NEW_CWD="$2"
INDEX="${HOME}/.claude/session-names/index.json"
PROJECTS_DIR="${HOME}/.claude/projects"
REGISTRY_PY="${HOME}/.claude/skills/resume-session/scripts/session_registry.py"

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
[[ -f "$INDEX" ]] || { echo "registry not found: $INDEX" >&2; exit 1; }
[[ -x "$REGISTRY_PY" || -f "$REGISTRY_PY" ]] || { echo "registry tool not found: $REGISTRY_PY" >&2; exit 1; }

NEW_CWD=$(realpath -m "$NEW_CWD")
[[ -d "$NEW_CWD" ]] || { echo "new cwd does not exist: $NEW_CWD" >&2; exit 1; }

SID=$(jq -r --arg n "$NAME" '.[$n].session_id // empty' "$INDEX")
OLD_CWD=$(jq -r --arg n "$NAME" '.[$n].cwd // empty' "$INDEX")
[[ -n "$SID" ]] || { echo "no session named '$NAME' in registry" >&2; exit 1; }
[[ -n "$OLD_CWD" ]] || { echo "registry entry for '$NAME' has no cwd" >&2; exit 1; }

if [[ "$OLD_CWD" == "$NEW_CWD" ]]; then
    echo "registry already shows cwd=$NEW_CWD; nothing to do."
    exit 0
fi

encode_cwd() { printf '%s\n' "$1" | sed 's|/|-|g'; }

OLD_ENC=$(encode_cwd "$OLD_CWD")
NEW_ENC=$(encode_cwd "$NEW_CWD")
OLD_FILE="${PROJECTS_DIR}/${OLD_ENC}/${SID}.jsonl"
NEW_FILE="${PROJECTS_DIR}/${NEW_ENC}/${SID}.jsonl"

# ---------------------------------------------------------------------------
# Safety checks
# ---------------------------------------------------------------------------
[[ -f "$OLD_FILE" ]] || { echo "transcript not at expected old path: $OLD_FILE" >&2; exit 1; }

# Recent-mtime guard. Claude Code does NOT keep the JSONL open between turns
# (open-write-close per turn), so a /proc-fd scan alone is unreliable. Refuse
# instead if the file was modified in the last LIVE_MTIME_SECS — that's the
# strongest signal a session is still running.
LIVE_MTIME_SECS="${LIVE_MTIME_SECS:-300}"
file_mtime=$(stat -c %Y -- "$OLD_FILE")
now=$(date +%s)
age=$(( now - file_mtime ))
if (( age < LIVE_MTIME_SECS )); then
    echo "ABORT: transcript was modified ${age}s ago — the session is likely still live." >&2
    echo "Exit the claude session, then wait until no new turns are happening before re-running." >&2
    echo "(Override threshold with LIVE_MTIME_SECS=<seconds>; defaults to 300.)" >&2
    exit 1
fi

# Defence-in-depth: also refuse if anything has the file open.
in_use_by_pid=""
if command -v lsof >/dev/null 2>&1; then
    in_use_by_pid=$(lsof -t -- "$OLD_FILE" 2>/dev/null | head -1 || true)
else
    for pid_dir in /proc/[0-9]*; do
        pid=$(basename "$pid_dir")
        for fd_link in "$pid_dir"/fd/*; do
            [[ -L "$fd_link" ]] || continue
            target=$(readlink -- "$fd_link" 2>/dev/null) || continue
            if [[ "$target" == "$OLD_FILE" ]]; then
                in_use_by_pid="$pid"
                break 2
            fi
        done
    done
fi
if [[ -n "$in_use_by_pid" ]]; then
    echo "ABORT: the transcript is currently open by PID $in_use_by_pid." >&2
    echo "Exit the live claude session first, then re-run this script." >&2
    exit 1
fi

if [[ -e "$NEW_FILE" ]]; then
    echo "ABORT: a transcript already exists at $NEW_FILE — refusing to overwrite." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Move + rewrite cwd fields + re-register
# ---------------------------------------------------------------------------
mkdir -p "${PROJECTS_DIR}/${NEW_ENC}"
mv "$OLD_FILE" "$NEW_FILE"
echo "moved: $OLD_FILE -> $NEW_FILE"

python3 - "$NEW_FILE" "$OLD_CWD" "$NEW_CWD" <<'PY'
import json, os, re, sys
path, old_cwd, new_cwd = sys.argv[1], sys.argv[2], sys.argv[3]

# Match exact JSON cwd field; tolerant of optional whitespace before the value.
pattern = re.compile(
    r'"cwd":\s*' + re.escape(json.dumps(old_cwd))
)
replacement = '"cwd":' + json.dumps(new_cwd)

with open(path, "r", encoding="utf-8", errors="replace") as f:
    content = f.read()
new_content, n = pattern.subn(replacement, content)
print(f"rewrote {n} cwd field(s)")

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(new_content)
os.replace(tmp, path)
PY

python3 "$REGISTRY_PY" register "$NAME" --session-id "$SID" --cwd "$NEW_CWD"

# Verify
echo
echo "Verification:"
python3 "$REGISTRY_PY" resume-cmd "$NAME"
