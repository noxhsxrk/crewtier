<p align="center">
  <img src="https://raw.githubusercontent.com/noxhsxrk/crewtier/main/assets/banner.png" alt="crewtier: Think like a lead. Ship like a crew." width="100%">
</p>

<h3 align="center">Think like a lead. Ship like a crew.</h3>

<p align="center">
  Your coding agent plans and reviews. The other coding agents on your machine write the code.
</p>

<p align="center">
  <a href="https://www.npmjs.com/package/@noxhsxrk/crewtier"><img alt="npm" src="https://img.shields.io/npm/v/@noxhsxrk/crewtier?color=cbf966&labelColor=0a0f16"></a>
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-cbf966?labelColor=0a0f16"></a>
  <img alt="macOS and Linux" src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-9aa9b8?labelColor=0a0f16">
  <img alt="needs bash, git, jq" src="https://img.shields.io/badge/needs-bash%20%C2%B7%20git%20%C2%B7%20jq-9aa9b8?labelColor=0a0f16">
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#changing-things-later">Changing things later</a> ·
  <a href="#safety">Safety</a> ·
  <a href="#commands">Commands</a> ·
  <a href="docs/reference.md">Reference</a>
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/noxhsxrk/crewtier/main/assets/demo/task.gif" alt="A lead agent splits a feature into tiers, sends two tasks to other agents, fixes a failed test through the same worker, does the security part itself, and reports its token savings." width="860">
</p>

---

**crewtier** is a skill plus a small CLI for AI coding agents. Whichever agent you talk to (Claude Code, Codex, opencode, Gemini, Antigravity, Copilot, Cursor, and more) becomes the **lead**. It splits your request into small tasks, gives each a difficulty tier, and hands them to the *other* agent CLIs on your machine. You keep using the agent and UI you like.

## Features

- **Any agent can lead.** 18 leads supported. Every other installed agent CLI is a worker. crewtier knows about 45 agent CLIs, and `crewtier agents add` wires up any other one.
- **Tiered routing.** Easy tasks go to a fast, cheap model; hard ones to a strong model; risky ones stay with the lead.
- **Live model lists.** Model names come straight from each CLI (`codex debug models`, `agy models`, `opencode models`), so the lead never guesses a name.
- **Sign-in and quota checks.** Every session starts by checking who is signed in and who still has quota. `crewtier login` fixes the rest.
- **Verified results.** Each task has a check command. A worker's "done" has to show up in git and pass the test.
- **Clean fallback.** If a worker runs dry or fails, crewtier saves its partial patch, resets, and tries the next one.
- **Lean lead.** The skill keeps the lead's own context small (narrow reads, big output kept out, exploration sent to workers) and `crewtier session` says when a conversation has grown long enough that a fresh one would be much cheaper.
- **Proof, not promises.** `crewtier report` and `crewtier bench` show whether delegating saved the lead anything.

## Quick start

Install with any one of these. `init` opens a short arrow-key checklist: it shows which agent CLIs are signed in, lets you sign in to the others (press `s`), lets you switch off the ones you don't want as workers, and then asks which leads to install the skill for.

```bash
npx @noxhsxrk/crewtier@latest init
```

```bash
pnpm dlx @noxhsxrk/crewtier@latest init
```

```bash
bunx @noxhsxrk/crewtier@latest init
```

```bash
curl -fsSL https://raw.githubusercontent.com/noxhsxrk/crewtier/main/install.sh | bash -s -- init
```

> [!TIP]
> Keep `@latest`. Without it, npx can reuse an older copy from its cache. To update later, run `crewtier update`.

<p align="center">
  <img src="https://raw.githubusercontent.com/noxhsxrk/crewtier/main/assets/demo/setup.gif" alt="crewtier init shows a checklist of agent CLIs: sign in to codex with s, turn agy off with space, then pick which leads get the skill." width="760">
</p>

Then open your agent in a repo:

1. Say **"set up crewtier"**. The lead lists your workers, proposes a tier table, and saves it once you agree.
2. Ask for a feature as usual: *"Add pagination to GET /orders, with tests."*

See [a day with crewtier](docs/walkthrough.md) for what that looks like.

## How it works

```mermaid
flowchart LR
    U([You]) --> L[Lead agent]
    L -->|plan + tier per task| R[crewtier run]
    R -->|brief| W[Worker agent]
    W -->|code| G[(git tree)]
    R -->|run the check| T{pass?}
    T -->|yes| S[short summary]
    T -->|no| F[fix with same worker]
    F --> R
    S -->|review, commit| L
```

The lead writes a short plan, picks a tier for each task, and `crewtier run` sends it to the first worker in that tier that is installed, signed in, and has quota. Afterwards the lead reads a ten-line summary instead of the whole diff.

| Tier | Typical task | Goes to |
|---|---|---|
| `t1-easy` | boilerplate, renames, simple CRUD, tests, docs | fast, cheap model |
| `t2-normal` | a feature across a few files with a clear spec | solid mid model |
| `t3-hard` | tricky logic, concurrency, cross-module refactors | strongest coding model |
| `lead` | unclear bugs, design decisions, security-sensitive code | the lead itself |

The lead only delegates work that is mostly typing, already decided, checkable by a command, and limited to a few files. Auth, payments, secrets, real-data migrations and deploy config never leave the lead. More in the [reference](docs/reference.md#when-to-delegate).

## Changing things later

You never need to run `init` again. Open the menu:

```bash
crewtier
```

<p align="center">
  <img src="https://raw.githubusercontent.com/noxhsxrk/crewtier/main/assets/demo/menu.gif" alt="crewtier opens a menu: add Grok with space, copy the prompt for the lead, then in Routing move gpt-6-luna to the top of t1-easy and save." width="760">
</p>

Use up/down to move, **space** to pick, **enter** to confirm, **q** to go back.

- **Workers:** turn workers on or off, and press `s` to sign in to the highlighted one.
- **Add agents:** lists agent CLIs on your machine that aren't set up yet. Just signed up for a new one? Install its CLI, then pick it here.
- **Routing:** for each tier, a checklist of every model your workers offer, read live from each CLI. `f` moves a model to the top, `e` sets its effort, `m` adds a model by hand.

After you add a worker, crewtier prints a prompt to paste into your lead so it rebuilds the tiers with the new models:

> I just added grok to crewtier. Run `crewtier health --force` and `crewtier agents --models`, then propose a new tier table for my routing file using only the model names those commands list. […] wait for my OK before saving.

Prefer plain commands? These do the same job:

```bash
crewtier agents add grok                            # a CLI crewtier already knows
crewtier agents add my-agent --headless 'my-agent exec --model {model} {prompt}'
crewtier routing add t1-easy codex gpt-6-luna --first
crewtier disable opencode
```

## Safety

> [!WARNING]
> Workers run with approvals bypassed, because headless runs would otherwise hang. Work on a clean git tree and review every diff before you commit.

- **Repo copies fail closed.** A skill copied into a repo refuses to run until you approve its exact contents with `crewtier trust`.
- **Your tree is only reset when it was clean** at the start of the task, and every discarded attempt is saved as a patch first.
- **Workers billed per API call stay off** unless you allow them.
- **No telemetry**, no network calls of its own, no credentials touched. Each worker uses its own sign-in.

> [!NOTE]
> Sending company code to an agent signed in with a personal account may break your employer's rules. Keep only the allowed workers in that repo's routing.

## Commands

You mostly use these. The lead calls the rest for you.

| Command | What it does |
|---|---|
| `crewtier init` | check sign-ins, then install the skill for the leads you choose |
| `crewtier setup` (or just `crewtier`) | menu to sign in, turn workers on or off, add newly installed agents, and pick the models for each tier |
| `crewtier update` | update to the latest release |
| `crewtier login [agent]` | sign in to an agent CLI and re-check it |
| `crewtier routing [add\|remove\|first\|edit]` | see or change which agent and model each tier uses |
| `crewtier agents add <bin>` | use another agent CLI as a worker |
| `crewtier disable <agent>` | never use a worker (`enable` turns it back on, `workers` lists them) |
| `crewtier health [--verbose]` | which workers are signed in and have quota; `--verbose` shows why one failed |
| `crewtier doctor` | check the whole install |

Full list of commands, options and environment variables: [reference](docs/reference.md#cli-reference).

## Docs

- [A day with crewtier](docs/walkthrough.md): an example session from request to commit
- [Reference](docs/reference.md): concepts, the routing file, `run` internals, health checks, measuring savings, install scopes, CLI, environment variables, FAQ

> [!NOTE]
> crewtier is new and has mostly been tested against stand-in CLIs. Agent CLIs change their flags often, so if a worker fails, run `crewtier health --verbose` and open an issue with the output.
