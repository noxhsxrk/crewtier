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
if [[ -z "$lead" ]]; then   # run from a plain terminal: use the lead whose routing file exists, if only one does
  rf="$(ls "$HOME"/.crewtier/routing.*.json 2>/dev/null)"
  [[ $(printf '%s\n' "$rf" | sed '/^$/d' | wc -l) -eq 1 ]] && { lead="$(basename "$rf" .json)"; lead="${lead#routing.}"; }
fi
lead="${lead:-unknown}"

state="$HOME/.crewtier"; mkdir -p "$state"
results="$state/results.tsv"
meter=".crewtier/meter"
ZERO='{"in":0,"out":0,"cw":0,"cr":0}'

transcript() {
  if [[ -n "${CREWTIER_TRANSCRIPT:-}" ]]; then echo "$CREWTIER_TRANSCRIPT"; return; fi
  case "$lead" in
    claude) # this folder's project first (Claude Code names it after the path, / and . become -)
            local d="$HOME/.claude/projects/$(pwd | sed 's#[/.]#-#g')"
            { ls -t "$d"/*.jsonl 2>/dev/null; ls -t "$HOME"/.claude/projects/*/*.jsonl 2>/dev/null; } | head -1 ;;
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

NOT_GENERATED='$3 !~ /(^|\/)(pnpm-lock\.yaml|package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|bun\.lockb?|Cargo\.lock|poetry\.lock|uv\.lock|Pipfile\.lock|Gemfile\.lock|composer\.lock|go\.sum|flake\.lock|mix\.lock|Podfile\.lock|packages\.lock\.json)$/ && $3 !~ /\.min\.(js|css)$/'   # lockfiles and minified bundles don't count as lines written
diff_lines() {  # lines added+removed vs HEAD (run before committing)
  git diff HEAD --numstat 2>/dev/null | awk "$NOT_GENERATED"' && $1 ~ /^[0-9]+$/ {a+=$1; d+=$2} END {print a+d+0}'
}

# meters still open, ignoring ones started more than 6 hours ago (left behind by a crash or an old version)
open_meters() {
  local f now mt; now="$(date +%s)"
  for f in "$meter"/*.start; do
    [[ -f "$f" ]] || continue
    mt="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now")"
    (( now - mt > 21600 )) && { rm -f "$f" "${f%.start}.overlap"; continue; }
    basename "$f" .start
  done
}

header='date\tlead\trepo\ttask\ttier\tworker\toutcome\tdiff_lines\tin\tout\tcache_write\tcache_read\tflag\n'

case "${1:-}" in
  start)
    t="${2:-session}"; mkdir -p "$meter"   # no id = one meter for the whole session
    open_now="$(open_meters | grep -vxF "$t" | tr '\n' ' ')"
    if [[ -n "$open_now" && "$t" != session ]]; then
      echo "warning: meter already running for: ${open_now}— the windows overlap, so this task will be flagged and left out of report averages. End those first." >&2
      echo "$open_now" >"$meter/$t.overlap"
    else rm -f "$meter/$t.overlap"; fi
    totals >"$meter/$t.start"
    echo "meter started${2:+ for $t} (lead: $lead). Work as usual, then: crewtier meter end${2:+ $t}" ;;

  end)
    t="${2:-session}"; tier="${3:-}"; who="${4:-}"; outcome="${5:-}"
    rj=".crewtier/results/$t.json"   # what `crewtier run` recorded wins over what was typed
    if [[ -f "$rj" ]]; then
      [[ -n "$tier" ]] || tier="$(jq -r '.tier // "-"' "$rj")"
      [[ -n "$who" ]] || who="$(jq -r 'if .worker then "\(.worker)/\(.model // "default")" else "-" end' "$rj")"
      [[ -n "$outcome" ]] || outcome="$(jq -r 'if .status == "done" and ((.verify.result // "none") | test("^(PASS|none)")) then "pass" else (.status // "fail") end' "$rj")"
    fi
    tier="${tier:--}"; who="${who:-session}"; outcome="${outcome:-pass}"
    # another task's meter started while this one ran? then the numbers mix two jobs
    others="$(open_meters | grep -vxF "$t" | grep -vxF session | tr '\n' ' ')"
    flag=""; { [[ -f "$meter/$t.overlap" ]] || [[ -n "$others" && "$t" != session ]]; } && flag="overlap"
    rm -f "$meter/$t.overlap"
    [[ -f "$meter/$t.start" ]] || { echo "no meter running${2:+ for $t}: start one with  crewtier meter start${2:+ $t}"; exit 2; }
    now="$(totals)"; before="$(cat "$meter/$t.start")"
    d=$(jq -nr --argjson a "$before" --argjson b "$now" \
      '[($b.in-$a.in),($b.out-$a.out),($b.cw-$a.cw),($b.cr-$a.cr)] | @tsv')
    [[ -f "$results" ]] || printf "$header" >"$results"
    repo="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
    lines="$(diff_lines)"
    [[ -f "$rj" ]] && lines="$(jq -r '.linesChanged // empty' "$rj" 2>/dev/null || echo "$lines")"; lines="${lines:-0}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%F)" "$lead" "$repo" "$t" "$tier" "$who" "$outcome" "$lines" "$d" "$flag" >>"$results"
    rm -f "$meter/$t.start"
    read -r i o cw cr <<<"$d"
    echo "$t: lead in=$i out=$o cache_write=$cw cache_read=$cr (diff $lines lines, $tier, $who, $outcome${flag:+, OVERLAP: left out of averages})" ;;

  clear)   # forget every open meter in this repo
    n="$(ls "$meter"/*.start 2>/dev/null | wc -l | tr -d ' ')"; rm -f "$meter"/*.start "$meter"/*.overlap 2>/dev/null
    echo "cleared $n open meter(s)" ;;

  long-note)   # one line for `do` to print when the lead's conversation has grown expensive to re-read
    f="$(transcript)"; [[ -n "$f" && -f "$f" ]] || exit 0
    totals_of "$lead" "$f" | jq -r '(.in + 5*.out + 1.25*.cw + 0.1*.cr) as $u
      | if ($u > 2000000) and ((0.1*.cr) / $u > 0.6)
        then "note: this conversation is now mostly re-reading itself (\(((0.1*.cr) / $u * 100) | floor)% of the lead cost). Start a fresh session for the next feature: routing and results carry over."
        else empty end' 2>/dev/null ;;

  session)   # the lead's whole current session, read from its own transcript: no meter needed
    f="$(transcript)"
    if [[ -z "$f" || ! -f "$f" ]]; then
      echo "No $lead session found for this folder. Run this inside the project folder where your lead is open."
      [[ "$lead" == unknown ]] && echo "(lead unknown: set it with  CREWTIER_LEAD=claude crewtier session)"
      exit 0
    fi
    t="$(totals_of "$lead" "$f")"
    # when the conversation started: first timestamp in the transcript
    ts="$(jq -r 'select(.timestamp != null) | .timestamp' "$f" 2>/dev/null | head -1)"
    since="$(jq -nr --arg t "$ts" '$t | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601' 2>/dev/null)"
    total=0; wl=0; wn=0; nl=0
    if [[ -n "$since" ]] && git rev-parse --git-dir >/dev/null 2>&1; then
      # lines changed since then: commits made in the session plus what's still uncommitted
      total="$( { git log --since="@$since" --numstat --format= 2>/dev/null; git diff HEAD --numstat 2>/dev/null; } \
               | awk "$NOT_GENERATED"' && $1 ~ /^[0-9]+$/ && $3 !~ /^\.crewtier\// {n += $1 + $2} END {print n + 0}')"
      # plus new files not added to git yet
      untracked="$(git ls-files --others --exclude-standard 2>/dev/null | grep -v '^\.crewtier/' | grep -vE '(^|/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock|bun\.lockb?|Cargo\.lock|poetry\.lock|uv\.lock|Gemfile\.lock|composer\.lock|go\.sum)$' | while IFS= read -r u; do [[ -f "$u" ]] && wc -l <"$u"; done | awk '{n += $1} END {print n + 0}')"
      total=$((total + untracked))
      # lines the workers wrote: results crewtier run saved during this session
      for r in .crewtier/results/*.json; do
        [[ -f "$r" ]] || continue
        mt="$(stat -c %Y "$r" 2>/dev/null || stat -f %m "$r" 2>/dev/null)"; [[ -n "$mt" && "$mt" -ge "$since" ]] || continue
        read -r st ln pf <<<"$(jq -r '"\(.status) \(.linesChanged // "-") \(.patch // "-")"' "$r")"
        [[ "$st" == done ]] || continue
        if [[ "$ln" == "-" ]]; then   # result written before crewtier recorded line counts (< 0.1.7)
          if [[ "$pf" != "-" && -f "$pf" ]]; then
            ln="$(grep -E '^[+-]' "$pf" | grep -vE '^(\+\+\+|---) ' | wc -l | tr -d ' ')"
          else nl=$((nl + 1)); continue; fi
        fi
        wl=$((wl + ln)); wn=$((wn + 1))
      done
    fi
    jq -r --arg l "$lead" --argjson total "${total:-0}" --argjson wl "$wl" --argjson wn "$wn" --argjson nl "$nl" '
      (.in + 5*.out + 1.25*.cw + 0.1*.cr) as $u
      | ([$total - $wl, 0] | max) as $ll
      | "\($l) session (whole conversation so far)",
        "  tokens: in=\(.in) out=\(.out) cache_write=\(.cw) cache_read=\(.cr)",
        "  cost units: \($u | floor)   (in x1, out x5, cache write x1.25, cache read x0.1)",
        "  lines changed this session: \($total)  (workers: \($wl) in \($wn) task(s) · lead: \($ll))",
        (if $nl > 0 then "  note: \($nl) worker task(s) ran on crewtier < 0.1.7 and have no line count, so their lines are counted as the lead\u0027s" else empty end),
        (if ($u > 0) and ((0.1*.cr) / $u > 0.6) and ($u > 2000000) then "  ! long conversation: \(((0.1*.cr) / $u * 100) | floor)% of the cost is re-reading it. Start a fresh session for the next feature (routing, results and measurements carry over)." else empty end),
        (if $total > 0 then "  lead cost per line shipped: \(($u / $total) | floor) units   (compare with a session where you don\u0027t delegate)" else "  lead cost per line shipped: no code changes found yet" end)' <<<"$t" ;;

  report)
    [[ -f "$results" ]] || { echo "no results yet"; exit 0; }
    # cost units ~ price-weighted tokens: output x5, cache write x1.25, cache read x0.1, input x1
    awk -F'\t' -v L="$lead" 'NR>1 && ($2==L || L=="unknown") && $13=="overlap" {ov++; next}
      NR>1 && ($2==L || L=="unknown") {
        k = $2 " " (($6=="self") ? "self" : "delegated:" $5)
        cu = $9 + 5*$10 + 1.25*$11 + 0.1*$12
        n[k]++; c[k]+=cu; l[k]+=$8; if ($7!="pass") f[k]++
      }
      END {
        printf "%-28s %5s %12s %10s %14s %6s\n", "lead / group","tasks","cost_units","avg/task","units/diffline","!pass"
        for (k in n) printf "%-28s %5d %12.0f %10.0f %14.1f %6d\n", k, n[k], c[k], c[k]/n[k], (l[k]? c[k]/l[k] : 0), f[k]+0
        if (ov) printf "(%d task(s) left out: their meter windows overlapped another task, so the numbers mix two jobs)\n", ov
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
