# Passive listening — hands-free voice control (phone only)

Status: **built 2026-09-29, not yet tried on the owner's phone.** Target
device: REVVL V+ 5G, Android 12 (sdk 31).

This replaces the abandoned steering-wheel attempt
(`docs/steering-wheel-control-proposal.md`). Nothing here touches Bluetooth,
media sessions, Telecom or call permissions.

## Owner decisions

| Topic | Decision |
|---|---|
| Switch | **Passive listening**, off by default, on the Terminal tab (mic button in the connection bar) and in the SSH session notification. |
| Service | While on, a foreground service of type **microphone**, started only while DevOTA is visible, keeps listening with the screen off and shows an ongoing "DevOTA · Listening" notification with **Stop**. |
| Recognizer | The phone's **Google SpeechRecognizer** (`SpeechRecognizer.createSpeechRecognizer`), restarted continuously. |
| Utterances | Every utterance is a **command** (only when the *whole* utterance matches the grammar) or **dictation** (appended to a per-window draft). A command word inside a longer sentence stays dictation. |
| Sending | Only **submit** (draft text + Enter) or an explicit key command ever sends anything. |
| Read-back | **None automatic.** "read it back" speaks the draft on request. |
| Confirmation | Destructive commands ask "…? Say yes to confirm." |
| Feedback | A rising chirp for a recognized command, a soft tick for dictation, a falling pair for an error; the draft is on screen; speech uses Android TTS. |
| Target | The windows bound in the Terminal tab (SSH settings → Notification macros), numbered as in the notification. "window N" switches. |

## How to use it

1. Terminal tab: connect SSH and bind at least one window (SSH settings →
   Notification macros).
2. Tap the **mic** button in the connection bar (or **Passive listening** in
   the SSH notification, which opens DevOTA and turns it on). Allow the
   microphone the first time.
3. Talk. Pause briefly before and after a command so it arrives as its own
   utterance. Everything that is not a command collects in the draft shown in
   the banner.
4. Say **submit** to send the draft to the target window.
5. Turn it off with the mic button, the banner's stop button, **Stop** in the
   notification, or by saying **stop listening**.

## The grammar

Normalisation: lowercase, punctuation stripped, "/" read as "slash",
"ctrl"/"ctl" → "control", "back space" → "backspace". Numbers are accepted as
digits or words ("twenty five", "a hundred") and, **inside a number slot
only**, the mishearings "to/too" → 2 and "for" → 4. There is no fuzzy
matching.

| Say | Does | Asks first? |
|---|---|---|
| submit · send it | draft + Enter to the target (Enter alone when the draft is empty); the draft is cleared only when the send succeeds | no |
| enter · press enter · return | Enter. With a draft waiting it first warns once: "Say submit to send it, or enter again for Enter only." | no |
| escape · escape key · esc | ESC | no |
| tab · shift tab | Tab / back-tab | no |
| control *letter* (control C, control see, Ctrl-C) | Ctrl-letter | **C and D** |
| control home · control end | ESC[1;5H / ESC[1;5F | no |
| page up · page down | ESC[5~ / ESC[6~ | no |
| arrow up/down/left/right [N] [times] · up arrow | arrow keys (N ≤ 20) | no |
| option N (1–9) | the digit, for numbered agent choices | no |
| backspace [N] [characters/times] · delete N characters | with a **draft**: removes N characters from the draft; with no draft: N × DEL to the window (N ≤ 200) | **N > 30** (window only) |
| clear line | Ctrl-U | **yes** |
| scroll up/down [N] [lines] · scroll to (the) bottom | tmux copy-mode scroll (default 15) / leave copy mode | no |
| macro N | the Nth macro in Macros-tab order (device macros refuse) | **yes** ("Macro 3, name, in window 1?") |
| macro *name* | the one macro whose name matches (exact, else a single ≥ 0.8 similarity); **an unknown name is dictation** | no |
| list macros | speaks the first nine | no |
| slash *word(s)* · /compact | `/word-word` + Enter (1–3 words) | **exit, clear, compact, and any command not in Claude Code's built-in list** |
| exit · exit claude · quit | `/exit` + Enter | **yes** |
| compact · clear conversation · plan mode | `/compact`, `/clear`, `/plan` | compact and clear |
| window N · target N · switch to window N | select the target | no |
| which window | speaks the window and draft size | no |
| read it back · read back · read (the) draft | speaks the draft | no |
| clear draft · clear the draft | empties the draft | **yes** |
| stop listening | turns the switch off | no |
| open/show keyboard · close/hide keyboard | the Terminal tab's keyboard (only while DevOTA is on screen) | no |

While a confirmation is pending: **yes / yeah / yep / confirm** runs it;
**no / nope / cancel / never mind** cancels; anything else cancels ("Cancelled.")
and is then handled normally; after **12 s** it cancels by itself. Outside a
confirmation, yes/no/cancel are ordinary dictation, because they are also
answers to the agent.

Deliberately **not** commands (they are common one-word answers or sentence
starts): bare up/down/left/right, home/end, plan, read, stop, done, more,
help. A sentence that starts with "slash" and runs longer than three words is
dictation.

## Where things live

| Part | File |
|---|---|
| Grammar | `app/lib/voice/voice_grammar.dart` (recovered from `e71eb7b`, fuzzy matching removed) |
| Draft / target / confirm state machine | `app/lib/voice/voice_controller.dart` |
| Switch + channel `devota/passive_voice` | `app/lib/voice/passive_voice_session.dart` |
| Guarded pane input (keys, paste + Enter, macros, scroll, backspace) | `TerminalWatchController.voice*` in `app/lib/terminal_watch.dart` (recovered from `8c604b6`) |
| Terminal tab UI | `app/lib/ssh_terminal_tab.dart` |
| Service, recognizer, TTS, tones | `app/android/.../voice/PassiveVoiceService.kt` |
| Loop, back-off, audio policies, start gate | `.../voice/ListeningLoop.kt`, `.../voice/VoicePolicy.kt` (pure Kotlin, JVM-tested) |
| Channel + notification switch | `.../voice/PassiveVoice.kt` |

Input reaches a window through the same guards as the notification buttons:
pane identity is checked on every tmux command, the observation must be
fresh, one input at a time, tmux copy mode is left first, and **text and
macros need a settled screen** (the notification quiet period, default
10 s) that a fresh capture still matches. So "submit" while the agent is
still printing says "Not sent: window still changing. The draft is kept."
Keys such as Escape and Ctrl-C only need a fresh, identified pane, because
interrupting a working agent is their purpose. Nothing is retried.

`server/terminal_transcribe.py` (home Whisper) is **not used**: the owner
chose the phone recognizer.

## The listening loop (Android)

- One `SpeechRecognizer` session after another, free-form, top result only.
  Each final result goes to Dart, which answers with a tone and optional
  speech; listening resumes after the tone/speech (a 5 s timeout resumes it
  if Dart never answers).
- **Holds** pause listening: DevOTA speaking; other **speech** playing
  (`AudioPlaybackCallback`: navigation, voice calls, assistant, and media
  whose content type is speech — podcasts, DevOTA's own Listen reader);
  **any audio mode other than NORMAL** (ringing, carrier calls, VoIP), read
  from `AudioManager` with `OnModeChangedListener` (API 31) — no phone-state
  permission. Music does **not** pause listening.
- DevOTA never talks over the owner: speech that arrives mid-utterance is
  held until the utterance ends.
- **Back-off** (`RestartPolicy`): silence ("no match"/"speech timeout" after
  ≥ 2 s) restarts at once. A no-match that returns instantly, busy, client
  and audio errors back off 0.5 s/1 s → 30 s and recreate the recognizer;
  network/server errors back off 2 s → 60 s; rate-limited waits 60 s;
  permission and language errors stop listening for good. Whatever the
  cause, at most 20 sessions start per minute (then a 15 s pause).
- A partial wake lock is held while on, re-armed per session with a 30-minute
  cap, so back-off timers still fire with the screen off.

### The Android 12 restart beeps

Google's recognizer plays an earcon at the start/end of every session, and a
continuously restarted recognizer beeps every few seconds in silence. There is
no supported extra to turn them off. The legitimate lever DevOTA uses
(**Quiet restart beeps**, SSH settings, default on) is to **mute the media
stream while a session starts and listens, and only when**: nothing audible
is playing, the owner has not muted media already, and the switch is on. It
unmutes the moment listening pauses, other audio starts, DevOTA plays a tone
or speaks, or the service stops. A mute left behind by a killed process is
undone the next time DevOTA or the service starts (persisted flag).
Side effect: while it is quiet, the media volume shows as muted; pressing
volume up unmutes it. Turn the switch off if that is unwelcome.

## When listening stops

- The switch goes off (Terminal tab, banner, notification Stop, "stop
  listening").
- DevOTA is removed from recents (`stopWithTask`, `onTaskRemoved`) or its
  Flutter engine goes away: nothing would be left to decide what speech
  means, so the service does not continue.
- A fatal recognizer error (no microphone permission, no recognizer,
  language unavailable).
- A transcript arriving while the Dart switch is off is answered "stop" and
  never interpreted.

The service is only ever started through `StartGate`: switch on, DevOTA
visible, microphone granted, a recognizer available. It never restarts
itself after a process death (`START_NOT_STICKY`, and a start without the
explicit action stops at once).

## Privacy

Transcripts and drafts live in memory only: they are not logged, not
persisted and not backed up, and a draft is lost when DevOTA closes. The
phone's recognizer may send audio to Google's servers, as Google's own
dictation does. Passive listening hears everyone in range (passengers
included) — their words go into the draft, never to a window, unless
"submit" is said.

## Tests

- `app/test/voice_grammar_test.dart` — whole-utterance commands vs the same
  words in sentences, number words and digits ("backspace twenty"),
  confirmation words only while confirming, slash rules.
- `app/test/voice_controller_test.dart` — drafts per window, submit /
  enter-warning / backspace-on-draft, confirmations (yes, no, timeout, other
  utterance, window unbound meanwhile), macros, keys, failures spoken.
- `app/test/passive_voice_session_test.dart` — switch off means no `start`
  call and every late transcript answered with `stop`; off, stop listening,
  a service stop and dispose all end it.
- `app/test/voice_terminal_test.dart` — the guarded pane input.
- `app/android/app/src/test/.../voice/PassiveVoiceTest.kt` — the loop never
  creates or starts a recognizer while disabled or after disable (stale
  callbacks, queued restarts), holds, back-off schedule, policies, tones.

## Not verified on a real device

Everything below is reasoned from documentation, not measured on the REVVL:

- that the Google recognizer keeps working from a microphone foreground
  service with the screen off on Android 12;
- which stream Google's earcons use on this phone, and so whether muting the
  media stream actually silences them;
- restart cadence in silence, battery drain per hour, and how often the
  recognizer returns instant no-match or busy errors;
- that `AudioPlaybackCallback` reports navigation and podcast players with
  the usages/content types the policy expects;
- that starting from the SSH notification switch reaches the running app on
  every path (warm, cold, locked screen);
- recognition accuracy for short commands in road noise.
