#!/usr/bin/env bash
# Keeps a `claude remote-control` server alive inside tmux.
#
# launchd runs this script; it does not exit on its own. If the Claude Code
# server dies (crash, or the ~10 minute network-outage timeout that makes
# server mode give up), the loop notices the tmux session is gone and starts a
# fresh one. If this script itself dies, launchd's KeepAlive restarts it.
#
# tmux is what gives Claude Code a real terminal. Server mode is an interactive
# TUI and launchd hands a job no TTY at all, so running the binary directly
# under launchd is unreliable; tmux allocates the pty and, as a bonus, lets you
# attach on the Mac to see the QR code.
#
# Values are baked in by install.sh.
set -uo pipefail

CLAUDE_BIN="__CLAUDE_BIN__"
PROJECT_DIR="__PROJECT_DIR__"
TMUX_BIN="__TMUX_BIN__"
TMUX_SESSION="__TMUX_SESSION__"
RC_NAME="__RC_NAME__"
SPAWN_MODE="__SPAWN_MODE__"
POLL_SECONDS=30

# Remote Control depends on feature-flag evaluation, which these switches turn
# off. A stray export in a shell profile silently disables the whole feature,
# so drop them from this process regardless of what the login shell set.
unset DISABLE_TELEMETRY DO_NOT_TRACK CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC DISABLE_GROWTHBOOK

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

# tmux joins any trailing arguments into a single string and hands it to a
# shell, so the shell re-splits on whitespace. Anything with a space in it
# (Mac computer names very often have one) has to be quoted for that shell,
# not just for this one.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

if [ ! -d "$PROJECT_DIR" ]; then
  log "FATAL: project directory $PROJECT_DIR does not exist. Re-run install.sh."
  # Sleep rather than exit so launchd does not spin restarting a doomed job.
  sleep 3600
  exit 1
fi

log "supervisor starting (tmux session '$TMUX_SESSION', project $PROJECT_DIR)"

while true; do
  if ! "$TMUX_BIN" has-session -t "$TMUX_SESSION" 2>/dev/null; then
    log "starting claude remote-control"
    RC_CMD="$(shq "$CLAUDE_BIN") remote-control --name $(shq "$RC_NAME") --spawn $(shq "$SPAWN_MODE")"
    "$TMUX_BIN" new-session -d -s "$TMUX_SESSION" -c "$PROJECT_DIR" "$RC_CMD"
    if [ $? -eq 0 ]; then
      log "started; attach on this Mac with: tmux attach -t $TMUX_SESSION"
    else
      log "failed to start; retrying in ${POLL_SECONDS}s"
    fi
  fi
  sleep "$POLL_SECONDS"
done
