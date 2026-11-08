#!/usr/bin/env bash
# Tiny arrow-key checklist for the terminal. Plain bash 3.2 (no dependencies), draws on /dev/tty so it
# also works inside $(...).  Source this file, then:
#
#   MENU_SEL=(1 1 0)                       # initial state, one 0/1 per item
#   menu_multi "Title" "help text" 3 render_fn [key_fn]
#
#   render_fn i      prints the label of item i (no newline)
#   key_fn key i     optional; called for keys the menu doesn't use (e.g. "s").
#                    return 0 = handled, redraw in place; return 2 = it printed output, redraw below it
#
# Keys: up/down or k/j move · space toggles · a all on · n all off · enter confirm · q or Ctrl+C cancel.
# Returns 0 on confirm (result in MENU_SEL), 1 on cancel.

tui_ok() { [[ -r /dev/tty && -w /dev/tty && -n "${TERM:-}" && "$TERM" != dumb ]]; }

menu_multi() {
  local title="$1" help="$2" n="$3" render="$4" keyfn="${5:-}"
  local cur=0 k rest i first=1 rc=0 on off bold dim reset
  on=$'\e[32m'; off=$'\e[2m'; bold=$'\e[1m'; dim=$'\e[2m'; reset=$'\e[0m'

  trap 'printf "\e[?25h" >/dev/tty; trap - INT; return 1' INT
  printf '\e[?25l' >/dev/tty

  while :; do
    [[ $first == 0 ]] && printf '\e[%dA' $((n + 2)) >/dev/tty
    first=0
    {
      printf '\r\e[2K%s%s%s\n' "$bold" "$title" "$reset"
      for ((i = 0; i < n; i++)); do
        local box="[ ]" ptr="  " col="$off"
        [[ "${MENU_SEL[$i]:-0}" == 1 ]] && { box="[x]"; col="$on"; }
        [[ $i == $cur ]] && ptr="${bold}> ${reset}"
        printf '\r\e[2K%s%s%s%s %s\n' "$ptr" "$col" "$box" "$reset" "$("$render" "$i")"
      done
      printf '\r\e[2K%s%s%s\n' "$dim" "$help" "$reset"
    } >/dev/tty

    IFS= read -rsn1 k </dev/tty || { rc=1; break; }
    if [[ "$k" == $'\e' ]]; then
      rest=""; IFS= read -rsn2 -t 1 rest </dev/tty || rest=""
      case "$rest" in
        '[A') cur=$(( (cur + n - 1) % n )) ;;
        '[B') cur=$(( (cur + 1) % n )) ;;
        *)    rc=1; break ;;      # a lone Esc cancels
      esac
    else
      case "$k" in
        '')  break ;;
        ' ') [[ "${MENU_SEL[$cur]:-0}" == 1 ]] && MENU_SEL[$cur]=0 || MENU_SEL[$cur]=1 ;;
        k)   cur=$(( (cur + n - 1) % n )) ;;
        j)   cur=$(( (cur + 1) % n )) ;;
        a)   for ((i = 0; i < n; i++)); do MENU_SEL[$i]=1; done ;;
        n)   for ((i = 0; i < n; i++)); do MENU_SEL[$i]=0; done ;;
        q)   rc=1; break ;;
        *)   if [[ -n "$keyfn" ]]; then
               printf '\e[?25h' >/dev/tty
               "$keyfn" "$k" "$cur"; local krc=$?
               printf '\e[?25l' >/dev/tty
               [[ $krc == 2 ]] && first=1
             fi ;;
      esac
    fi
  done

  printf '\e[?25h' >/dev/tty
  trap - INT
  return $rc
}

# Pick one item with up/down + enter. Prints nothing; result index in MENU_PICK. Returns 1 on cancel.
#   menu_single "Title" "help" n render_fn
menu_single() {
  local title="$1" help="$2" n="$3" render="$4" cur="${MENU_PICK:-0}" k rest i first=1 rc=0
  local bold=$'\e[1m' dim=$'\e[2m' reset=$'\e[0m'
  trap 'printf "\e[?25h" >/dev/tty; trap - INT; return 1' INT
  printf '\e[?25l' >/dev/tty
  while :; do
    [[ $first == 0 ]] && printf '\e[%dA' $((n + 2)) >/dev/tty
    first=0
    {
      printf '\r\e[2K%s%s%s\n' "$bold" "$title" "$reset"
      for ((i = 0; i < n; i++)); do
        if [[ $i == $cur ]]; then printf '\r\e[2K%s> %s%s\n' "$bold" "$("$render" "$i")" "$reset"
        else printf '\r\e[2K  %s\n' "$("$render" "$i")"; fi
      done
      printf '\r\e[2K%s%s%s\n' "$dim" "$help" "$reset"
    } >/dev/tty
    IFS= read -rsn1 k </dev/tty || { rc=1; break; }
    if [[ "$k" == $'\e' ]]; then
      rest=""; IFS= read -rsn2 -t 1 rest </dev/tty || rest=""
      case "$rest" in '[A') cur=$(( (cur + n - 1) % n ));; '[B') cur=$(( (cur + 1) % n ));; *) rc=1; break;; esac
    else
      case "$k" in '') break;; k) cur=$(( (cur + n - 1) % n ));; j) cur=$(( (cur + 1) % n ));; q) rc=1; break;; esac
    fi
  done
  printf '\e[?25h' >/dev/tty; trap - INT
  MENU_PICK=$cur
  return $rc
}
