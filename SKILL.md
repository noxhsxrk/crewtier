---
name: crewtier
description: Whichever coding agent the user is talking to becomes the lead - it plans and reviews - while the other coding-agent CLIs installed on the machine (Claude Code, Codex, opencode, Antigravity, Gemini, Copilot, ...) write the code, each task routed to the model that fits its difficulty. Use when the user asks to build, implement or refactor in a repo, to save tokens, to hand work to another agent, dispatch or delegate, or asks which coding agents are installed (in any language).
---

# crewtier

**You are the lead.** You decide *whether* to delegate and at which tier; `crewtier run` decides *who* gets it (installed, signed in, has quota, not you, not API-billed unless allowed) and tells you why. The lead is whatever agent loaded this skill: Claude Code, Codex, opencode, Gemini, or anything else. The lead plans, routes and reviews. Every *other* coding-agent CLI on the machine is a potential worker, including ones that are usually leads themselves (if you are Codex, Claude Code is a worker).
The user talks only to the lead. Goal: spend the lead's tokens on thinking and checking, not typing.

## 0. Who am I, where am I

- Commands below use the `crewtier` CLI (installed by `./install.sh` + `crewtier init`). If it's not on PATH, call the scripts directly: `bash <this skill's folder>/scripts/<script>.sh` with the same arguments (`agents` → `discover.sh`, `health` → `health.sh`, `run` → `worker.sh`, `meter`/`report`/`models` → `measure.sh`, `bench` → `bench.sh`).
- `LEAD` = the binary name of the agent you are: `claude`, `codex`, `opencode`, `agy`, `gemini`, `copilot`, ... Prefix every `crewtier` call with `CREWTIER_LEAD=<name>`. If your global rules file has a crewtier block (added by `crewtier init`), it already tells you your name. The scripts never send work to the lead, so the lead can't delegate to itself.
  (Claude Code is detected automatically from `CLAUDECODE=1`. Other agents must set it.)
- State lives in `~/.crewtier/`: `routing.<lead>.json`, `results.tsv`, `worker-usage.tsv`, `health.tsv`, `bench.tsv`, `trusted.tsv`.
- Prefer the `crewtier` command on your PATH. A copy vendored into the repo (`.agents/skills/crewtier`, from a project-scope install) refuses to run until the user approves its exact contents with `crewtier trust`, because anyone who can push to the repo could have changed it. If you hit that refusal, tell the user and don't work around it.

## 0.5 Every session: who's signed in?

Before routing the first task of a session, run `CREWTIER_LEAD=<lead> crewtier health`. It checks each worker in your routing file:

- `ready`: signed in, answered a one-word ping. (Ready results are cached for 3h.)
- `auth-required`: signed out or the token expired. The detail column says how to sign in.
- `quota-exhausted`: credit, billing, plan or usage limit used up. Re-checked after 60 min.
- `rate-limited`: temporary (429, too many requests). Re-checked after 5 min.
- `error`: something else failed (timeout, crash). Treat it as unavailable for now.

`auth-required` and `error` are re-checked after 10 minutes, so a fresh login is picked up fast. `crewtier run` skips workers in any of these states, marks a worker when it hits one mid-task, saves and resets whatever that worker changed, and moves to the next candidate in the same tier.

You can't complete an interactive sign-in for the user. Ask them to run `crewtier login <agent>` in a terminal (in Claude Code they can type `! crewtier login <agent>`), which runs that CLI's own login and re-checks it.
Tell the user in one line which workers are unavailable and the fix (for example "codex isn't signed in: run `codex login`"), then carry on with the rest. If a whole tier has no ready worker, say so and route that tier one level up, or do it yourself. Run `health --force` after the user says they've signed in again. The ping spends a few of the worker's tokens, never yours.

## 1. Know the fleet (first use; refresh when asked)

1. Run `CREWTIER_LEAD=<lead> crewtier agents` (`--models` adds model lists, `--json` is for parsing). When the user asks which agents are installed, run it and show the table as-is. The lead's row is marked `(you)`.
   - `LOGIN=off` = the user turned that worker off (`crewtier disable <agent>`). Never put it in the routing file or route to it. To turn one on or off, the user runs `crewtier enable|disable <agent>` (`crewtier workers` lists them).
   - `ADAPTER=no` = installed, but no adapter yet. Offer to add it without code changes: confirm its one-shot (headless) mode with `<bin> --help`, then run `crewtier agents add <bin>` (uses the known form shown in HEADLESS) or `crewtier agents add <bin> --headless '<bin> <flags> {prompt}'` (`{model}` optional). Check it with `crewtier health --force --verbose <bin>`. Agents not in the table at all can be added the same way.
2. Get model names per worker with `crewtier agents --models`. It reads each CLI's own list: `opencode models`, `agy models`, `codex debug models` (fetched live from the user's account, with a one-line description and effort levels per model), Claude Code's `haiku`/`sonnet`/`opus`. Use only names from that list; never invent a model name or borrow one from another CLI's list. Read the descriptions: a model described as fast or for easier tasks is a `t1-easy` candidate. For CLIs it can't list (gemini, copilot, user-added), check `<bin> --help` and their config files, and say which names you couldn't verify.
3. Put every usable worker model into a tier (below), using the evidence order in "How the lead judges models". Show the user the table in 8 lines or fewer, with a few words on why each model went where it did, let them correct it, then save `~/.crewtier/routing.<lead>.json` (start from `routing.example.json`).
4. Don't guess flags. Confirm with `<bin> --help` once, then trust the routing file.
5. Run `crewtier health --force` and leave workers that aren't `ready` out of the proposal, or list them as "add once signed in".

### Tiers

| tier | task looks like | pick |
|---|---|---|
| `t1-easy` | boilerplate, rename, add a field, simple CRUD, tests for existing code, docs, config | fastest or cheapest model |
| `t2-normal` | a feature across 2–5 files with a clear spec, moderate refactor | solid mid model |
| `t3-hard` | tricky logic, concurrency, algorithms, cross-module refactor, perf | strongest coding model, high reasoning effort |
| `lead` | unclear bug cause, architecture or design calls, security-sensitive code, anything that failed in t3 | you do it yourself |

Each tier lists candidates in preference order (for example, use a quota-limited plan first while it lasts). `crewtier run` walks the list until one runs, and prints a `route:` line listing every candidate it skipped and why.

Routing file extras (all optional):
- `"timeouts": {"t1-easy": 600, "t2-normal": 1200, "t3-hard": 2400}` — the worker is killed after this many seconds (these are the defaults). A timeout is reported as `TIMED OUT`; treat it as a failed attempt.
- `"paid": true` on a candidate marks it as billed per API call. Paid candidates are skipped unless the user sets `"allow_paid": true` or `CREWTIER_ALLOW_PAID=1`. Ask before turning that on.

### How the lead judges models

Your built-in knowledge of models goes stale, and new models ship every month. Use evidence in this order. The first source that has an answer wins:

1. **Local track record** (strongest): `crewtier models` shows each worker model's pass rate, escalations and typical diff size per tier, from real tasks on this user's repos. Once a model has about 5 or more tasks in a tier:
   - pass rate under about 60%, or escalating often: move it down a tier, or off the list.
   - pass rate 90% or higher: try it one tier up for the next few tasks.
2. **Public coding benchmarks**, if you can browse the web: look up current scores for the models you have on coding-agent leaderboards (e.g. SWE-bench Verified, Terminal-Bench, Aider's polyglot leaderboard), plus the price per token or plan limits. Search for them fresh; don't quote scores from memory. Note the date of what you found.
3. **Your own knowledge**: only for models that neither source covers, and say it's a guess.

Cost matters as much as pass rate: `crewtier models` also shows each worker model's **cost per passed task** (all the tokens it burned on a tier divided by the tasks it actually got through), for workers whose usage can be read (Claude Code, Codex). A cheap model that fails half the time can cost more per finished task than a mid one. `crewtier models --check` lists models a worker CLI offers that your routing file doesn't use yet (opencode can list them; for the others, look up their current models).

Re-check at the end of a session that recorded several tasks, or when the user asks "are the tiers still right?". Propose changes and wait for a yes before editing the routing file.

## 2. Delegate or not

Do it yourself when the change is about 20 lines or less, or the work is mostly thinking (see the `lead` tier). Delegating costs a brief plus a review, so it only pays off when the diff is much bigger than the brief.

Delegate only when all four hold:

1. **Bulk**: mostly typing. The diff will be much bigger than the brief.
2. **Decided**: the design choices are already made; the worker doesn't have to pick an approach.
3. **Verifiable**: there's a command that proves it worked (`Done when:`).
4. **Contained**: a known, small set of files (1–4).

Never delegate, whatever the size: auth / permissions / crypto, payment or money logic, secrets and credentials, database migrations that touch real data, CI / deploy / infra config, deleting data or files in bulk, and anything the user asked *you* to do personally. Do those yourself.

Delegate **execution**, not conversation: "implement X in these files", "write tests for Y", "migrate Z". Don't send a worker questions or ask for its opinion and then reason about the answer. That back-and-forth costs you more than doing it. For pure analysis you do want done elsewhere (e.g. "list every call site of `foo` and what it passes"), use `--read-only`.

### Keep your own cache warm

Your prompt cache is part of the savings. Stay on the same model for the whole session (don't switch lead models mid-task), keep `.crewtier/plan.md` stable and append to it rather than rewriting it, and don't re-read the same large files between tasks. Read the `run` summaries instead.

## 3. Plan

Start from a clean tree (`git status --porcelain`). If it's dirty, ask the user to commit or stash.
Write `.crewtier/plan.md`:

```markdown
# Goal
<one paragraph>
# Constraints
- repo conventions (package manager, code style), files NOT to touch, rules from any repo-specific skill
# Tasks
## T1 — <title>   [tier: t1-easy]
Files: src/a.ts
Do: <concrete steps>
Done when: <command that proves it, e.g. the repo's test command for that file>
## T2 — <title>   [tier: t3-hard]
...
```

Rules: 1–4 files per task. Every task gets a tier, a `Files:` line and a `Done when:` command. Order tasks so each one builds on committed work.

`crewtier run` turns each task into a self-contained brief (`.crewtier/tasks/T1.md` = Goal + Constraints + that task only), so the worker doesn't read the whole plan or the shell mangle a long prompt. Make each task stand on its own: name the files, the function signatures or behaviour you expect, and the edge cases. A vague brief makes the worker search the repo from scratch, which is slow and burns its quota.

The `Done when:` line is run automatically after the worker finishes (when it's a plain command, optionally in backticks). Keep it fast and scoped, e.g. one test file rather than the whole suite.
Tell the user the task list with tiers in 3–8 lines, then go ahead unless the plan is risky or ambiguous.

If a repo-specific skill also applies (for example a team skill with its own conventions or its own allowed tools), its rules win. Copy them into Constraints, and leave out of the routing any worker that skill or company policy doesn't allow for that repo's code.

## 4. Execute

One task at a time by default. Start the meter, then run the task:

```bash
CREWTIER_LEAD=<lead> crewtier meter start T1
CREWTIER_LEAD=<lead> crewtier run T1 t1-easy
```

What comes back is a short summary, not the worker's transcript:

```
crewtier T1 [t1-easy] codex/gpt-5-mini — done — 2m13s
route: skipped agy (quota exhausted), opencode (not installed)
diff:
  src/orders.ts | 24 ++++++++++++-----
verify: pnpm test src/orders.test.ts → PASS
result:
  status: done
  files: src/orders.ts
  verify: pnpm test src/orders.test.ts pass
  notes: none
log: .crewtier/logs/T1-codex.log
```

Exit code: `0` done and verified, `1` verify failed / worker failed / no changes, `3` no worker in the tier could run, `124` timed out. The same facts are in `.crewtier/results/T1.json` (status, worker, model, touched files from git, verify result, skipped candidates, worker token usage when it can be read, patch and log paths) if you'd rather parse than read.

`NO CHANGES` means the worker reported back but nothing in the tree changed. Don't take its word that it's done: look at the result block's notes, then fix the brief or escalate.
Useful options: `--verify "cmd"` / `--no-verify`, `--timeout SEC`, `--read-only`, `--spec FILE` (or `-` for stdin) for a task that isn't in plan.md.

Run the meter on tasks you do yourself (`lead` tier) too. They are the baseline that shows whether delegating saves anything.

### Long conversations

In a long session most of your cost is re-reading the conversation (cache reads), not writing code. When a feature is done and committed and the conversation is long, suggest to the user to start a fresh session for the next feature: the routing file, results and measurements all carry over.

### Parallel (independent tasks only)

When two or more tasks touch different files and don't depend on each other:

```bash
CREWTIER_LEAD=<lead> crewtier run-many T2:t1-easy T3:t1-easy T4:t2-normal
```

Each runs in its own git worktree (dependency folders like `node_modules` are linked, not reinstalled), and leaves a patch instead of touching your tree. Review each summary, then `crewtier apply T2` (or `crewtier discard T2`). Apply one, commit, then the next. Stay sequential when tasks share files or build on each other: merging overlapping patches costs more than it saves.

Only one task at a time writes the main tree. If you start a second `crewtier run` while one is still running there, crewtier moves the new one to its own worktree automatically (apply it later). While a task writes the main tree, don't edit files there yourself: crewtier counts every change in the tree as that task's work.

`crewtier bench --keep` leaves its two worktrees for comparison; remove them afterwards with `crewtier bench --clean`.

## 5. Review

The summary already has the diff stat and the verify result, so you usually don't need to run anything:

1. Diff stat: only the planned files, roughly the size you expected?
2. Verify: `PASS`?
3. Result block: `status: done`, nothing alarming in `notes`?

Only if one of those looks wrong: `git diff -- <that file>`, then `tail -50` of the log if it's still unclear. A `WARNING: read-only task changed files` line means the worker ignored the read-only rule: discard those changes.

## 6. Fix or escalate

- Verify failed: `crewtier run T1 <same tier> --fix`. With no message, it sends the saved verify output back to the same worker's session. Add a message (`--fix "the empty-list case returns 500"`) when you know more than the test says.
- Failed again: discard that task's changes (`git checkout -- <files>`, remove new files) and rerun it one tier up.
- Failed in `t3-hard`: do it yourself.
- `TIMED OUT`: the task is probably too big or too vague. Split it or escalate, don't just retry.
- Hands-off option: `crewtier run T1 t1-easy --auto-escalate`. On a failed verify (or no changes) it does one fix round on the same worker, then saves the attempt as a patch, resets the tree and retries one tier up, t1 → t2 → t3, and stops at you. Use it when the user wants fewer interruptions; it only resets a tree that was clean when the task started.
- Passed: close the meter **before committing** (it measures the diff against HEAD), then commit `T1: <title> [<worker>/<model>]`:

```bash
CREWTIER_LEAD=<lead> crewtier meter end T1        # delegated task: tier, worker and pass/fail come from .crewtier/results/T1.json
CREWTIER_LEAD=<lead> crewtier meter end T3 lead self pass   # a task you did yourself: meter these too, or there is nothing to compare against
```

Keep one meter open at a time, wrapped tightly around one task: start it right before writing the brief (or before starting work on a task you keep), end it right after reviewing the result. Don't leave a meter open while you do other work, and don't open a second one: overlapping windows are flagged and left out of the report.

```bash
```

An escalated task keeps one meter running across all its retries, so its row shows the full cost of the detour.
When a worker stops on a sign-in, quota or rate-limit error, `run` saves what it changed to `.crewtier/patches/<task>.<worker>.partial.patch`, resets the tree, and the next worker starts clean. Mention it in the final report, not mid-run.

## 7. Finish

Report to the user in 2–5 lines: what was built, which tests ran, which worker and model did what, anything escalated or done by the lead, and the lead tokens per task from the `meter end` lines. When the user asks how much the session cost, run `crewtier session` (it reads your whole transcript, no meter needed). If a tier kept escalating, offer to adjust the routing file. Delete `.crewtier/` unless the user wants to keep it, and never commit it. Measurements live in `~/.crewtier/results.tsv`, so deleting `.crewtier/` loses nothing.

## Is it actually saving tokens?

When the user asks, run `CREWTIER_LEAD=<lead> crewtier report`. It groups recorded tasks per lead into `self` and `delegated:<tier>`, and shows cost units per task and per changed line. Explain it in plain words:
- `units/diffline` lower for a delegated tier than for `self`: delegating that kind of task pays off.
- Not cheaper, or fails often: suggest raising the do-it-yourself threshold or moving that tier to a stronger model.
- Fewer than about 5 tasks in a group: say it's too early to tell.

`measure.sh` can read session usage for Claude Code and Codex leads. For other leads it still logs tasks and diff sizes, and says that token counts aren't available, so use that tool's own stats instead (for example `opencode stats`).
For a real A/B number, use the benchmark (Claude Code or Codex as lead):

```bash
crewtier bench --lead claude --task "Add pagination to GET /orders with tests" --test "pnpm test"
```

It runs the same task twice from the same commit, in separate worktrees, with the lead headless: once alone, once using crewtier. Then it runs the same test command on both and prints the lead's tokens, price-weighted cost units, time, test result, diff size and how many tasks were routed. Results go to `~/.crewtier/bench.tsv`. Suggest it when the user asks whether crewtier is worth it for a kind of task. It spends real tokens on both runs, so say so before running it.

## Token rules
- Never paste a worker's full output into your context. The `run` summary is all you need unless a check failed.
- Never re-read files a worker wrote unless a check failed.
- "Done when" must be a command, not something you eyeball.
- No step-by-step narration. Report at the end or when you're blocked.
