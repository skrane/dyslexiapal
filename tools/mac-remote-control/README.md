# Always-on Claude Code Remote Control for a Mac

Keeps a `claude remote-control` **server** running on a Mac so you can create and
drive Claude Code sessions on that machine from the Claude app on your phone —
without having to be at the Mac first to start something.

## Why the server, not just `/remote-control`

There are three ways to turn Remote Control on, and they solve different problems:

| Mode | What it gives you |
|---|---|
| `/remote-control` in a running session | Hands *that one conversation* to your phone. You must already be at the Mac. |
| `claude --remote-control` | A normal interactive session that is also reachable remotely. Still one session, started at the Mac. |
| **`claude remote-control` (server)** | Waits for connections and **creates sessions on demand from the phone**. Up to 32 at once. This is the one you want. |

The catch is that the server is an ordinary local process: close the terminal and
it is gone, and after roughly ten minutes without network it gives up and exits.
That is what this installer handles — launchd restarts it, tmux keeps it alive
across terminal and SSH disconnects, and `caffeinate` stops the Mac idling to
sleep out from under it.

## Install

On the Mac, in a checkout of this repo:

```bash
brew install tmux                       # if you don't have it
cd tools/mac-remote-control
./install.sh ~/path/to/a/project        # a project folder, NOT ~
```

Then on your phone: open the Claude app and the machine shows up in your session
list, named after the Mac's computer name.

Options:

```bash
RC_NAME="Mac mini" ./install.sh ~/code/dyslexiapal    # custom title in the app
RC_SPAWN_MODE=worktree ./install.sh ~/code/repo       # each new session gets its own git worktree
RC_CAPACITY=2 ./install.sh ~/some/folder              # cap concurrent sessions (default 32)
```

`same-dir` (the default) means every session the phone creates shares that one
directory, so two at once can collide on the same files. `worktree` isolates
them and needs the directory to be a git repo.

**Don't point it at your home directory.** Claude Code never saves workspace
trust for `$HOME`, so the server would hang forever on the trust prompt.

## Pointing it at a Google Drive folder

This works, and `install.sh` detects it and warns, but a synced folder is not a
normal working directory:

```bash
RC_CAPACITY=2 RC_NAME="Mac mini" \
  ./install.sh "$HOME/Library/CloudStorage/GoogleDrive-you@example.com/My Drive/Your Folder"
```

- **Mark the folder available offline** in Drive. Otherwise files are
  placeholders that download on first read — slow, and they fail when the Mac
  is offline, which is exactly when a phone session is most likely to be
  reaching for them.
- **Cap concurrency.** The default lets the phone open 32 sessions in the same
  directory. Several of them writing to a syncing folder is how you get
  Drive's conflicted copies. `RC_CAPACITY=2` is a reasonable ceiling.
- **`worktree` mode is unavailable** unless the folder is a git repo, which
  Drive folders normally are not. You get `same-dir`.
- **Full Disk Access.** A launchd agent may not be allowed to read
  `~/Library/CloudStorage`. If the log shows permission errors, grant Full Disk
  Access to `/bin/bash` in System Settings → Privacy & Security.
- **Everything in that folder is reachable from the phone.** Server mode means
  anyone who can get into your Claude account can open a session with read and
  write access to the whole directory. If it holds client material, that is the
  real blast radius — worth a passcode on the phone and leaving permission
  prompts on rather than running sessions in a bypass mode.

## What gets installed

| Path | What |
|---|---|
| `~/Library/LaunchAgents/com.skrane.claude-remote-control.plist` | launchd agent, `RunAtLoad` + `KeepAlive` |
| `~/.local/share/claude-remote-control/supervisor.sh` | restart loop, with your paths baked in |
| `~/Library/Logs/claude-remote-control.log` | supervisor log |

Nothing is written outside your user account and nothing needs `sudo`.

## Day to day

```bash
tmux attach -t claude-rc     # watch it; spacebar shows a QR code, Ctrl-b d detaches
tail -f ~/Library/Logs/claude-remote-control.log
./install.sh --uninstall
```

## Requirements

- macOS, `tmux`, and Claude Code **2.1.51+** (2.1.232+ recommended — it has the
  reconnect and unarchive fixes)
- A Pro, Max, Team, or Enterprise account signed in via `claude` → `/login`.
  API keys are not supported.
- Run `claude` once in the project directory first to accept the workspace trust
  dialog.
- `DISABLE_TELEMETRY`, `DO_NOT_TRACK`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`,
  and `DISABLE_GROWTHBOOK` each silently disable Remote Control. Unset them in
  your shell profile and in any `settings.json` `env` block. The supervisor also
  clears them from its own environment.

`install.sh` checks all of the above before it installs anything.

## Two things it does not solve

- **Hard sleep.** `caffeinate -i` blocks *idle* sleep. If you close the lid on a
  laptop or the Mac sleeps for another reason, it goes offline until it wakes.
  On an always-on desktop, also set System Settings → Energy to never sleep.
- **Power loss / reboot.** The agent starts again at login, but a Mac sitting at
  the login screen after a reboot has not logged in yet. Enable automatic login
  if you need it to survive unattended restarts.

## Related

If you want a session to be remote-controllable every time you start Claude Code
by hand — separate from the server — set `remoteControlAtStartup: true` in
`~/.claude/settings.json`, or run `/config` and turn on **Enable Remote Control
for all sessions**.
