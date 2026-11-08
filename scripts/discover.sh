#!/usr/bin/env bash
# List every coding-agent CLI installed on this machine.
#
#   discover.sh            table: agent, binary path, version, headless command, whether worker.sh has an adapter
#   discover.sh --models   also list models for CLIs that can print them (slower)
#   discover.sh --json     machine-readable, for building routing.json
#
# To teach it a new agent, add one line to AGENTS below.
set -uo pipefail

want_models=0; json=0
lead="${CREWTIER_LEAD:-}"; [[ -z "$lead" && "${CLAUDECODE:-}" == "1" ]] && lead=claude
for a in "$@"; do case "$a" in --models) want_models=1;; --json) json=1;; esac; done

# name | binary | headless form | worker.sh backend ("-" = not wired yet)
AGENTS='
Claude Code      | claude       | claude -p "<prompt>"                         | claude
Codex            | codex        | codex exec "<prompt>"                        | codex
opencode         | opencode     | opencode run "<prompt>"                      | opencode
Antigravity      | agy          | agy -p "<prompt>"                            | agy
Muse             | muse         | muse exec "<prompt>"                         | muse
Gemini CLI       | gemini       | gemini -p "<prompt>"                         | gemini
GitHub Copilot   | copilot      | copilot -p "<prompt>"                        | copilot
Aider            | aider        | aider --yes-always --message "<prompt>"      | -
Cursor CLI       | cursor-agent | cursor-agent -p "<prompt>"                   | -
Amp              | amp          | amp -x "<prompt>"                            | -
Qwen Code        | qwen         | qwen -p "<prompt>"                           | -
Crush            | crush        | crush run "<prompt>"                         | -
Goose            | goose        | goose run -t "<prompt>"                      | -
Kiro             | kiro-cli     | kiro-cli chat --no-interactive "<prompt>"    | -
Amazon Q         | q            | q chat --no-interactive "<prompt>"           | -
Factory Droid    | droid        | droid exec "<prompt>"                        | -
Kimi CLI         | kimi         | kimi -p "<prompt>"                           | -
Cline CLI        | cline        | cline -y "<prompt>"                          | -
Continue         | cn           | cn -p "<prompt>"                             | -
Kilo Code        | kilocode     | kilocode --auto "<prompt>"                   | -
Kilo             | kilo         | kilo run "<prompt>"                          | -
Roo Code         | roo          | roo "<prompt>"                               | -
OpenHands        | openhands    | openhands -t "<prompt>"                      | -
Pi               | pi           | pi -p "<prompt>"                             | -
Auggie           | auggie       | auggie --print "<prompt>"                    | -
Junie            | junie        | junie "<prompt>"                             | -
Grok             | grok         | grok -p "<prompt>"                           | -
Mistral Vibe     | vibe         | vibe -p "<prompt>"                           | -
Hermes Agent     | hermes       | hermes -p "<prompt>"                         | -
ForgeCode        | forge        | forge -p "<prompt>"                          | -
Plandex          | plandex      | plandex tell "<prompt>"                      | -
gptme            | gptme        | gptme --non-interactive "<prompt>"           | -
Letta Code       | letta        | letta -p "<prompt>"                          | -
Codebuff         | codebuff     | codebuff "<prompt>"                          | -
Open Interpreter | interpreter  | interpreter -y "<prompt>"                    | -
Trae Agent       | trae-cli     | trae-cli run "<prompt>"                      | -
iFlow CLI        | iflow        | iflow -p "<prompt>"                          | -
Qoder CLI        | qodercli     | qodercli -p "<prompt>"                       | -
CodeBuddy        | codebuddy    | codebuddy -p "<prompt>"                      | -
Nanocoder        | nanocoder    | nanocoder run "<prompt>"                     | -
Deep Agents      | deepagents   | deepagents -n "<prompt>"                     | -
Codewhale        | codewhale    | codewhale exec "<prompt>"                    | -
Command Code     | cmd          | cmd -p "<prompt>"                            | -
Every Code       | coder        | coder exec "<prompt>"                        | -
Tabnine CLI      | tabnine      | tabnine -p "<prompt>"                        | -
Warp             | warp         | warp agent run --prompt "<prompt>"           | -
'
# Headless forms are a starting point: confirm with `<binary> --help` before wiring one in.
# Agents the user added with `crewtier agents add` (name|binary|template) are listed too.
CUSTOM_FILE="$HOME/.crewtier/agents.tsv"
if [[ -f "$CUSTOM_FILE" ]]; then
  P='{prompt}'; QP='"<prompt>"'
  while IFS='|' read -r cn cb ct; do
    [[ -z "$cb" ]] && continue
    AGENTS="$(printf '%s\n' "$AGENTS" | awk -F'|' -v b="$cb" '{x=$2; gsub(/ /,"",x)} x!=b')"
    AGENTS="$AGENTS
$cn | $cb | ${ct//"$P"/$QP} | $cb"
  done <"$CUSTOM_FILE"
fi

if command -v timeout >/dev/null; then TO=(timeout 10)
elif command -v gtimeout >/dev/null; then TO=(gtimeout 10)
else TO=(); fi
run() { ${TO[@]+"${TO[@]}"} "$@" 2>/dev/null; }

version_of() {
  local v
  v=$(run "$1" --version | head -1)
  [[ -z "$v" ]] && v=$(run "$1" -v | head -1)
  # keep it short: first thing that looks like a version number
  grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?([-.][0-9A-Za-z]+)?' <<<"$v" | head -1 || true
}

# shellcheck source=adapters.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/adapters.sh"
models_of() {
  local out; out="$(list_models "$1" 2>/dev/null)"
  if [[ -n "$out" ]]; then sed 's/^/    /' <<<"$out"
  else echo "    (no model list found: see \`$1 --help\` or its settings file)"; fi
}

found=0; rows=()
while IFS='|' read -r name bin headless backend; do
  name=$(xargs <<<"$name"); bin=$(xargs <<<"$bin")
  [[ -z "$bin" ]] && continue
  path=$(command -v "$bin" 2>/dev/null) || continue
  found=$((found+1))
  ver=$(version_of "$bin"); ver=${ver:-?}
  headless=$(sed 's/^ *//;s/ *$//' <<<"$headless"); backend=$(xargs <<<"$backend")
  rows+=("$name|$bin|$ver|$path|$headless|$backend")
done <<<"$AGENTS"

if [[ $json == 1 ]]; then
  printf '['
  for i in "${!rows[@]}"; do
    IFS='|' read -r name bin ver path headless backend <<<"${rows[$i]}"
    [[ $i -gt 0 ]] && printf ','
    jq -cn --arg n "$name" --arg b "$bin" --arg v "$ver" --arg p "$path" --arg h "$headless" --arg w "$backend" --arg l "$lead" \
      '{name:$n, binary:$b, version:$v, path:$p, headless:$h, is_lead:($b==$l), adapter:(if $w=="-" then null else $w end)}'
  done
  printf ']\n'
  exit 0
fi

if [[ $found == 0 ]]; then echo "no coding-agent CLIs found on PATH (have one that isn't listed? crewtier agents add <binary> --headless '<binary> ... {prompt}')"; exit 0; fi
health="$HOME/.crewtier/health.tsv"
hstat() { [[ -f "$health" ]] && awk -F'|' -v a="$1" '$1==a{s=$2} END{print s}' "$health"; }
printf '%-15s %-13s %-10s %-9s %-12s %s\n' AGENT BINARY VERSION ADAPTER LOGIN HEADLESS
for r in "${rows[@]}"; do
  IFS='|' read -r name bin ver path headless backend <<<"$r"
  [[ "$backend" == "-" ]] && d="no" || d="yes"
  [[ "$bin" == "$lead" ]] && { d="(you)"; name="$name"; }
  hs="$(hstat "$bin")"; hs="${hs:-?}"; [[ "$d" == "(you)" ]] && hs="-"
  [[ -f "$HOME/.crewtier/disabled" ]] && grep -qxF "$bin" "$HOME/.crewtier/disabled" && hs="off"
  printf '%-15s %-13s %-10s %-9s %-12s %s\n' "$name" "$bin" "$ver" "$d" "$hs" "$headless"
  [[ $want_models == 1 ]] && models_of "$bin"
done
echo "($found found. (you) = the lead running this skill, never used as a worker. ADAPTER=no = installed, not wired up yet: crewtier agents add <binary>. LOGIN ? = not checked yet: run \`crewtier health\`. off = turned off with \`crewtier disable\`: never used as a worker.)"
echo "(Agent missing from this list? crewtier agents add <binary> --headless '<binary> <flags> {prompt}')"
