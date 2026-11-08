---
name: crewtier
description: Hands big, already-decided coding tasks (about 300+ changed lines) from the agent the user is talking to (the lead) to the other coding-agent CLIs on the machine (Claude Code, Codex, opencode, Antigravity, Gemini, Copilot, ...), one call per task, to cut the lead's token use. Use when the user asks to delegate, dispatch or hand work to another agent, to save tokens on a large implementation, to set up crewtier, or which coding agents are installed (in any language). Not for small edits.
---

# crewtier

You are the **lead**. Other coding-agent CLIs on this machine are **workers**. The goal is to cut what you, the lead, cost.

Your cost has two parts: **output** (code you type, the priciest tokens) and **re-reading** (every turn re-reads your whole context; in measured sessions this was most of the cost). Delegating saves output but every extra turn adds re-reading. A 10-run benchmark found that delegating small and mid tasks the old way, with many turns per task, cost *more* than doing them yourself. So: delegate rarely, in big pieces, in one turn each.

## Rules

1. **Do it yourself unless the task is big.** Delegate only work you expect to be about 300+ changed lines, already decided (no design choices left), and checkable by a command. Never split a task into smaller ones just to delegate them. Never delegate auth, payments, secrets, real-data migrations, CI/deploy config, or bulk deletes.
2. **One turn per delegated task.** Use `crewtier do` (below). Don't call `health`, `meter`, `run` or `apply` separately, and don't write a plan file for a single task.
3. **Don't read code to write the spec.** If the user or a task file already describes the work, pass it as is. The worker explores the code at its own cost. Read code yourself only for a real design decision.
4. **Don't review a pass.** When `do` prints `PASS`, take it: no `git diff`, no opening the files. Look only when it fails.
5. **Keep your context small.** Read a file of up to ~400 lines in one go rather than in slices over several turns; for bigger files, search first and read only the part you need. Never `cat` big files, lockfiles, or logs; redirect long command output to a file and read its tail. Screenshots and other images are the heaviest thing you can add: take one only when you must see something, not to confirm every small change. Send "where is X / list every caller of Y" questions to a worker with `crewtier run <id> t1-easy --read-only --spec -`.
6. **Start fresh per feature.** After a feature is committed in a long conversation, tell the user once that a new session for the next feature costs much less. Everything crewtier keeps carries over.

## Delegating a task

Call it once and wait for it to finish. It can take several minutes, so give the shell call a long timeout (in Claude Code, `timeout: 600000`). Don't run it in the background and check on it: each check is another full re-read of your context. Budget: reading this skill once plus one `do` call per task. A benchmark lead doing the same tasks itself needed 3 to 11 turns, so every extra turn you spend on delegation eats the saving.

```bash
CREWTIER_LEAD=<lead> crewtier do t2-normal --spec path/to/spec.md --commit "Add crumbling platforms"
```

If the spec already exists in a file, pass its path; don't retype it (that's paid output). Otherwise pipe it in:

```bash
CREWTIER_LEAD=<lead> crewtier do t2-normal --commit "Add crumbling platforms" <<'EOF'
<what to build, which files, constraints>
Done when: `<command that proves it, e.g. pnpm test>`
EOF
```

- `<lead>` is your CLI's binary name (`claude`, `codex`, `gemini`, …); Claude Code is detected automatically.
- Tiers: `t1-easy` (boilerplate, tests, docs), `t2-normal` (a feature across a few files), `t3-hard` (tricky logic, cross-module refactors).
- `do` saves the spec, runs the first ready worker in the tier, checks it, gives a failing worker one fix round, moves up a tier if it still fails, meters your tokens, and commits on success (only if the tree was clean).
- Success is one line: `D1 PASS codex/gpt-6.1-sol · 412 lines (5 files) · 3m10s · commit abc123`. Report it to the user in a sentence and move on.
- `VERIFY-ERROR` means the check command itself didn't run (typo, missing tool). The worker's changes are in the tree: fix the command and run it once. Don't review the code.
- Any other failure prints the last tier tried and the check's output, and leaves the last attempt in the tree. Exit 3 means no worker was available. Then finish the task yourself; don't send it again.
- No `crewtier health` or other setup calls first: `do` checks the workers itself.

## When you need more

Read only the section you need from `REFERENCE.md` in this skill's folder:

- No `~/.crewtier/routing.<lead>.json` yet, or the user asks to set up or change workers and models → "Know the fleet".
- A worker is signed out or out of quota (`do` exits 3 or says so) → "Every session: who's signed in?". The user signs in with `crewtier login <agent>`.
- Several big independent tasks at once → "Parallel".
- The user asks what it saved → run `crewtier session` (whole conversation) or `crewtier report`; for an A/B test, "Is it actually saving tokens?".
