# Terminal notification controls

Read-aloud and home-model conclusion assessment are also available; see
[terminal conclusions](terminal-conclusions.md) for Listen/Earlier controls,
per-window verdicts, setup, and limits.

Connect SSH, open **Terminal → SSH settings → Notification macros**, and bind
up to three tmux panes to saved terminal macros. Set a quiet period of 5, 10,
15, or 30 seconds. Saving enables the existing background SSH service. Grant
notification permission so Android can display the controls.

The setup screen opens immediately and displays progress while discovering
windows. Discovery failures stay on that screen with the SSH diagnostic and a
Retry button. No macro needs to run before selecting windows. Notification
commands use separate SSH exec channels. Automatic routing detects Windows's
"tmux not recognized" error and enters WSL. Discovery shows **Execution host →
WSL · distribution · user**; Save pins that exact distribution/user to this SSH
profile. All later discovery, monitoring, history, macro/Enter actions, and
model checks use the same route. Failed writes are never retried on another host.

If your terminal uses a non-default distribution/user, tap **Execution host**,
choose **Windows / WSL**, enter those names and tap **Find windows**. Blank names
use Windows/WSL defaults for discovery, then resolve to explicit names on Save.
Changes clear draft window selections but leave existing notifications alone
until Save. **Direct Linux SSH** and **Automatic** remain available. A nested
SSH hop, custom tmux socket, or interactive-shell environment is not inherited.
Distribution/user names accept letters, numbers, dots, dashes and underscores;
names containing spaces or shell metacharacters are rejected. WSL must already
be installed for the Windows SSH account; DevOTA does not install or reconfigure it.

Linux commands travel on SSH stdin to `wsl.exe --exec /bin/sh -s`, not through
Windows shell parsing, and start in the selected Linux user's home directory.
Model JSON gets a separate decoded stdin stream. WSL UTF-16 error output is
decoded for the setup screen. The routing follows Microsoft's
[WSL distribution/user command options](https://learn.microsoft.com/en-us/windows/wsl/basic-commands).

Setup regression fixture (separate app, no production settings or agents):
build `test_support/terminal_setup_demo.dart` with
`DEVOTA_APPLICATION_ID=io.github.chasekolozsy.devota.terminalsetuptest`, install
on the emulator, reverse port 22222 to the existing Vim fixture, grant notification
permission, and launch it. Then run
`python3 scripts/test/terminal-notification-ui.py setup --output /tmp/devota-terminal-setup-evidence`.
This uses the real SSH settings screen, injects a discovery failure, retries,
selects a window/macro, saves, and checks that its notification button appears
without executing a macro. Widget tests also cover pending discovery, timeout,
retry, and leaving the screen before discovery completes.

For the Windows bridge test, launch the fixture with `--windows-wsl` and use UI
mode `wsl-setup`. This forwards the SSH commands through real Windows CMD and
WSL, preserving isolated Vim targets, checks the persisted route, then runs a
tiny notification macro that appends `hello` and saves the fixture buffer.
`cd app && dart run test_support/wsl_route_smoke.dart` additionally checks real
CMD and PowerShell routing, Unicode/metacharacters, stdin, and home directory.
These host-specific smoke checks require this Windows/WSL development machine;
portable routing/widget tests run in ordinary CI. No coding agents are invoked.

Each pane has a grouped notification with its macro action. Expand a pane to
see the buttons. The SSH session and Flutter engine must remain alive;
backgrounding the app works, but force-stopping it or removing its task stops
the session. Reopen and reconnect after that. Nothing is replayed on reconnect.
Mappings are local to the SSH user/host/port; they do not alter shared macros.

## Status and actions

- **Changing:** sampled terminal content is changing.
- **Settled:** content is unchanged for the configured quiet period, with fresh
  observations. This is not evidence that an agent completed its work.
- **Submission unconfirmed:** input/Enter was sent without application-level
  acknowledgment. This remains conservative even if a command actually worked.
- **Disconnected / unavailable:** no valid observation or the original pane no
  longer exists. Run/Enter actions are removed.

**Run macro** targets the bound pane, including hidden windows. **Send Enter**
is available after an attempted submission once the pane settles again. It
sends one carriage return to that pane; it does not retype the prompt or rerun
the macro. There are no automatic retries. **Stop** cancels remaining steps and
waits; it cannot undo input already delivered.

Only one notification/terminal macro runs at a time. Duplicate and stale
actions are rejected. A fresh capture is checked before sending input. Each
remote operation verifies the pane's server/session/process identity, so a
renumbered or newly created window cannot silently receive an old button's
input. After replacing/restarting tmux panes, select them again in settings.

## Macro compatibility and Enter

Notification macros support Command, Key and Wait. A tmux selection step for
the bound window number is redundant and skipped. Other tmux operations and
Ctrl-B are rejected before any input is sent; use a macro that operates within
its assigned window.

Commands use bracketed paste when the receiving application requests it, wait
200 ms for paste handling, then send a separate carriage return. If the next
non-Wait step is an explicit Enter, that step owns submission and the Command
does not add another Enter. Command-only macros still submit once. The same
submission rule applies to existing in-app terminal macros.

This addresses the previous LF/CR combination and same-burst paste/submit
behavior. It does not prove the cause of every historical missed Enter. Quiet
screens and SSH acknowledgments cannot establish whether an arbitrary agent
accepted a prompt. Agent-specific completion/acceptance integrations are not
part of this change; no UI claims verified agent completion.

## Implementation and limits

The independent Dart controller uses SSH exec channels to capture each bound
tmux pane every two seconds and send pane-targeted input. It does not switch
the interactive window, open an Activity, or focus the keyboard. Captures
compare rendered text and attributes, ignoring cursor blinking and identical
redraws. Changes that begin and end between samples can be missed. Native
notifications remove actions after twelve seconds without controller updates;
the controller also rejects observations older than eight seconds.

The existing Flutter engine owns the SSH connection; the Android foreground
service protects background operation, not persistence across process death.
tmux and POSIX shell/base64 must be available in the SSH user's noninteractive
command environment. This version uses the default tmux socket. SSH host-key
verification remains the existing terminal's responsibility.

## Repeatable emulator verification

The fixture uses three isolated **Vim Ex-mode** windows and a temporary tmux
socket. It writes `hello 1`, `hello 2`, and `hello 3` to temporary files. It
never launches an agent or reads production SSH credentials/macros.

1. Start an Android 36 emulator with 1080×2436 geometry:
   `emulator -avd revvl7pro-macro -no-window -no-audio -no-snapshot-save -gpu swiftshader_indirect`
2. From the repo root, start the fixture:
   `uv run --with paramiko scripts/test/terminal-notification-fixture.py`
3. In `app/`, build the isolated fixture APK:
   `DEVOTA_APPLICATION_ID=io.github.chasekolozsy.devota.terminaltest flutter build apk --debug --target-platform android-x64 --target test_support/terminal_notifications_demo.dart`
4. Install that APK on the explicitly selected emulator, grant it
   `android.permission.POST_NOTIFICATIONS`, and reverse TCP 22222 with adb.
5. Launch `io.github.chasekolozsy.devota.terminaltest/io.github.chasekolozsy.devota.MainActivity`,
   collapse the notification shade if necessary, and press **Start Vim test**.
6. Run `python3 scripts/test/terminal-notification-ui.py verify --serial emulator-5554`.

The driver taps actual notification UI nodes, checks the foreground Activity
stays outside DevOTA, verifies exact file contents, deliberately drops the
third macro's final Enter, and tests its notification recovery button. It also
checks removal of actions on disconnect. Screenshots, UI XML, foreground
Activity records, and fixture assertions are saved under
`/tmp/devota-terminal-notification-evidence` by default. Stop the fixture with
Ctrl-C; it kills only its own temporary tmux server and preserves its evidence.

Build the real phone APK afterward with `scripts/build/devota-public-debug.sh`.
The fixture entry point and package ID are not used by that build.

## Recorded verification — 2026-09-21

- Flutter suite: **86 passed**, analysis: **no issues**.
- Android 36 emulator: three pane-specific notification macros operated while
  the launcher remained the resumed Activity. Each Vim file contained exactly
  one greeting. Two ordinary runs delivered four Enters total; the third run
  delivered one, deliberately dropped its final Enter, then completed through
  the pane's **Send Enter** action. Six Enters were delivered and one was
  deliberately dropped. Disconnecting removed Run/Enter actions.
- The first fixture attempt used Vim normal mode, which inserted bracketed
  command text into the buffer. The corrected fixture uses Ex mode. The UI
  driver also needed to collapse previous cards to expose the third card's
  buttons; windows 1 and 2 had already passed, and window 3 was then verified.
- The production ARM64 APK was built and registered in `/builds`, package
  `io.github.chasekolozsy.devota`, version code **2026094101**. Physical-phone
  installation and behavior under Doze or real mobile-network latency remain
  unverified. No agent acceptance/completion behavior was tested.
