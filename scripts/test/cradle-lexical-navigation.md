# Cradlespeak lexical navigation regression

Use the signed ARM64 preview APK, version 2132 or later. The accepted emulator
is `emulator-5556`, Android 36, 1080×2436, density 480, with ARM64 native bridge.
Do not clear an existing phone's data or change other emulators.

Prerequisites:

- Preview engine `http://10.243.53.96:8002`, with the preserved reviewed Cebuano
  sentence decisions. No paid calls are performed by the test.
- Cradlespeak Settings: lexical session credential connected, hidden words
  visible (or the test words already pronounced), normal reading mode.
- Dismiss fresh-install sync/pronunciation dialogs before testing. The preview
  intentionally forbids sync and content mutations.
- DevOTA accessibility enabled. Sync the Macros tab with the build server.

`cradle-lexical-navigation.macro.json` is a **draft**, not an accepted native
macro. Its trial ID was `cradle-lexical-navigation-20260922`, priority 1000;
it was withdrawn from the shared list after the trials below. It resets
only the reader route, opens the action sentence, selects the lemma, checks
both JEV labels, then repeats through morphology and checks that neither
label remains. Captures are stored after every step. A slow/cold server can
fail the bounded readiness waits; inspect the failed frame instead of adding
blind taps. The macro contains no bearer or recovery secrets.

For emulator exploration, use the selector driver:

```bash
python3 scripts/test/cradle-lexical-ui.py inspect \
  --serial emulator-5556 --output /tmp/cradle-lexical-ui-evidence --name inspect
python3 scripts/test/cradle-lexical-ui.py tap $'Gilatigo\nlatigo' \
  --serial emulator-5556 --output /tmp/cradle-lexical-ui-evidence --name menu
python3 scripts/test/cradle-lexical-ui.py tap latigo \
  --serial emulator-5556 --output /tmp/cradle-lexical-ui-evidence --name lesson
```

Every tap requires exactly one fresh accessibility node. The driver refuses
stale UIAutomator dumps; an animated screen can fail that check honestly.
`type --secret-file <private-path>` neither prints nor captures secret input.
Do not run UIAutomator while a native accessibility macro is executing: Android
automation can interrupt DevOTA's accessibility service. If that happens,
re-enable the service, launch Run from the already-verified control, and inspect
the native run archive instead. Exact native text selectors are case-insensitive;
the sentence selector therefore also has a bounded screen region to distinguish
`Gilatigo` in prose from `gilatigo` in the table. A profile-gated swipe reveals
the example below the expanded sense, and network settling waits are bounded.
The existing yellow superscript lemma notation is not a JEV rank: the ranked
sense cards have explicit first/second-choice labels and colored borders.

The native macro is intended for the prepared English-chrome preview profile;
different screen geometry, language or lesson reading position requires a
separately verified selector path. Physical-phone acceptance is separate from
emulator acceptance.

## Measured outcome, September 22

The direct ADB touch path passed with signed APK 2132: a real classified
sentence opens the exact-form/lemma menu and the lemma's green/yellow sense
cards; the morphology path opens the same lesson without colors. Evidence:
`/tmp/cradle-lexical-ui-evidence/classified-settled.png` and
`authenticated-morph-settled.png`.

Native trials did **not** pass. Initial attempts exposed an interrupted
accessibility service, missing explicit package scope, a partly clipped word,
case-insensitive selector ambiguity and a loading frame. After correcting those
macro prerequisites, the selected native accessibility click navigated to the
lemma directly instead of opening the form menu; it is not equivalent to the
successful finger/ADB-center tap. The last run also captured the app's remote
engine reachability warning. Do not claim a repeatable native acceptance until
that target uses a validated image/gesture or corrected accessibility action.

Last failure: `run-20260923052849576284-cradle-lexical-navigation-20260922`;
archive: `/tmp/cradle-lexical-ui-evidence/native-macro-draft-failure.zip`.
The server retains all trial captures under `.devota-cache/macro-runs/`.
Source is preserved here; withdrawing the unverified shared macro deletes no
test evidence and no Cradlespeak content.
