# Cradlespeak authoring macros

The maintained definitions in `macros/cradlespeak_authoring.json` cover all 17 active terminal authoring macros: three Cebuano Blended Definition directions, eight creative macros, and six commentary macros. Archived benchmarks and device macros are outside this workflow.

Before clearing or typing into the terminal, DevOTA resolves the runtime assignment marker through `POST /macros/resolve`. It reads the live queue, selects up to 20 eligible targets, refreshes isolated Codex kits, and inserts the assignments and local paths into the parent prompt. Empty queues produce an empty assignment list. Failed preparation sends no terminal input.

Forward selects the first 20; middle selects the centered 20; reverse selects the last 20 in reverse order. Existing language and source policies remain: rank-strict creatives take missing Primer entries in rank order; full-pool creatives exclude Primer entries. English and Tagalog full-pool batches preserve the ten Backstage / ten UX mix when available. Cebuano full-pool prioritizes UX, BootEye, then Backstage. Hungarian full-pool uses canonical queue order. Commentary queues use approved creative source lessons missing the chosen commentary style.

Rank-strict kits include `topic_pool.json`; commentary kits include `source_packet.json` and both ordinary and semantic skills. Their existing fetch helpers read these local packets first. The parent delegates drafting, stages each returned draft with `submit_one.py --stage` (or `compile_blended.py --submit`), reviews the insertion compile and staged lesson, repairs issues, and approves. Submission itself is the compile gate. No handoff document, separate compile preflight, eligibility recheck, or tools after final approval are required. Report only counts already observed.

The Cradlespeak generator owns the shared workflow section in the installed authoring skill and the overrides in refreshed language kits. DevOTA must run a build supporting both `{{devota:ceb-primer:...}}` and `{{devota:cradle:...}}` markers; refresh the Macros list after installing that build.
