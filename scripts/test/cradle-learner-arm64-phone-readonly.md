# Signed ARM64 Cradlespeak phone check (read only)

This renders one fixture-bound DevOTA device macro for a phone whose model,
Android SDK, screen geometry and density have been observed. The macro launches the installed app, observes the
selected peer's CENC3 full-sync block, opens an existing owned book, taps one
unique bound word, and observes its contextual lookup. It never installs,
imports, syncs, classifies, purchases, edits, or asks for a human checkpoint.

## Required preflight

1. The signed ARM64 Cradlespeak build must already be installed on a compatible
   phone. Verify its
   package version and signer separately; `launchApp` cannot attest a build.
2. Read the phone's exact model, Android SDK, short and long screen sides, and
   density from a read-only device status/profile response. Do not infer these
   from an earlier REVVL device or an established relay socket. The first
   macro step checks every supplied value and stops on a mismatch.
3. In the app, select an existing CENC3 peer whose compatibility probe reports
   that full sync is unsupported. Do not start a full transfer. Record the exact
   selected peer origin and the three visible, localized labels: incompatibility
   warning, disabled full-sync button, and language-picker button.
4. The phone must already own a book with a visible, unique word occurrence and
   a persisted contextual lookup. Record the book ID, visible title, exact
   occurrence ID, accessibility content description of the word, and expected
   lookup text from a read-only fixture inspection. The macro label records the
   occurrence ID; the exact ID binding still needs backend evidence or a known
   fixture map. Do not create or classify content merely to run this macro.
5. The DevOTA phone agent must be visibly connected, its accessibility service
   and whole-device control enabled, and Macros synced. A relay socket alone
   does not establish visible control.

Render, then validate before publishing to the DevOTA build server:

```bash
python3 scripts/test/cradle-learner-arm64-phone-readonly.py \
  --device-model "$OBSERVED_PHONE_MODEL" \
  --android-sdk "$OBSERVED_PHONE_SDK" \
  --short-side-px "$OBSERVED_SHORT_SIDE_PX" \
  --long-side-px "$OBSERVED_LONG_SIDE_PX" \
  --density-dpi "$OBSERVED_DENSITY_DPI" \
  --peer-url 'https://EXISTING-PEER' \
  --book-id 'EXISTING-OWNED-BOOK-ID' \
  --book-title 'VISIBLE BOOK TITLE' \
  --occurrence-id 'EXACT-OCCURRENCE-ID' \
  --tap-description 'UNIQUE ACCESSIBILITY WORD DESCRIPTION' \
  --sync-block-text 'EXACT VISIBLE LOCALIZED WARNING' \
  --sync-now-text 'EXACT VISIBLE FULL-SYNC BUTTON' \
  --choose-languages-text 'EXACT VISIBLE LANGUAGE-PICKER BUTTON' \
  --lookup-text 'EXACT VISIBLE LOOKUP RESULT' \
  --output /private/evidence/cradle-arm64-phone-readonly.macro.json
```

The generated macro is accepted by `devota_server.normalize_macro`. It uses
only `assertDeviceProfile`, `launchApp`, `launchIntent`, `assertUi`, and `tapUi`.
The unique `tapUi` selector fails closed when zero or multiple nodes match.
Capture is sparse: launch, sync block, reader, and lookup only. Run it from
DevOTA's Macros screen, then collect the **run ID**, per-step screenshots and
UI trees. Review the sync screenshot/tree to verify **Sync now is disabled**;
the current `assertUi` action checks visible text but cannot assert a node's
enabled property. Never tap that button to prove the block.

## Memory observation

The current DevOTA device macro has no action that reports Cradlespeak's PSS.
`assertDeviceProfile` reports hardware shape, not app RAM. If the **same
physical phone** also has an authorized local ADB transport, start this
bounded read-only observer immediately before the macro:

```bash
python3 scripts/test/cradle-learner-arm64-memory-observer.py \
  --serial EXACT-PHYSICAL-ADB-SERIAL \
  --device-model "$OBSERVED_PHONE_MODEL" \
  --android-sdk "$OBSERVED_PHONE_SDK" \
  --output-dir /private/evidence/phone-meminfo \
  --duration-seconds 180 --interval-seconds 5
```

It refuses a different model/SDK, samples `dumpsys meminfo` for the app every
five seconds, and saves timestamped raw files plus a PSS summary. Compare its
timestamps with the DevOTA step times and report baseline, peak, and endpoint
PSS only when the same phone is identified in both records. An emulator or a
different ADB device does not establish phone RAM. The currently connected
phone is DevOTA-only and has no ADB transport, so this observer cannot be used
for that session. Without an ADB connection,
the macro provides UI evidence only and phone memory remains unmeasured.

No physical-phone run or memory result is implied by rendering or publishing
this macro. A successful run also does not prove full-corpus RAM, a completed
sync, or authorization for a different peer/profile.

## Emulator route check, September 25

On the preserved API36 x86 emulator `emulator-5554` with debug build 2153,
`adb shell am start -W -a android.intent.action.VIEW -d cradle:///sync -p
io.github.chasekolozsy.cradlespeak` returned `Status: ok` and delivered the
intent to `MainActivity`. A subsequent UIAutomator dump showed `Sync`, the
saved peer `http://10.0.2.2:18003`, `Sync now`, the protected-library warning,
and `Choose languages instead`. This checks actual navigation despite the
claim-specific `_onDeepLink` handler in app code.

The same intent command with
`cradle:///native-gateway/book/book-9402d14230f2411a3692591fce6982c0`
also returned `Status: ok`. Its UI showed the GuidedReader shell (`Books` and
`Retry`); that book did **not** load under the emulator's current content
server/license configuration. Thus this check proves reader-route dispatch,
not successful reader content or exact-occurrence lookup. The renderer's
reader-title assertion will fail closed until an accessible owned phone
fixture is verified. No physical phone was controlled in this route check.
