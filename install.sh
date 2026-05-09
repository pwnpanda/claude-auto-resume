#!/usr/bin/env bash
# install.sh — install claude-auto-resume into ~/.claude/auto-resume/
#
# Idempotent. Re-running upgrades the symlinks in place.
#
# What it does:
#   1. Creates ~/.claude/auto-resume/{sessions,bin}
#   2. Symlinks bin/* from the repo into ~/.claude/auto-resume/
#   3. Adds the statusline hook to ~/.claude/settings.json (using jq).
#   4. Prints the alias line to add to your shell rc.
#
# Re-runs are safe — symlinks get replaced, settings.json is patched
# only if the statusline command isn't already pointing at our script.

set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEST="${HOME}/.claude/auto-resume"
SETTINGS="${HOME}/.claude/settings.json"

mkdir -p "$DEST/sessions"

ln -sfn "$REPO_DIR/bin/claude-auto-resume.sh"  "$DEST/claude-auto-resume.sh"
ln -sfn "$REPO_DIR/bin/statusline.sh"          "$DEST/statusline.sh"
ln -sfn "$REPO_DIR/bin/claude-resume-status"   "$DEST/claude-resume-status"

chmod +x "$REPO_DIR"/bin/*

echo "✓ Linked scripts into $DEST"

# ---------------------------------------------------------------------------
# Patch settings.json — set statusLine.command to our statusline.sh.
# We don't overwrite a user-set command unless it already points at our path
# or doesn't exist.
# ---------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
    echo "✗ jq is required to patch $SETTINGS automatically." >&2
    echo "  Install jq, or add this manually:" >&2
    echo "    \"statusLine\": { \"type\": \"command\", \"command\": \"$DEST/statusline.sh\" }" >&2
else
    [[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
    current_cmd=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null || true)
    if [[ -z "$current_cmd" || "$current_cmd" == "$DEST/statusline.sh" ]]; then
        tmp="${SETTINGS}.tmp.$$"
        jq --arg cmd "$DEST/statusline.sh" \
           '.statusLine = {"type": "command", "command": $cmd}' \
           "$SETTINGS" > "$tmp" && mv -f "$tmp" "$SETTINGS"
        echo "✓ Patched $SETTINGS statusLine → $DEST/statusline.sh"
    else
        echo "! $SETTINGS already has a custom statusLine command:"
        echo "    $current_cmd"
        echo "  Leaving it alone. To use ours, set:"
        echo "    \"statusLine\": { \"type\": \"command\", \"command\": \"$DEST/statusline.sh\" }"
    fi
fi

# ---------------------------------------------------------------------------
# Final instructions
# ---------------------------------------------------------------------------
cat <<EOF

Next steps
----------
Add this alias to your shell rc (~/.bashrc or ~/.zshrc):

  alias claude="\$HOME/.claude/auto-resume/claude-auto-resume.sh"

Then reload your shell, run \`claude\` as usual, and check status with:

  $DEST/claude-resume-status

Optional: add ~/.claude/auto-resume to PATH so \`claude-resume-status\`
is callable without the full path:

  export PATH="\$HOME/.claude/auto-resume:\$PATH"

EOF
