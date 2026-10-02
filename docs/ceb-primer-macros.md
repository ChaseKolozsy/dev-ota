# Cebuano Primer Blended Definition macros

`macros/ceb_primer_blended.json` maintains the three served definitions, preserving
their IDs, priorities and tmux windows: forward 1, middle 2, reverse 3.

Shell prompts contain `{{devota:ceb-primer:forward}}`, `middle`, or `reverse`.
The Terminal runner and notification runner resolve the macro through
`POST /macros/resolve` before sending any terminal input. The build server queries
Cradle at `http://localhost:8002/lessons/blended-definition-queue?lang=ceb&source=primer_first_1000`.
Forward requests `limit=20`; middle and reverse fetch the whole queue. Middle
starts at `floor((queue_length - min(20, queue_length)) / 2)`. Reverse takes the
last 20, highest rank first. Short queues supply all remaining words; an empty
roster completes without authoring. No reservations or local-draft scans occur.

DevOTA then calls `/agents/generate` for every selected topic, using standard
Cebuano Blended Definition kits, `selected_register`, `[primer]`, and fresh
isolated directories under `/home/chase/Cradlespeak/batches/devota-ceb-primer`.
It checks the generated kit files and mnemonic_v4 policy locally and adds
`kit_path` and `draft_path` to each assignment. Parent and workers use the supplied
paths without refreshing kits or rechecking generation. A generation failure
stops preparation before any terminal input; partial kits from that failed
preparation are removed. Each Run generates a new set of kits.

Resolution returns an expanded copy; it never saves a static roster into the
macro store. Each Run gets a fresh roster. A selection failure prevents clearing
or typing. Other macros perform no resolution request.

Install the served DevOTA ARM64 debug build with versionCode `2026102201` or
newer, then refresh Macros. Older apps cannot expand the token; the prompt tells
the parent to stop without tools rather than selecting words itself.

The parent trusts the roster, submits worker drafts directly, reviews and repairs
the staged lessons, and approves. Submission and save APIs provide the parent
compile gates. No handoff documents, eligibility rechecks, parent dry compiles,
approval readbacks or tool calls after final approval are part of this workflow.
Cradlespeak owns the generated skill contract in
`desktop/internal/server/handlers/agentgen.go`; generated Blended kits and the
direct-submit helper carry the same contract.
