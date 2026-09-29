# Steering-wheel control for DevOTA — proposal

Status: **PROPOSAL ONLY, nothing is built.** Written 2026-09-28 for the owner,
who uses DevOTA while driving for Uber and DoorDash.

> "Create a new version of DevOTA where I can navigate the app using my steering
> wheel. I can navigate the buttons and stuff like that using my steering wheel.
> Like if I press the call button it wants to record; when I hang up it stops
> recording, stuff like that. Because that could make DevOTA way more safe for
> me to use while driving." — the owner, 2026-09-28

The goal is an **eyes-free car mode**. The car's Bluetooth buttons move a
focus through a small spoken menu and trigger actions. Every focus change and
every result is spoken aloud. The call button starts dictation, hanging up
stops it, and a second trigger (a double press where the car allows it) enters
a spoken **voice-command** mode. No step may require looking at or touching the
screen while the car is moving.

Every claim about Android or Bluetooth below is tagged:

- **[V]** verified, meaning read in the cited documentation or source during
  this research;
- **[V2]** verified only in a secondary source, such as an open-source project's
  issue tracker quoting AOSP code, and not independently checked against AOSP;
- **[A]** assumed: an inference or general knowledge that has to be tested
  before anything depends on it.

Source numbers such as [S1] refer to the list at the end.

---

## 0. Summary and recommendation

**The central fact:** the car's call and hang-up buttons are **not key events**.
Over Bluetooth Hands-Free Profile (HFP) they are AT commands handled by the
phone's Bluetooth and telephony stack. No ordinary app receives them as keys,
and an accessibility service cannot see them either. An app reaches them only
in three ways:

1. **As the voice-command handler.** A voice-button press (often a long press
   of "call") makes the car send `AT+BVRA=1`, and Android launches the
   `ACTION_VOICE_COMMAND` handler [V2 S2, S3; S4].
2. **As a Telecom call.** A self-managed `ConnectionService` / Core-Telecom
   call is "visible on and controllable via bluetooth devices (e.g. car head
   units and headsets)" [V S5, S6]. Hang-up then reaches the app as
   `onDisconnect` / `onSetCallDisconnected`.
3. **As a media button, on some cars only.** A few head units send the call
   button as AVRCP play/pause or `KEYCODE_HEADSETHOOK`. That varies per car [A].

The next, previous and play/pause buttons are reliable. They arrive as
**AVRCP** media keys and go to the media session that most recently played
audio locally [V S1].

**Recommended combination** (the details are in §3–§10):

| Need | Primary mechanism | Fallback |
|---|---|---|
| Next / previous / play-pause (menu focus, activate, scroll) | A DevOTA **MediaSession** that holds "last played" by playing its own speech through its own player | Accessibility key filter for Bluetooth HID remotes; a cheap steering-wheel Bluetooth remote |
| **Call button → start dictation** | **Voice-command handler** (`AT+BVRA` → `ACTION_VOICE_COMMAND`) through an invisible trampoline, then a **self-managed Telecom call** that stands for the recording | Play/pause long press; a spoken menu item "Dictate" |
| **Hang up → stop and transcribe** | The self-managed call's **disconnect callback** | The Bluetooth audio link dropping; the play/pause button |
| **Double press → command mode** | Detected only where the car delivers two separate events (to be proven in the Phase 0 probe) | **Spoken prefix**: start with "command …" after a single press (works on every car); play/pause double-tap |
| Real incoming call | Telecom concurrency: DevOTA's call yields and the audio stops at once | Audio-focus / audio-mode listeners |
| Navigating other apps' buttons | Optional **separate** DevOTA accessibility service, off by default | None; never needed while moving |

Recognizers: **Android's on-device recognizer for commands** (offline, free,
fast), and **the owner's home Whisper server for dictation** (free, better on
long speech). The paid OpenAI `whisper-1` call used today becomes an opt-in
fallback only.

Nothing in the design is proven on the owner's car yet. **Phase 0 is a "car
probe" build** that records which signal each physical button actually sends
and says it aloud. Most open risks close after one parked session with it.

---

## 1. DevOTA today

### 1.1 The phone app

- **Flutter** app (`app/`, package `io.github.chasekolozsy.devota`), with native
  Kotlin under `app/android/app/src/main/kotlin/io/github/chasekolozsy/devota/`.
- One screen, `BuildListScreen` (`app/lib/build_list_screen.dart`), with a tab
  strip: **Connect, Builds, Projects, Terminal, Commands, Macros, Agent,
  Backup, Files**.
- **Terminal** (`app/lib/ssh_terminal_tab.dart`, 3,906 lines) is an SSH
  terminal (dartssh2 + xterm). It has a control pad of keys
  (`terminal_pad_key.dart`, including the human key-spec parser
  `resolveKeySpec`), a quick-macro strip, tmux scroll mode, a fullscreen toggle
  that hides the tabs, a collapsible **Tools** panel, a native-keyboard lock,
  and a composer text field with **mic** and **send** buttons.
- **Macros** (`terminal_macro.dart`) have Command, Key, tmux, Wait and Device
  steps. Their order is `rankTerminalMacros()`: priority first, then list
  order, and the Macros tab and the terminal strip share it. Device macros run
  through `device_macro_runner.dart` and the accessibility service.
- **Notification controls** (`terminal_notification_bridge.dart`,
  `terminal_watch.dart`, `TerminalNotifications.kt`) bind up to three tmux
  panes to macros. They act on those panes over separate SSH exec channels
  (`TmuxWatchTransport.paste/key/capture`), with pane-identity guards and a
  fresh-capture preflight, so they work while DevOTA is backgrounded.
- **Read aloud** (`TerminalSpeech.kt`) uses Android TTS with `USAGE_MEDIA`,
  transient ducking audio focus, a reader notification with
  **Earlier / Replay / Stop**, and it stops on audio-focus loss or
  `ACTION_AUDIO_BECOMING_NOISY`. Home-model **conclusion verdicts**
  (`terminal_conclusion.dart`, `server/terminal_review.py`) label each pane as
  Reported success, Needs attention, or Outcome unknown.
- **Accessibility**: `ControlAccessibilityService.kt` is the MCP/macro control
  agent. It uses gestures, screenshots, UI trees and `flagRequestAccessibilityButton`.
  It does not request key filtering or touch exploration. It is **live
  infrastructure** for the camera audit and the MCP tools, and this proposal
  does not touch it (see §10).
- Foreground services: `SshSessionService` and `ControlAgentService`
  (`dataSync|specialUse`). Permissions already include `RECORD_AUDIO`,
  `POST_NOTIFICATIONS` and `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`.
- Settings persist in `SharedPreferences`. Backup allowlists the keys in
  `app/lib/backup_service.dart`, and `_scheduleServerBackup()` copies them to
  the build server.

### 1.2 Dictation and recording today

`app/lib/voice_input_service.dart` records AAC with the `record` package to a
temporary file, then posts it to **OpenAI `whisper-1`** with a key from secure
storage. That is a **paid hosted service**. There are two call sites:

- **Terminal composer** (`_startVoiceRecording` / `_finishVoiceRecording` in
  `ssh_terminal_tab.dart`): tap the mic to start and tap again to stop. The
  transcript is **appended to the composer**, and the owner must **tap Send**
  (`_submitComposer`) to deliver it.
- **Issues** (`_toggleIssueRecording` in `build_list_screen.dart`): the same
  flow into the issue note.

The mic records whichever input Android picks, normally the phone's own mic,
because nothing opens a Bluetooth voice (SCO) link [A]. Nothing is spoken back.

The owner already has a **home Whisper server**. Whisper Notes
(`/home/chase/whisper-notes`) serves `POST /v1/transcribe` with default model
`large-v3-turbo` behind an authenticated, encrypted envelope, and DevOTA
already reaches the same service over SSH for conclusion review (`/v1/chat`,
via `server/terminal_review.py`). A transcription helper can reuse that path.

### 1.3 How the owner interacts while driving now (inferred)

A search of the repo found **no driving, car or hands-free feature**. From the
code, the in-car workflow today must be touch and sight:

- open the notification shade → **Run macro / Send Enter / Listen / Earlier /
  Replay / Stop / Reconnect / Restart ZeroTier** buttons;
- or open DevOTA → Terminal → tap **mic**, speak, tap **stop**, wait, tap
  **send**;
- read verdict labels and terminal text on screen.

Each of those steps needs eyes and a finger. Listen is the only eyes-free
part, and it is still started by a tap.

Phones: the recorded physical acceptance device is a **REVVL V+ 5G on Android
12 (SDK 31)** (`docs/terminal-notification-controls.md`, 2026-09-22). Macro
profiles also target a **REVVL 7 Pro on Android 36**. Which one rides in the
car matters for several APIs below (question Q2).

---

## 2. Android and Bluetooth facts

| # | Fact | Status | Source |
|---|---|---|---|
| F1 | Media buttons go to the foreground activity first, then the active media session, then a restart of the last session. On Android 8+, "the system tries to find the last app with a MediaSession that played audio locally". Without a media button receiver, an inactive session's event is discarded. | [V] | S1 |
| F2 | Bluetooth **AVRCP** keys (next, previous, play/pause) are synthesised inside the Bluetooth process (`AvrcpTargetService`) and passed to `AudioManager.dispatchMediaKeyEvent`. They **never pass through** `InputDispatcher`, `PhoneWindowManager` or `AccessibilityInputFilter`. | [V2] | S9 |
| F3 | So an app's MediaSession receives AVRCP keys **only while it is the "last app that played audio locally"**. If the owner's music, a podcast or Google Maps plays later, the keys go there instead. | [V] from F1; interplay [A] | S1 |
| F4 | Speech from `android.speech.tts.TextToSpeech` is played by the TTS engine's process (for example Google TTS), so it probably does **not** count as DevOTA playing audio for F1. DevOTA must synthesise to a buffer or file and play it through its own `AudioTrack` or `MediaPlayer`. | [A] (test in Phase 0) | — |
| F5 | The car's **call** and **hang-up** buttons are HFP AT commands (answer `ATA`, hang-up `AT+CHUP`, redial `AT+BLDN`, voice `AT+BVRA`), not key events. Redial is handled by the telephony stack and is not visible to apps. | [V2] | S2, S16 |
| F6 | `AT+BVRA=1` (the voice button, often a long press of call) launches the `ACTION_VOICE_COMMAND` handler. An app becomes eligible by declaring an intent filter for `android.intent.action.VOICE_COMMAND`. Google Assistant uses BVRA for its sessions. | [V2] S2, S3; Assistant use [V] S4 | S2, S3, S4 |
| F7 | After BVRA the stack waits about 5 s for the launched app to call `BluetoothHeadset.startVoiceRecognition(device)`. Without that call it replies `+BVRA: 0`, and **further button presses are lost until then**. | [V2] | S2 |
| F8 | How Android chooses among several `VOICE_COMMAND` handlers (resolver "Always" versus the default-assistant role) is not documented in the sources read. | [A] | — |
| F9 | Self-managed ConnectionService calls: "your calls will be visible on and controllable via bluetooth devices (e.g. car head units and headsets)". The app needs `MANAGE_OWN_CALLS`. | [V] | S5 |
| F10 | Core-Telecom (`androidx.core.telecom`): remote devices (Bluetooth headsets, Android Auto, watches) manage calls, and the app handles them in `onAnswerCall`, `onSetCallDisconnected`, `onSetCallActive` and `onSetCallInactive`. It must post a notification within 5 s of adding a call. Do not use `startBluetoothSco` / `setCommunicationDevice` under Telecom, and audio must use `STREAM_VOICE_CALL`. | [V] | S6 |
| F11 | Setting `EXTRA_ADD_SELF_MANAGED_CALLS_TO_INCALLSERVICE=false` hides calls from **every** InCallService, **including Bluetooth**, so car audio and control break. It must stay true. | [V2] | S19 |
| F12 | Answering a mobile call can disconnect an ongoing third-party (self-managed) call, and Telecom arbitrates concurrency across apps. Telecom disconnects self-managed calls for an emergency call. | [V] S17; emergency [V2] S5 mirror / search summary | S5, S17 |
| F13 | Recording from the **car's mic** needs the Bluetooth voice link (SCO or LE Audio). It opens under a Telecom call, after `startVoiceRecognition`, or with `AudioManager.setCommunicationDevice` (API 31+). `startBluetoothSco` is deprecated from API 33. | [V] | S7, S8 |
| F14 | HFP voice audio is narrowband CVSD (8 kHz) or wideband mSBC (16 kHz), depending on the car. While SCO is open, A2DP media is suspended, and switching between them takes around a second. | [A] (general Bluetooth knowledge) | — |
| F15 | A2DP speech is heard in many cars only when the head unit's source is "Bluetooth audio", or when the car auto-switches. | [A] (car-dependent) | — |
| F16 | `KEYCODE_CALL`, `KEYCODE_ENDCALL`, `KEYCODE_HEADSETHOOK` ("used to hang up calls and stop media"), `KEYCODE_VOICE_ASSIST` and the media keycodes exist as key codes. `KEYCODE_HOME` "is never delivered to applications". None of these is what an HFP car sends (F5). | [V] | S18 |
| F17 | `AccessibilityService.onKeyEvent` sees key events "before they are passed to the rest of the system … the device policy, the input method, or applications". Returning true consumes them. It needs key-filtering capability. | [V] | S10 |
| F18 | With the **screen off**, `PhoneWindowManager` clears pass-to-user for `MEDIA_PLAY_PAUSE` and `HEADSETHOOK` and sends them straight to MediaSessionService, and the accessibility filter drops events without pass-to-user. Together with F2, **accessibility key filtering cannot see car AVRCP buttons, or anything with the screen off.** It sees Bluetooth **HID** keys, such as a keyboard-style remote, while the screen is on. | [V2]; HID part [A] | S9 |
| F19 | Accessibility global actions include Back, Home, Recents, Notifications, Quick Settings, Dismiss notification shade, **KEYCODE_HEADSETHOOK**, **DPAD up/down/left/right/center** and Media play/pause. The API levels (headset hook ≈31, DPAD ≈33) are recalled from memory, not checked. | [V] list; levels [A] | S11 |
| F20 | On Android 13+, sideloaded apps hit **restricted settings**: enable them in Settings → Apps → DevOTA → ⋮ → **Allow restricted settings**. | [V] | S12 |
| F21 | `SpeechRecognizer.createOnDeviceSpeechRecognizer` is API 31+. `RecognizerIntent.EXTRA_BIASING_STRINGS` ("strings towards which the recognizer should bias") is **API 33+**, so it is unavailable on the Android 12 phone. | [V] | S13, S14 |
| F22 | Android 12+ blocks starting foreground services from the background, with exemptions: a visible activity, a notification or widget tap, battery optimisation off, among others. **Media-button and Bluetooth events are not listed.** Android 14+ also throws when a background start asks for the `microphone` type, except when a system component starts it, a notification or widget interaction starts it, or a `VoiceInteractionService` app starts it. | [V] | S15 |
| F23 | DevOTA is sideloaded (GitHub Actions / OTA APKs), not on Google Play, so Play's AccessibilityService and phone-call policies do not apply. Android's platform rules still do. | [V] (README distribution) | README |
| F24 | Google's own guidance on BVRA and car features assumes plain Bluetooth. With **Android Auto** the car buttons go to Android Auto's media and call handling instead, and none of this may reach DevOTA. | [A] | — |

**Consequences for the design:**

- **Use the car's next/previous/play-pause for navigation.** They are the only
  buttons that reach a normal app without special roles (F1–F3). DevOTA must
  own "last played" (F4).
- **Call and hang-up need a Telecom call to be reliable.** Hang-up is only
  delivered when there is a call to hang up (F9, F10). Starting from a
  press-with-no-call is only possible through BVRA (F6), and that makes DevOTA
  the car's voice-button target in place of Google Assistant (Q4).
- **Accessibility key filtering is not the answer for car buttons** (F2, F18).
  It is useful for a Bluetooth HID remote and for navigating other apps (§10).

---

## 3. Architecture

```
 car buttons ──AVRCP──► CarMediaSession ─┐
 voice/call ──BVRA───► VoiceCommandTrampolineActivity ─┐
 hang-up / answer ─HFP─► DevotaConnection (self-managed call) ─┤
 BT HID remote ──────► CarNavAccessibilityService.onKeyEvent ─┤   (optional)
                                                               ▼
                          CarControlService (foreground: mediaPlayback|microphone|phoneCall)
                          ├─ SignalNormalizer  → CarSignal{source, button, press, t}
                          ├─ PressClassifier   → single / double / long (per signal)
                          ├─ ButtonMap (editable, per mode)  → CarAction
                          ├─ CarStateMachine: Idle · Menu · Dictating · Transcribing ·
                          │                   Staged · Command · Confirming · Reading · Yielded
                          ├─ Speaker (own TTS→AudioTrack; earcons; interruptible queue)
                          ├─ Recognizers: OnDeviceCommand / HomeWhisper / OpenAI(opt-in)
                          └─ Actions → MethodChannel "devota/car" → Dart CarController
                                         ├─ pane actions: TmuxWatchTransport (terminal_watch.dart)
                                         ├─ in-app terminal: _sendTerminalKey / _runMacro …
                                         ├─ macros: rankTerminalMacros (terminal_macro.dart)
                                         └─ reading: TerminalSpeech / conclusion reader
```

- **Native owns the car session.** The media session, Telecom connection,
  audio focus and routing, and the speaker must keep working with the screen
  off and DevOTA backgrounded. They live in a new Kotlin
  `CarControlService` + `CarMediaSession`, shaped like the existing
  `TerminalNotifications`/`TerminalSpeech` bridge.
- **Dart owns the meaning** (`app/lib/car/`). The grammar, button map,
  menu model and actions sit next to the existing terminal logic, so voice and
  buttons reuse exactly the same send paths as the touch UI.
- **Target = one bound tmux pane.** Car actions go to a **selected
  notification-bound pane** through `TmuxWatchTransport` (pane-identity
  guarded, preflight-captured, works in the background). They do not go to the
  interactive terminal widget, which needs the Flutter UI alive and focused. UI
  commands (§8.6) are the exception: they act on the visible app.
- **Nothing new on the server side.** One small host helper is added: a
  transcription twin of `server/terminal_review.py` that forwards audio to
  Whisper Notes `/v1/transcribe` over the existing SSH channel. No running
  service is restarted by this proposal.

**Microphone from the background (F22).** A foreground service can use the mic
only if it was started while DevOTA was visible, or by an exempt path. The
design therefore starts the microphone-capable service from:

- (a) the BVRA trampoline activity, since a system-started activity is visible;
- (b) a tap on "Start car mode" while parked; or
- (c) the car-mode notification's action.

Auto-on at car connect (§4.3) starts only the media session and speech. The
mic part starts on the first BVRA press. This is the largest platform
constraint, and it has to be proven in Phase 0 on both Android 12 and 16.

---

## 4. Settings: every car feature has its own switch

### 4.1 Switches

| Setting (pref key) | Values | Recommended default | Effect when OFF |
|---|---|---|---|
| **Car button control** — master (`car_control_enabled`) | on / off | **off** until the owner turns it on once | DevOTA registers no media session, no voice-command handling, no Telecom account and no key filter, and **behaves exactly as today**. The `VOICE_COMMAND` activity alias is **disabled with `PackageManager.setComponentEnabledSetting`**, so the car's voice button goes back to Google Assistant. |
| Auto-on with car (`car_auto_device`) | off / one chosen paired Bluetooth device | **the owner's car** | Car mode must be started by hand. |
| **Dictation on the call button** (`car_dictation_enabled`) | on / off | **on** | Call/voice presses are ignored, and no Telecom call is placed. |
| **Voice commands** (`car_commands_enabled`) | on / off | **on** | Double press and the "command …" prefix are ignored, and speech is always dictation. |
| **Next / previous function** (`car_nextprev_mode`) | Menu focus / Scroll pane / Arrow keys | **Menu focus** | — |
| Up/down arrows (`car_updown_mode`), only if the car sends a separate pair | Scroll / Arrow keys / Menu focus / off | **Scroll** | — |
| **Spoken feedback** (`car_speech_enabled`) | on / off | **on** (turning it off also turns off the master switch while moving, see §11 rule S4) | Earcons only. |
| Verbosity (`car_speech_verbosity`) | Terse / Normal / Verbose | **Terse** | — |
| **Confirm destructive commands** (`car_confirm_destructive`) | on / off (per-command overrides in the grammar table) | **on — recommended to stay on** | Destructive commands run after an echo only. |
| **Screen navigation via accessibility** (`car_a11y_nav_enabled`) | on / off | **off** | The separate accessibility service stays disabled (§10). |
| Command recognizer (`car_command_recognizer`) | On-device / Home Whisper | **On-device** | — |
| Dictation recognizer (`car_dictation_recognizer`) | Home Whisper → on-device fallback / On-device / OpenAI (paid) | **Home Whisper, on-device fallback** | — |
| After hang-up (`car_dictation_send`) | Stage + read back + confirm / Auto-send after read-back countdown / Stage only | **Stage + read back + confirm** | — |
| Command mode ends (`car_command_end`) | "done" + hang-up + 10 s silence / each alone | **all three** | — |
| Passenger privacy (`car_privacy_mode`) | Normal / Don't read terminal text aloud | **Normal**, reachable by voice ("privacy on") | Terminal text is summarised as a status only. |
| Read-back cap (`car_readback_max_words`) | 20–200 | **40 words** | — |
| Target pane (`car_target_pane`) | one of the bound panes | first bound pane | — |
| Button map (`car_button_map_json`) | table (§5.2) | defaults in §5.2 | — |
| Macro confirm (`car_macro_confirm`) | Always / By position only / Never | **By position only** | — |

### 4.2 Where settings live

- **UI:** a new **Car control** screen (`app/lib/car/car_settings_screen.dart`),
  opened from **Terminal → SSH settings**, next to **Notification macros**.
  Car control depends on the same bound panes, so it belongs there. It includes
  a **Button learning** page (§5.3) and the editable button map.
- **Storage:** `SharedPreferences`, using the keys above. Every key is added to
  the allowlists in `app/lib/backup_service.dart` (booleans to the bool list,
  the JSON map to the string list), so Backup export/import and
  `_scheduleServerBackup()` carry them.
- **Editing is parked-only.** The screen is a normal touch UI. While car mode
  is active it shows a single large "Car mode on — settings are for when
  parked" card. The one exception is the master switch (§4.3).

### 4.3 Toggling the master switch safely while driving

1. **Auto on/off with the car (recommended).** Pick the car's paired device
   once. Its `ACTION_ACL_CONNECTED`/`DISCONNECTED` (needs `BLUETOOTH_CONNECT`)
   turns car mode on and off, with one spoken line: "DevOTA car mode on."
   Companion Device Manager is a sturdier alternative for starting from the
   background (F22 exemption 12) [V S15].
2. **By voice, in command mode:** "car mode off", or "buttons off". Turning it
   **on** by voice is impossible when it is off, because nothing listens.
3. **Notification action** "Car mode off" (for passengers or when parked).
4. **Kill switch:** holding play/pause for 3 s speaks "Car buttons off" and
   hands the media keys back to the owner's music [A, needs the car to send a
   long-press].

---

## 5. Buttons

### 5.1 What each button can do (per car capability)

| Physical button | What reaches DevOTA | Reliability |
|---|---|---|
| Next / previous (track ▶▶ / ◀◀, often also the wheel's up/down arrows) | AVRCP → `CarMediaSession.onSkipToNext/Previous` | **High**, if DevOTA owns "last played" (F1–F4) |
| Play/pause (or "mode"/"source" on some cars) | AVRCP → `onPlay`/`onPause`/`onMediaButtonEvent` | **High**; long-press and double-press timing depend on the car [A] |
| Voice (a long press of call on many cars) | BVRA → `VoiceCommandTrampolineActivity` | **Medium**. Car-dependent, and it takes the button from Assistant (F6–F8) |
| Call (short press) with no call active | Usually nothing, or the head unit's own phone menu, or redial (F5) | **Low / none** |
| Call / answer while DevOTA's self-managed call is **ringing** | `onAnswer` | **High** (F9/F10) [A per car] |
| Hang-up while DevOTA's call is active | `onDisconnect` / `onSetCallDisconnected` | **High** (F9/F10) [A per car] |
| Volume up/down | Absolute volume to the car; not a key event for apps [A] | **Unusable** |
| Wheel up/down arrows that only drive the instrument cluster | Nothing (never sent to the phone) [A] | **Unusable** |
| Bluetooth HID steering-wheel remote (≈ $10–20 accessory) | Real key events → accessibility `onKeyEvent` with the screen on (F17/F18) | **High**, if the owner buys one (Q9) |

### 5.2 Default button map (editable)

Modes are **Idle** (car mode on, nothing active), **Menu** (a focus exists),
**Dictating**, **Staged** (a transcript is waiting), **Command**,
**Confirming**, and **Reading** (speech playing). "—" means the button is
ignored and the app says nothing.

| Signal | Idle / Menu | Dictating | Staged | Command | Confirming | Reading |
|---|---|---|---|---|---|---|
| Next | focus next menu item | — | "read again" | — (commands are spoken) | **cancel** | skip to next chunk |
| Previous | focus previous item | — | "read again" | — | **cancel** | Earlier |
| Play/pause (single) | **activate focused item** | stop + transcribe | **submit** | end command mode | **confirm** | stop reading |
| Play/pause (double, if detectable) | enter command mode | — | discard (with confirm) | — | — | — |
| Play/pause (long, if detectable) | repeat last announcement | cancel recording (discard, confirm) | — | — | — | — |
| Voice/call (BVRA) single | **start dictation** | — (stack busy, F7) | re-dictate (replace) | — | **confirm** (where delivered) | stop reading, start dictation |
| Voice/call second press within 600 ms (if delivered) | **command mode** | — | — | — | — | — |
| Answer (DevOTA call ringing) | start the armed action | — | — | — | **confirm** | — |
| Hang-up (DevOTA call active) | — | **stop + transcribe** | — | end command mode | **cancel** | stop reading |
| HID remote OK / arrows | same as play-pause / next / previous | same | same | same | same | same |

The owner edits this table in **Car control → Buttons**. Each cell is a
dropdown of the fixed action list: focus next/prev, activate, dictate, command
mode, stop+transcribe, submit, enter, cancel, confirm, Earlier, stop reading,
scroll up/down, arrow up/down, status, repeat, nothing. It is saved as
`car_button_map_json`, and **Reset to defaults** is one tap.
**Next/previous function** (§4.1) rewrites the Idle/Menu column in one step:
Menu focus, Scroll pane (15 lines per press), or Arrow up/down keys to the
target pane.

### 5.3 Button learning (Phase 0 and a permanent settings page)

"Press each steering-wheel button now." DevOTA listens on every adapter at once
(media session, VOICE_COMMAND, a test Telecom call, accessibility key filter,
Bluetooth audio-state broadcasts). For each press it says what it saw, for
example: *"Next, via media session, 1 event, press held 90 milliseconds."* It
writes a **local** log (signal, source, timings; no audio, no text), which the
owner can export for the proposal's open unknowns. The result pre-fills the
button map and greys out the cells for signals the car never sends.

### 5.4 Fallbacks for cars that do not send a key

- **No BVRA from the car:** dictation starts from the menu item "Dictate"
  (next/previous to it, then play/pause). DevOTA places its own self-managed
  call first, so **hang-up still stops it**.
- **No hang-up delivered:** play/pause stops the recording. It also stops when
  the SCO audio link is dropped (`BluetoothHeadset.ACTION_AUDIO_STATE_CHANGED`)
  [A], or after a 3-minute cap with a 10-second spoken warning.
- **No double press:** use the spoken prefix "command …" (§8.5).
- **No AVRCP ownership** (music keeps stealing the keys): a spoken "take the
  buttons back" command in command mode, or a HID remote (§10).

---

## 6. Spoken feedback

- **What is spoken:**
  - focus changes (the item label only: "Listen, window 2");
  - mode changes, each with a distinct **earcon** (a short tone) plus a word:
    "Recording", "Commands", "Done";
  - results: "Sent to window 2", "Macro 3 sent, waiting for output",
    "Deleted 12 characters: the tests";
  - verdict changes on bound panes, only when they change: "Window 1 reported
    success";
  - errors: "Not sent: window 2 changed".
- **How briefly:** Terse by default. Labels are 1–4 words, results name the
  outcome first ("Sent. Window 2."), and no text is repeated unless asked.
  Normal adds the pane name and counts. Verbose adds a short reason. Read-backs
  of dictation are capped at `car_readback_max_words` (40): the first 25 words
  plus "…and 60 more words". Terminal reading uses the existing reader rules
  (Markdown and escape stripping, code announced as omitted).
- **Interruptibility:** any button press **stops the current speech
  immediately** (≤ 150 ms target), then acts, unless that press is itself
  "repeat". Speech also yields at once to navigation prompts and ride-app
  alerts, through transient ducking audio focus, the same as `TerminalSpeech`
  today, and it stops completely for any real call (§11). Queued announcements
  older than 5 s are dropped, not played late.
- **Voice and route:** speech is synthesised offline (the existing
  offline-voice requirement) into PCM and played by DevOTA's own `AudioTrack`
  (F4). Outside dictation and command mode it plays as media over A2DP. Inside
  them it plays over the open SCO link as voice-call audio, so the route does
  not flap (F14).
- **Secret redaction before speech:** the text passes through a redactor for
  token-like strings (`sk-…`, long base64/hex runs, `password=`, SSH key
  blocks), which are spoken as "redacted". Passenger privacy mode speaks only
  status, never terminal content.

---

## 7. Dictation: call to start, hang-up to stop

**Recommended flow** (BVRA available, with a Telecom call standing for the
recording):

1. The owner presses the **voice/call** button. The car sends BVRA, and
   Android starts `VoiceCommandTrampolineActivity`, which is transparent,
   excluded from recents, and finishes within one frame. It **never covers the
   Uber or DoorDash app**: no layout is drawn, and it does not move the task
   to the front.
2. The trampoline starts `CarControlService` with the **microphone** type
   (legal, because an activity is visible, F22). It then acknowledges the
   Bluetooth voice request, so the stack does not block buttons (F7), and adds
   a **self-managed call** "DevOTA · window 2 · recording" (F9/F10). The call
   gives three things: the car shows a timer, **hang-up is delivered**, and
   Telecom routes the car's mic.
   - Ordering is an **open engineering risk**: acknowledging BVRA and adding a
     call must not fight over the SCO link. Phase 0 tests both orders, and a
     third option that skips `startVoiceRecognition` and adds the call within
     the 5 s window.
3. Earcon plus "Recording, window 2." Audio is captured at 16 kHz mono into
   memory (not disk, the same as Whisper Notes), with a 3-minute cap.
4. The owner presses **hang-up** → `onDisconnect`. DevOTA ends the call, earcon
   plus "Transcribing."
5. The transcript comes from Home Whisper (`/v1/transcribe` through the SSH
   helper), falling back to on-device recognition when home is unreachable
   within 8 s, in which case it says "Using phone recognizer."
6. **Staged**, not typed. The transcript is held in DevOTA and read back:
   "Staged for window 2: *first 25 words* … Press play to send, next to hear it
   again, or call to redo."
7. **Submit:** play/pause, or the voice command "submit". DevOTA runs the same
   preflight as a notification macro (a fresh capture must match the settled
   pane), then `TmuxWatchTransport.paste` (bracketed paste), waits 200 ms
   (`terminalPasteSettleTime`), and sends Enter. It says "Sent to window 2."
   If the pane changed, it says "Not sent: window 2 changed. Say submit to try
   again."

**Why stage instead of sending on hang-up.** Whisper can mishear, and it
sometimes invents text on silence, such as a lone "Thank you." A mis-sent
prompt to a coding agent can start long, wrong work. One extra press is the
cheapest guard. The owner can pick auto-send instead (Q5): after the read-back
DevOTA says "Sending in 3", and any button cancels.

**Existing code this extends:**

- `voice_input_service.dart` gains an in-memory recorder and pluggable
  transcribers (home, on-device, OpenAI).
- `terminal_watch.dart` gains `pasteThenEnter(pane, text)`, reusing the
  preflight in `act()`.
- The composer mic in `ssh_terminal_tab.dart` keeps working unchanged. Car
  dictation is a separate path.

**Interruptions while dictating:**

- A real incoming call means Telecom arbitration (§11). DevOTA stops capturing,
  **keeps the partial audio in memory**, and after the call says "Dictation
  paused by a call. Play to transcribe what I have, call to start over."
- Loss of the Bluetooth link does the same, using the phone mic only if the
  owner restarts.

---

## 8. Voice-command mode (double press)

### 8.1 Entering and leaving

- **Enter:** a double press of the call button where the car delivers two
  events, or play/pause double-tap, or a single press followed by the spoken
  prefix "command …" / "computer …" (§8.5). Earcon plus "Commands, window 2."
- **Leave** — recommended **all of**:
  - saying **"done"** (also "that's all", "stop listening");
  - **hang-up**;
  - **10 s of silence**;
  - another double press where available.
  DevOTA says "Commands off." The word "exit" is **never** a mode-exit word,
  because "exit" is the Claude `/exit` command.
- Inside the mode the recognizer loops: one utterance becomes one command,
  which is echoed, then run (or confirmed, then run), and it listens again.
  Several commands per session are normal: "escape", "slash compact", "done".

### 8.2 The grammar

The grammar is a fixed vocabulary with **number slots** (`N`). DevOTA
normalises the recognized text first:

- lowercase and strip punctuation;
- turn number words into digits ("one"…"thirty", "a hundred") inside slots
  only;
- map the common mishearings "to"/"too" → 2 and "for" → 4 **only inside number
  slots**;
- fold "control"/"ctrl"/"ctl".

It then matches **whole phrases** against the table. A phrase must match
exactly, or within one word-level edit of exactly one table entry. Anything
ambiguous or unmatched gets "Didn't catch that" and **does nothing**. Every
match is echoed before or with its action.

**Keys** (sent to the target pane as the bytes from `resolveKeySpec` in
`terminal_pad_key.dart`, through `tmux send-keys -H`):

| Say | Synonyms | Sends | Confirm? |
|---|---|---|---|
| tab | "tab key" | `\t` | no |
| shift tab | "back tab" | `ESC [Z` (in Claude Code this switches mode, including plan mode) | no |
| escape | "escape key", "E S C" | `ESC` (single byte, 0x1B) | no (echo "Escape"). See §8.3 |
| enter | "return", "press enter" | `\r` only | no |
| submit | "send", "send it" | **staged transcript + Enter**, or Enter if nothing is staged (§8.4) | no |
| control C | "control see", "interrupt" | `0x03` | **yes** |
| control D | — | `0x04` (EOF; can end a shell) | **yes** |
| control *letter* | e.g. "control L", "control R" | Ctrl-letter via `resolveKeySpec` | Ctrl-C and Ctrl-D yes, the rest no |
| forward slash | "slash" (alone) | `/` | no |
| plus | — | `+` | no |
| minus | "dash", "hyphen" | `-` | no |
| question mark | — | `?` | no |
| space | — | ` ` | no |
| option N (1–9) | "choose N", "number N" | the digit `N` (picks a numbered choice in agent prompts) | no |
| up / down / left / right [N times] (N ≤ 20) | "arrow up …" | CSI arrows × N | no |
| home / end | — | `ESC[H` / `ESC[F` | no |
| control home / control end | — | `ESC[1;5H` / `ESC[1;5F` | no |
| page up / page down | "PG up" | `ESC[5~` / `ESC[6~` | no |
| backspace [N] [characters] (N 1–200, default 1) | "delete N", "back N" | `0x7F` × N | **yes when N > 30** |
| clear line | — | `0x15` (Ctrl-U) [A: Claude Code's input box behaviour to verify] | **yes** |

**Slash commands** ("slash *word*…" → `/` + words joined by `-`, then Enter):

| Say | Bare synonyms | Sends | Confirm? |
|---|---|---|---|
| slash compact | "compact" | `/compact` + Enter | **yes by default** (irreversible summarisation; per-command switch) |
| slash exit | "exit", "exit Claude", "quit" | `/exit` + Enter | **yes** |
| slash clear | "clear conversation" | `/clear` + Enter | **yes** |
| slash plan | "plan", "plan mode" | `/plan` + Enter | no |
| slash *other* | — | `/other` + Enter, echoed first as "Slash other" | per table (default no) |

The slash table is an **editable list**, because Claude Code's commands change
between versions. Words that are not in the list are still sent after the
echo, and the echo spells them out so a mishearing is audible before Enter.

**Macros:**

| Say | Meaning | Confirm? |
|---|---|---|
| macro N (1–99) | the Nth entry of `rankTerminalMacros(_macros)` (the order of the Macros tab, `build_list_screen.dart` `_rankedMacros`) | **yes by default** ("Macro 3, Cebuano middle. Play to run."). Positions move when macros are reordered or synced from the server |
| macro *name* | fuzzy name match (option, Q7): runs only if exactly one name matches ≥ 0.8 similarity | no by default (the spoken name is the check); echo names it |
| list macros | reads the first 9 as "1, …; 2, …" | no |

Only **Command / Key / Wait** macros run by voice. They go through the
existing pane-targeted runner (`TerminalWatchController.act` path, validated by
`notificationMacroError`). **Device macros are refused while moving** ("Device
macro, run it when parked"), because they drive the screen and may install
builds.

**Terminal reading, windows and scrolling:**

| Say | Synonyms | Action | Confirm? |
|---|---|---|---|
| read | "listen", "read latest" | existing conclusion reader for the target pane | no |
| earlier | "read earlier", "go back" | existing Earlier | no |
| stop | "quiet", "stop reading" | `TerminalSpeech.stop()` | no |
| status | "which window", "how are the windows" | speaks each bound pane's status and verdict | no |
| window N (1–3) | "target N" | select target pane | no |
| scroll up [N] [lines] | "scroll back" | pane enters tmux copy mode, scrolls N lines (default **15**, max 200); speaks the top line in Normal verbosity | no |
| scroll up more | "more" (right after a scroll) | repeats the last distance in the same direction | no |
| scroll down [N] | — | the same, downward | no |
| scroll to bottom | "bottom", "latest" | leaves copy mode (`q` / `send-keys -X cancel`) | no |
| submit / enter / keys **while in copy mode** | — | **DevOTA leaves copy mode first**, so keys never land in copy mode | — |

For the pane, scrolling uses `tmux copy-mode -t PANE` then
`send-keys -X -N n scroll-up` [A: tmux version support to check]. In the
visible in-app terminal it reuses `_enterTmuxScrollMode` and the
`_scrollTmuxCopyMode` arrow sequence. Eyes-free, **"earlier" is the useful
form of scrolling**. Scroll exists for when the screen is glanced at while
stopped.

**UI commands** (they act on the visible DevOTA app; if it is not in front,
DevOTA says "DevOTA isn't open" and does nothing):

| Say | Synonyms | Existing mechanism | Confirm? |
|---|---|---|---|
| open keyboard | "show keyboard" | `_setNativeKeyboardLocked(false)` + `_focusTerminalInput()` (`ssh_terminal_tab.dart`) | no |
| close keyboard | "hide keyboard" | `_hideTerminalKeyboard()` | no |
| maximize | "full screen", "hide tabs" | `_setTerminalFullscreen(true)` (`build_list_screen.dart`) | no |
| minimize | "exit full screen", "show tabs" | `_setTerminalFullscreen(false)` | no |
| open tools | "expand tools", "show tools" | set `_terminalToolsVisible = true` (new explicit setter beside `_toggleTerminalTools`) | no |
| collapse tools | "close tools", "hide tools" | set it false | no |

**Car-mode control:**

| Say | Action | Confirm? |
|---|---|---|
| done | "that's all", "stop listening": leave command mode | no |
| repeat | "say again": repeat last announcement | no |
| cancel | "never mind": cancel a pending confirm or a staged transcript read | no |
| scratch that | discard the staged transcript | **yes** |
| privacy on / privacy off | passenger privacy mode | no |
| car mode off | "buttons off": master switch off | no (safe direction) |
| take the buttons back | re-claim AVRCP by playing a short earcon | no |
| help | reads the six most-used commands | no |

### 8.3 "exit" is not "escape"

- **"escape"** sends one byte, `ESC` (0x1B). In Claude Code that interrupts the
  current response or closes a menu. The session survives, and the owner can
  continue it. It is **not confirmed** by default, but it is echoed "Escape".
- **"exit"** (bare, or "slash exit", "exit Claude", "quit") types `/exit` and
  Enter, which **ends the Claude Code session**. It is **always confirmed**:
  "Exit Claude in window 2? Press play to confirm."
- They sound alike ("ess-" / "eks-"). So "escape" is accepted **only** as
  "escape", "escape key" or "E S C". A recognition that hovers between the two
  (edit distance ≤ 1 from both) is rejected as ambiguous. Q8 asks whether
  "escape" should also be confirmed, since it stops agent work.

### 8.4 "submit" and "enter"

- **enter** always sends exactly one carriage return and nothing else. Use it
  for agent prompts such as "Press Enter to continue", or after "option 1".
- **submit** sends the **staged transcript first**, if one exists (paste, wait
  200 ms, then Enter, the same rule as `commandNeedsEnter`). With nothing
  staged it behaves exactly like enter and says "Enter".
- When a transcript is staged and the owner says "enter", DevOTA warns once:
  "You have staged text. Say submit to send it, or enter again to press Enter
  only." Recommended, so a staged dictation is never silently left behind.

### 8.5 Detecting a double press

- **Call button via BVRA:** after the first `AT+BVRA=1`, the stack **drops
  further presses for about 5 s** unless DevOTA acknowledges with
  `startVoiceRecognition` (F7). After an acknowledgement, a second press
  probably sends `AT+BVRA=0` (voice recognition off), which Android handles
  internally [A]. **So a call-button double press most likely cannot be seen
  as two events.** This is the first thing Phase 0 measures.
- **Call button delivered as AVRCP/HEADSETHOOK** (some cars) [A]: every press
  arrives separately, and timing decides — double = two presses within
  **400 ms** (tunable 250–700 ms), long = held ≥ 700 ms. The AndroidX
  `MediaSessionCompat` built-in "double-tap HEADSETHOOK = skip next" must be
  overridden in `onMediaButtonEvent`.
- **During a DevOTA self-managed call,** what a call-button press sends is
  unknown (nothing, hold, or swap) [A]. Phase 0 checks this.

**Fallback triggers**, in the recommended order:

1. **Spoken prefix.** A single press starts listening, and if the first word is
   "command" (or "computer"), the rest is a command and command mode stays
   open. It works on every car and needs no timing.
2. **Play/pause double-tap** (AVRCP), if the car delivers press and release
   events separately.
3. **Play/pause long-press**, if the car sends a held event.
4. **A HID remote** button.

DevOTA does **not** guess from the transcript whether speech was a command. A
short dictation such as "tab" must never be executed.

### 8.6 Confirmation

- A destructive command is echoed with its target, then waits **6 s** for:
  **confirm** (play/pause; answer or call where delivered; or saying "yes" /
  "confirm") or **cancel** (next, previous, hang-up, "no", "cancel", or
  timeout: "Cancelled").
- Only one pending confirmation at a time.
- A confirmed command re-runs the pane preflight before sending. If the pane
  changed during the confirm window, it says "Not sent: window changed".
- **Destructive by default:** Ctrl-C, Ctrl-D, clear line, `/exit`, `/clear`,
  `/compact`, backspace N > 30, scratch that, macro by position, any macro
  marked destructive, and any future "kill" or "discard" command.
- The switch `car_confirm_destructive` can turn this off (not recommended).
  Per-command overrides live in the editable grammar table.

### 8.7 Backspace read-back

The owner hears what was deleted. That text comes from three sources, in order
of preference:

1. **Staged text** (not yet sent): backspace edits DevOTA's own buffer, so the
   read-back is exact: "Deleted 12 characters: *the tests*."
2. **Text DevOTA itself pasted** into the pane since the last Enter: DevOTA
   keeps a per-pane ledger of that input, so the deleted suffix is known
   exactly, as long as the owner did not type in between.
3. **Otherwise:** tmux capture of the pane before and after, and a diff of the
   cursor line. If exactly one contiguous run disappeared, it is spoken;
   otherwise "Deleted 20 characters" (count only). Agent TUIs redraw boxes,
   so a count-only answer is expected here [A].

N is capped at **200**, and N > **30** needs confirmation. The owner's example
of 30 therefore runs without a confirm, and 31 or more asks first.

### 8.8 The recognizer

| | Android on-device `SpeechRecognizer` | Home Whisper (Whisper Notes `/v1/transcribe`, `large-v3-turbo`) | OpenAI `whisper-1` (today) |
|---|---|---|---|
| Cost | free | free (owner's hardware) | **paid per minute** (hosted) |
| Works in dead zones | **yes** (on-device, API 31+ F21) | no, needs ZeroTier over mobile data | no |
| Latency for a 1–2 s command | streaming, result right after end of speech [A] | upload + queue + GPU; the GPU is shared with Gemma/ComfyUI and can report busy (Whisper Notes docs) [A: not measured] | upload + API [A] |
| Short-command accuracy in road noise | good on common words; biasing only on API 33+ (F21); **unknown on SCO 8/16 kHz audio** [A] | strong on long speech; Whisper **tends to invent text on short or silent clips** [A], which needs voice detection and strict grammar matching | similar to home |
| Grammar bias | `EXTRA_BIASING_STRINGS` (API 33+) with the grammar phrases | `initial_prompt` with the grammar phrases [A: helper support to add] | prompt param |
| Dictation quality | adequate | **best** of the three for long free text [A] | good |

**Recommendation:** commands use **on-device** recognition, because
predictable latency and offline operation matter more than peak accuracy on a
closed grammar. The grammar matcher is strict, so a mis-hearing becomes "didn't
catch that", never a wrong action. **Dictation** uses **home Whisper** with an
on-device fallback. OpenAI is off unless the owner selects it.

**None of these accuracy or latency claims is measured.** Phase 3 includes a
**measurement**: the owner records 50 command utterances and 10 dictations in
the car while parked with the engine and AC running, then plays them through
both recognizers and reports the per-command accuracy observed.

### 8.9 Where each command lands (files)

| Kind | Mechanism | File |
|---|---|---|
| key bytes | `resolveKeySpec()` → `TmuxWatchTransport` new `sendBytes` (`send-keys -H`, which `key()` already uses for named keys) | `terminal_pad_key.dart`, `terminal_watch.dart` |
| paste text / submit | `TmuxWatchTransport.paste` + `terminalPasteSettleTime` + Enter, preflight from `TerminalWatchController.act` | `terminal_watch.dart`, `terminal_submission.dart` |
| macros | `rankTerminalMacros`, `notificationMacroError`, pane runner | `terminal_macro.dart`, `terminal_watch.dart`, `build_list_screen.dart` (`_rankedMacros`) |
| reading / Earlier / stop | conclusion reader + `TerminalSpeech` | `terminal_conclusion.dart`, `terminal_notification_bridge.dart`, `TerminalSpeech.kt` |
| status / verdicts | `PaneObservation` statuses and verdicts | `terminal_watch.dart`, `terminal_conclusion.dart` |
| UI commands | the setters named in §8.2 | `ssh_terminal_tab.dart`, `build_list_screen.dart` |
| in-app terminal (when it is the chosen target) | `_sendTerminalKey`, `_writeToSession`, `_runMacro` | `ssh_terminal_tab.dart` |
| new | grammar, matcher, button map, car controller, settings | `app/lib/car/*.dart` |
| new native | `CarControlService`, `CarMediaSession`, `CarSpeaker`, `DevotaConnectionService`, `VoiceCommandTrampolineActivity`, `CarNavAccessibilityService` | `app/android/.../devota/car/*.kt` |

---

## 9. DevOTA's actions as a spoken menu

Next and previous move through the list. Play/pause activates. Items that
cannot be done eyes-free are **absent while car mode is on**, not disabled and
announced.

1. **Dictate to window N** — the §7 flow.
2. **Listen, window N** — the latest conclusion; next/previous then act as skip
   and Earlier.
3. **Status** — one line per bound pane: status and verdict.
4. **Send Enter, window N** — only when the notification path would offer it.
5. **Macros ›** — a submenu of the ranked terminal macros (Command/Key/Wait
   only). Activating one confirms ("Run Cebuano middle? Play to run").
6. **Select window ›** — the bound panes by label.
7. **Commands** — enter command mode (for cars without a double press).
8. **Reconnect SSH** / **Restart ZeroTier** — the existing notification
   actions, spoken.
9. **Builds ›** — reads "Latest DevOTA build 2026094201 is newer than
   installed." Install is **queued for parking** ("Install queued; it needs a
   tap when parked"), because Android's package installer needs an on-screen
   confirmation.
10. **Car mode off.**

The focus position persists within a drive. The menu wraps around. The first
press after a period of idle speaks the current item instead of moving.

---

## 10. Own accessibility service, a subset for screen navigation

**Proposal:** a **separate** service, `CarNavAccessibilityService` ("DevOTA car
navigation"), **not** an extension of `ControlAccessibilityService`. The
existing service is live MCP and audit infrastructure. Changing its
capabilities could force re-consent or disturb running agents [A]. A separate
service also gives the owner an independent switch ("Screen navigation via
accessibility", default **off**).

**What it does:**

- **Read the focused screen and element in any app.** On a focus event, it
  reads `AccessibilityNodeInfo` for the focused or accessibility-focused node
  (text, content description, role, state) and speaks it through DevOTA's
  speaker: "Accept, button" or "Messages, tab, selected".
- **Move focus among actionable elements and click.** It builds an ordered
  list of clickable, focusable and scrollable nodes in the active window (the
  existing service already walks trees with
  `flagRetrieveInteractiveWindows`). It moves with
  `ACTION_ACCESSIBILITY_FOCUS` and activates with `ACTION_CLICK`. The car's
  next and previous buttons drive it when the button map selects "Screen
  focus" mode. Accessibility focus draws its own highlight box, so no overlay
  is needed.
- **Global actions:** back, home, recents, notifications, dismiss shade, and
  DPAD on newer Android (F19). Scrolling uses `ACTION_SCROLL_FORWARD/BACKWARD`
  on the nearest scrollable node, falling back to `dispatchGesture` swipes
  (the gesture capability already used by the control agent).
- **Key filtering** (`flagRequestFilterKeyEvents`) catches **Bluetooth HID
  remotes and keyboards** while the screen is on (F17). It **cannot** catch
  car AVRCP buttons (F2), HFP call or hang-up (F5), or media or hook keys with
  the screen off (F18). So it is a supplement, not the car path.
- **Only DevOTA's own feedback, no TalkBack behaviour.** It does not request
  `flagRequestTouchExplorationMode`, so normal touch keeps working. This
  matches the existing service, which does not request it either, and the
  touch behaviour is [A] until tested. It does not do double-tap-to-activate
  or gesture takeover, and it has no spoken hints of its own.
- **Terminals:** terminal widgets (DevOTA's xterm view, Termux) expose little or
  no text to accessibility [A]. Terminal content is read from **tmux capture**,
  not from the accessibility tree.

**Costs:**

- **Setup:** Settings → Accessibility → DevOTA car navigation → On. On Android
  13+ a sideloaded app first needs **Allow restricted settings** (F20):
  Settings → Apps → DevOTA → ⋮ → Allow restricted settings. The owner already
  did this for the control agent if that phone is on 13+ [A]. The Android 12
  REVVL V+ has no restricted-settings block.
- **Battery:** event volume scales with screen activity. The service listens
  only to window-state, focus and scroll event types (not `typeAllMask`), and
  uses `setServiceInfo` to go idle (no event types) whenever car mode or the
  switch is off. Cost is expected to be small [A: measure in Phase 4].
- **Security:** it can read every screen, including ride-app rider details and
  bank apps. Rules:
  - node text is **processed in memory only**;
  - it is **never logged, stored, sent to the relay, or included in macro
    evidence**;
  - password nodes (`isPassword`) are spoken as "password field";
  - the §6 redactor applies before speech;
  - the service has **no network code**;
  - it cannot be enabled remotely.
- **Policy:** Google Play's AccessibilityService policy does not apply, because
  DevOTA is sideloaded (F23). Android still shows its own warnings.

**Comparison:**

| | Media session + Telecom (car path) | Own accessibility service |
|---|---|---|
| Sees car next / previous / play | **yes** | no (F2) |
| Sees call / hang-up | **yes** (via BVRA + Telecom call) | no (F5) |
| Works with the screen off | **yes** | no (F18) |
| Navigates other apps' buttons | no | **yes** |
| Catches a Bluetooth HID remote | no | **yes** (screen on) |
| Setup | notification + mic permission, `MANAGE_OWN_CALLS`, voice-command choice | accessibility enable + restricted settings (13+) |
| Risk | Assistant loses the voice button; Telecom quirks per car | reads everything; must stay local |

**Recommended combination:**

- The **media session + Telecom** path is the car control. It is always the
  primary path, because it is the only one that sees the car's buttons.
- The **accessibility service** is an **optional add-on, off by default**, for:
  1. a HID remote, and
  2. navigating another app's buttons **while parked or stopped**.
- Driving use of other apps' buttons is **not** recommended. Tapping into the
  Uber or DoorDash apps by focus is exactly the kind of screen interaction the
  safety rules exclude (§12). Phase 4, only if the owner wants it (Q10).

---

## 11. Audio routing and real calls

**Routing:**

- **Menu and read-backs (Idle, Menu, Reading):** DevOTA's own player, media
  usage, **A2DP**, with transient ducking focus (as `TerminalSpeech` does
  today). If the car does not play A2DP unless its source is set to Bluetooth
  (F15), the owner leaves the source on Bluetooth, or picks the setting "Speak
  over call audio", which uses SCO at call-audio quality (Q6).
- **Dictation and command mode:** inside the self-managed call, Telecom opens
  **SCO/HFP** and the **car mic** is used (F10, F13). Speech plays on the same
  link as voice-call audio. DevOTA never calls `startBluetoothSco` or
  `setCommunicationDevice` under Telecom (F10).
- **Without Telecom** (fallback builds): `setCommunicationDevice` on API 31+
  (F13), with `clearCommunicationDevice` afterwards.
- **Phone-mic fallback:** only when the car link is not available, announced as
  "Using phone mic."

**Real call arrives (rider, customer, support):**

1. **Telecom takes over** (F12). DevOTA receives a hold or disconnect for its
   call, and `AudioManager.OnModeChangedListener` (API 31+, no permission)
   plus audio-focus loss signal it.
2. DevOTA **stops speaking at once**, stops capture (keeping any partial
   dictation in memory), **releases the media session's claim**, so that the
   car's answer and hang-up belong only to the real call, and says nothing
   until the real call ends.
3. After the call, one line: "Back. Dictation paused, play to transcribe what
   I have." Nothing resumes automatically.
4. **DevOTA never auto-answers, rejects or delays a real call.** If a real
   call is ringing, all car buttons pass through to it. DevOTA does not
   consume `onAnswer` for a call it does not own.
5. **Emergency call:** Telecom disconnects DevOTA's call (F12). DevOTA stays
   silent until car mode is re-entered by a button.

Ride-app alerts and navigation prompts take focus. DevOTA ducks or pauses and
never requests exclusive focus (no `AUDIOFOCUS_GAIN` for speech). A DevOTA
"call" ends the moment a ride-app alert plays, only when the owner picks that
option (Q11).

---

## 12. Safety rules

- **S1. No step needs the screen while car mode is on.** Every action is
  reachable by buttons or voice, and every result is spoken. Anything that
  needs a tap is absent from the menu or deferred ("queued for parking").
- **S2. DevOTA never covers another app.** No activity is brought to the front
  by a car event. The BVRA trampoline is transparent and finishes
  immediately. No full-screen notifications or heads-up alerts are posted.
- **S3. Real calls, navigation and ride-app audio always win** (§11).
- **S4. Silence is never success.** If spoken feedback is off, car mode refuses
  to start while it can speak nothing, except earcons for mode changes. A
  failure is always spoken ("Not sent: …").
- **S5. No surprise input.**
  - Every command is echoed.
  - Destructive commands are confirmed (§8.6).
  - Dictation is staged before sending by default.
  - An unmatched or ambiguous phrase does nothing.
  - DevOTA leaves tmux copy mode before sending keys.
- **S6. Preflight before every send.** This is the existing
  settled-snapshot/identity rule. Nothing is retried automatically.
- **S7. Short speech.** Terse wording, a 40-word cap, interruptible by any
  button within 150 ms (target).
- **S8. Privacy.** Secrets are redacted before speech. Passenger privacy mode
  exists. The accessibility text and audio stay on the device. Audio is held
  in memory and sent only to the owner's home server, unless the owner
  selects OpenAI.
- **S9. One gesture never does two things.** Timing-based press classes
  (double or long) are only enabled for signals the Button learning page
  measured as reliable.
- **S10. Easy off.** Car mode goes off automatically on car disconnect, by
  saying "car mode off", from the notification, and with the master switch.
  With the master switch off, DevOTA behaves exactly as today.
- **S11. Legal.** Using steering-wheel buttons and voice is the intended
  hands-free pattern. The owner's local hands-free and phone laws still
  govern, and this proposal is not legal advice.

---

## 13. Test plan

**None of these commands were run for this proposal** (constraints: no adb,
no installs). They are the plan. The emulator runs use an **isolated fixture
APK**, a separate `DEVOTA_APPLICATION_ID` as the existing notification
fixtures use, on a dedicated emulator, never the audit lanes' emulators.

### 13.1 On an emulator (automatable)

| What | How |
|---|---|
| Grammar and normaliser | Pure Dart unit tests: transcript strings to commands, for every synonym, number slot, ambiguity rejection, and exit versus escape. |
| Button-map state machine | Dart tests that feed `CarSignal` sequences through every mode, including confirm timeout, copy-mode exit and staged-text warnings. |
| Media-session navigation | `adb shell input keyevent KEYCODE_MEDIA_NEXT` / `KEYCODE_MEDIA_PREVIOUS` / `KEYCODE_MEDIA_PLAY_PAUSE` with DevOTA in the background. These go through the input pipeline, then fall back to the session. Then `adb shell cmd media_session dispatch next` [A: check `cmd media_session help` first], which uses the MediaSessionService path that AVRCP also reaches. Assert on spoken-announcement callbacks (TTS start via the fixture, as the reader fixture does now) and on a debug event log. |
| Double and long press timing | `input keyevent --longpress …` [A], and scripted down/up pairs at 150/300/450/700 ms spacing. |
| "Last played" ownership | Start a music app on the emulator, then check which session receives `media_session dispatch`, with and without DevOTA's own-player speech. This checks F3/F4. |
| BVRA entry | `adb shell am start -a android.intent.action.VOICE_COMMAND` checks the trampoline: that it is invisible, starts the service, and does not come to the front. It cannot reproduce the stack's 5 s behaviour. |
| Self-managed call lifecycle | The fixture adds a call. A test-only broadcast calls the same disconnect path, and the Telecom state is checked with `adb shell dumpsys telecom`. |
| Real-call interruption | Emulator console: `adb emu gsm call 5551234`, `adb emu gsm accept 5551234`, `adb emu gsm cancel 5551234` during dictation, command mode and reading. Assert immediate stop, retained partial audio, and one post-call line. |
| Pane actions | Reuse the existing isolated Vim/tmux fixture (`scripts/test/terminal-notification-fixture.py`): each key, submit, backspace read-back, macro by position, and scroll/copy-mode exit. File contents are checked exactly. |
| Recognizer plumbing | On-device: emulator images may lack an offline recognizer [A], so use a fake recognizer seam. Home Whisper: a helper test with a synthetic clip, as `scripts/test/terminal-review-smoke.py` does, sent only to the home service. |
| Accessibility navigation | The fixture enables `CarNavAccessibilityService` with `adb shell settings put secure enabled_accessibility_services …` on the **fixture emulator only**. Focus order, click and global-action tests run on a sample app, and a test checks that normal taps still work. |

### 13.2 On the owner's real car (manual, parked first, then short drives)

1. **Button learning** (§5.3): which signal each button sends, whether a
   double press of call gives two events, whether long presses are sent, and
   whether hang-up reaches a DevOTA call. The exported log closes F5–F8 and
   F24 for this car.
2. **Voice button choice:** whether the car sends BVRA, and whether Android
   asks which app handles it.
3. **Audio:** read-back audible on A2DP with the radio source on FM or on
   Bluetooth. SCO quality of speech and of the recording, and the delay when
   switching routes.
4. **Recognizer measurement** (§8.8) with the car's mic, engine and AC on.
5. **A real call** from a second phone during dictation and command mode.
6. **The ride apps:** an Uber or DoorDash alert while DevOTA speaks. Its
   screen must stay in front and its sound must win.
7. **A 10-minute drive on familiar roads** with Terse feedback. The owner then
   says what was too long, too quiet or confusing. This is subjective and
   only the owner can judge it.
8. **Android Auto,** if the car uses it: repeat items 1–3 with it connected.

---

## 14. Build phases (rough estimates)

**All durations are estimates** for an agent working with the owner. They
exclude calendar time waiting for car tests and they have not been checked
against past velocity.

| Phase | Scope | Estimate |
|---|---|---|
| **0. Car probe** | Settings master switch; `CarMediaSession` with own-player speech; VOICE_COMMAND trampoline; test self-managed call; SCO audio-state listener; Button learning page and local log. The owner runs it parked. | 2–3 days |
| **1. Spoken menu** | Car settings screen and backup keys; button map and editor; state machine; speaker (queue, earcons, interrupt, redaction); menu items 2–10; auto-on with the car. | 3–5 days |
| **2. Dictation** | Call → Telecom call → in-memory capture → hang-up → home-Whisper helper (SSH, a `terminal_review.py` twin) → on-device fallback → staged read-back → submit with preflight; real-call handling. | 4–6 days |
| **3. Voice commands** | Grammar table and matcher; command-mode loop; confirmations; backspace ledger; scroll and copy mode; UI commands; macro by number and name; the recognizer measurement. | 5–7 days |
| **4. Accessibility navigation** (optional) | `CarNavAccessibilityService`: focus list, read, click, global actions, HID key filter, battery idle. | 3–5 days |
| **5. Hardening** | Car-test fixes, per-car button-map presets, Android 12 versus 16 differences, docs and recorded verification. | 2–4 days + owner drives |

Every phase ships behind the master switch, which defaults to **off**, so no
phase changes today's behaviour for anyone who has not turned it on.

---

## 15. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| The car's call button never reaches DevOTA (no BVRA, or Android Auto intercepts it) | Medium | Menu "Dictate", play/pause trigger, HID remote; hang-up still works through the self-managed call. |
| Double press of call is not observable (F7) | **High** | Spoken "command …" prefix (§8.5); play/pause double-tap. |
| Taking the voice button from **Google Assistant** removes voice navigation ("navigate to …") while driving | High (a real cost) | Q4. The alias is disabled when car mode is off, and a "Assistant" menu item hands off to Assistant (launched explicitly) [A]. |
| Music or Maps take AVRCP ownership mid-drive | Medium | "Take the buttons back"; claim again after DevOTA speech; HID remote. |
| BVRA acknowledgement and the Telecom call fight over SCO | Medium | Phase 0 tests three orderings; the fallback is call-only started from the menu. |
| Background mic restrictions (F22) block recording started by AVRCP alone | Medium | Start the mic service from the BVRA activity, or once per drive while parked; test on Android 12 and 16. |
| Using Telecom for a non-call ("recording as a call") confuses the car (call log entries, "call ended" chimes) | Medium | A clear call name; no system call-log entry by default [A]; the owner judges it in the car. |
| Whisper hallucination or mishearing sends the wrong prompt | Medium | Staging + read-back + confirm; strict grammar for commands. |
| Speech is too long or distracting — the opposite of safe | Medium | Terse default, word cap, any-button interrupt, owner review after the first drive. |
| Reading terminal text aloud in front of passengers leaks work or secrets | Medium | Redactor; privacy mode by voice. |
| Changes disturb the live MCP / camera-audit infrastructure | Low if the rules are followed | Separate accessibility service; no edits to `ControlAccessibilityService`, `devota.yaml` or the server; fixture emulators only; the master switch defaults to off. |
| Device differences (REVVL Android 12 versus Android 16) | Medium | API-gated features (biasing is 33+); test both. |
| Battery | Low–medium | One foreground service only while car mode is on; accessibility idles when off. |

---

## 16. Open questions for the owner

The first option in each question is the recommended one.

**Q1. What is the car, and how does the phone connect?**
- a) Plain Bluetooth (phone + media), no Android Auto — *recommended target*
- b) Android Auto (wired or wireless)
- c) Both, depending on the day
- d) Not sure; I'll run the Phase 0 probe and it will tell us

**Q2. Which phone rides in the car?**
- a) The Android 16 phone (the REVVL 7 Pro profile) — recommended, more APIs
  (biasing, newer accessibility actions)
- b) The REVVL V+ 5G on Android 12
- c) Either; support both

**Q3. How should the first build's car buttons behave by default?**
- a) Next/previous = menu focus, play/pause = activate, call = dictate, hang-up = stop — *recommended*
- b) Next/previous = scroll the target window, play/pause = Listen
- c) Next/previous = arrow up/down keys to the agent (for picking options)

**Q4. The car's voice button is used by Google Assistant today. May DevOTA take it while car mode is on?**
- a) Yes, only while car mode is on; it returns to Assistant when car mode is off — *recommended*
- b) Yes, always
- c) No. Start dictation from the menu or play/pause only, and keep Assistant

**Q5. What happens after hang-up?**
- a) Stage, read back, press play (or say "submit") to send — *recommended*
- b) Read back, then auto-send after a 3-second countdown that any button cancels
- c) Send immediately; no read-back

**Q6. Where should DevOTA's voice play when you aren't recording?**
- a) Media audio (A2DP), and I'll keep the car on Bluetooth audio — *recommended*
- b) Always over call audio (SCO), heard on any source but lower quality and slower to start
- c) Decide per the Phase 0 test

**Q7. How should voice commands pick macros?**
- a) "macro N" by position with confirmation, plus "macro *name*" with no confirmation — *recommended*
- b) Position only, with confirmation
- c) Names only
- d) Position only, no confirmation

**Q8. Should "escape" (interrupts the agent) also need confirmation?**
- a) No; echo only, since the session survives — *recommended*
- b) Yes, like Ctrl-C
- c) Only while the target window is Working (output changing)

**Q9. Would you add a cheap Bluetooth steering-wheel remote (≈ $10–20) if your car's own buttons fall short?**
- a) Only if Phase 0 shows the car's buttons are not enough — *recommended*
- b) Yes, plan for it from the start
- c) No, car buttons only

**Q10. Screen navigation of other apps through DevOTA's own accessibility service?**
- a) Build it later (Phase 4), off by default, for parked or stopped use — *recommended*
- b) Build it now, alongside the car path
- c) Don't build it

**Q11. When a ride-app alert (a new trip offer) sounds during dictation:**
- a) DevOTA ducks and keeps recording; the alert is heard over it — *recommended*
- b) DevOTA pauses recording until the alert ends
- c) DevOTA ends the recording, stages what it has, and goes quiet

**Q12. Which recognizers?**
- a) On-device for commands, home Whisper for dictation (on-device fallback), OpenAI off — *recommended*
- b) Home Whisper for both
- c) On-device for both (fully offline)
- d) Keep OpenAI for dictation (paid)

**Q13. How should car mode turn on?**
- a) Automatically when the car's Bluetooth connects, with a spoken line — *recommended*
- b) Only by hand, before driving
- c) Automatically, but silently

**Q14. How should command mode end?**
- a) "done", hang-up, or 10 s of silence — *recommended*
- b) Only "done" or hang-up (stays open until told)
- c) After each single command

**Q15. How much should DevOTA say?**
- a) Terse, 40-word read-back cap — *recommended*
- b) Normal: pane names and counts
- c) Verbose

---

## Sources

- **S1** Android Developers, *Responding to media buttons*: https://developer.android.com/media/legacy/media-buttons
- **S2** Key Mapper issue #2275, AT+BVRA blocks presses about 5 s (quotes the AOSP HFP flow): https://github.com/keymapperorg/KeyMapper/issues/2275
- **S3** Home Assistant Android issue #4126, `VOICE_COMMAND` intent filter for BVRA: https://github.com/home-assistant/android/issues/4126
- **S4** Google Assistant accessories, *Bluetooth voice optimization* (BVRA starts Assistant sessions): https://developers.google.com/assistant/accessories/integrate/bluetooth/voice-optimization
- **S5** `ConnectionService` Javadoc (mirrored by Microsoft Learn): https://learn.microsoft.com/en-us/dotnet/api/android.telecom.connectionservice?view=net-android-35.0 (original: https://developer.android.com/reference/android/telecom/ConnectionService)
- **S6** Android Developers, *Core-Telecom*: https://developer.android.com/develop/connectivity/telecom/voip-app/telecom
- **S7** Android Developers, *Audio Manager self-managed call guide*: https://developer.android.com/develop/connectivity/bluetooth/ble-audio/audio-manager
- **S8** Android Developers, *Manage calls using the Telecom API*: https://developer.android.com/develop/connectivity/bluetooth/ble-audio/telecom-api-managed-calls
- **S9** like-current-song issue #158, media-key dispatch analysis (AVRCP → `dispatchMediaKeyEvent`; screen-off accessibility): https://github.com/Osasuwu/like-current-song/issues/158
- **S10** `AccessibilityService.onKeyEvent` Javadoc (mirror): https://learn.microsoft.com/en-us/dotnet/api/android.accessibilityservices.accessibilityservice.onkeyevent?view=net-android-35.0
- **S11** Accessibility global actions (mirror): https://learn.microsoft.com/en-us/dotnet/api/android.accessibilityservices.globalaction?view=net-android-35.0
- **S12** Google Help, *Allow restricted settings*: https://support.google.com/android/answer/12623953
- **S13** `RecognizerIntent.EXTRA_BIASING_STRINGS` (API 33) (mirror): https://learn.microsoft.com/en-us/dotnet/api/android.speech.recognizerintent.extrabiasingstrings?view=net-android-35.0
- **S14** `SpeechRecognizer.createOnDeviceSpeechRecognizer` (API 31) (mirror): https://learn.microsoft.com/en-us/dotnet/api/android.speech.speechrecognizer.createondevicespeechrecognizer?view=net-android-35.0
- **S15** Android Developers, *Restrictions on starting a foreground service from the background*: https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start
- **S16** Tasker group, intercepting the steering-wheel CALL button: https://groups.google.com/g/tasker/c/CrqnzlRKQ1Y ; XDA, intercept AT+BLDN: https://xdaforums.com/t/request-module-to-intercept-bluetooth-redial-action-at-bldn.3315784/
- **S17** AOSP, *Support third-party calling apps*: https://source.android.com/docs/core/connect/third-party-call-apps
- **S18** Android key codes (mirror of `KeyEvent`): https://learn.microsoft.com/en-us/dotnet/api/android.views.keycode?view=net-android-35.0
- **S19** dumble PR #174, `EXTRA_ADD_SELF_MANAGED_CALLS_TO_INCALLSERVICE=false` hides calls from Bluetooth: https://github.com/danstiner/dumble/pull/174

AOSP source (`HeadsetSystemInterface`, `HeadsetStateMachine`) could not be
fetched during this research: googlesource returned 503 and the GitHub mirrors
returned 404. The [V2] claims therefore rest on the secondary sources above,
and Phase 0 exists to confirm them on the owner's hardware.

## Owner decisions (2026-09-28)

| # | Decision |
|---|---|
| Q1 | Plain Bluetooth (phone + media), no Android Auto. |
| Q2 | The Android 16 phone (REVVL 7 Pro profile). |
| Q4 | DevOTA takes the car's voice button **only while car mode is on**, and gives it back to Google Assistant when car mode is off. |
| Q5 | After hang-up: stage the text, read it back, and send only on play or a spoken "submit". |
| Q3, Q6–Q15 | The recommended options, unless the owner says otherwise. |

Owner requirements given during design, which are all in the proposal: a double-press or voice trigger for command mode; keys, macros by number, slash commands (a bare "exit" maps to /exit), UI commands, submit/enter, backspace N, scroll; every car feature switchable on and off; and an optional, minimal accessibility service of DevOTA's own.
