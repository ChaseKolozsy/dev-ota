# Signed ARM64 Cradlespeak phone check (read only)

This renders one fixture-bound DevOTA device macro for the physical REVVL7 Pro
(TMRV07P5G, Android 36). The macro launches the installed app, observes the
selected peer's CENC3 full-sync block, opens an existing owned book, taps one
unique bound word, and observes its contextual lookup. It never installs,
imports, syncs, classifies, purchases, edits, or asks for a human checkpoint.

## Required preflight

1. The signed ARM64 Cradlespeak build must already be installed. Verify its
   package version and signer separately; `launchApp` cannot attest a build.
2. In the app, select an existing CENC3 peer whose compatibility probe reports
   that full sync is unsupported. Keep English as the display language. Do not
   start a full transfer. Record the exact selected peer origin from the UI.
3. The phone must already own a book with a visible, unique word occurrence and
   a persisted contextual lookup. Record the book ID, visible title, exact
   occurrence ID, accessibility content description of the word, and expected
   lookup text from a read-only fixture inspection. The macro label records the
   occurrence ID; the exact ID binding still needs backend evidence or a known
   fixture map. Do not create or classify content merely to run this macro.
4. The DevOTA phone agent must be visibly connected, its accessibility service
   and whole-device control enabled, and Macros synced. A relay socket alone
   does not establish visible control.

Render, then validate before publishing to the DevOTA build server:

```bash
python3 scripts/test/cradle-learner-arm64-phone-readonly.py \
  --peer-url 'https://EXISTING-PEER' \
  --book-id 'EXISTING-OWNED-BOOK-ID' \
  --book-title 'VISIBLE BOOK TITLE' \
  --occurrence-id 'EXACT-OCCURRENCE-ID' \
  --tap-description 'UNIQUE ACCESSIBILITY WORD DESCRIPTION' \
  --lookup-text 'JEV first choice' \
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
  --output-dir /private/evidence/phone-meminfo \
  --duration-seconds 180 --interval-seconds 5
```

It refuses a different model/SDK, samples `dumpsys meminfo` for the app every
five seconds, and saves timestamped raw files plus a PSS summary. Compare its
timestamps with the DevOTA step times and report baseline, peak, and endpoint
PSS only when the same phone is identified in both records. An emulator or a
different ADB device does not establish phone RAM. Without an ADB connection,
the macro provides UI evidence only and phone memory remains unmeasured.

No physical-phone run or memory result is implied by rendering or publishing
this macro. A successful run also does not prove full-corpus RAM, a completed
sync, or authorization for a different peer/profile.
