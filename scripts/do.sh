#!/usr/bin/env bash
# One call per delegated task, so the lead spends one turn on it instead of six or more.
#
#   crewtier do t2-normal --spec task.md --commit "Add crumbling platforms"
#   crewtier do t2-normal --commit "Add wind zones" <<'EOF'
#   ...the spec, ending with:  Done when: <command>   (or "Done when: auto": the project's own tests)
#   EOF
#
# If the call is cut off (a shell timeout), the worker keeps going. Run the same command again:
# it picks the running or finished task back up instead of starting over.
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

mkdir -p "$dir/running"
# ---- the spec ----
if [[ -z "$spec" && ! -t 0 ]]; then spec="-"; fi
[[ -n "$spec" ]] || { echo "no spec: pass --spec FILE or pipe it in"; exit 2; }
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
if [[ "$spec" == "-" ]]; then cat >"$tmp"; else cp "$spec" "$tmp" || exit 2; fi
[[ -s "$tmp" ]] || { echo "the spec is empty"; exit 2; }
if [[ -n "$verify" ]] && ! grep -qi '^done when:' "$tmp"; then printf '\nDone when: %s\n' "$verify" >>"$tmp"; fi
hash="$(cksum <"$tmp" | awk '{print $1 "-" $2}')-$tier"

# the same spec cut off earlier (shell timeout)? pick that task back up
attach=0; pid=""; clean=1
for jf in "$dir"/running/*.do; do
  [[ -f "$jf" ]] || continue
  read -r jh jpid jclean <"$jf"
  [[ "$jh" == "$hash" ]] || continue
  task="$(basename "$jf" .do)"; clean="$jclean"
  if kill -0 "$jpid" 2>/dev/null || [[ -f "$dir/results/$task.json" && "$dir/results/$task.json" -nt "$jf" ]]; then
    attach=1; pid="$jpid"; echo "… picking up $task (started earlier with this spec)"
  fi
  break
done

if [[ -z "$task" ]]; then
  n=1; while [[ -e "$dir/tasks/D$n.md" || -e "$dir/results/D$n.json" ]]; do n=$((n + 1)); done; task="D$n"
fi
brief="$dir/tasks/$task.md"; jobf="$dir/running/$task.do"; rcf="$dir/running/$task.rc"
out="$dir/logs/$task.do.txt"

if [[ $attach == 0 ]]; then
  cp "$tmp" "$brief"
  # commit only what this task changed: the tree has to start clean
  [[ -n "$(git status --porcelain -- . ':(exclude).crewtier' 2>/dev/null)" ]] && clean=0
  rm -f "$rcf" "$dir/results/$task.json"
  bash "$here/measure.sh" start "$task" >/dev/null 2>&1
  args=("$task" "$tier" --spec "$brief")
  [[ $escalate == 1 ]] && args+=(--auto-escalate)
  [[ $isolated == 1 ]] && args+=(--isolated)
  # own session, so the worker outlives this call if the lead's shell kills it
  if command -v setsid >/dev/null; then DETACH=(setsid)
  elif command -v perl >/dev/null; then DETACH=(perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV')
  else DETACH=(nohup); fi
  "${DETACH[@]}" bash -c 'bash "$0" "$@"; echo $? >"'"$rcf"'"' "$here/worker.sh" "${args[@]}" </dev/null >"$out" 2>&1 &
  pid=$!
  echo "$hash $pid $clean" >"$jobf"
fi
if [[ -n "$msg" && "$clean" == 0 ]]; then
  echo "note: the tree had uncommitted changes, so $task won't be committed automatically"; msg=""
fi

t0=$SECONDS; next=180
while kill -0 "$pid" 2>/dev/null; do
  sleep 2
  if (( SECONDS - t0 >= next )); then   # a short heartbeat, so a long task doesn't look stuck
    who="$(grep -o '^crewtier [^ ]* \[[^]]*\] [^ ]*\|^↑ auto-escalate: .*\|^↻ auto-escalate: .*' "$out" | tail -1)"
    echo "… $task still running ($(( (SECONDS - t0) / 60 ))m)${who:+ · $who}"
    next=$((next + 180))
  fi
done
rc="$(cat "$rcf" 2>/dev/null)"; rc="${rc:-1}"
bash "$here/measure.sh" end "$task" >/dev/null 2>&1
rm -f "$jobf" "$rcf"
note() { bash "$here/measure.sh" long-note 2>/dev/null; }

# ---- report ----
rj="$dir/results/$task.json"
[[ -f "$rj" ]] || { echo "$task: no result recorded (see $out)"; grep -v '^\s*$' "$out" | tail -6; [[ "$rc" == 3 ]] && exit 3; exit 1; }
read -r st ft wk md ln nf <<<"$(jq -r '[.status, .tier, (.worker // "-"), (.model // "-"), (.linesChanged // 0), (.touchedFiles | length)] | @tsv' "$rj")"
secs="$(jq -r '.seconds // empty' "$rj" 2>/dev/null)"; [[ $attach == 0 || -z "$secs" ]] && secs=$((SECONDS - t0))
mins="$(( secs / 60 ))m$(( secs % 60 ))s"
chk=""; [[ "$(jq -r '.verify.result? // .verify // "none"' "$rj" 2>/dev/null)" == none ]] && chk=" · no check found, untested"

if [[ "$st" == done ]]; then
  line="$task PASS $wk/$md · $ln lines ($nf files) · $mins$chk"
  if [[ $isolated == 1 ]]; then echo "$line · patch: crewtier apply $task"; exit 0; fi
  if [[ -n "$msg" ]]; then
    git add -A -- . ':(exclude).crewtier' 2>/dev/null
    if git commit -q -m "$msg" -m "Crewtier-Worker: $wk/$md" 2>/dev/null; then
      line="$line · commit $(git rev-parse --short HEAD)"
    else line="$line · commit failed (changes left in the tree)"; fi
  fi
  echo "$line"; note; exit 0
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
note
case "$rc" in 3) exit 3 ;; 124) exit 124 ;; *) exit 1 ;; esac
