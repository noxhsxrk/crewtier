# A day with crewtier

A typical exchange, with Claude Code as the lead (any lead works the same way):

> **you:** Add pagination and filtering to GET /orders, with tests.
>
> **lead:** Checked the crew: agy and codex are ready; opencode is out of quota until later. Plan:
> - T1 parse and validate query params → `t1-easy`
> - T2 paged and filtered repository query → `t2-normal`
> - T3 signed cursor tokens → I'll do this one myself (security)
>
> T1 done by agy, tests pass. T2: codex's first attempt failed the repo test (off-by-one on the limit); sent the failure back and it fixed it. T3 done by me. All tests pass. This feature cost me 31% of the tokens doing it alone would have.

Things you can ask the lead at any time:

| ask | what happens |
|---|---|
| "which agents do I have?" | `crewtier agents`: every agent CLI found, with version, sign-in status and whether it has an adapter |
| "who's signed in?" | `crewtier health`: per-worker status and how to fix any problems |
| "are the tiers still right?" | `crewtier models`: pass rate and cost per passed task per model; the lead proposes changes |
| "is crewtier worth it?" | `crewtier report` for day-to-day numbers, or offers a `crewtier bench` A/B run |
| "do it yourself, don't dispatch" | the lead works alone (and can meter it as a baseline) |

