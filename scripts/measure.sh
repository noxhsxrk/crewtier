#!/usr/bin/env bash
# Measure the LEAD agent's own token use per task, and keep a track record per worker model.
#
#   measure.sh start T1                               snapshot before a task
#   measure.sh end   T1 t2-normal codex/gpt-x pass    delta since start -> results.tsv
#   measure.sh end   T3 lead self pass                (task the lead did itself = baseline)
#   measure.sh session                                lead's totals for the current session
#   measure.sh report                                 is delegating cheaper than doing it yourself?
#   measure.sh models                                 pass rate and cost per task per worker model
#   measure.sh worker-session <claude|codex> <epoch>  newest worker session transcript started after epoch
#   measure.sh file-totals <claude|codex> <file>      token totals of one transcript (JSON)
#
# CREWTIER_LEAD = the agent running this skill (auto-detected for Claude Code).
# Token counts are read from the lead's own session transcript:
#   claude: newest ~/.claude/projects/*/*.jsonl
#   codex : newest ~/.codex/sessions/**/rollout-*.jsonl (token_count events)
# Other leads: tasks and diff sizes are still logged; token columns stay 0.
# Override the transcript with CREWTIER_TRANSCRIPT=<file>.
set -uo pipefail
command -v jq >/dev/null || { echo "jq required"; exit 2; }

lead="${CREWTIER_LEAD:-}"
[[ -z "$lead" && "${CLAUDECODE:-}" == "1" ]] && lead=claude
lead="${lead:-unknown}"

state="$HOME/.crewtier"; mkdir -p "$state"
results="$state/results.tsv"
meter=".crewtier/meter"
ZERO='{"in":0,"out":0,"cw":0,"cr":0}'

transcript() {
  if [[ -n "${CREWTIER_TRANSCRIPT:-}" ]]; then echo "$CREWTIER_TRANSCRIPT"; return; fi
  case "$lead" in
    claude) ls -t "$HOME"/.claude/projects/*/*.jsonl 2>/dev/null | head -1 ;;
    codex)  find "$HOME/.codex/sessions" -name 'rollout-*.jsonl' -type f 2>/dev/null \
              | while read -r f; do printf '%s\t%s\n' "$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")" "$f"; done \
              | sort -rn | head -1 | cut -f2 ;;
    *) ;;
  esac
}

totals() {
  local f; f="$(transcript)"
  if [[ -z "$f" || ! -f "$f" ]]; then
    [[ "$lead" == claude || "$lead" == codex ]] && echo "warning: no $lead transcript found" >&2
    echo "$ZERO"; return
  fi
  totals_of "$lead" "$f"
}

# A session transcript for <kind> whose first entry is at/after <epoch>: a worker run started then.
# (First-line timestamps, not file times, so a lead of the same kind writing its own transcript
# at the same moment isn't mistaken for the worker.)
worker_session() {  # kind epoch
  local kind="$1" since iso f first
  since="$2"; iso="$(date -u -d "@$since" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -r "$since" +%Y-%m-%dT%H:%M:%S)"
  local ref; ref="$(mktemp)"   # portable "modified after epoch": compare against a file stamped then
  touch -d "@$since" "$ref" 2>/dev/null || touch -t "$(date -r "$since" +%Y%m%d%H%M.%S)" "$ref"
  case "$kind" in
    claude) find "$HOME/.claude/projects" -name '*.jsonl' -type f -newer "$ref" 2>/dev/null ;;
    codex)  find "$HOME/.codex/sessions" -name 'rollout-*.jsonl' -type f -newer "$ref" 2>/dev/null ;;
  esac | while read -r f; do
    first="$(head -c 4000 "$f" | grep -o '"timestamp":"[^"]*"' | head -1 | cut -d'"' -f4)"
    [[ -n "$first" && "${first:0:19}" > "$iso" || "${first:0:19}" == "$iso" ]] && echo "$f"
  done | while read -r f; do printf '%s\t%s\n' "$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")" "$f"; done | sort -rn | head -1 | cut -f2
  rm -f "$ref"
}

totals_of() {  # kind file
  local kind="$1" f="$2"
  [[ -f "$f" ]] || { echo "$ZERO"; return; }
  case "$kind" in
    codex)  # cumulative counters: take the last token_count event
      jq -cs '[ .[] | select(.payload.type? == "token_count") | .payload.info.total_token_usage? | select(. != null) ] | last
        | if . == null then {in:0,out:0,cw:0,cr:0}
          else {in: ((.input_tokens // 0) - (.cached_input_tokens // 0)), out: (.output_tokens // 0), cw: 0, cr: (.cached_input_tokens // 0)} end' "$f" ;;
    *)      # claude format: usage on each assistant message, one reply may span several lines
      jq -cs '
        [ .[] | select(.type=="assistant" and .message.usage != null)
              | {id: (.message.id // .uuid), u: .message.usage} ]
        | unique_by(.id) | map(.u)
        | { in:  (map(.input_tokens // 0) | add // 0),
            out: (map(.output_tokens // 0) | add // 0),
            cw:  (map(.cache_creation_input_tokens // 0) | add // 0),
            cr:  (map(.cache_read_input_tokens // 0) | add // 0) }' "$f" ;;
  esac
}

diff_lines() {  # lines added+removed vs HEAD (run before committing)
  git diff HEAD --numstat 2>/dev/null | awk '{a+=$1; d+=$2} END {print a+d+0}'
}

header='date\tlead\trepo\ttask\ttier\tworker\toutcome\tdiff_lines\tin\tout\tcache_write\tcache_read\n'

case "${1:-}" in
  start)
    t="${2:?task id}"; mkdir -p "$meter"
    totals >"$meter/$t.start"
    echo "meter started for $t (lead: $lead)" ;;

  end)
    t="${2:?task id}"; tier="${3:?tier}"; who="${4:?worker/model, or self}"; outcome="${5:?pass|fail|escalated}"
    [[ -f "$meter/$t.start" ]] || { echo "no start snapshot for $t"; exit 2; }
    now="$(totals)"; before="$(cat "$meter/$t.start")"
    d=$(jq -nr --argjson a "$before" --argjson b "$now" \
      '[($b.in-$a.in),($b.out-$a.out),($b.cw-$a.cw),($b.cr-$a.cr)] | @tsv')
    [[ -f "$results" ]] || printf "$header" >"$results"
    repo="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
    lines="$(diff_lines)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%F)" "$lead" "$repo" "$t" "$tier" "$who" "$outcome" "$lines" "$d" >>"$results"
    read -r i o cw cr <<<"$d"
    echo "$t: lead in=$i out=$o cache_write=$cw cache_read=$cr (diff $lines lines)" ;;

  session)
    totals | jq -r --arg l "$lead" '"\($l) session: in=\(.in) out=\(.out) cache_write=\(.cw) cache_read=\(.cr)"' ;;

  report)
    [[ -f "$results" ]] || { echo "no results yet"; exit 0; }
    # cost units ~ price-weighted tokens: output x5, cache write x1.25, cache read x0.1, input x1
    awk -F'\t' -v L="$lead" 'NR>1 && ($2==L || L=="unknown") {
        k = $2 " " (($6=="self") ? "self" : "delegated:" $5)
        cu = $9 + 5*$10 + 1.25*$11 + 0.1*$12
        n[k]++; c[k]+=cu; l[k]+=$8; if ($7!="pass") f[k]++
      }
      END {
        printf "%-28s %5s %12s %10s %14s %6s\n", "lead / group","tasks","cost_units","avg/task","units/diffline","!pass"
        for (k in n) printf "%-28s %5d %12.0f %10.0f %14.1f %6d\n", k, n[k], c[k], c[k]/n[k], (l[k]? c[k]/l[k] : 0), f[k]+0
      }' "$results"
    echo "(lower units/diffline = cheaper for the lead per line of code produced)"
    wu="$state/worker-usage.tsv"
    if [[ -f "$wu" ]]; then
      echo; echo "worker side (billed to each worker's own plan; only workers whose usage can be read):"
      awk -F'\t' 'NR>1 && $9!="" { k=$5" "$4; cu=$9+5*$10+1.25*$11+0.1*$12; n[k]++; c[k]+=cu }
        END { printf "  %-26s %5s %12s\n", "tier worker/model", "runs", "avg units"; for (k in n) printf "  %-26s %5d %12.0f\n", k, n[k], c[k]/n[k] }' "$wu"
    fi ;;

  models)
    if [[ "${2:-}" == --check ]]; then
      r="$state/routing.$lead.json"; [[ -f "$r" ]] || r="$state/routing.json"
      inroute="$( [[ -f "$r" ]] && jq -r '.tiers[][]? | "\(.backend)|\(.model)"' "$r" | sort -u )"
      echo "models the worker CLIs offer that aren't in your routing file:"
      source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/adapters.sh"
      for b in $(all_backends); do
        command -v "$b" >/dev/null || continue; is_disabled "$b" && continue; [[ "$b" == "$lead" ]] && continue
        list_models "$b" 2>/dev/null | grep -v '^(' | while read -r m note; do
          [[ -n "$m" ]] && ! grep -qxF "$b|$m" <<<"$inroute" && printf '  %-9s %-28s %s\n' "$b" "$m" "$note"
        done
      done | head -60
      echo "  (gemini, copilot and user-added agents can't list models here: check their --help)"
      exit 0
    fi
    [[ -f "$results" || -f "$state/worker-usage.tsv" ]] || { echo "no results yet"; exit 0; }
    [[ -f "$results" ]] || : >"$results.empty"
    # track record of each worker model, across all leads and repos
    awk -F'\t' 'NR>1 && $6!="self" {
        k = $6 " @" $5
        n[k]++; if ($7=="pass") p[k]++; if ($7=="escalated") e[k]++; l[k]+=$8
      }
      END {
        printf "%-36s %5s %6s %9s %9s\n", "worker/model @tier","tasks","pass%","escalated","avg_diff"
        for (k in n) printf "%-36s %5d %5.0f%% %9d %9.0f\n", k, n[k], 100*p[k]/n[k], e[k]+0, l[k]/n[k]
      }' "$( [[ -f "$results" ]] && echo "$results" || echo "$results.empty" )" | { read -r h; echo "$h"; sort -k3 -t' ' -r; }
    rm -f "$results.empty"
    wu="$state/worker-usage.tsv"
    if [[ -f "$wu" ]]; then
      echo; echo "cost per task (worker cost units, runs whose usage could be read):"
      awk -F'\t' 'NR>1 && $9!="" { k=$4" @"$5; cu=$9+5*$10+1.25*$11+0.1*$12; n[k]++; c[k]+=cu; if ($13=="done") {p[k]++; cp[k]+=cu} }
        END { printf "  %-36s %5s %10s %14s\n", "worker/model @tier", "runs", "avg/run", "per passed task"
              for (k in n) printf "  %-36s %5d %10.0f %14s\n", k, n[k], c[k]/n[k], (p[k] ? sprintf("%.0f", c[k]/p[k]) : "-") }' "$wu"
      echo "  (per passed task = all the units a model burned on a tier, divided by the tasks it actually got through)"
    fi
    echo "(use this to promote/demote models between tiers; under ~5 tasks = too early to judge)" ;;

  worker-session) worker_session "${2:?kind}" "${3:?epoch}" ;;
  file-totals)    totals_of "${2:?kind}" "${3:?file}" ;;
  *) sed -n '2,19p' "$0"; exit 2 ;;
esac
