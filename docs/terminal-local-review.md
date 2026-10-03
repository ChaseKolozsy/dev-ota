# Phone-local terminal outcome checks

Notification macros now check each quiet tmux pane locally on the phone. The
existing SSH connection captures at most 40 recent history lines plus the pane
screen. The review excerpt is bounded to 40 lines and 6,000 characters, isolates
the latest bullet-style assistant reply when a turn boundary is clear, and
retains potentially shared caveats when that boundary is ambiguous.

The phone renders this excerpt as a monochrome terminal snapshot in memory.
This is a reconstruction of the selected pane's bottom section, not a capture
of whichever Android app happens to be foreground. Bundled ML Kit Latin OCR
runs on this image without a model download or remote OCR endpoint. The bitmap
is discarded after recognition. There is no screenshot/transcript upload, saved
review image, cloud completion request, or home-model request in this path.
SSH still needs connectivity to read fresh terminal output; stale and disconnected
panes retain their existing unknown state.

Analysis uses conservative English phrase rules, not a generative language
model. Explicit completion reports can show Reported success; failure, negation,
partial counts and requests for action can show Needs attention. Bare "Done",
passed-test output, future plans and unsupported wording remain unknown. The
source and OCR classifications must agree; disagreement remains unknown, and
evidence always comes from the original excerpt. These rules cannot verify the
underlying work or reliably interpret every assistant format/language. The
existing bounded retry and stale-result guards still apply. Listen keeps its
separate history and Earlier controls.

Enable or disable this in Terminal > SSH settings > Notification macros >
Check conclusions locally on this phone. The previous server/terminal_review.py
helper remains available for separate legacy clients, but the production SSH
watch transport no longer invokes it.

# ZeroTier recovery

Recovery runs on phone even with a disconnected relay. It requires the saved
whole-device permission and Android Accessibility service. Notification recovery
checks these before any macro action and preserves SSH when it cannot start.
In Agent, enable whole-device control and press Start Agent to apply that setting;
relay connectivity is not required for the local actions. If needed, enable
DevOTA in Android Accessibility settings.

The shipped recovery definition no longer syncs over the network before repairing
that network. It removes the eight-second foreground-package assertion after
turning ZeroTier on, reopens ZeroTier, and polls its online UI for up to 60 seconds.
OFFLINE is explicitly excluded so its substring "ONLINE" cannot satisfy the check.
Cached shipped steps are upgraded by the app; unrelated macros are preserved.
The separate computer relay must also listen on port 8083 for Agent connectivity.

Observed saved failures: September 30 and October 2 stopped after the on-toggle
because another app became foreground. Two October 3 runs stopped on the initial
Back action because whole-device control was disabled. On October 3 the Windows
ZeroTier service was running at the configured address while the relay port had
no listener. Starting the existing wrapper restored the listener and WebSocket
handshake response; that alone does not establish a phone reconnect.

Validation: 215 Flutter tests passed in an isolated checkout of these changes;
231 passed in the working tree including existing local changes. Flutter analysis
reported no issues in both. The native bundled OCR instrumentation test passed (1 test, Android 36
emulator), preserving negation and partial counts. Physical phone recovery
acceptance remains separate from the saved-run diagnosis and regression checks.
