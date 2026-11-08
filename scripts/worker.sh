#!/usr/bin/env bash
# Send one task to a worker agent CLI, picked from a tier in the routing file, then check it.
#
#   worker.sh T1 t1-easy                       run task T1 from .crewtier/plan.md
#   worker.sh T1 t1-easy --fix "what broke"    resume the same worker's session with a fix request
#   worker.sh T1 t1-easy --fix                 same, sending the last failed verify output as the fix request
#   options:
#     --isolated        run in a throwaway git worktree; the result becomes .crewtier/patches/T1.patch
#                       (apply with `crewtier apply T1`). Needed for running tasks in parallel.
#     --read-only       analysis only: read-only / plan mode where the CLI has one; changes are flagged
#     --verify "cmd"    check command (default: the task's "Done when:" line)    --no-verify  skip it
#     --timeout SEC     kill the worker after SEC seconds (default per tier: 600 / 1200 / 2400)
#     --spec FILE|-     use this brief instead of extracting the task from plan.md (- = stdin)
#     --auto-escalate   if verify fails: one automatic fix round on the same worker, then save the
#                       attempt as a patch, reset, and retry one tier up (t1 → t2 → t3 → back to the lead)
#
# Routing: candidates in the tier are tried in order. Skipped: the lead, not installed, signed out,
# out of quota, rate-limited, and API-billed candidates ("paid": true) unless CREWTIER_ALLOW_PAID=1
# or "allow_paid": true in the routing file. Every skip is listed with its reason.
# Fallback: if a worker stops on a sign-in / quota / rate-limit error after touching files, its
# partial diff is saved to .crewtier/patches/<task>.<worker>.partial.patch and the tree is reset,
# so the next worker starts from the same known state.
#
# CREWTIER_LEAD = the agent running this skill (auto-detected for Claude Code). Never used as a worker.
# Output is a short summary for the lead: worker, time, diff stat, verify result, the worker's result
# block. Full worker output (ANSI-stripped) goes to .crewtier/logs/. Needs git and jq.
#
# Machine-readable result: .crewtier/results/<task>.json (status, worker, model, files, verify,
# skipped candidates, worker usage where it can be read, patch/log paths).
# Status: done | no-changes | verify-failed | worker-failed | timed-out | no-worker
#   no-changes = the worker said it finished but nothing in the tree changed (not trusted as done).
#
# Exit: 0 done (verify passed or none) | 1 verify failed / worker failed / no changes
#       3 no worker could run | 124 worker timed out | 2 usage error
set -uo pipefail

task="${1:?task id, e.g. T1}"; tier="${2:?tier, e.g. t1-easy}"; shift 2
fixmsg=""; isolated=0; readonly_=0; verify=""; no_verify=0; tmo=""; spec=""; auto=0; round=0
orig_args=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix) if [[ $# -ge 2 && "$2" != --* ]]; then fixmsg="$2"; shift 2; else fixmsg="@verify"; shift; fi ;;
    --isolated) isolated=1; shift ;;
    --read-only) readonly_=1; shift ;;
    --verify) verify="${2:?}"; shift 2 ;;
    --no-verify) no_verify=1; shift ;;
    --timeout) tmo="${2:?}"; shift 2 ;;
    --spec) spec="${2:?}"; shift 2 ;;
    --auto-escalate) auto=1; shift ;;
    --round) round="${2:?}"; shift 2 ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done

lead="${CREWTIER_LEAD:-}"
[[ -z "$lead" && "${CLAUDECODE:-}" == "1" ]] && lead=claude
[[ -n "$lead" ]] || { echo "set CREWTIER_LEAD=<your agent's binary name>"; exit 2; }
[[ "$tier" == "lead" ]] && { echo "tier 'lead' means: do it yourself"; exit 2; }
command -v jq >/dev/null || { echo "jq required"; exit 2; }
root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "run inside a git repo"; exit 2; }
cd "$root"

state="$HOME/.crewtier"
routing="${CREWTIER_ROUTING:-$state/routing.$lead.json}"
[[ -f "$routing" ]] || routing="$state/routing.json"
[[ -f "$routing" ]] || { echo "no routing file ($state/routing.$lead.json) — ask the lead to \"set up crewtier\""; exit 2; }

dir=".crewtier"; logs="$dir/logs"; tasks="$dir/tasks"; mkdir -p "$logs" "$tasks" "$dir/patches" "$dir/results"
if ex="$(git rev-parse --git-path info/exclude 2>/dev/null)"; then
  mkdir -p "$(dirname "$ex")"; touch "$ex"; grep -qxF "/$dir/" "$ex" || echo "/$dir/" >>"$ex"
fi
plan="$dir/plan.md"; brief="$tasks/$task.md"; last="$dir/last-$task"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=adapters.sh
source "$here/adapters.sh"
health="$state/health.tsv"

# ---- brief: a self-contained task file, so prompts never go through shell quoting ---------------
section() {  # print plan.md's "# <name>" top-level section
  awk -v h="$1" 'BEGIN{IGNORECASE=1} /^# /{p=(tolower($0) ~ "^# " tolower(h))} p' "$plan"
}
task_section() {  # "## T1 ..." up to the next "## "
  awk -v t="$task" '/^## /{p=($2==t || $2==t":" || index($0,"## "t" ")==1)} p' "$plan"
}
if [[ -z "$fixmsg" ]]; then
  if [[ -n "$spec" ]]; then
    if [[ "$spec" == "-" ]]; then cat >"$brief"; elif [[ ! "$spec" -ef "$brief" ]]; then cp "$spec" "$brief"; fi
  else
    [[ -f "$plan" ]] || { echo "no $plan (or pass --spec FILE)"; exit 2; }
    ts="$(task_section)"; [[ -n "$ts" ]] || { echo "task $task not found in $plan"; exit 2; }
    { echo "# Task $task (one task from a larger plan — do only this)"; echo
      section Goal; echo; section Constraints; echo; echo "$ts"; } >"$brief"
  fi
fi
if [[ -z "$verify" && $no_verify == 0 && -f "$brief" ]]; then
  vline="$(grep -iE '^[[:space:]]*(done when|verify)[[:space:]]*:' "$brief" | head -1 | sed -E 's/^[^:]*:[[:space:]]*//')"
  if [[ "$vline" == *'`'*'`'* ]]; then
    # "Done when: `pnpm test` passes" -> run only what's inside the first pair of backticks
    verify="$(printf '%s' "$vline" | sed -E 's/^[^`]*`+([^`]*)`.*$/\1/')"
  else
    verify="$vline"
  fi
  # only run it if it looks like a command, not prose
  [[ "$verify" =~ ^[A-Za-z0-9_./-]+([[:space:]]|$) ]] && command -v "${verify%% *}" >/dev/null 2>&1 || verify=""
fi
[[ $no_verify == 1 ]] && verify=""

# ---- timeout per tier -------------------------------------------------------------------------
if [[ -z "$tmo" ]]; then
  tmo="$(jq -r --arg t "$tier" '.timeouts[$t] // empty' "$routing" 2>/dev/null)"
  [[ -n "$tmo" ]] || case "$tier" in t1-easy) tmo=600 ;; t2-normal) tmo=1200 ;; *) tmo=2400 ;; esac
fi
if command -v timeout >/dev/null; then TO=(timeout --kill-after=10 "$tmo")
elif command -v gtimeout >/dev/null; then TO=(gtimeout --kill-after=10 "$tmo")
else TO=(); fi

# ---- where the worker runs --------------------------------------------------------------------
# Two tasks writing the main tree at once can't be told apart (each would claim the other's files),
# so if another task is already running there, this one goes to its own worktree.
running="$root/$dir/running"; mkdir -p "$running"
if [[ $isolated == 0 && $readonly_ == 0 ]]; then
  for pf in "$running"/*.pid; do
    [[ -f "$pf" ]] || continue
    other="$(basename "$pf" .pid)"; [[ "$other" == "$task" ]] && continue
    if kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
      echo "$other is already writing the main tree: running $task in its own worktree (apply it later with: crewtier apply $task)"
      isolated=1; break
    else rm -f "$pf"; fi
  done
  if [[ $isolated == 0 ]]; then echo $$ >"$running/$task.pid"; trap 'rm -f "$running/$task.pid"' EXIT; fi
fi
work="$root"
if [[ $isolated == 1 ]]; then
  work="$root/$dir/wt/$task"
  if [[ ! -d "$work" ]]; then
    git worktree add --detach -q "$work" HEAD || { echo "could not create worktree"; exit 1; }
    # reuse heavy, untracked dependency folders instead of reinstalling them
    for d in node_modules .venv venv vendor .pnpm-store; do
      [[ -e "$root/$d" && ! -e "$work/$d" ]] && ! git ls-files --error-unmatch "$d" >/dev/null 2>&1 && ln -s "$root/$d" "$work/$d"
    done
  fi
  mkdir -p "$work/$tasks"; [[ -f "$brief" ]] && cp "$brief" "$work/$brief"
fi

# ---- prompt: short, fixed, refers to the brief file ---------------------------------------------
CONTRACT='When you are done, end your reply with exactly this block and nothing after it:
<<<CREWTIER
status: done | partial | blocked
files: <files you changed, comma separated, or none>
verify: <command you ran and pass/fail, or none>
notes: <one line: anything unfinished or the lead should know>
CREWTIER>>>'
if [[ -n "$fixmsg" ]]; then
  [[ -f "$last" ]] || { echo "no previous run for $task to fix"; exit 2; }
  if [[ "$fixmsg" == "@verify" ]]; then
    [[ -s "$tasks/$task.verify.txt" ]] || { echo "no failed verify output saved for $task — pass --fix \"message\""; exit 2; }
    { echo "The check command failed. Its output:"; echo '```'; tail -60 "$tasks/$task.verify.txt"; echo '```'; } >"$tasks/$task.fix.md"
  else
    printf '%s\n' "$fixmsg" >"$tasks/$task.fix.md"
  fi
  [[ $isolated == 1 ]] && cp "$tasks/$task.fix.md" "$work/$tasks/"
  prompt="Task $task is not finished. Read $tasks/$task.fix.md for what is wrong, fix it, and stay within task $task (brief: $brief).
$CONTRACT"
  candidates="$(cat "$last")"; resume=1
else
  ro=""; [[ $readonly_ == 1 ]] && ro=" This is a READ-ONLY task: do not create, edit or delete any files; only read, analyze and report."
  vf=""; [[ -n "$verify" ]] && vf=" Before finishing, run \`$verify\` and fix any failures it shows."
  prompt="You are a worker agent. Read $brief and do exactly that task, nothing else.$ro Start from the files it lists; only search the wider repo if you must.$vf Do not commit.
$CONTRACT"
  candidates="$(jq -c --arg t "$tier" '.tiers[$t][]?' "$routing")"; resume=0
  [[ -n "$candidates" ]] || { echo "tier $tier is empty or missing in $routing"; exit 2; }
fi

# ---- health cache helpers -----------------------------------------------------------------------
health_status() { bash "$here/health.sh" "$1" >/dev/null 2>&1; awk -F'|' -v a="$1" '$1==a{s=$2} END{print s}' "$health" 2>/dev/null; }
mark_health() {
  mkdir -p "$state"; touch "$health"
  grep -v "^$1|" "$health" >"$health.tmp" 2>/dev/null; mv "$health.tmp" "$health"
  printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$(date +%s)" >>"$health"
}

# ---- run ----------------------------------------------------------------------------------------
ran="" code=3 log="" t0=$(date +%s) skipped=""
export CREWTIER_READONLY=$readonly_
allow_paid="${CREWTIER_ALLOW_PAID:-$(jq -r '.allow_paid // false' "$routing" 2>/dev/null)}"
skip() { skipped="$skipped${skipped:+, }$1"; echo "skip $1"; }
changed() { ( cd "$work" && git status --porcelain -- . ':(exclude).crewtier' ':(exclude)node_modules' ':(exclude).venv' ':(exclude)venv' ); }
dirty0="$(changed)"   # state before any attempt; we only auto-reset a tree that started clean
reset_attempt() {  # $1 label: save what the failed attempt changed, then put the tree back
  local now; now="$(changed)"; [[ "$now" == "$dirty0" ]] && return 0
  local pf="$dir/patches/$task.$1.partial.patch"
  ( cd "$work" && git add -A -N . 2>/dev/null; git diff HEAD --binary -- . ':(exclude).crewtier' ) >"$pf"
  if [[ -n "$dirty0" && $isolated == 0 ]]; then
    echo "  partial changes kept in place (tree wasn't clean before) — saved copy: $pf"; return 0
  fi
  ( cd "$work" && git reset -q HEAD -- . 2>/dev/null; git checkout -q -- . 2>/dev/null
    git clean -fdq -e .crewtier -e node_modules -e .venv -e venv -e vendor -e .pnpm-store -- . )
  echo "  partial changes saved to $pf and reset"
}
while IFS= read -r c; do
  [[ -z "$c" ]] && continue
  b=$(jq -r .backend <<<"$c"); m=$(jq -r '.model // ""' <<<"$c"); e=$(jq -r '.effort // ""' <<<"$c")
  paid=$(jq -r '.paid // false' <<<"$c")
  [[ "$b" == "$lead" ]] && { skip "$b (the lead)"; continue; }
  [[ $resume == 0 ]] && is_disabled "$b" && { skip "$b (turned off: crewtier enable $b)"; continue; }
  command -v "$b" >/dev/null || { skip "$b (not installed)"; continue; }
  [[ "$paid" == true && "$allow_paid" != true && "$allow_paid" != 1 ]] && { skip "$b/$m (API-billed; set CREWTIER_ALLOW_PAID=1)"; continue; }
  if [[ "${CREWTIER_SKIP_HEALTH:-}" != 1 && $resume == 0 ]]; then
    case "$(health_status "$b")" in
      auth-required)   skip "$b (signed out: $(login_hint "$b"))"; continue ;;
      quota-exhausted) skip "$b (quota exhausted)"; continue ;;
      rate-limited)    skip "$b (rate-limited, cooling down)"; continue ;;
    esac
  fi
  log="$logs/$task-$b.log"; t_att=$(date +%s)
  printf '=== %s %s/%s tier=%s fix=%s isolated=%s readonly=%s timeout=%ss ===\n' "$(date +%T)" "$b" "$m" "$tier" "$resume" "$isolated" "$readonly_" "$tmo" >>"$log"
  start=$(wc -l <"$log")
  ( cd "$work" && ${TO[@]+"${TO[@]}"} bash -c "$(declare -f $ADAPTER_FNS); prompt=$(printf '%q' "$prompt"); run_one $(printf '%q ' "$b" "$m" "$e" "$resume")" ) 2>&1 \
    | strip_ansi >>"$log"
  code=${PIPESTATUS[0]}
  if [[ $code -ne 0 && $code -ne 124 && $code -ne 137 ]]; then
    case "$(tail -n +"$((start+1))" "$log" | tail -n 40 | classify_failure)" in
      auth)      mark_health "$b" auth-required "$(login_hint "$b")"; skip "$b/$m (signed out mid-task)"; reset_attempt "$b"; continue ;;
      quota)     mark_health "$b" quota-exhausted "hit during task $task"; skip "$b/$m (quota exhausted mid-task)"; reset_attempt "$b"; continue ;;
      ratelimit) mark_health "$b" rate-limited "hit during task $task"; skip "$b/$m (rate-limited mid-task)"; reset_attempt "$b"; continue ;;
    esac
  fi
  echo "$c" >"$last"; ran="$b/$m"; break
done <<<"$candidates"

write_result() {  # status [extra jq args...]
  local st="$1"; shift
  jq -n --arg task "$task" --arg tier "$tier" --arg status "$st" --arg worker "${ran%%/*}" --arg model "${ran#*/}" \
        --arg skipped "$skipped" --arg log "$log" --argjson exit "${code:-3}" --argjson seconds "${secs:-0}" \
        --argjson readonly "$readonly_" --argjson isolated "$isolated" --arg verify_cmd "$verify" --arg verify "${vres:-none}" \
        --arg files "${files:-}" --arg patch "${patch:-}" --arg session "${wsession:-}" --argjson usage "${wusage:-null}" \
        --arg reported "${block:-}" --argjson lines "${lines:-0}" '
    {task:$task, tier:$tier, status:$status, worker:(if $worker=="" then null else $worker end), model:(if $model=="" then null else $model end),
     exitCode:$exit, seconds:$seconds, readOnly:($readonly==1), isolated:($isolated==1),
     touchedFiles:($files|split("\n")|map(select(.!=""))), linesChanged:$lines,
     verify:{command:(if $verify_cmd=="" then null else $verify_cmd end), result:$verify},
     skipped:($skipped|split(", ")|map(select(.!=""))),
     workerUsage:$usage, sessionFile:(if $session=="" then null else $session end),
     reported:($reported|split("\n")|map(select(.!="")|capture("^(?<key>[a-z]+):\\s*(?<value>.*)$")?)|from_entries),
     patch:(if $patch=="" then null else $patch end), log:(if $log=="" then null else $log end)}' >"$dir/results/$task.json"
}

if [[ -z "$ran" ]]; then
  write_result no-worker
  echo "--- no worker in tier $tier could run (skipped: ${skipped:-none}) — escalate a tier or do it yourself ---"; exit 3
fi

# worker usage, where the worker CLI leaves a readable session transcript (claude, codex)
wusage="null"; wsession=""
case "$b" in
  claude|codex)
    if [[ $resume == 1 && -f "$last.session" ]]; then wsession="$(cat "$last.session")"; base_u="$(cat "$last.usage" 2>/dev/null || echo '{"in":0,"out":0,"cw":0,"cr":0}')"
    else wsession="$(bash "$here/measure.sh" worker-session "$b" "$t_att" 2>/dev/null)"; base_u='{"in":0,"out":0,"cw":0,"cr":0}'; fi
    if [[ -n "$wsession" && -f "$wsession" ]]; then
      now_u="$(bash "$here/measure.sh" file-totals "$b" "$wsession")"
      wusage="$(jq -cn --argjson a "$base_u" --argjson b "$now_u" '{in:($b.in-$a.in), out:($b.out-$a.out), cw:($b.cw-$a.cw), cr:($b.cr-$a.cr)}')"
      echo "$wsession" >"$last.session"; echo "$now_u" >"$last.usage"
    fi ;;
esac
secs=$(( $(date +%s) - t0 )); dur="$((secs/60))m$((secs%60))s"
out="$(tail -n +"$((start+1))" "$log")"

# ---- results ------------------------------------------------------------------------------------
if [[ $isolated == 1 ]]; then
  ( cd "$work" && git add -A -N . 2>/dev/null; git diff HEAD --binary -- . ':(exclude).crewtier' ':(exclude)node_modules' ':(exclude).venv' ':(exclude)venv' ':(exclude)vendor' ) >"$dir/patches/$task.patch"
  diffstat="$(cd "$work" && git diff HEAD --stat -- . ':(exclude).crewtier' ':(exclude)node_modules' | tail -15)"
else
  git add -A -N . 2>/dev/null
  diffstat="$(git diff HEAD --stat -- . ':(exclude).crewtier' | tail -15)"
fi

vres="none"; vtail=""
if [[ $code -eq 0 && -n "$verify" ]]; then
  VTO=(); [[ ${#TO[@]} -gt 0 ]] && VTO=("${TO[0]}" --kill-after=10 "${CREWTIER_VERIFY_TIMEOUT:-900}")
  ( cd "$work" && ${VTO[@]+"${VTO[@]}"} bash -c "$verify" ) >"$tasks/$task.verify.raw" 2>&1; vcode=$?
  strip_ansi <"$tasks/$task.verify.raw" >"$tasks/$task.verify.txt"; rm -f "$tasks/$task.verify.raw"
  if [[ "$vcode" == 0 ]]; then vres="PASS"; : >"$tasks/$task.verify.txt"
  elif [[ "$vcode" == 127 || ( "$vcode" == 2 && -n "$(grep -iE 'syntax error|unexpected (EOF|token)|unterminated|command not found' "$tasks/$task.verify.txt")" ) ]]; then
    # the check command itself is broken: that says nothing about the worker's code
    vres="ERROR (exit $vcode)"
    { echo "command: $verify"; cat "$tasks/$task.verify.txt"; } >"$tasks/$task.verify.tmp" && mv "$tasks/$task.verify.tmp" "$tasks/$task.verify.txt"
    vtail="$(grep -v '^\s*$' "$tasks/$task.verify.txt" | tail -8)"
  else
    vres="FAIL (exit $vcode)"
    [[ -s "$tasks/$task.verify.txt" ]] || echo "\`$verify\` exited $vcode with no output" >"$tasks/$task.verify.txt"
    { echo "command: $verify"; cat "$tasks/$task.verify.txt"; } >"$tasks/$task.verify.tmp" && mv "$tasks/$task.verify.tmp" "$tasks/$task.verify.txt"
    vtail="$(grep -v '^\s*$' "$tasks/$task.verify.txt" | tail -15)"
  fi
fi

block="$(printf '%s\n' "$out" | awk '/<<<CREWTIER/{p=1;next} /CREWTIER>>>/{p=0} p' | tail -6)"
files="$(cd "$work" && git add -A -N . 2>/dev/null; git diff HEAD --name-only -- . ':(exclude).crewtier' ':(exclude)node_modules' ':(exclude).venv' ':(exclude)venv' ':(exclude)vendor')"
lines="$(cd "$work" && git diff HEAD --numstat -- . ':(exclude).crewtier' ':(exclude)node_modules' ':(exclude).venv' ':(exclude)venv' ':(exclude)vendor' 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {n += $1 + $2} END {print n + 0}')"
patch=""; [[ $isolated == 1 ]] && patch="$dir/patches/$task.patch"

status="done"; rstatus="done"
if [[ $code -eq 124 || $code -eq 137 ]]; then status="TIMED OUT after ${tmo}s"; rstatus="timed-out"
elif [[ $code -ne 0 ]]; then status="worker failed (exit $code)"; rstatus="worker-failed"
elif [[ "$vres" == ERROR* ]]; then status="VERIFY-ERROR — the check command is broken, the worker's changes are kept"; rstatus="verify-error"
elif [[ "$vres" == FAIL* ]]; then status="verify failed"; rstatus="verify-failed"
elif [[ -z "$files" && $readonly_ == 0 && -z "$fixmsg" ]]; then status="NO CHANGES — the worker reported back but changed nothing"; rstatus="no-changes"
fi
write_result "$rstatus"
if [[ -n "$wusage" && "$wusage" != null ]]; then
  wu="$state/worker-usage.tsv"
  [[ -f "$wu" ]] || printf 'date\trepo\ttask\tworker\ttier\tlead\tseconds\tmodel\tin\tout\tcache_write\tcache_read\tstatus\n' >"$wu"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%F)" "$(basename "$root")" "$task" "$ran" "$tier" "$lead" "$secs" "${ran#*/}" \
    "$(jq -r '[.in,.out,.cw,.cr]|@tsv' <<<"$wusage")" "$rstatus" >>"$wu"
fi

echo "crewtier $task [$tier] $ran — $status — $dur"
[[ -n "$skipped" ]] && echo "route: skipped ${skipped}"
if [[ -n "$diffstat" ]]; then echo "diff:"; printf '%s\n' "$diffstat" | sed 's/^/  /'; else echo "diff: no changes"; fi
[[ $readonly_ == 1 && -n "$diffstat" ]] && echo "WARNING: read-only task changed files — review or discard them"
[[ -n "$verify" ]] && echo "verify: $verify → $vres"
[[ -n "$vtail" ]] && { printf '%s\n' "$vtail" | sed 's/^/  | /'; echo "  → send it back: crewtier run $task $tier --fix"; }
if [[ -n "$block" ]]; then echo "result:"; printf '%s\n' "$block" | sed 's/^/  /'
else echo "result (no result block, last lines):"; printf '%s\n' "$out" | grep -v '^\s*$' | tail -"${CREWTIER_TAIL:-10}" | sed 's/^/  /'; fi
[[ $isolated == 1 ]] && echo "patch: $dir/patches/$task.patch → crewtier apply $task (or crewtier discard $task)"
[[ -n "$wusage" && "$wusage" != null ]] && echo "worker usage: $(jq -r '"in \(.in), out \(.out), cache read \(.cr)"' <<<"$wusage")"
echo "log: $log · result: $dir/results/$task.json"

# ---- automatic escalation (opt-in) ---------------------------------------------------------------
if [[ $auto == 1 && ( "$rstatus" == verify-failed || "$rstatus" == no-changes ) ]]; then
  pass=(); [[ $isolated == 1 ]] && pass+=(--isolated); [[ $readonly_ == 1 ]] && pass+=(--read-only)
  [[ -n "$spec" ]] && pass+=(--spec "$brief")   # the brief came from --spec, not plan.md: keep using it
  [[ -n "$verify" ]] && pass+=(--verify "$verify"); [[ $no_verify == 1 ]] && pass+=(--no-verify)
  [[ -n "${CREWTIER_BASE_CLEAN:-}" ]] || { [[ -z "$dirty0" || -n "$fixmsg" ]] && export CREWTIER_BASE_CLEAN=1 || export CREWTIER_BASE_CLEAN=0; }
  if [[ $round == 0 && "$rstatus" == verify-failed ]]; then
    echo; echo "↻ auto-escalate: one fix round on $ran"
    exec bash "$0" "$task" "$tier" --fix --auto-escalate --round 1 ${pass[@]+"${pass[@]}"}
  fi
  case "$tier" in t1-easy) next=t2-normal ;; t2-normal) next=t3-hard ;; *) next="" ;; esac
  if [[ "$CREWTIER_BASE_CLEAN" == 1 ]]; then
    pf="$dir/patches/$task.$tier.${ran%%/*}.attempt.patch"
    ( cd "$work" && git add -A -N . 2>/dev/null; git diff HEAD --binary -- . ':(exclude).crewtier' ) >"$pf"
    ( cd "$work" && git reset -q HEAD -- . 2>/dev/null; git checkout -q -- . 2>/dev/null
      git clean -fdq -e .crewtier -e node_modules -e .venv -e venv -e vendor -e .pnpm-store -- . )
    echo "  attempt saved to $pf and reset"
    if [[ -n "$next" ]]; then
      echo; echo "↑ auto-escalate: $task $tier → $next"
      rm -f "$last" "$last.session" "$last.usage"
      exec bash "$0" "$task" "$next" --auto-escalate --round 0 ${pass[@]+"${pass[@]}"}
    fi
    # last tier: put the final attempt back in the tree, so the lead can fix it instead of hunting for patches
    ( cd "$work" && git apply --whitespace=nowarn "$pf" 2>/dev/null ) && echo "  last attempt left in the tree (also saved as $pf)"
    echo "↑ auto-escalate: $task failed in $tier — back to the lead (earlier attempts are in $dir/patches/)"
  else
    echo "↑ auto-escalate stopped: the tree wasn't clean before $task, so it can't be reset safely"
  fi
fi

if [[ $code -eq 124 || $code -eq 137 ]]; then exit 124; fi
[[ "$rstatus" == done ]] && exit 0
exit 1
