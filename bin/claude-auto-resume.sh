#!/usr/bin/env bash
# claude-auto-resume.sh
#
# Foreground wrapper around `claude` that detects rate-limit exits, waits
# until the reset epoch, and resumes the SAME session automatically.
#
# This is a multi-instance-safe fork of karthiknitt/smart_resume:
#   1. Auto-detects the `claude` binary instead of hardcoding a path.
#   2. Pins the session UUID by diffing the projects-dir BEFORE/AFTER
#      claude starts, so two wrappers running in the same cwd never
#      latch onto each other's JSONL.
#   3. Writes per-session state to ~/.claude/auto-resume/sessions/<uuid>.json
#      so the `claude-resume-status` command can list active wrappers.
#   4. set -euo pipefail throughout.
#
# Usage (after install):
#   alias claude="$HOME/.claude/auto-resume/claude-auto-resume.sh"
#   claude            # any args you'd pass to claude
#
# License: MIT (see LICENSE). Original work © Karthikeyan N.

set -euo pipefail

PROJECTS_DIR="${HOME}/.claude/projects"
STATE_DIR="${HOME}/.claude/auto-resume/sessions"
RL_WARN_FLAG="${HOME}/.claude/.rl_warn"
BUFFER_SECS=60
WATCHER_POLL_SECS=5

mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------------------
# Resolve the real `claude` binary.
#
# We can't trust `which claude` because the user is expected to alias claude
# to this wrapper — that would recurse. Look for the real binary in the
# usual install locations, then fall back to scanning PATH for an entry
# that isn't this script.
# ---------------------------------------------------------------------------
resolve_claude_bin() {
  if [[ -n "${CLAUDE_BIN:-}" && -x "$CLAUDE_BIN" ]]; then
    printf '%s\n' "$CLAUDE_BIN"
    return
  fi
  local self_real
  self_real=$(readlink -f "$0" 2>/dev/null || echo "$0")
  local candidates=(
    "$HOME/.claude/local/claude"
    "$HOME/.local/bin/claude"
    "/usr/local/bin/claude"
    "/opt/homebrew/bin/claude"
  )
  local c
  for c in "${candidates[@]}"; do
    [[ -x "$c" ]] && { printf '%s\n' "$c"; return; }
  done
  # Fallback: scan PATH for any `claude` that isn't us.
  local IFS=:
  for p in $PATH; do
    c="$p/claude"
    [[ -x "$c" ]] || continue
    local c_real
    c_real=$(readlink -f "$c" 2>/dev/null || echo "$c")
    [[ "$c_real" != "$self_real" ]] && { printf '%s\n' "$c"; return; }
  done
  echo "claude-auto-resume: cannot locate the real 'claude' binary." >&2
  echo "  Set CLAUDE_BIN=/path/to/claude in your shell rc and retry." >&2
  exit 127
}

CLAUDE_BIN=$(resolve_claude_bin)

# ---------------------------------------------------------------------------
# UI helpers — all to stderr so they never corrupt --print output.
# ---------------------------------------------------------------------------
_msg_rl_hit() {
  local name="$1" reset_epoch="$2" wake_epoch="$3"
  local bar='──────────────────────────────────────────────────────────────────'
  printf '\n  \e[1;33m⚡ Rate limit hit\e[0m\n' >&2
  printf '  \e[2m%s\e[0m\n' "$bar" >&2
  printf '  \e[2mSession\e[0m  \e[33m"%s"\e[0m\n' "$name" >&2
  printf '  \e[2mResets \e[0m  \e[32m%s\e[0m\n' \
    "$(date -d "@${reset_epoch}" '+%H:%M:%S %Z  (%Y-%m-%d)')" >&2
  printf '  \e[2mWaking \e[0m  \e[32m%s\e[0m  \e[2m(+%ds buffer)\e[0m\n' \
    "$(date -d "@${wake_epoch}" '+%H:%M:%S %Z')" "$BUFFER_SECS" >&2
  printf '  \e[2m%s\e[0m\n' "$bar" >&2
  printf '  \e[2mPress Ctrl-C to cancel\e[0m\n\n' >&2
}

_msg_resuming() {
  local name="$1"
  printf '\n  \e[1;32m✓ Resuming\e[0m  \e[33m"%s"\e[0m\n\n' "$name" >&2
}

# ---------------------------------------------------------------------------
# Session-discovery helpers
# ---------------------------------------------------------------------------
encoded_cwd() { pwd | sed 's|/|-|g; s|^-||'; }

# Snapshot the set of *.jsonl files in the cwd's projects dir. Used to diff
# before/after claude starts so we can pin the new session UUID exactly.
snapshot_jsonl() {
  local enc; enc=$(encoded_cwd)
  local dir="${PROJECTS_DIR}/${enc}"
  [[ -d "$dir" ]] || return 0
  find "$dir" -maxdepth 1 -name '*.jsonl' -type f -printf '%f\n' 2>/dev/null | sort
}

# Compare a pre-snapshot to current state and return the path of the new file.
# Returns empty if no new file found yet.
diff_for_new_session() {
  local pre_snapshot="$1"
  local enc; enc=$(encoded_cwd)
  local dir="${PROJECTS_DIR}/${enc}"
  [[ -d "$dir" ]] || return 0
  local current; current=$(find "$dir" -maxdepth 1 -name '*.jsonl' -type f -printf '%f\n' 2>/dev/null | sort)
  local new_file
  new_file=$(comm -13 <(echo "$pre_snapshot") <(echo "$current") | head -1)
  [[ -n "$new_file" ]] && printf '%s/%s\n' "$dir" "$new_file"
}

# Latest-mtime fallback (used when resuming an existing session — claude
# doesn't create a new file, it appends to the existing one).
latest_jsonl_in_cwd() {
  local enc; enc=$(encoded_cwd)
  local dir="${PROJECTS_DIR}/${enc}"
  [[ -d "$dir" ]] || return 0
  find "$dir" -maxdepth 1 -name '*.jsonl' -type f -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-
}

# ---------------------------------------------------------------------------
# Reset-time parsing — unchanged from upstream design but stripped of
# next-day-rollover guesswork: the JSONL line in current Claude Code builds
# always carries a full date, so a past epoch is a hard error.
# ---------------------------------------------------------------------------
get_reset_info() {
  local session_file="$1" start_line="${2:-1}"
  local reset_line
  reset_line=$(tail -n "+${start_line}" "$session_file" 2>/dev/null \
    | grep -i 'resets .*(' | tail -1)
  [[ -z "$reset_line" ]] && return 0
  local reset_time reset_tz
  reset_time=$(echo "$reset_line" | grep -oP '(?i)resets \K[^(]+' | sed 's/[[:space:]]*$//')
  reset_tz=$(echo "$reset_line"   | grep -oP '\([^)]+\)' | tr -d '()')
  [[ -n "$reset_time" && -n "$reset_tz" ]] && echo "${reset_time} ${reset_tz}" || true
}

parse_reset_epoch() {
  local reset_time="$1" reset_tz="$2"
  local reset_epoch now_epoch
  reset_epoch=$(TZ="$reset_tz" date -d "$reset_time" +%s 2>/dev/null) || return 1
  now_epoch=$(date +%s)
  if (( reset_epoch <= now_epoch )); then
    if [[ "${reset_time,,}" =~ ^[0-9]+:[0-9]+[apm]+$ ]]; then
      reset_epoch=$(( reset_epoch + 86400 ))   # bare time → next day
    else
      return 1
    fi
  fi
  echo "$reset_epoch"
}

# Read pre-computed reset epoch from statusline.sh's flag file.
# Returns 0 epoch (= no signal) on any parse trouble.
read_warn_flag_epoch() {
  [[ -f "$RL_WARN_FLAG" ]] || { echo 0; return; }
  local rl5p rl5r rl7p rl7r
  rl5p=$(awk -F= '/^5h_pct=/{print $2}'   "$RL_WARN_FLAG" 2>/dev/null)
  rl5r=$(awk -F= '/^5h_reset=/{print $2}' "$RL_WARN_FLAG" 2>/dev/null)
  rl7p=$(awk -F= '/^7d_pct=/{print $2}'   "$RL_WARN_FLAG" 2>/dev/null)
  rl7r=$(awk -F= '/^7d_reset=/{print $2}' "$RL_WARN_FLAG" 2>/dev/null)
  local pick=0
  if (( ${rl5p:-0} >= ${rl7p:-0} )); then
    pick=${rl5r:-0}
  else
    pick=${rl7r:-0}
  fi
  # Stale check: ignore epochs already in the past.
  (( pick <= $(date +%s) )) && pick=0
  echo "$pick"
}

# ---------------------------------------------------------------------------
# Naming. Suffix with the first 6 chars of the session UUID so two sessions
# in the same cwd on the same day don't clash.
# ---------------------------------------------------------------------------
generate_name() {
  local session_id="$1"
  local date_tag cwd_slug uuid_tag
  date_tag=$(date '+%Y-%m-%d')
  cwd_slug=$(pwd | awk -F/ '{n=NF; if(n>=2) printf "%s-%s", $(n-1), $n; else print $n}' \
    | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')
  uuid_tag=${session_id:0:6}
  echo "ar-${date_tag}-${cwd_slug}-${uuid_tag}"
}

get_session_name() {
  grep -F '"type":"custom-title"' "$1" 2>/dev/null \
    | tail -1 | grep -oP '"customTitle":"\K[^"]+' || true
}

name_session() {
  local session_file="$1" session_id="$2" name="$3"
  printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' \
    "$name" "$session_id" >> "$session_file"
}

# ---------------------------------------------------------------------------
# Per-session state file. Lets `claude-resume-status` enumerate live wrappers.
# ---------------------------------------------------------------------------
state_file_for() { printf '%s/%s.json\n' "$STATE_DIR" "$1"; }

write_state() {
  local session_id="$1" name="$2" status="$3" wake_epoch="${4:-0}"
  local f; f=$(state_file_for "$session_id")
  printf '{"session_id":"%s","name":"%s","cwd":"%s","status":"%s","wrapper_pid":%d,"wake_epoch":%d,"updated_at":%d}\n' \
    "$session_id" "$name" "$(pwd)" "$status" "$$" "$wake_epoch" "$(date +%s)" > "$f"
}

remove_state() {
  local session_id="$1"
  rm -f "$(state_file_for "$session_id")"
}

# ---------------------------------------------------------------------------
# JSONL watcher. Polls the pinned session file; SIGINT claude when it sees
# a "resets …(" entry. The pinned-file model is the key parallel-safety
# improvement vs upstream — the watcher never re-discovers via mtime.
# ---------------------------------------------------------------------------
_rl_watcher() {
  local claude_pid="$1" session_file="$2"

  # Wait briefly for the file to exist.
  local i=0
  while (( i++ < 30 )) && [[ ! -f "$session_file" ]]; do sleep 1; done
  [[ -f "$session_file" ]] || return

  local baseline current
  baseline=$(wc -l < "$session_file" 2>/dev/null | tr -d ' ' || echo 0)

  while kill -0 "$claude_pid" 2>/dev/null; do
    sleep "$WATCHER_POLL_SECS"
    current=$(wc -l < "$session_file" 2>/dev/null | tr -d ' ' || echo 0)
    if (( current > baseline )); then
      if tail -n "+$(( baseline + 1 ))" "$session_file" 2>/dev/null \
          | grep -qi 'resets .*('; then
        sleep 0.3
        kill -INT "$claude_pid" 2>/dev/null || true
        return
      fi
      baseline=$current
    fi
  done
}

# ---------------------------------------------------------------------------
# Run claude in the foreground, with the watcher in the background.
# Returns the pinned session_file path via a global (BASH_REMATCH-style).
# ---------------------------------------------------------------------------
PINNED_SESSION_FILE=''

_run_claude() {
  local resume_id="$1"; shift
  local extra_args=("$@")

  # Permission-bypass injection. Default ON (matches user's pre-existing
  # `alias claude="claude --dangerously-skip-permissions"` behaviour).
  # Opt out by exporting CLAUDE_AUTO_RESUME_SAFE=1 (used by `claude-safe`),
  # or by passing the flag yourself (we never double-add it).
  local inject_dsp=true
  [[ -n "${CLAUDE_AUTO_RESUME_SAFE:-}" ]] && inject_dsp=false
  local a
  for a in "${extra_args[@]}"; do
    [[ "$a" == "--dangerously-skip-permissions" ]] && { inject_dsp=false; break; }
  done
  local final_args=()
  $inject_dsp && final_args+=("--dangerously-skip-permissions")
  final_args+=("${extra_args[@]}")

  local pre_snap=''
  if [[ -z "$resume_id" ]]; then
    pre_snap=$(snapshot_jsonl)
  fi

  local my_pid=$$

  # Background watcher. It needs both the claude PID (discovered via /proc
  # children) and the pinned session file path (discovered via dir-diff for
  # new sessions, or latest-mtime for resumes).
  (
    exec >/dev/null 2>/dev/null

    local watcher_self=0 _stat_line
    read -r _stat_line < /proc/self/stat 2>/dev/null \
      && watcher_self=${_stat_line%% *}

    # 1) Find claude's PID — it's our parent script's other child.
    local claude_pid='' i=0
    while (( i++ < 200 )) && [[ -z "$claude_pid" ]]; do
      local raw=''
      read -r raw < "/proc/${my_pid}/task/${my_pid}/children" 2>/dev/null \
        || raw=$(pgrep -d' ' -P "$my_pid" 2>/dev/null) || true
      for pid in $raw; do
        [[ "$pid" == "$watcher_self" ]] && continue
        claude_pid=$pid; break
      done
      [[ -z "$claude_pid" ]] && sleep 0.05
    done
    [[ -n "$claude_pid" ]] || exit 0

    # 2) Pin the session file.
    local session_file=''
    if [[ -n "$resume_id" ]]; then
      session_file="${PROJECTS_DIR}/$(encoded_cwd)/${resume_id}.jsonl"
    else
      i=0
      while (( i++ < 60 )) && [[ -z "$session_file" ]]; do
        session_file=$(diff_for_new_session "$pre_snap")
        [[ -z "$session_file" ]] && sleep 0.5
      done
    fi
    [[ -n "$session_file" ]] || exit 0

    # 3) Publish the pinned path so the foreground main loop can read it.
    printf '%s\n' "$session_file" > "${STATE_DIR}/.pin.$$"

    _rl_watcher "$claude_pid" "$session_file"
  ) > /dev/null 2>/dev/null &
  local watcher_pid=$!

  trap 'true' INT
  "$CLAUDE_BIN" "${final_args[@]}" || true
  trap - INT

  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

  # Read pinned-path published by the watcher.
  PINNED_SESSION_FILE=''
  if [[ -f "${STATE_DIR}/.pin.$$" ]]; then
    PINNED_SESSION_FILE=$(cat "${STATE_DIR}/.pin.$$" 2>/dev/null || true)
    rm -f "${STATE_DIR}/.pin.$$"
  fi
  # Fallback for resume runs: we already know the path.
  if [[ -z "$PINNED_SESSION_FILE" && -n "$resume_id" ]]; then
    PINNED_SESSION_FILE="${PROJECTS_DIR}/$(encoded_cwd)/${resume_id}.jsonl"
  fi
  # Last-ditch fallback for new-session runs that finished too fast for the
  # watcher to discover the file (rare, but possible).
  [[ -z "$PINNED_SESSION_FILE" ]] && PINNED_SESSION_FILE=$(latest_jsonl_in_cwd)
}

# ---------------------------------------------------------------------------
# Countdown loop until wake_epoch. Ctrl-C aborts cleanly.
# ---------------------------------------------------------------------------
show_countdown() {
  local wake_epoch="$1" session_id="$2"

  tput civis 2>/dev/null >&2 || true
  trap '
    tput cnorm 2>/dev/null >&2 || true
    printf "\r\e[K  \e[33mCancelled.\e[0m Resume manually:\n" >&2
    printf "  claude --resume %s\n\n" "'"$session_id"'" >&2
    exit 0
  ' INT

  local remaining mins secs
  while true; do
    remaining=$(( wake_epoch - $(date +%s) ))
    (( remaining <= 0 )) && break
    mins=$(( remaining / 60 ))
    secs=$(( remaining % 60 ))
    printf '\r  \e[2mWaiting until reset.\e[0m  Remaining: \e[33m%d min %02ds\e[0m\e[K' \
      "$mins" "$secs" >&2
    sleep 1
  done
  printf '\r\e[K' >&2
  tput cnorm 2>/dev/null >&2 || true
  trap - INT
}

# ---------------------------------------------------------------------------
# Main loop.
# ---------------------------------------------------------------------------
main() {
  local resume_id=""
  local resume_msg="Rate limits have reset — continuing where we left off."
  local cleanup_session_id=""

  cleanup() {
    [[ -n "$cleanup_session_id" ]] && remove_state "$cleanup_session_id"
    rm -f "${STATE_DIR}/.pin.$$"
  }
  trap cleanup EXIT

  while true; do
    local pre_run_lines=0 pre_run_file=''
    if [[ -n "$resume_id" ]]; then
      pre_run_file="${PROJECTS_DIR}/$(encoded_cwd)/${resume_id}.jsonl"
      [[ -f "$pre_run_file" ]] && \
        pre_run_lines=$(wc -l < "$pre_run_file" 2>/dev/null | tr -d ' ' || echo 0)
    fi

    if [[ -z "$resume_id" ]]; then
      _run_claude "" "$@"
    else
      _run_claude "$resume_id" --resume "$resume_id" "$resume_msg"
    fi

    local session_file="$PINNED_SESSION_FILE"
    [[ -z "$session_file" || ! -f "$session_file" ]] && break

    local session_id; session_id=$(basename "$session_file" .jsonl)
    cleanup_session_id="$session_id"

    local session_name; session_name=$(get_session_name "$session_file")
    if [[ -z "$session_name" ]]; then
      session_name=$(generate_name "$session_id")
      name_session "$session_file" "$session_id" "$session_name"
    fi

    # Determine reset epoch — flag file (cheap) first, JSONL grep fallback.
    local reset_epoch; reset_epoch=$(read_warn_flag_epoch)
    if (( reset_epoch <= 0 )); then
      local start_line=1
      [[ "$session_file" == "$pre_run_file" ]] && start_line=$(( pre_run_lines + 1 ))
      local reset_info; reset_info=$(get_reset_info "$session_file" "$start_line")
      [[ -z "$reset_info" ]] && { write_state "$session_id" "$session_name" "exited" 0; break; }
      local rt rz
      rt=$(echo "$reset_info" | awk '{print $1}')
      rz=$(echo "$reset_info" | awk '{print $2}')
      reset_epoch=$(parse_reset_epoch "$rt" "$rz") || break
    fi

    local wake_epoch=$(( reset_epoch + BUFFER_SECS ))
    write_state "$session_id" "$session_name" "waiting" "$wake_epoch"
    _msg_rl_hit "$session_name" "$reset_epoch" "$wake_epoch"
    show_countdown "$wake_epoch" "$session_id"
    write_state "$session_id" "$session_name" "resuming" 0
    _msg_resuming "$session_name"

    resume_id="$session_id"
  done
}

main "$@"
