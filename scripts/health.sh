#!/usr/bin/env bash
# Check which worker agents are signed in and still have credit, and cache the answer.
#
#   health.sh                 check workers whose cached result is missing or stale
#   health.sh --force         re-check every worker now
#   health.sh --cached        print the cache, run nothing
#   health.sh --json          machine-readable output
#   health.sh --verbose       also print the full output of each failed check
#   health.sh --installed     every installed worker CLI, not just the ones in the routing file
#   health.sh --all-models    ping every backend/model pair in the routing file (implies --force).
#                             Run it after changing the routing: plans often allow only some models.
#   health.sh <agent> ...     only these agents
#
# Statuses: ready | auth-required | quota-exhausted | model-unavailable | rate-limited | error | not-installed | no-adapter
# Per model: a worker is checked with the models the routing file gives it, in order, until one answers.
#   A model that is out of credit or not on the plan is cached as "<agent>/<model>" and only that model is
#   skipped; the worker is ready if any of its models is. Sign-in and rate limits count for the whole worker.
# How it checks, cheapest first:
#   1. a CLI's own status command, where one exists (codex login status, opencode auth list)
#   2. a one-word ping through the worker adapter ("Reply with OK"), run in an empty temp dir, at the
#      lowest reasoning effort. This spends a handful of the WORKER's tokens, never the lead's.
# Cache: ~/.crewtier/health.tsv  (agent | status | detail | epoch)
#   ready results are reused for CREWTIER_HEALTH_TTL seconds (default 10800 = 3h)
#   cooldowns before a re-check: rate-limited 5 min, auth-required / error 10 min, quota-exhausted 60 min
#   (a fresh login is picked up quickly; `health --force` re-checks now)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=adapters.sh
source "$here/adapters.sh"

lead="${CREWTIER_LEAD:-}"; [[ -z "$lead" && "${CLAUDECODE:-}" == "1" ]] && lead=claude
state="$HOME/.crewtier"; mkdir -p "$state"
cache="$state/health.tsv"; touch "$cache"
ttl_ok="${CREWTIER_HEALTH_TTL:-10800}"; ttl_bad=600
ADAPTERS="$(all_backends)"

force=0; cached_only=0; json=0; only=""; installed=0; verbose=0; all_models=0
for a in "$@"; do case "$a" in --force) force=1;; --cached) cached_only=1;; --json) json=1;; --installed) installed=1;; --verbose|-v) verbose=1;; --all-models) all_models=1; force=1;; -*) ;; *) only="$only $a";; esac; done

now() { date +%s; }
get_cache() { awk -F'|' -v a="$1" '$1==a' "$cache" | tail -1; }
put_cache() {  # agent status detail
  grep -v "^$1|" "$cache" >"$cache.tmp" 2>/dev/null; mv "$cache.tmp" "$cache"
  printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$(now)" >>"$cache"
}

# Which agents to check: explicit list > workers in the lead's routing file > every installed adapter
targets() {
  if [[ -n "$only" ]]; then echo $only; return; fi
  if [[ $installed == 1 ]]; then for b in $ADAPTERS; do command -v "$b" >/dev/null && echo "$b"; done; return; fi
  local r="$state/routing.$lead.json"; [[ -f "$r" ]] || r="$state/routing.json"
  if [[ -f "$r" ]] && command -v jq >/dev/null; then
    jq -r '[.tiers[][]?.backend] | unique | .[]' "$r"
  else
    for b in $ADAPTERS; do command -v "$b" >/dev/null && echo "$b"; done
  fi
}

# Models the routing file lists for this backend, cheapest first (t1-easy entries, then the rest), once each
ping_models() {
  local r="$state/routing.$lead.json"; [[ -f "$r" ]] || r="$state/routing.json"
  [[ -f "$r" ]] || return 0
  jq -r --arg b "$1" '[.tiers["t1-easy"][]?, .tiers[][]? | select(.backend==$b) | .model // empty]
    | reduce .[] as $m ([]; if index([$m]) then . else . + [$m] end) | .[]' "$r" 2>/dev/null
}

status_cmd() {  # prints ready|auth-required|"" from a CLI's own status command, no tokens spent
  case "$1" in
    codex)    codex login status >/dev/null 2>&1 && echo ready || echo auth-required ;;
    opencode) local o; o="$(opencode auth list 2>&1)"
              if grep -qiE '\b0 credentials\b|no credentials' <<<"$o"; then
                env | grep -qE '^(ANTHROPIC|OPENAI|GEMINI|GOOGLE|OPENROUTER|GROQ|XAI|DEEPSEEK)_API_KEY=' || echo auth-required
              fi ;;
    gemini)   [[ -n "${GEMINI_API_KEY:-}${GOOGLE_API_KEY:-}" || -f "$HOME/.gemini/oauth_creds.json" ]] || echo auth-required ;;
  esac
}

if command -v timeout >/dev/null; then TO=(timeout 90); elif command -v gtimeout >/dev/null; then TO=(gtimeout 90); else TO=(); fi

ping_agent() {  # agent model -> status|detail
  local b="$1" m="$2" tmp out code cls
  tmp="$(mktemp -d)"
  # lowest effort: a ping at the default effort costs codex thousands of tokens
  out="$(cd "$tmp" && CREWTIER_PING=1 ${TO[@]+"${TO[@]}"} bash -c "$(declare -f $ADAPTER_FNS); prompt='Reply with the single word OK. Do not use any tools.'; run_one $(printf '%q ' "$b" "$m" low 0)" 2>&1)"
  code=$?
  rm -rf "$tmp"
  out="$(strip_ansi <<<"$out")"
  printf '%s\n' "$out" >"$state/health.$b${m:+.${m//\//_}}.log" 2>/dev/null   # full output, for --verbose
  if [[ $code -eq 0 ]] && grep -qw 'OK' <<<"$out"; then echo "ready|ping ok${m:+ ($m)}"; return; fi
  cls="$(classify_failure <<<"$out")"
  local last; last="$(grep -iE 'error|unexpected|unknown|invalid|unrecognized|not found|usage:' <<<"$out" | head -1 | cut -c1-100 | tr '|' '/')"
  [[ -n "$last" ]] || last="$(grep -v '^\s*$' <<<"$out" | head -1 | cut -c1-100 | tr '|' '/')"
  case "$cls" in
    auth)  echo "auth-required|$(login_hint "$b")" ;;
    model) echo "model-unavailable|${m:-default model}: $last" ;;
    quota) echo "quota-exhausted|${m:+$m: }$last" ;;
    ratelimit) echo "rate-limited|$last" ;;
    *)  if grep -qE -- '--trust\b' <<<"$out"; then   # e.g. cursor-agent stops to ask whether to trust the folder
          echo "error|$b asks to trust the folder: add --trust (and its skip-approval flag) to its command, e.g. crewtier agents add $b --headless '$b -p --trust --force --model {model} {prompt}' (check $b --help)"
        elif [[ $code -eq 124 ]]; then echo "error|ping timed out${m:+ ($m)}"
        else echo "error|exit $code: $last"; fi ;;
  esac
}

check() {  # agent -> line 1 "status|detail" for the worker, then "<agent>/<model>|status|detail" per model pinged
  # (the parent writes the cache, so parallel checks can't clobber it)
  local b="$1" st m res first="" last="" lines=""
  if ! command -v "$b" >/dev/null; then echo "not-installed|-"; return; fi
  case " $ADAPTERS " in *" $b "*) ;; *) echo "no-adapter|worker.sh has no adapter"; return;; esac
  st="$(status_cmd "$b")"
  if [[ "$st" == auth-required ]]; then echo "auth-required|$(login_hint "$b")"; return; fi
  while IFS= read -r m; do   # no models in the routing file: one ping with the CLI's default model
    res="$(ping_agent "$b" "$m")"
    [[ -n "$m" ]] && lines+="$b/$m|$res"$'\n'
    case "${res%%|*}" in
      ready) [[ -n "$first" ]] || first="$res"; [[ $all_models == 1 ]] || break ;;
      auth-required|rate-limited) [[ -n "$first" ]] || first="$res"; break ;;   # whole account: other models fail the same way
      *) last="$res" ;;
    esac
  done <<<"$(ping_models "$b")"
  echo "${first:-$last}"; printf '%s' "$lines"
}

stale() {  # agent -> 0 if needs a check
  local line st ts age
  line="$(get_cache "$1")"; [[ -z "$line" ]] && return 0
  st="$(cut -d'|' -f2 <<<"$line")"; ts="$(cut -d'|' -f4 <<<"$line")"
  age=$(( $(now) - ts ))
  case "$st" in
    ready)           [[ $age -gt $ttl_ok ]] ;;
    rate-limited)    [[ $age -gt 300 ]] ;;
    quota-exhausted) [[ $age -gt 3600 ]] ;;
    *)               [[ $age -gt $ttl_bad ]] ;;
  esac
}

# the lead isn't a worker; --installed (used by the sign-in wizard) still lists it
skip="${lead:-__none__}"; [[ $installed == 1 ]] && skip="__none__"
list="$(targets | grep -vxF "$skip" | sort -u)"
if [[ -z "$only" ]]; then   # workers the user turned off are neither checked nor listed
  kept=""; for b in $list; do is_disabled "$b" || kept="$kept $b"; done; list="$(tr ' ' '\n' <<<"$kept" | sed '/^$/d')"
fi
if [[ $cached_only == 0 ]]; then
  out="$(mktemp -d)"; checked=""
  for b in $list; do
    if [[ $force == 1 ]] || stale "$b"; then check "$b" >"$out/$b" 2>/dev/null & checked="$checked $b"; fi
  done
  wait
  for b in $checked; do
    res="$(head -1 "$out/$b")"; [[ -n "$res" ]] || res="error|check produced no result"
    put_cache "$b" "${res%%|*}" "${res#*|}"
    tail -n +2 "$out/$b" | while IFS='|' read -r k st d; do [[ -n "$k" ]] && put_cache "$k" "$st" "$d"; done
  done
  rm -rf "$out"
fi

if [[ $json == 1 ]]; then
  printf '['; first=1
  for b in $list; do
    IFS='|' read -r a st d ts <<<"$(get_cache "$b")"
    [[ $first == 0 ]] && printf ','; first=0
    jq -cn --arg a "$b" --arg s "${st:-unknown}" --arg d "${d:-}" --arg t "${ts:-0}" '{agent:$a,status:$s,detail:$d,checked:($t|tonumber)}'
  done; printf ']\n'; exit 0
fi

[[ -z "$list" ]] && { echo "no worker agents to check (none installed, or only the lead)"; exit 0; }
printf '%-10s %-13s %-8s %s\n' WORKER STATUS CHECKED DETAIL
bad=0
for b in $list; do
  IFS='|' read -r a st d ts <<<"$(get_cache "$b")"
  ago="-"; [[ -n "${ts:-}" ]] && ago="$(( ($(now) - ts) / 60 ))m ago"
  printf '%-10s %-13s %-8s %s\n' "$b" "${st:-unknown}" "$ago" "${d:-}"
  [[ "${st:-}" == ready ]] || bad=$((bad+1))
  # per-model results for models still in the routing file: all with --all-models, else only the failures
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    IFS='|' read -r a st d ts <<<"$(get_cache "$b/$m")"
    [[ -n "${st:-}" ]] || continue; [[ $all_models == 1 || "$st" != ready ]] || continue
    [[ "$st" == ready || $(( $(now) - ts )) -lt 3600 ]] || continue   # worker.sh retries a failed model after 1h
    printf '  └ %-26s %-17s %-8s %s\n' "$m" "$st" "$(( ($(now) - ts) / 60 ))m ago" "$( [[ "$st" == ready ]] || echo "${d:-}" )"
  done <<<"$(ping_models "$b")"
done
if [[ $verbose == 1 ]]; then
  for b in $list; do
    while IFS= read -r m; do   # each routed model; the worker itself (m empty) when it has none
      IFS='|' read -r a st d ts <<<"$(get_cache "$b${m:+/$m}")"
      f="$state/health.$b${m:+.${m//\//_}}.log"
      [[ -z "${st:-}" || "$st" == ready || ! -s "$f" ]] && continue
      printf '\n--- %s: full output of the last check (%s) ---\n' "$b${m:+/$m}" "$st"
      head -40 "$f"
    done <<<"$(ping_models "$b")"
  done
fi
if [[ $bad -gt 0 ]]; then
  echo "($bad worker(s) unavailable — worker.sh skips them until they pass a check again)"
  [[ $all_models == 1 ]] || echo "(models a plan doesn't include are skipped one by one; check every routed model: crewtier health --all-models)"
  [[ $verbose == 1 ]] || echo "(see why:  crewtier health --verbose)"
fi
exit 0
