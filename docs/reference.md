# crewtier reference

Details behind the [README](../README.md): concepts, the routing file, what `crewtier run` does, health checks, measuring savings, install scopes, the full CLI and environment variables.

## Concepts

### Leads and workers

- The **lead** is whichever agent loaded the skill. It never routes work to itself.
- **Workers** are every other agent CLI crewtier has an adapter for: Claude Code (`claude -p`), Codex (`codex exec`), opencode (`opencode run`), Antigravity (`agy -p`), Muse (`muse exec`), Gemini CLI (`gemini -p`), GitHub Copilot CLI (`copilot -p`). If you lead with Codex, Claude Code is a worker, and the other way round.
- Each worker uses **its own sign-in and plan**. crewtier never handles API keys.

### Tiers

| tier | typical task | goes to |
|---|---|---|
| `t1-easy` | boilerplate, rename, add a field, simple CRUD, tests for existing code, docs, config | fastest / cheapest model |
| `t2-normal` | a feature across 2–5 files with a clear spec, moderate refactor | solid mid model |
| `t3-hard` | tricky logic, concurrency, algorithms, cross-module refactor, performance | strongest coding model, high reasoning effort |
| `lead` | unclear bug, design decisions, security-sensitive code, anything that failed in `t3` | the lead itself |

The lead decides **whether** to delegate and at which tier. The CLI decides **who** gets it.

### When to delegate

The skill only delegates a task when all four hold:

1. **Bulk**: mostly typing; the diff will be much bigger than the brief.
2. **Decided**: the design is settled, so the worker doesn't choose an approach.
3. **Verifiable**: a command proves it worked.
4. **Contained**: a known set of 1–4 files.

It never delegates auth, permissions or crypto, payment logic, secrets, migrations that touch real data, CI/deploy/infra config, or bulk deletions. Small changes (about 20 lines or less) are done by the lead too, because writing the brief and reviewing the diff would cost more than doing it.

It delegates **execution, not conversation**. Asking another model for its opinion and then reasoning about the answer costs the lead more than thinking it through itself.

### The routing file

Saved per lead at `~/.crewtier/routing.<lead>.json`. The lead builds it with you during setup, using your local track record first, fresh public benchmarks second, and its own knowledge last.

```json
{
  "lead": "codex",
  "timeouts": { "t1-easy": 600, "t2-normal": 1200, "t3-hard": 2400 },
  "allow_paid": false,
  "tiers": {
    "t1-easy":   [ { "backend": "agy",     "model": "gemini-flash" },
                   { "backend": "claude",  "model": "haiku" } ],
    "t2-normal": [ { "backend": "copilot", "model": "claude-sonnet" },
                   { "backend": "claude",  "model": "sonnet" } ],
    "t3-hard":   [ { "backend": "claude",  "model": "opus" },
                   { "backend": "opencode","model": "anthropic/claude-opus", "paid": true } ]
  }
}
```

| field | meaning |
|---|---|
| `tiers.<tier>[]` | candidates in preference order: `backend` (worker CLI), `model`, optional `effort` (reasoning effort, Codex) |
| `paid: true` | billed per API call; skipped unless `allow_paid` is true or `CREWTIER_ALLOW_PAID=1` |
| `timeouts` | seconds before a worker is killed, per tier (defaults shown) |

## What `crewtier run` does

```
crewtier T1 [t1-easy] agy/flash — done — 1m42s
route: skipped opencode (quota exhausted)
diff:
  src/orders/params.ts      | 38 ++++++
  src/orders/params.test.ts | 41 ++++++
verify: pnpm test params → PASS
result:
  status: done
  files: src/orders/params.ts, src/orders/params.test.ts
  verify: pnpm test params pass
  notes: none
worker usage: in 4120, out 6890, cache read 51200
log: .crewtier/logs/T1-agy.log · result: .crewtier/results/T1.json
```

**A brief, not a prompt.** The task is cut out of the plan (goal + constraints + that one task) into `.crewtier/tasks/T1.md`. The worker gets a short, fixed prompt that points at it. Long specs never pass through shell quoting, and the worker doesn't read the whole plan. Tasks outside the plan: `--spec FILE` or `--spec -` (stdin).

**Routing with reasons.** Candidates are tried in order. The lead, missing CLIs, signed-out, out-of-quota and rate-limited workers, and paid models (unless allowed) are skipped, and the `route:` line says why.

**Timeouts per tier.** 10, 20 or 40 minutes by default. A worker stuck in a loop is killed and reported as `TIMED OUT` instead of quietly burning quota.

**Verification gate.** The task's `Done when:` command runs after the worker finishes. On failure, `crewtier run T1 t1-easy --fix` (no message needed) sends that output back to the **same worker session**. Add a message when you know more than the test says: `--fix "empty list should return 200, not 404"`.

**Short answers only.** Workers must end with a fixed result block (status, files, verify, notes). The lead sees the summary; the full ANSI-stripped transcript stays in `.crewtier/logs/`.

**"Done" has to show up in git.** A worker that reports success but changed nothing gets `NO CHANGES`, not `done`. Touched files come from git, not from the worker's claim.

**Clean fallbacks.** If a worker stops on a sign-in, quota or rate-limit error after touching files, its partial work is saved to `.crewtier/patches/T1.<worker>.partial.patch`, the tree is reset, and the next worker in the tier starts from the same known state. It only resets a tree that was clean when the task started; otherwise it keeps a copy and warns.

**Read-only tasks.** `--read-only` uses each CLI's plan / read-only mode where it has one ("list every caller of `charge()` and what it passes"), and flags any file a worker changed anyway.

**Auto-escalation (opt-in).** `--auto-escalate`: failed verify → one fix round on the same worker → save the attempt as a patch, reset, retry one tier up → … → back to the lead. Good for when you'd rather not be interrupted.

**Machine-readable result.** `.crewtier/results/T1.json`:

```json
{
  "task": "T1", "tier": "t1-easy", "status": "done",
  "worker": "agy", "model": "flash", "exitCode": 0, "seconds": 102,
  "touchedFiles": ["src/orders/params.ts", "src/orders/params.test.ts"],
  "verify": { "command": "pnpm test params", "result": "PASS" },
  "skipped": ["opencode (quota exhausted)"],
  "workerUsage": null,
  "reported": { "status": "done", "files": "…", "verify": "…", "notes": "none" },
  "patch": null, "log": ".crewtier/logs/T1-agy.log"
}
```

`status` is one of `done`, `no-changes`, `verify-failed`, `worker-failed`, `timed-out`, `no-worker`. Exit codes: `0` done, `1` verify failed / worker failed / no changes, `3` no worker could run, `124` timed out.

## Parallel tasks

```bash
crewtier run-many T2:t1-easy T3:t1-easy T4:t2-normal
crewtier apply T2        # or: crewtier discard T2
```

Each task runs in its own git worktree. `node_modules`, `.venv` and `vendor` are linked instead of reinstalled, and each task leaves a **patch** instead of touching your tree. Apply one, commit, apply the next.

Sequential is the default for a reason: one task, review, commit, next is faster and safer when tasks share files or build on each other. Use `run-many` for genuinely independent tasks.

## Signed in? Out of quota?

```
$ crewtier health
WORKER     STATUS           CHECKED  DETAIL
claude     ready            0m ago   ping ok (haiku)
codex      auth-required    0m ago   run `codex login`
opencode   quota-exhausted  0m ago   You have exceeded your usage limit
agy        rate-limited     2m ago   429 Too Many Requests
```

| status | meaning | re-checked after |
|---|---|---|
| `ready` | signed in, answered a one-word ping | 3 hours (`CREWTIER_HEALTH_TTL`) |
| `auth-required` | signed out or token expired | 10 minutes |
| `quota-exhausted` | credit, billing, plan or usage limit used up | 60 minutes |
| `rate-limited` | temporary (429, overloaded) | 5 minutes |
| `error` | timeout, crash, anything else | 10 minutes |

- **How:** a CLI's own status command where there is one (`codex login status`, `opencode auth list`), otherwise a one-word ping ("Reply with OK") in an empty temp folder. The ping costs a few of the **worker's** tokens, never the lead's. Workers are checked in parallel.
- **When:** the lead checks at the start of every session, and `crewtier run` checks any worker whose result is stale right before using it. Mid-task sign-in or quota errors mark the worker on the spot.
- **Fixing it:** `crewtier login` (or `crewtier login codex`) runs that CLI's own sign-in and re-checks it. In Claude Code you can type `! crewtier login codex` without leaving the chat.

## Is it saving anything?

### Day to day

The lead meters each task (its own tokens, read from its session transcript), and workers' usage is read from theirs where possible.

```
$ crewtier report
lead / group                 tasks   cost_units   avg/task units/diffline  !pass
codex self                       7        88900      12700         1270.0      0
codex delegated:t1-easy         14        19600       1400           70.0      1
codex delegated:t2-normal        9        36000       4000          180.0      2
```

`cost_units` weights tokens roughly by price (output ×5, cache write ×1.25, cache read ×0.1, input ×1). Compare `units/diffline`: lower means it's cheaper for the lead per line of code shipped.

```
$ crewtier models
worker/model @tier                   tasks  pass% escalated  avg_diff
claude/haiku @t1-easy                   12    92%         1        34
agy/gemini-flash @t1-easy                9    56%         4        41

cost per task (worker cost units, runs whose usage could be read):
  worker/model @tier                    runs    avg/run per passed task
  claude/haiku @t1-easy                   13      9100           9858
```

**Cost per passed task** is what a model really costs on a tier: a cheap model that fails half the time can end up dearer than a mid one. The lead uses this to promote or demote models, and asks before changing your routing. `crewtier models --check` lists models your workers offer that the routing file doesn't use yet.

### Benchmark: the same task, with and without crewtier

```bash
crewtier bench --lead claude --task "Add pagination to GET /orders with tests" --test "pnpm test"
```

```
RUN         LEAD_IN  LEAD_OUT CACHE_READ  COST_UNITS     TIME   TEST   DIFF TASKS
self           3000      7000     120000       60000     412s   PASS     96     0
crewtier       1200       900      40000       13450     538s   PASS    101     2
lead cost with crewtier: 22% of doing it alone
```

Both runs start from the same commit in separate worktrees, with the lead running headless (Claude Code or Codex), and finish with the same test command. Planning, reviewing and retries all count. Worker usage is billed to each worker's plan and isn't included in the lead's number. Results are appended to `~/.crewtier/bench.tsv`. Both runs spend real tokens. *(Numbers in this README are illustrative.)*

## Installing in depth

### Scopes

| scope | where | who gets it | use it for |
|---|---|---|---|
| `user` (default) | your home folder | you, in every repo | your own machine |
| `project` | the current repo, committed | everyone who clones it | a team that agrees to work this way |
| `local` | the current repo, kept out of git | only you, only this repo | trying it on one repo without touching anything else |

```bash
crewtier init                          # user scope, asks which leads
crewtier init --scope project --all    # this repo, every lead found, for the team
crewtier init --scope local --lead codex
```

- **Project** copies the skill once into `.agents/skills/crewtier/` and points each agent's skills folder at it with a relative symlink, so it works on every clone. Commit it. Teammates still install the CLI, or the lead calls the scripts in the copied skill (after `crewtier trust`, see [Safety](#safety)).
- **Local** links instead of copying, and lists everything it creates in `.git/info/exclude`. It uses an agent's own git-ignored file where there is one (`CLAUDE.local.md`, `.qwen/QWEN.local.md`) and won't add a block to a rules file that's already tracked by git.

### Leads

Any of these can be the lead. `init` installs the skill where the agent reads skills and adds a short, marked rules block that makes it use crewtier by default and tells it its `CREWTIER_LEAD` name. Agents that share one file (Codex, opencode, Amp, Droid and Kimi all read `AGENTS.md`) get one block naming all of them.

| lead | user scope: skill / rules | project scope: skill / rules |
|---|---|---|
| Claude Code | `~/.claude/skills/` / `~/.claude/CLAUDE.md` | `.claude/skills/` / `CLAUDE.md` |
| Codex | `~/.codex/skills/` / `~/.codex/AGENTS.md` | `.codex/skills/` / `AGENTS.md` |
| opencode | `~/.config/opencode/skills/`¹ / `~/.config/opencode/AGENTS.md` | shared skill / `AGENTS.md` |
| Antigravity CLI | `~/.gemini/antigravity-cli/skills/` / `~/.gemini/GEMINI.md` | shared skill / `GEMINI.md` |
| Gemini CLI | `~/.gemini/skills/` / `~/.gemini/GEMINI.md` | `.gemini/skills/` / `GEMINI.md` |
| GitHub Copilot CLI | `~/.copilot/skills/` / `~/.copilot/copilot-instructions.md` | `.github/skills/` / `.github/copilot-instructions.md` |
| Factory Droid | `~/.factory/skills/` / `~/.factory/AGENTS.md` | `.factory/skills/` / `AGENTS.md` |
| Crush | `~/.config/crush/skills/` / `~/.config/crush/CRUSH.md` | shared skill / `CRUSH.md` |
| Cursor Agent | — / `~/.cursor/rules/crewtier.mdc` | — / `.cursor/rules/crewtier.mdc` |
| Kiro | — / `~/.kiro/steering/crewtier.md` | — / `.kiro/steering/crewtier.md` |
| Cline | — / `~/Documents/Cline/Rules/crewtier.md` | — / `.clinerules/crewtier.md` |
| Continue | — / `~/.continue/rules/crewtier.md` | — / `.continue/rules/crewtier.md` |
| Kilo Code | — / `~/.kilocode/rules/crewtier.md` | — / `.kilocode/rules/crewtier.md` |
| Amp | — / `~/.config/amp/AGENTS.md` | — / `AGENTS.md` |
| Qwen Code | — / `~/.qwen/QWEN.md` | — / `QWEN.md` |
| Kimi CLI | — / `~/.kimi/AGENTS.md` | — / `AGENTS.md` |
| Goose | — / `~/.config/goose/.goosehints` | — / `.goosehints` |
| Aider | no file-based rules: `crewtier prompt aider`, then add it to your config | same |

¹ Skipped when opencode already sees the skill through `~/.claude/skills` or `~/.agents/skills`, so it isn't loaded twice.

`crewtier leads` (or `crewtier leads --scope project`) prints this for your machine. To add an agent that isn't listed: `crewtier init --lead zed --rules ~/.config/zed/rules.md` (optionally `--skills <dir>`).

### Managing installs

```bash
crewtier status                          # everything installed, by scope and lead
crewtier uninstall --scope local         # remove this repo's local install
crewtier uninstall --scope user --lead codex
crewtier uninstall                       # everything (project/local: the repo you're in)
crewtier init --dry-run                  # preview any init
crewtier doctor                          # deps, installs, routing files, worker health, agents
```

Every file `init` creates or edits is recorded in `~/.crewtier/installed.tsv`, and `uninstall` reverses exactly those changes. User-scope rules files are backed up once to `<file>.crewtier.bak`. Running `init` again replaces its own block instead of adding a second one.

## Safety

- **Repo copies fail closed.** A project-scope install vendors the skill into the repo. Those scripts launch other agents with approvals bypassed, so a vendored copy **refuses to run** until you approve its exact contents with `crewtier trust`, which shows how it differs from your installed copy. Any later change needs approving again, so after you update crewtier, re-run `init --scope project` (or `crewtier trust`) in each repo that vendors a copy. `init --scope project` trusts the copy it just made.
- **The lead can't route to itself**, routing files only live in your home folder, and per-call-billed models stay off unless you allow them.
- **Your tree is only reset when it was clean** at the start of the task, and every discarded attempt is saved as a patch first.
- **Workers run with approvals bypassed** (`-s workspace-write`, `--yolo`, `acceptEdits`, …) because headless runs would otherwise hang. Work on a clean git tree; the lead reviews every diff before committing.
- **Company code:** sending it to an agent signed in with a personal account may break your employer's rules. Keep only the allowed workers in that repo's routing.
- No telemetry, no network calls of its own, no credentials touched.

## CLI reference

| command | what it does |
|---|---|
| `crewtier init [--scope user\|project\|local] [--lead X…\|--all] [--no-auto] [--copy] [--dry-run] [--skip-login]` | sign-in check, then install the skill and rules for the chosen leads |
| `crewtier login [agent…]` | sign-in wizard, or sign in to specific agents |
| `crewtier leads [--scope …]` | supported leads and where `init` writes for each |
| `crewtier prompt <lead>` | print the rules text, for agents configured by hand |
| `crewtier status` · `uninstall` · `doctor` | install state · undo · full check-up |
| `crewtier agents add <bin> [--headless 'cmd … {prompt}'] [--name N]` · `agents remove <bin>` | use any agent CLI as a worker without changing code; `{model}` in the template is optional |
| `crewtier routing` · `routing add <tier> <agent> <model> [--effort E] [--first]` · `routing remove|first <tier> <agent> [model]` · `routing edit` | show or change the routing file yourself, no lead needed; warns when a model isn't in the agent's live list |
| `crewtier workers` · `disable <agent…>` · `enable <agent…>` | list workers and turn some off or on; a turned-off worker is never checked or used |
| `crewtier trust [dir]` | approve a repo's vendored copy |
| `crewtier agents [--models\|--json]` | coding-agent CLIs on this machine |
| `crewtier health [--force\|--cached\|--installed\|--verbose] [agent…]` | sign-in / quota status per worker; `--verbose` prints the full output of any failed check |
| `crewtier run <task> <tier> [options]` | run one task on a worker, verify, summarize |
| &nbsp;&nbsp;`--fix ["msg"]` | resume the same worker with the failed verify output (or your message) |
| &nbsp;&nbsp;`--verify "cmd"` · `--no-verify` | override or skip the check command |
| &nbsp;&nbsp;`--timeout SEC` · `--read-only` · `--spec FILE\|-` | time limit · analysis only · brief from a file or stdin |
| &nbsp;&nbsp;`--isolated` · `--auto-escalate` | run in a worktree, leave a patch · fix once, then climb tiers |
| `crewtier run-many T1:tier T2:tier … [-- opts]` | independent tasks in parallel worktrees |
| `crewtier apply <task>` · `discard <task>` | apply / drop an isolated run's patch |
| `crewtier session` | the lead's tokens and cost units for the whole current conversation, lines changed split into worker and lead, and the lead's cost per line shipped (run it in the project folder) |
| `crewtier meter start\|end [task tier worker outcome]` | lead tokens for one task (tier, worker and outcome are read from the task's result when it was run with `crewtier run`); overlapping meters are flagged and left out of `report` |
| `crewtier report` · `models [--check]` · `session` | savings · track record and cost per passed task · lead session totals |
| `crewtier bench --lead claude\|codex --task "…" [--test "cmd"] [--keep]` | A/B benchmark |

The lead calls almost all of these for you. You'll mostly use `init`, `login`, `health` and `doctor`.

## Environment variables

| variable | default | meaning |
|---|---|---|
| `CREWTIER_LEAD` | auto for Claude Code | the lead's binary name; written into each lead's rules by `init` |
| `CREWTIER_ROUTING` | `~/.crewtier/routing.<lead>.json` | use another routing file |
| `CREWTIER_ALLOW_PAID` | off | allow candidates marked `"paid": true` |
| `CREWTIER_HEALTH_TTL` | `10800` | seconds a `ready` result is trusted |
| `CREWTIER_SKIP_HEALTH` | off | skip the pre-run health check |
| `CREWTIER_VERIFY_TIMEOUT` | `900` | seconds the verify command may run |
| `CREWTIER_TAIL` | `10` | lines of worker output shown when there's no result block |
| `CREWTIER_CLAUDE_PERMS` | `acceptEdits` | permission mode for Claude Code as a worker |
| `CREWTIER_TRANSCRIPT` | newest session | lead transcript to meter |
| `CREWTIER_BENCH_CLAUDE_FLAGS` / `_CODEX_FLAGS` | bypass approvals in the bench worktree | lead flags used by `bench` |
| `CREWTIER_BIN_DIR` | `~/.local/bin` | where the `crewtier` command is linked |
| `CREWTIER_NO_SELF_INSTALL` | off | run from the package cache instead of copying to `~/.crewtier/app` |
| `CREWTIER_REF` | `main` | branch or tag `install.sh` downloads |

## Files and state

```
crewtier/
├── SKILL.md               what the lead follows
├── bin/crewtier           the CLI
├── install.sh             curl installer / link a checkout
├── routing.example.json
├── scripts/
│   ├── adapters.sh        one headless adapter per worker CLI, error classification, trust check
│   ├── worker.sh          run one task: brief, route, timeout, verify, fallback, summary, result.json
│   ├── health.sh          sign-in / quota check per worker, cached
│   ├── discover.sh        list installed coding-agent CLIs
│   ├── measure.sh         lead tokens per task, worker usage, reports
│   └── bench.sh           A/B benchmark
└── assets/                banner, icon, demo GIFs (demo/render.py regenerates them)
```

In your repo, `.crewtier/` holds the plan, task briefs, logs, results, patches and worktrees. It's added to `.git/info/exclude` automatically and is safe to delete.

In your home folder, `~/.crewtier/` holds `routing.<lead>.json`, `results.tsv` (lead meters), `worker-usage.tsv`, `bench.tsv`, `health.tsv`, `installed.tsv` and `trusted.tsv`.

## Where it fits

Most delegation tools do one part well: hand a brief to another CLI, route by task type, or run agents side by side in a terminal multiplexer. crewtier's focus is the **whole loop, automated**:

| | crewtier |
|---|---|
| Any agent can lead; every other installed agent CLI is a worker | ✓ |
| Routing by **difficulty tier**, with the reason for every skipped worker | ✓ |
| Sign-in / quota / rate-limit checks **before** sending work, and clean fallback mid-task | ✓ |
| A verification gate on every task, and results that have to show up in git | ✓ |
| **Measured** savings: lead tokens per task, worker cost per passed task, A/B benchmark | ✓ |
| One `npx` install, no server, no tmux: plain bash + git + jq | ✓ |

## FAQ

**Doesn't the lead spend tokens planning and reviewing anyway?**
Yes, and that's exactly what `crewtier report` and `crewtier bench` measure. For small changes it doesn't pay off, which is why the skill does those itself. The win is on tasks where the diff is much bigger than the brief.

**Does it work if I only have one agent?**
No. crewtier needs at least one other agent CLI to send work to. Many have free tiers or come with a plan you already pay for.

**Will it use my API credits without asking?**
Only for candidates you mark `"paid": true` *and* explicitly allow. Workers otherwise run on their own subscriptions or free quotas.

**What if a worker is rate-limited in the middle of a task?**
Its partial work is saved as a patch, the tree is reset, the worker is marked `rate-limited` for 5 minutes, and the next worker in the tier takes over.

**Why a skill and a CLI, not an MCP server?**
A skill costs nothing until it's used, and a CLI's output is exactly what the lead needs, nothing more. An MCP server's tool schemas sit in every turn's context.

**Windows?**
Use WSL or Git Bash. The scripts are bash.

**Can my team use it?**
Yes: `crewtier init --scope project` and commit. Each teammate keeps their own routing, sign-ins and history.

## Limitations

- **Worker CLIs change their flags.** codex dropped `--full-auto` and agy has no `--yolo`, for example. crewtier tries a few known spellings per CLI and stops at the first one that works, and `crewtier health --verbose` shows exactly what a CLI said when it refused. If a CLI still fails, open an issue with that output.
- **Not yet battle-tested against every CLI version.** Adapters use each CLI's documented headless flags, but flags drift. The lead checks `--help` during setup; please open an issue when something doesn't match.
- **Token measurement** reads session transcripts for Claude Code and Codex (lead and worker). Other agents still get pass rates, diff sizes and timings.
- **Error classification** matches known wording for sign-in, quota and rate-limit errors. Unknown wording falls back to "worker failed", which is reported to the lead rather than triggering a fallback.
- **Antigravity's `agy -p`** has open reports of empty output without a TTY. crewtier wraps it in a pseudo-terminal and relies on `git diff`, not its output.
- **Rules file locations** come from each tool's docs as of late 2026. If one moves, `--lead <name> --rules <file>` overrides it.

## Interactive menus

`crewtier setup` (or plain `crewtier` in a terminal) opens a hub: **Workers** (sign in, on/off), **Add agents found on this machine** (space to pick CLIs that aren't wired up yet; afterwards it prints a prompt to paste into your lead so it can rebuild the tiers), **Routing** (per tier, a checklist of every model your workers list: space in/out, `f` move to first, `e` set effort, `m` type a model by hand), and **Install for more leads**.


`crewtier init` and `crewtier login` use an arrow-key checklist when a terminal is attached: **↑/↓** (or `k`/`j`) move, **space** switches an item on or off, **s** signs in to the highlighted agent, **a** / **n** switch all on / off, **enter** confirms, **q** or **Esc** cancels (nothing is changed). Without a terminal (CI, pipes) or with `TERM=dumb`, `login` falls back to numbered prompts and `init` installs for every lead it finds, so scripts keep working.

## Adding any agent

crewtier knows the one-shot command of about 45 agent CLIs (`crewtier agents` lists the ones on your machine). Seven have built-in adapters; the rest are one command away:

```bash
crewtier agents add aider                                   # uses the known headless form
crewtier agents add my-agent --headless 'my-agent exec --model {model} {prompt}'
crewtier health --force --verbose my-agent                  # check it answers
```

Added agents live in `~/.crewtier/agents.tsv`, show up in `agents`, `health`, `workers` and the `init` menu, and can be routed to like any built-in worker. Token usage and session resume aren't tracked for them.
