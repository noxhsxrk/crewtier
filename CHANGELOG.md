# Changelog

## 0.1.15 (2026-11-25)

### Added
- **Claude Code mod:** the band now stays above the prompt with an `off | on` delegation switch (kept across sessions), the running `crewtier do` tier and elapsed time, this session's delegated/pass/fail count, and **Board** (opens the pane) and **Health** buttons. Off adds a system-prompt rule telling the lead to do the work itself and blocks `crewtier do`. `/crew on | off` does the same from the prompt.

### Fixed
- **Claude Code mod:** the pane's Refresh button no longer times out (Claude Code gives a button press 10s; `crewtier health` now runs in the background).

## 0.1.14 (2026-11-23)

### Added
- **Claude Code mod** (`mod/`), installed with `/plugin install crewtier --marketplace noxhsxrk/crewtier`:
  - a band above the prompt while `crewtier do` runs (tier, elapsed time), then a toast with the PASS/FAIL line;
  - a pane listing workers' health and every task delegated in the session (`/crew` opens it, Refresh re-runs `crewtier health`);
  - `/crew health | workers | routing | status | doctor` runs that command and shows the output in the chat.

## 0.1.13 (2026-11-23)

### Fixed
- **One unusable model no longer takes down the whole worker.** Quota and "not on your plan" errors are now recorded per model (`<agent>/<model>` in `health.tsv`) and only that model is skipped for 60 minutes; the worker's other models are still tried. Before, a Cursor model answering "not included in your weekly usage. Buy credits" marked all of `cursor-agent` as quota-exhausted, so working models such as `composer-2.5` were skipped too. Sign-in and rate-limit errors still count for the whole worker.
- New failure class `model-unavailable` for models that aren't on the plan or don't exist ("not included in your …", "unknown model", "model not found").
- `crewtier health` details no longer carry ANSI color codes.
- Cursor CLI's default headless command is now `cursor-agent -p --trust --force --model {model} "<prompt>"`; the old one stopped at the trust prompt and had no model. When a CLI asks to trust the folder, `health` now says how to fix the command instead of echoing the CLI's message.
- `crewtier agents --models` lists Cursor's models (`cursor-agent models`).
- Codex's `priority` speed modes are no longer listed as models.

### Added
- `crewtier health --all-models`: pings every agent/model pair in the routing file. Plain `health` now tries a worker's routed models in order until one answers, and lists failing models under the worker.
- `crewtier routing check`: validates the routing file in one go without spending tokens (JSON, known agents, turned-off workers, model names the CLI no longer lists, effort values, and `effort` set on a CLI that ignores it). `routing edit` runs it on save and keeps the previous file as `.prev`.
- `crewtier models --check` also checks the other way: routed models the worker CLIs no longer list.

### Changed
- Health pings run at the lowest reasoning effort (`low`), so a Codex ping costs far less.
- Long model lists are shortened: lists over 30 lines keep 4 models per provider or model family in `agents --models` (`--all` shows all), and `models --check` shows counts per family for CLIs with hundreds of models.
- `routing.example.json` is now a Claude Code lead example with Codex candidates that set `"effort"` (`high` in `t3-hard`).
- Skill docs: "Know the fleet" now covers setting effort (Codex uses an `effort` field, agy and Cursor put the level in the model name), running `routing check` and `health --all-models` after every routing change, plans that only include some models, and the `crewtier setup` menu.
