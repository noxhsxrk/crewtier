#!/usr/bin/env bash
# One call per delegated task, so the lead spends one turn on it instead of six or more.
#
#   crewtier do t2-normal --spec task.md --commit "Add crumbling platforms"
#   crewtier do t2-normal --commit "Add wind zones" <<'EOF'
#   ...the spec, ending with:  Done when: <command>
#   EOF
#
# Does, in order: save the spec as a task brief → meter the lead → run the task (with
# --auto-escalate: one fix round on the same worker, then the next tier up) → end the meter →
# commit when it passed and --commit was given. Prints one line on success, a short report on failure.
#
# Options:
#   --spec FILE|-     the spec (default: stdin when it isn't a terminal)
#   --commit "msg"    commit the result when it passes (needs a clean tree at the start)
#   --verify "cmd"    check command, if the spec has no "Done when:" line
#   --task ID         task id (default: next free D1, D2, …)
#   --isolated        run in its own worktree; leaves a patch (crewtier apply ID)
#   --no-escalate     stop after the first worker instead of fixing / escalating
#
# Exit: 0 passed · 1 failed all the way up (do it yourself) · 3 no worker could run · 124 timed out
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tier="${1:-}"; [[ -n "$tier" && "$tier" != -* ]] || { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
shift
spec=""; msg=""; verify=""; task=""; isolated=0; escalate=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec) spec="${2:?}"; shift 2 ;;
    --commit) msg="${2:?}"; shift 2 ;;
    --verify) verify="${2:?}"; shift 2 ;;
    --task) task="${2:?}"; shift 2 ;;
    --isolated) isolated=1; shift ;;
    --no-escalate) escalate=0; shift ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done

root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repo"; exit 2; }
cd "$root" || exit 2
dir=".crewtier"; mkdir -p "$dir/tasks" "$dir/results" "$dir/logs"

# ---- the spec ----
if [[ -z "$task" ]]; then
  n=1; while [[ -e "$dir/tasks/D$n.md" || -e "$dir/results/D$n.json" ]]; do n=$((n + 1)); done; task="D$n"
fi
brief="$dir/tasks/$task.md"
if [[ -z "$spec" && ! -t 0 ]]; then spec="-"; fi
[[ -n "$spec" ]] || { echo "no spec: pass --spec FILE or pipe it in"; exit 2; }
if [[ "$spec" == "-" ]]; then cat >"$brief"; else cp "$spec" "$brief" || exit 2; fi
[[ -s "$brief" ]] || { echo "the spec is empty"; exit 2; }
if [[ -n "$verify" ]] && ! grep -qi '^done when:' "$brief"; then printf '\nDone when: %s\n' "$verify" >>"$brief"; fi

# commit only what this task changed: the tree has to start clean
clean=1; [[ -n "$(git status --porcelain -- . ':(exclude).crewtier' 2>/dev/null)" ]] && clean=0
if [[ -n "$msg" && $clean == 0 ]]; then
  echo "note: the tree has uncommitted changes, so $task won't be committed automatically"; msg=""
fi

# ---- run, metered, in this one call ----
bash "$here/measure.sh" start "$task" >/dev/null 2>&1
args=("$task" "$tier" --spec "$brief")
[[ $escalate == 1 ]] && args+=(--auto-escalate)
[[ $isolated == 1 ]] && args+=(--isolated)
out="$dir/logs/$task.do.txt"
bash "$here/worker.sh" "${args[@]}" >"$out" 2>&1 &
pid=$!
t0=$SECONDS; next=180
while kill -0 "$pid" 2>/dev/null; do
  sleep 2
  if (( SECONDS - t0 >= next )); then   # a short heartbeat, so a long task doesn't look stuck
    who="$(grep -o '^crewtier [^ ]* \[[^]]*\] [^ ]*\|^↑ auto-escalate: .*\|^↻ auto-escalate: .*' "$out" | tail -1)"
    echo "… $task still running ($(( (SECONDS - t0) / 60 ))m)${who:+ · $who}"
    next=$((next + 180))
  fi
done
wait "$pid"; rc=$?
bash "$here/measure.sh" end "$task" >/dev/null 2>&1

# ---- report ----
rj="$dir/results/$task.json"
[[ -f "$rj" ]] || { echo "$task: no result recorded (see $out)"; tail -15 "$out"; exit 1; }
read -r st ft wk md ln nf <<<"$(jq -r '[.status, .tier, (.worker // "-"), (.model // "-"), (.linesChanged // 0), (.touchedFiles | length)] | @tsv' "$rj")"
mins="$(( (SECONDS - t0) / 60 ))m$(( (SECONDS - t0) % 60 ))s"

if [[ "$st" == done ]]; then
  line="$task PASS $wk/$md · $ln lines ($nf files) · $mins"
  if [[ $isolated == 1 ]]; then echo "$line · patch: crewtier apply $task"; exit 0; fi
  if [[ -n "$msg" ]]; then
    git add -A -- . ':(exclude).crewtier' 2>/dev/null
    if git commit -q -m "$msg" -m "Crewtier-Worker: $wk/$md" 2>/dev/null; then
      line="$line · commit $(git rev-parse --short HEAD)"
    else line="$line · commit failed (changes left in the tree)"; fi
  fi
  echo "$line"; exit 0
fi

if [[ "$st" == verify-error ]]; then
  echo "$task VERIFY-ERROR: the check command didn't run ($wk/$md's changes are in the tree, not checked) · $mins"
  echo "fix the command and run it once; no need to review the code:"
  grep -v '^\s*$' "$dir/tasks/$task.verify.txt" 2>/dev/null | head -6 | sed 's/^/  | /'
  exit 1
fi
echo "$task $st (last tier: $ft, last worker: $wk/$md) · $mins"
vt="$dir/tasks/$task.verify.txt"
[[ -s "$vt" ]] && { echo "verify output (last 20 lines):"; grep -v '^\s*$' "$vt" | tail -20 | sed 's/^/  | /'; }
ls "$dir/patches/$task".* 2>/dev/null | sed 's/^/attempt: /'
echo "log: $out"
case "$rc" in 3) exit 3 ;; 124) exit 124 ;; *) exit 1 ;; esac
