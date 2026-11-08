#!/usr/bin/env bash
# Ask a cheap worker about the code, so the lead doesn't read files into its own context.
#
#   crewtier scout "Where is CSV export for reports done, and how is it tested?"
#
# A read-only t1-easy worker reads the repo and answers in at most ~15 lines: the files and
# line numbers involved, the functions or types to know, the command that checks this area,
# and a rough size for the change. Prints only that answer.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
q="${*:-}"; [[ -n "$q" ]] || { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repo"; exit 2; }
cd "$root" || exit 2
dir=".crewtier"; mkdir -p "$dir/tasks"
n=1; while [[ -e "$dir/tasks/S$n.md" ]]; do n=$((n + 1)); done; task="S$n"
cat >"$dir/tasks/$task.md" <<SPEC
# Question from the lead (read-only: change nothing)

$q

Answer for another agent that will write a task spec from your answer without opening the code.
Put the whole answer between the two marker lines below, at most 15 lines, no code blocks:
<<<ANSWER
files: path:line for each place involved (most important first)
know: functions, types or conventions to follow, with their signatures
check: the command that tests this area (or "none found")
size: rough number of lines a change here would touch
notes: anything surprising, in one line
ANSWER>>>
SPEC
out="$(bash "$here/worker.sh" "$task" "${CREWTIER_SCOUT_TIER:-t1-easy}" --spec "$dir/tasks/$task.md" --read-only --no-verify 2>&1)"
log="$(printf '%s\n' "$out" | sed -n 's/^log: \([^ ]*\) ·.*/\1/p' | tail -1)"
ans=""
[[ -n "$log" && -f "$log" ]] && ans="$(awk '/<<<ANSWER/{p=1; a=""; next} /ANSWER>>>/{p=0; last=a} p{a=a $0 "\n"} END{printf "%s", last}' "$log" | grep -v '^\s*$' | head -20)"
if [[ -n "$ans" ]]; then printf '%s\n' "$ans"; exit 0; fi
echo "scout: no answer (the worker didn't reply in the expected form)"
printf '%s\n' "$out" | grep -E '^(skip|route|crewtier|---)' | head -4
exit 1
