#!/usr/bin/env bash
# Shared worker adapters. Sourced by worker.sh and health.sh.
# Each adapter runs one headless prompt on one worker CLI. Confirm flags with `<bin> --help` when adding one.
#   run_one <backend> <model> <effort> <resume 0|1>     (reads $prompt)
# CREWTIER_READONLY=1 = analysis task: use each CLI's read-only / plan mode where it has one.
# CREWTIER_PING=1 = health check run outside a repo (adds flags some CLIs need for that).

# ---- fail-closed for copies that came with a repo ---------------------------------------------
# A project-scope install vendors crewtier into <repo>/.agents/skills/crewtier. Anyone who can push
# to that repo could change those scripts, and they run worker CLIs with approvals bypassed. So a
# vendored copy only runs after the user has approved its exact contents with `crewtier trust`.
crewtier_hash() {  # dir -> one hash over bin/, scripts/, SKILL.md
  local d="$1" h
  h="$(command -v sha256sum >/dev/null && echo sha256sum || echo 'shasum -a 256')"
  ( cd "$d" && find bin scripts SKILL.md -type f 2>/dev/null | LC_ALL=C sort | xargs $h | $h ) | cut -c1-64
}
crewtier_trust_check() {
  local copy; copy="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  case "$copy" in */.agents/skills/crewtier) ;; *) return 0 ;; esac
  [[ "$copy" == "$HOME/.agents/skills/crewtier" ]] && return 0
  local h; h="$(crewtier_hash "$copy")"
  grep -q "^$h|" "$HOME/.crewtier/trusted.tsv" 2>/dev/null && return 0
  echo "crewtier: refusing to run the copy that came with this repo ($copy)."
  echo "  It hasn't been approved, or it changed since you approved it."
  echo "  Use your installed crewtier instead, or review the copy and run:  crewtier trust"
  exit 4
}
crewtier_trust_check

# Built-in worker adapters, plus agents the user added with `crewtier agents add` (~/.crewtier/agents.tsv:
# name|binary|template, where the template holds {prompt} and optionally {model}).
BUILTIN_BACKENDS="claude codex opencode agy muse gemini copilot"
custom_agents_file() { echo "$HOME/.crewtier/agents.tsv"; }
custom_template() { awk -F'|' -v b="$1" '$2==b{t=$3} END{print t}' "$(custom_agents_file)" 2>/dev/null; }
all_backends() {
  local b out="$BUILTIN_BACKENDS"
  for b in $(awk -F'|' 'NF>=3{print $2}' "$(custom_agents_file)" 2>/dev/null); do
    case " $out " in *" $b "*) ;; *) out="$out $b";; esac
  done
  echo "$out"
}

# Models a worker CLI offers, one per line: "<model>  <short note>". Reads each CLI's own list where
# there is one, so the lead doesn't have to guess model names.
list_models() {
  case "$1" in
    opencode) opencode models 2>/dev/null | grep -v '^[[:space:]]*$' ;;
    agy)      agy models 2>/dev/null | grep -v '^[[:space:]]*$' ;;
    codex)    # live: `codex debug models` refreshes the catalog from your account, then prints it as JSON
              local j; j="$( (command -v timeout >/dev/null && timeout 30 codex debug models || codex debug models) 2>/dev/null)"
              if [[ -n "$j" ]] && command -v jq >/dev/null; then
                jq -r '[.. | objects | select(((.slug // .id // .model) | type) == "string")
                        | select(has("description") or has("visibility") or has("display_name"))]
                       | unique_by(.slug // .id // .model) | sort_by(.priority // 0) | .[]
                       | select((.visibility // "list") == "list")
                       | "\(.slug // .id // .model)  \(.description // .display_name // "" | gsub("\n"; " ") | .[0:60])\(if (.supported_reasoning_levels|type)=="array" then "  [effort: " + ([.supported_reasoning_levels[] | if type=="object" then (.effort // .level // tostring) else tostring end] | join(",")) + "]" else "" end)"' <<<"$j" 2>/dev/null
              else
                echo "(codex debug models gave nothing: update codex, or check \`codex debug models\` yourself)"
              fi
              local d; d="$(sed -n 's/^ *model *= *"\([^"]*\)".*/\1/p' "${CODEX_HOME:-$HOME/.codex}/config.toml" 2>/dev/null | head -1)"
              [[ -n "$d" ]] && echo "(default in config.toml: $d)" ;;
    claude)   printf '%s\n' "haiku  fast, cheap" "sonnet  mid" "opus  strongest" "(aliases; full names also work with --model)" ;;
    *)        local t; t="$(custom_template "$1")"; return 1 ;;
  esac
}

# Workers the user turned off (`crewtier disable <agent>`): one backend name per line.
crewtier_disabled_file() { echo "$HOME/.crewtier/disabled"; }
is_disabled() { grep -qxF "$1" "$(crewtier_disabled_file)" 2>/dev/null; }

# Pseudo-terminal for CLIs whose print mode stays silent or hangs without a TTY (agy).
pty() { if [[ "$(uname)" == "Darwin" ]]; then script -q /dev/null "$@"; else script -qec "$(printf '%q ' "$@")" /dev/null; fi; }

# Run <fn> once per flag set until one is not rejected as a bad flag. A rejected flag is exit 2 plus
# usage-style text; anything else (success, auth, quota, a real failure) ends the loop.
# Callbacks read the caller's locals (prompt, mflag, eff, extra, r), which bash scoping allows.
run_fallback() {
  local fn="$1"; shift
  local f c fs; f="$(mktemp)"
  for fs in "$@"; do
    # shellcheck disable=SC2086
    $fn $fs >"$f" 2>&1; c=$?
    if [[ $c -eq 2 ]] && grep -qiE 'unexpected argument|unknown (flag|option)|flag provided but not defined|unrecognized (option|argument)|invalid (option|flag)|usage:' "$f"; then continue; fi
    break
  done
  cat "$f"; rm -f "$f"; return $c
}
_codex_exec() {
  if [[ $r == 1 ]]; then codex exec ${eff[@]+"${eff[@]}"} "$@" resume --last "$prompt"
  else codex exec ${mflag[@]+"${mflag[@]}"} ${eff[@]+"${eff[@]}"} ${extra[@]+"${extra[@]}"} "$@" "$prompt"; fi
}
_agy_print() { pty agy -p "$prompt" ${mflag[@]+"${mflag[@]}"} "$@"; }
# muse: options go before the `exec` subcommand; `exec` runs one prompt headless
_muse_exec() { muse ${mflag[@]+"${mflag[@]}"} "$@" exec "$prompt"; }
# Generic adapter for user-added agents: split the template into words, put the prompt and model in.
# A word holding {model} is dropped (with the flag before it) when no model is set.
_custom_run() {
  local tpl="$1" w out=() P='{prompt}' M='{model}' Q='"{prompt}"' SQ="'{prompt}'"
  local words; read -r -a words <<<"$tpl"
  for w in "${words[@]}"; do
    if [[ "$w" == *"$M"* ]]; then
      if [[ -n "$m" ]]; then out+=("${w//"$M"/$m}")
      elif [[ ${#out[@]} -gt 0 && "${out[${#out[@]}-1]}" == -* ]]; then unset "out[$(( ${#out[@]} - 1 ))]"; out=("${out[@]}"); fi
      continue
    fi
    w="${w//"$Q"/$P}"; w="${w//"$SQ"/$P}"
    out+=("${w//"$P"/$prompt}")
  done
  "${out[@]}"
}
# Functions a subshell needs to re-create the adapters (used with: declare -f $ADAPTER_FNS)
ADAPTER_FNS="run_one pty run_fallback _codex_exec _agy_print _muse_exec _custom_run custom_template custom_agents_file"

run_one() {
  local b="$1" m="$2" e="$3" r="$4" mflag=()
  case "$b" in
    claude)
      local perm="${CREWTIER_CLAUDE_PERMS:-acceptEdits}"
      [[ "${CREWTIER_READONLY:-}" == 1 ]] && perm=plan
      [[ -n "$m" ]] && mflag=(--model "$m")
      if [[ $r == 1 ]]; then claude -c -p "$prompt" ${mflag[@]+"${mflag[@]}"} --permission-mode "$perm"
      else claude -p "$prompt" ${mflag[@]+"${mflag[@]}"} --permission-mode "$perm"; fi ;;
    codex)
      local eff=() extra=() variants=()
      [[ -n "$e" ]] && eff=(-c "model_reasoning_effort=\"$e\"")
      [[ -n "$m" ]] && mflag=(-m "$m")
      [[ "${CREWTIER_PING:-}" == 1 ]] && extra=(--skip-git-repo-check)
      # Sandbox flag has changed between codex releases (--full-auto was removed in 0.149), so try
      # each spelling in turn and stop at the first one the installed codex accepts.
      if [[ "${CREWTIER_READONLY:-}" == 1 ]]; then variants=("-s read-only" "-c sandbox_mode=read-only")
      else variants=("-s workspace-write" "-c sandbox_mode=workspace-write" "--full-auto"); fi
      run_fallback _codex_exec "${variants[@]}" ;;
    opencode)
      [[ -n "$m" ]] && mflag=(-m "$m")
      if [[ $r == 1 ]]; then opencode run -c ${mflag[@]+"${mflag[@]}"} "$prompt"
      else opencode run ${mflag[@]+"${mflag[@]}"} "$prompt"; fi ;;
    agy)      # no reliable resume: the fix prompt is self-contained
      local variants=()
      [[ -n "$m" ]] && mflag=(--model "$m")
      if [[ "${CREWTIER_READONLY:-}" == 1 ]]; then variants=("--mode plan" "--sandbox")
      else variants=("--mode accept-edits" "--dangerously-skip-permissions" ""); fi
      run_fallback _agy_print "${variants[@]}" ;;
    muse)     # no reliable resume: the fix prompt is self-contained
      local variants=()
      [[ -n "$m" ]] && mflag=(--model "$m")
      [[ -n "$e" ]] && mflag+=(--reasoning-effort "$e")
      if [[ "${CREWTIER_READONLY:-}" == 1 ]]; then variants=("--approval-mode never --trust-workspace --disable-write --disable-shell" "--disable-write")
      else variants=("--approval-mode never --trust-workspace" "--yolo"); fi
      run_fallback _muse_exec "${variants[@]}" ;;
    gemini)
      [[ -n "$m" ]] && mflag=(-m "$m")
      gemini -p "$prompt" ${mflag[@]+"${mflag[@]}"} --yolo ;;
    copilot)
      [[ -n "$m" ]] && mflag=(--model "$m")
      if [[ $r == 1 ]]; then copilot --continue -p "$prompt" ${mflag[@]+"${mflag[@]}"} --allow-all-tools
      else copilot -p "$prompt" ${mflag[@]+"${mflag[@]}"} --allow-all-tools; fi ;;
    *) local tpl; tpl="$(custom_template "$b")"
       if [[ -n "$tpl" ]]; then _custom_run "$tpl"
       else echo "no adapter for '$b' - add it with: crewtier agents add $b"; return 2; fi ;;
  esac
}

# Classify a worker's output after a failed run: prints auth | ratelimit | quota | "" (unknown)
#   ratelimit = temporary (429, too many requests): short cooldown
#   quota     = credit, billing, plan or usage limit used up: long cooldown
classify_failure() {  # stdin: output
  local out; out="$(cat)"
  if grep -qiE 'not logged in|log ?in required|please (log|sign) ?in|authentication required|unauthori[sz]ed|invalid api key|no api key|expired token|token (has )?expired|re-?authenticate|\b401\b' <<<"$out"; then
    echo auth
  elif grep -qiE 'quota|credit|insufficient|billing|subscription|payment required|\b402\b|usage limit|limit reached|plan limit|out of (requests|messages)' <<<"$out"; then
    echo quota
  elif grep -qiE 'rate.?limit|\b429\b|too many requests|overloaded|try again (later|in)|retry after|\b529\b' <<<"$out"; then
    echo ratelimit
  fi
}

strip_ansi() { sed -E $'s/\x1B\\[[0-9;?]*[ -/]*[@-~]//g; s/\x1B\\][^\a]*(\a|\x1B\\\\)//g; s/\r//g'; }

# How to fix each status, per CLI (shown to the user by the lead)
login_hint() {
  case "$1" in
    claude)   echo "run \`claude\` and use /login (or set ANTHROPIC_API_KEY)" ;;
    codex)    echo "run \`codex login\`" ;;
    opencode) echo "run \`opencode auth login\`" ;;
    agy)      echo "run \`agy\` once interactively to sign in" ;;
    muse)     echo "run \`muse login\`" ;;
    gemini)   echo "run \`gemini\` once to sign in, or set GEMINI_API_KEY" ;;
    copilot)  echo "run \`copilot\` and use /login" ;;
    *)        echo "sign in to $1" ;;
  esac
}

# Interactive sign-in for each CLI: prints "<command>|<what to do inside it>"
login_cmd() {
  case "$1" in
    codex)    echo "codex login|follow the browser sign-in" ;;
    opencode) echo "opencode auth login|pick a provider and paste its key or sign in" ;;
    claude)   echo "claude|type /login, finish sign-in, then /exit" ;;
    copilot)  echo "copilot|type /login, finish sign-in, then /exit" ;;
    agy)      echo "agy|sign in when asked, then exit (Ctrl+C or /exit)" ;;
    muse)     echo "muse login|pick a provider and finish sign-in" ;;
    gemini)   echo "gemini|choose a sign-in method, then /quit" ;;
    *)        echo "$1|sign in, then exit" ;;
  esac
}
