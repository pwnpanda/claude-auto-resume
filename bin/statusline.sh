#!/usr/bin/env bash
# statusline.sh
#
# Claude Code statusline + rate-limit sensor.
#
# Reads the JSON status payload Claude Code writes to stdin, prints a
# compact one-line statusline to stdout, and (as a side-effect) writes
# pre-computed reset epochs to ~/.claude/.rl_warn when 5h or 7d usage
# crosses the warning threshold.
#
# The wrapper (claude-auto-resume.sh) reads that flag file as a fast path
# so it doesn't have to parse JSONL on rate-limit exit.
#
# Multi-instance safe: rate-limit values are account-global, so every
# concurrent statusline invocation writes the same content. The `rm -f`
# on the else branch is harmless because the wrapper ignores stale
# (past-epoch) entries anyway.
#
# Adapted from karthiknitt/smart_resume (MIT). De-zsh'd so it runs under
# any POSIX-ish shell exposed by Claude Code.

set -u

WARN_THRESHOLD_PCT=90
RL_WARN_FLAG="${HOME}/.claude/.rl_warn"

input=$(cat)

# ---------------------------------------------------------------------------
# Color palette (Gruvbox 256-color)
# ---------------------------------------------------------------------------
fg() { printf "\e[38;5;%sm" "$1"; }
C_ORANGE=$(fg 208)
C_YELLOW=$(fg 214)
C_AQUA=$(fg 43)
C_FG2=$(fg 250)
C_FG0=$(fg 230)
C_RED=$(fg 196)
C_GREEN=$(fg 40)
C_RESET=$(printf "\e[0m")

# ---------------------------------------------------------------------------
# Extract JSON fields with safe defaults.
# ---------------------------------------------------------------------------
jq_get() { echo "$input" | jq -r "$1 // empty" 2>/dev/null; }

cwd=$(jq_get '.workspace.current_dir')
input_tokens=$(jq_get '.context_window.current_usage.input_tokens')
cache_creation=$(jq_get '.context_window.current_usage.cache_creation_input_tokens')
cache_read=$(jq_get '.context_window.current_usage.cache_read_input_tokens')
context_window_size=$(jq_get '.context_window.context_window_size')
model_name=$(jq_get '.model.display_name')
version=$(jq_get '.version')
output_style=$(jq_get '.output_style.name')
session_cost=$(jq_get '.cost.total_cost_usd')
rl_5h_pct=$(jq_get '.rate_limits.five_hour.used_percentage')
rl_7d_pct=$(jq_get '.rate_limits.seven_day.used_percentage')
rl_5h_rst=$(jq_get '.rate_limits.five_hour.resets_at')
rl_7d_rst=$(jq_get '.rate_limits.seven_day.resets_at')

: "${input_tokens:=0}" "${cache_creation:=0}" "${cache_read:=0}"

# ---------------------------------------------------------------------------
# Path: replace $HOME with ~, keep last 3 components.
# ---------------------------------------------------------------------------
display_path="${cwd/#$HOME/~}"
truncated=$(echo "$display_path" | awk -F/ '{
    n = NF
    if (n <= 3) { print $0 }
    else { printf "…/%s/%s/%s", $(n-2), $(n-1), $n }
}')

user_name=$(whoami)

# ---------------------------------------------------------------------------
# Git branch + dirty marker
# ---------------------------------------------------------------------------
git_info=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
    if [ -n "$branch" ]; then
        if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
            git_info=" ${C_AQUA} ${branch} ✗${C_RESET}"
        else
            git_info=" ${C_AQUA} ${branch}${C_RESET}"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Context window usage
# ---------------------------------------------------------------------------
context_info=""
total_input=$((input_tokens + cache_creation + cache_read))
if [ "$total_input" -gt 0 ] && [ -n "$context_window_size" ] && [ "$context_window_size" -gt 0 ]; then
    input_k=$(( (total_input + 500) / 1000 ))
    window_k=$(( (context_window_size + 500) / 1000 ))
    pct=$(( (total_input * 100 + context_window_size / 2) / context_window_size ))
    if   [ "$pct" -lt 50 ]; then ctx_color="$C_GREEN"
    elif [ "$pct" -lt 80 ]; then ctx_color="$C_YELLOW"
    else                          ctx_color="$C_RED"; fi
    context_info=" ${ctx_color}ctx:${input_k}k/${window_k}k (${pct}%)${C_RESET}"
fi

# ---------------------------------------------------------------------------
# Rate limits + .rl_warn flag write
# ---------------------------------------------------------------------------
rl_info=""
if [ -n "$rl_5h_pct" ]; then
    rl_5h_int=$(printf "%.0f" "$rl_5h_pct")
    rl_7d_int=$(printf "%.0f" "${rl_7d_pct:-0}")
    if   [ "$rl_5h_int" -lt 50 ]; then rl_color="$C_GREEN"
    elif [ "$rl_5h_int" -lt 80 ]; then rl_color="$C_YELLOW"
    else                                rl_color="$C_RED"; fi
    rl_info=" ${rl_color}rl:${rl_5h_int}%/5h ${rl_7d_int}%/7d${C_RESET}"

    if [ "$rl_5h_int" -ge "$WARN_THRESHOLD_PCT" ] || [ "$rl_7d_int" -ge "$WARN_THRESHOLD_PCT" ]; then
        # Atomic write via temp file + rename to avoid partial reads.
        tmp="${RL_WARN_FLAG}.tmp.$$"
        {
            printf '5h_pct=%s\n5h_reset=%s\n7d_pct=%s\n7d_reset=%s\nwritten_at=%s\n' \
                "$rl_5h_int" "${rl_5h_rst:-0}" \
                "$rl_7d_int" "${rl_7d_rst:-0}" "$(date +%s)"
        } > "$tmp" && mv -f "$tmp" "$RL_WARN_FLAG"
    else
        rm -f "$RL_WARN_FLAG"
    fi
fi

# ---------------------------------------------------------------------------
# Model + version
# ---------------------------------------------------------------------------
model_info=""
if [ -n "$model_name" ]; then
    short_model="${model_name#Claude }"
    if [ -n "$version" ]; then
        model_info=" ${C_FG2}[${short_model} v${version}]${C_RESET}"
    else
        model_info=" ${C_FG2}[${short_model}]${C_RESET}"
    fi
fi

style_info=""
[ -n "$output_style" ] && style_info=" ${C_FG2}{${output_style}}${C_RESET}"

cost_info=""
if [ -n "$session_cost" ]; then
    cost_fmt=$(printf "%.2f" "$session_cost")
    cost_info=" ${C_FG2}\$${cost_fmt}${C_RESET}"
fi

# ---------------------------------------------------------------------------
# Render: user @ dir  branch  [model] {style}  ctx  rl  cost
# ANSI escapes carried via %s args (avoids SC2059 — printf format never holds vars)
# ---------------------------------------------------------------------------
printf '%s%s%s' "$C_ORANGE" "$user_name" "$C_RESET"
printf '%s @ %s' "$C_FG0"   "$C_RESET"
printf '%s%s%s' "$C_YELLOW" "$truncated" "$C_RESET"
[ -n "$git_info"     ] && printf '%s' "$git_info"
[ -n "$model_info"   ] && printf '%s' "$model_info"
[ -n "$style_info"   ] && printf '%s' "$style_info"
[ -n "$context_info" ] && printf '%s' "$context_info"
[ -n "$rl_info"      ] && printf '%s' "$rl_info"
[ -n "$cost_info"    ] && printf '%s' "$cost_info"
