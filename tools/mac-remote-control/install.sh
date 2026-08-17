#!/usr/bin/env bash
# Set up always-on Claude Code Remote Control on this Mac, so the machine can
# be driven from the Claude app on a phone.
#
#   ./install.sh ~/code/some-project      # install
#   ./install.sh --uninstall              # remove
#
# Optional overrides:
#   RC_NAME="Mac mini"    session title shown in the Claude app
#   RC_SPAWN_MODE         same-dir (default) | worktree | session
#   RC_TMUX_SESSION       tmux session name (default: claude-rc)
set -euo pipefail

LABEL="com.skrane.claude-remote-control"
MIN_VERSION="2.1.51"          # first release with Remote Control
GOOD_VERSION="2.1.232"        # first release with all the reconnect fixes

PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INSTALL_DIR="$HOME/.local/share/claude-remote-control"
LOG_FILE="$HOME/Library/Logs/claude-remote-control.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RC_NAME="${RC_NAME:-$(scutil --get ComputerName 2>/dev/null || hostname -s)}"
# The name is substituted into a sed replacement, a shell string, and XML, so
# keep it to characters that are inert in all three.
RC_NAME="$(printf '%s' "$RC_NAME" | tr -cd '[:alnum:] ._-')"
[ -n "$RC_NAME" ] || RC_NAME="mac"
RC_SPAWN_MODE="${RC_SPAWN_MODE:-same-dir}"
RC_TMUX_SESSION="${RC_TMUX_SESSION:-claude-rc}"
RC_CAPACITY="${RC_CAPACITY:-}"

# Escape a string for use as a sed *replacement*. Cloud-sync folders are named
# by humans, and an unescaped & expands to the whole match, silently corrupting
# the path it was supposed to insert.
sed_rep() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[32m  ok\033[0m  %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }

unload_agent() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null \
    || launchctl unload "$PLIST" 2>/dev/null \
    || true
}

# ---------------------------------------------------------------- uninstall
if [ "${1:-}" = "--uninstall" ]; then
  unload_agent
  tmux kill-session -t "$RC_TMUX_SESSION" 2>/dev/null || true
  rm -f "$PLIST"
  rm -rf "$INSTALL_DIR"
  ok "removed $LABEL"
  echo "Sessions already created stay in your Claude app until they are archived."
  exit 0
fi

# -------------------------------------------------------------- preflight
[ "$(uname -s)" = "Darwin" ] || die "this installer is macOS-only (found $(uname -s))"

PROJECT_DIR="${1:-}"
[ -n "$PROJECT_DIR" ] || die "usage: ./install.sh /path/to/project-dir  (see README.md)"
PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd)" \
  || die "project directory '${1}' does not exist"
[ "$PROJECT_DIR" != "$HOME" ] \
  || die "don't use your home directory: Claude Code never saves workspace trust for \$HOME, so the server would stall on the trust prompt. Pick a project folder."
ok "project directory: $PROJECT_DIR"

# Cloud-sync folders work, but they behave differently enough from a normal
# working directory to be worth calling out before anything is installed.
case "$PROJECT_DIR" in
  */Library/CloudStorage/*|*/Google?Drive*|*/Dropbox/*|*/OneDrive*|*/Library/Mobile?Documents/*)
    warn "$PROJECT_DIR looks like a cloud-sync folder. Three things to know:"
    warn "  1. Set the folder to available offline. Files-on-demand placeholders"
    warn "     make reads slow, and they fail outright when the Mac is offline."
    warn "  2. Concurrent sessions editing the same synced files can produce"
    warn "     conflicted copies. Consider RC_CAPACITY=1 or 2."
    warn "  3. If the agent cannot read the folder, grant Full Disk Access to"
    warn "     /bin/bash under System Settings > Privacy & Security."
    ;;
esac

CLAUDE_BIN="$(command -v claude || true)"
[ -n "$CLAUDE_BIN" ] || die "'claude' not found on PATH. Install Claude Code first."
ok "claude: $CLAUDE_BIN"

TMUX_BIN="$(command -v tmux || true)"
[ -n "$TMUX_BIN" ] || die "'tmux' not found. Install it with: brew install tmux"
ok "tmux: $TMUX_BIN"

VERSION="$("$CLAUDE_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ -n "$VERSION" ] || die "could not read 'claude --version'"
lowest() { printf '%s\n%s\n' "$1" "$2" | sort -V | head -1; }
[ "$(lowest "$VERSION" "$MIN_VERSION")" = "$MIN_VERSION" ] \
  || die "Claude Code $VERSION is too old for Remote Control (need $MIN_VERSION+). Update, then re-run."
if [ "$(lowest "$VERSION" "$GOOD_VERSION")" != "$GOOD_VERSION" ]; then
  warn "Claude Code $VERSION works, but $GOOD_VERSION+ has the reconnect and unarchive fixes. Consider updating."
else
  ok "claude version: $VERSION"
fi

# These four each disable the feature-flag evaluation Remote Control needs.
# printenv rather than ${!var}: macOS still ships bash 3.2 as /bin/bash.
for var in DISABLE_TELEMETRY DO_NOT_TRACK CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC DISABLE_GROWTHBOOK; do
  if [ -n "$(printenv "$var" || true)" ]; then
    warn "$var is set in this shell — it disables Remote Control. Remove it from your shell profile and any settings.json 'env' block."
  fi
done

# Eligibility check: Claude Code validates the account before printing help, so
# a non-zero exit here means not signed in or not on a supporting plan.
if ! "$CLAUDE_BIN" remote-control --help >/dev/null 2>&1; then
  die "'claude remote-control --help' failed. Run 'claude' then '/login' to sign in with a Pro/Max/Team/Enterprise account (API keys are not supported), then re-run."
fi
ok "account is eligible for Remote Control"

case "$RC_SPAWN_MODE" in
  same-dir|worktree|session) ;;
  *) die "RC_SPAWN_MODE must be same-dir, worktree, or session (got '$RC_SPAWN_MODE')" ;;
esac
if [ "$RC_SPAWN_MODE" = "worktree" ] && ! git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  die "RC_SPAWN_MODE=worktree needs $PROJECT_DIR to be a git repository"
fi

if [ -n "$RC_CAPACITY" ]; then
  case "$RC_CAPACITY" in
    ''|*[!0-9]*) die "RC_CAPACITY must be a whole number (got '$RC_CAPACITY')" ;;
    0)           die "RC_CAPACITY must be at least 1" ;;
  esac
  [ "$RC_SPAWN_MODE" != "session" ] \
    || die "RC_CAPACITY cannot be combined with RC_SPAWN_MODE=session, which serves exactly one session by definition"
  ok "capacity: $RC_CAPACITY concurrent session(s)"
fi

# ---------------------------------------------------------------- install
mkdir -p "$INSTALL_DIR" "$HOME/Library/LaunchAgents" "$(dirname "$LOG_FILE")"

sed \
  -e "s|__CLAUDE_BIN__|$(sed_rep "$CLAUDE_BIN")|g" \
  -e "s|__PROJECT_DIR__|$(sed_rep "$PROJECT_DIR")|g" \
  -e "s|__TMUX_BIN__|$(sed_rep "$TMUX_BIN")|g" \
  -e "s|__TMUX_SESSION__|$(sed_rep "$RC_TMUX_SESSION")|g" \
  -e "s|__RC_NAME__|$(sed_rep "$RC_NAME")|g" \
  -e "s|__SPAWN_MODE__|$(sed_rep "$RC_SPAWN_MODE")|g" \
  -e "s|__CAPACITY__|$(sed_rep "$RC_CAPACITY")|g" \
  "$SCRIPT_DIR/supervisor.sh" > "$INSTALL_DIR/supervisor.sh"
chmod +x "$INSTALL_DIR/supervisor.sh"
ok "supervisor installed to $INSTALL_DIR/supervisor.sh"

# caffeinate -i holds off idle sleep for as long as the supervisor runs, which
# keeps the Mac reachable without needing sudo pmset.
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/caffeinate</string>
        <string>-i</string>
        <string>/bin/bash</string>
        <string>$INSTALL_DIR/supervisor.sh</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$PROJECT_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>
    <string>$LOG_FILE</string>
</dict>
</plist>
PLIST_EOF

plutil -lint "$PLIST" >/dev/null || die "generated plist failed validation"
ok "launch agent written to $PLIST"

unload_agent
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
  || launchctl load "$PLIST" \
  || die "could not load the launch agent"
ok "launch agent loaded"

echo
echo "Waiting for the server to come up..."
for _ in $(seq 1 20); do
  if tmux has-session -t "$RC_TMUX_SESSION" 2>/dev/null; then
    ok "server is running"
    echo
    echo "On your phone: open the Claude app, and '$RC_NAME' will be in your session list."
    echo "On this Mac:   tmux attach -t $RC_TMUX_SESSION   (spacebar shows a QR code; Ctrl-b d to detach)"
    echo "Logs:          tail -f $LOG_FILE"
    echo "Remove:        ./install.sh --uninstall"
    exit 0
  fi
  sleep 1
done

warn "the server did not report ready within 20s. Check the log: tail -50 $LOG_FILE"
exit 1
