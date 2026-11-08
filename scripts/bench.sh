#!/usr/bin/env bash
# A/B benchmark: the same task, from the same commit, done twice by the same lead —
# once by itself, once using crewtier — then the same test command on both results.
#
#   bench.sh --lead claude --task "Add pagination to GET /orders" --test "pnpm test"
#   bench.sh --lead codex  --task-file task.md --test "go test ./..." --keep
#
# Reports per run: the LEAD's tokens (from its own headless JSON output), price-weighted cost units,
# wall time, test result, diff size, and how many crewtier tasks were routed. Results are appended
# to ~/.crewtier/bench.tsv. Leads supported for measuring: claude, codex.
#
# Each run happens in its own git worktree under .crewtier/bench/, and the lead runs headless with
# permissions bypassed inside that worktree (needed so it can edit files and call crewtier without
# prompts). Override with CREWTIER_BENCH_CLAUDE_FLAGS / CREWTIER_BENCH_CODEX_FLAGS.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/adapters.sh"

lead=""; taskp=""; test_cmd=""; keep=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lead) lead="${2:?}"; shift 2 ;;
    --task) taskp="${2:?}"; shift 2 ;;
    --task-file) taskp="$(cat "${2:?}")"; shift 2 ;;
    --test) test_cmd="${2:?}"; shift 2 ;;
    --keep) keep=1; shift ;;
    --clean)  # remove worktrees kept by earlier --keep runs
      r="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repo"; exit 2; }
      n=0; for d in "$r"/.crewtier/bench/*/self "$r"/.crewtier/bench/*/crewtier; do
        [[ -d "$d" ]] || continue
        ( cd "$d" && git add -A -N . 2>/dev/null; git diff HEAD -- . ':(exclude).crewtier' ) >"$d.diff" 2>/dev/null
        git -C "$r" worktree remove --force "$d" 2>/dev/null && n=$((n + 1))
      done
      git -C "$r" worktree prune 2>/dev/null
      m=$(ls -d "$r"/.crewtier/bench/*/ 2>/dev/null | wc -l | tr -d ' ')
      echo "removed $n bench worktree(s); kept $m run folder(s) in .crewtier/bench/ with each run's diff, numbers and lead output"
      echo "(delete those too: rm -rf .crewtier/bench)"; exit 0 ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done
[[ -n "$lead" && -n "$taskp" ]] || { echo "usage: crewtier bench --lead claude|codex --task \"…\" [--test \"cmd\"] [--keep]   ·   crewtier bench --clean"; exit 2; }
case "$lead" in claude|codex) ;; *) echo "bench can measure claude or codex as the lead for now"; exit 2 ;; esac
command -v "$lead" >/dev/null || { echo "$lead is not installed"; exit 2; }
command -v jq >/dev/null || { echo "jq required"; exit 2; }
root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "run inside a git repo"; exit 2; }
cd "$root"
[[ -z "$(git status --porcelain -- . ':(exclude).crewtier')" ]] || { echo "commit or stash your changes first: both runs must start from the same commit"; exit 2; }

id="$(date +%Y%m%d-%H%M%S)"; base="$(git rev-parse --short HEAD)"
bdir="$root/.crewtier/bench/$id"; mkdir -p "$bdir"
state="$HOME/.crewtier"; mkdir -p "$state"; tsv="$state/bench.tsv"
[[ -f "$tsv" ]] || printf 'date\trepo\tcommit\tlead\tmode\tin\tout\tcache_write\tcache_read\tcost_units\tseconds\ttest\tdiff_lines\tcrewtier_tasks\ttask\tturns\tusd\n' >"$tsv"

lead_run() {  # $1 dir  $2 prompt  -> prints usage JSON {in,out,cw,cr}; raw output saved next to it
  local d="$1" p="$2" raw="$1.lead.out"
  if [[ "$lead" == claude ]]; then
    # shellcheck disable=SC2086
    ( cd "$d" && CREWTIER_LEAD=claude claude -p "$p" --output-format json ${CREWTIER_BENCH_CLAUDE_FLAGS:---permission-mode bypassPermissions} ) >"$raw" 2>"$raw.err"
    jq -c '{in:(.usage.input_tokens//0), out:(.usage.output_tokens//0), cw:(.usage.cache_creation_input_tokens//0), cr:(.usage.cache_read_input_tokens//0),
            turns:(.num_turns // null), usd:(.total_cost_usd // null),
            usd_lead:((.modelUsage // {}) | to_entries | if length > 0 then (max_by(.value.outputTokens // 0) | .value.costUSD // null) else null end)}' "$raw" 2>/dev/null \
      || echo '{"in":0,"out":0,"cw":0,"cr":0}'
  else
    # shellcheck disable=SC2086
    ( cd "$d" && CREWTIER_LEAD=codex codex exec --json ${CREWTIER_BENCH_CODEX_FLAGS:---dangerously-bypass-approvals-and-sandbox} "$p" ) >"$raw" 2>"$raw.err"
    # sum usage from turn events; fall back to the last cumulative token_count event
    jq -cs '
      ([ .[] | (.usage? // empty) ] ) as $u
      | if ($u|length) > 0 then
          {in: ([$u[].input_tokens // 0]|add) - ([$u[].cached_input_tokens // 0]|add), out: ([$u[].output_tokens // 0]|add), cw: 0, cr: ([$u[].cached_input_tokens // 0]|add), turns: ($u|length)}
        else
          ([ .[] | (.msg.info.total_token_usage? // .payload.info.total_token_usage? // empty) ] | last // {}) as $t
          | {in: (($t.input_tokens // 0) - ($t.cached_input_tokens // 0)), out: ($t.output_tokens // 0), cw: 0, cr: ($t.cached_input_tokens // 0)}
        end' "$raw" 2>/dev/null || echo '{"in":0,"out":0,"cw":0,"cr":0}'
  fi
}

one() {  # $1 mode self|crewtier
  local mode="$1" d="$bdir/$1" p t0 u secs tres="none" lines tasks cu
  git worktree add --detach -q "$d" HEAD || { echo "worktree failed"; return 1; }
  for x in node_modules .venv venv vendor; do [[ -e "$root/$x" && ! -e "$d/$x" ]] && ln -s "$root/$x" "$d/$x"; done
  if [[ "$mode" == self ]]; then
    p="$taskp

Do this task yourself. Do not use crewtier and do not delegate to other agents. Do not commit."
  else
    p="$taskp

Use the crewtier skill for this (read its SKILL.md and follow it). Do not commit."
  fi
  echo "… $mode run ($lead as lead)" >&2
  t0=$(date +%s); u="$(lead_run "$d" "$p")"; secs=$(( $(date +%s) - t0 ))
  if [[ -n "$test_cmd" ]]; then ( cd "$d" && bash -c "$test_cmd" ) >"$d.test.out" 2>&1 && tres=PASS || tres=FAIL; fi
  lines="$(cd "$d" && git add -A -N . 2>/dev/null; git diff HEAD --numstat -- . ':(exclude).crewtier' ':(exclude)node_modules' | awk '{a+=$1+$2} END{print a+0}')"
  tasks="$(ls "$d"/.crewtier/results/*.json 2>/dev/null | wc -l | tr -d ' ')"   # one result per delegated task
  cu="$(jq -r '(.in + 5*.out + 1.25*.cw + 0.1*.cr) | floor' <<<"$u")"
  turns="$(jq -r '.turns // "-"' <<<"$u")"
  # dollars: Claude Code reports its own cost; otherwise CREWTIER_PRICE="in,out,cache_write,cache_read" (USD per 1M tokens)
  usd="$(jq -r '.usd // empty | . * 10000 | round / 10000' <<<"$u" 2>/dev/null)"
  usd_lead="$(jq -r '.usd_lead // empty | . * 10000 | round / 10000' <<<"$u" 2>/dev/null)"
  # other models (advisor, subagents) billed in the same run are reported, but the comparison uses the lead's own cost
  if [[ -n "$usd_lead" && -n "$usd" ]]; then
    other="$(jq -nr --argjson a "$usd" --argjson b "$usd_lead" '($a - $b) * 10000 | round / 10000')"
    [[ "$other" != 0 ]] && echo "  ($mode: \$$other of this run went to other models, e.g. an advisor or subagents; not counted below)" >&2
    usd="$usd_lead"
  fi
  if [[ -z "$usd" && -n "${CREWTIER_PRICE:-}" ]]; then
    usd="$(jq -r --arg p "$CREWTIER_PRICE" '($p | split(",") | map(tonumber)) as $r | ((.in*$r[0] + .out*$r[1] + .cw*$r[2] + .cr*$r[3]) / 1000000 * 10000 | round / 10000)' <<<"$u")"
  fi
  usd="${usd:--}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%F)" "$(basename "$root")" "$base" "$lead" "$mode" \
    "$(jq -r '[.in,.out,.cw,.cr]|@tsv' <<<"$u")" "$cu" "$secs" >"$d.row"
  printf '\t%s\t%s\t%s\t%s\t%s\t%s\n' "$tres" "$lines" "$tasks" "$(head -c 80 <<<"$taskp" | tr '\t\n' '  ')" "$turns" "$usd" >>"$d.row"
  tr -d '\n' <"$d.row" >>"$tsv"; echo >>"$tsv"
  printf '%-9s %9s %9s %10s %11s %7ss %6s %6s %5s %5s %8s\n' "$mode" \
    "$(jq -r .in <<<"$u")" "$(jq -r .out <<<"$u")" "$(jq -r .cr <<<"$u")" "$cu" "$secs" "$tres" "$lines" "$tasks" "$turns" "$usd"
  echo "$cu" >"$d.cu"; echo "$usd" >"$d.usd"
}

printf '%-9s %9s %9s %10s %11s %8s %6s %6s %5s %5s %8s\n' RUN LEAD_IN LEAD_OUT CACHE_READ COST_UNITS TIME TEST DIFF TASKS TURNS USD
one self; one crewtier
a="$(cat "$bdir/self.cu" 2>/dev/null || echo 0)"; b="$(cat "$bdir/crewtier.cu" 2>/dev/null || echo 0)"
if [[ "$a" -gt 0 ]]; then
  echo "lead cost with crewtier: $(( (b * 100) / a ))% of doing it alone (cost units)"
fi
ua="$(cat "$bdir/self.usd" 2>/dev/null)"; ub="$(cat "$bdir/crewtier.usd" 2>/dev/null)"
if [[ "$ua" != "-" && -n "$ua" && "$ub" != "-" && -n "$ub" ]]; then
  echo "in dollars: \$$ua alone vs \$$ub with crewtier ($(jq -nr --argjson a "$ua" --argjson b "$ub" 'if $a > 0 then ($b / $a * 100 | floor | tostring) + "%" else "-" end'))"
fi
echo "(worker usage is billed to each worker's own plan and isn't counted here; results appended to ${tsv/#$HOME/~})"
for m in self crewtier; do   # keep each side's diff, so the two results can be compared after the worktrees go
  ( cd "$bdir/$m" 2>/dev/null && git add -A -N . 2>/dev/null; git diff HEAD -- . ':(exclude).crewtier' ':(exclude)node_modules' ) >"$bdir/$m.diff" 2>/dev/null
done
echo "diffs: ${bdir#$root/}/self.diff · ${bdir#$root/}/crewtier.diff"
if [[ $keep == 0 ]]; then
  git worktree remove --force "$bdir/self" 2>/dev/null; git worktree remove --force "$bdir/crewtier" 2>/dev/null
else
  echo "worktrees kept in ${bdir#$root/} — compare with: git -C ${bdir#$root/}/self diff, git -C ${bdir#$root/}/crewtier diff"
  echo "remove them when done: crewtier bench --clean"
fi
