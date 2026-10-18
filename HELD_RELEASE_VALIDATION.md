# Held combined release, October 17, 2026

Public-build support and typed events have been combined locally. This record
is verification evidence, not a publication or deployment record.

Validated: 114 Lua tests.

The merge preserves public-key consent and inert-without-key behavior,
stable event IDs, typed event helpers and opt-in performance sampling.
JavaScript now defers performance listeners until consent; Android health
summaries carry the same deduplication IDs as other events.

Physical-device and live-service validation is not implied by these checks.
Publishing, tags, marketplace submission and deployments remain held pending
owner approval. Older README test counts describe their earlier branch runs;
this file records the combined candidate.

Remote config wave: 119 Lua tests and 30 JavaScript bridge tests pass. New cases cover typed cache fallback, exposure labels, context isolation, stale identity responses and web mailbox consent. Version 0.4.1 remains held. A packaged love.js runtime test is still a release gate; the bridge tests use a virtual-filesystem double.

Config identifier compatibility audit: 6 focused Lua config cases passed.
Config property keys reject constructor/prototype, including nested JSON properties.
Experiment keys and variant labels may use those words as string values, matching
the server contract. Regression coverage distinguishes those cases. Publishing remains held.
