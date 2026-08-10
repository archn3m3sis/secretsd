#!/usr/bin/env bash
# lib/timepick.sh — pick a time of day against a live clock face.
#
# Typing "0" into a bare `hour of day to check, 0-23:` prompt tells you nothing
# about what you just chose. A clock does: the hands move as you type, and
# midnight versus midday stops being an arithmetic exercise.
#
# HOUR FIRST, IN 24-HOUR, THEN MINUTES. The hour is the decision that matters —
# it is the difference between "while I sleep" and "in the middle of a meeting"
# — so it is asked first and on its own. Minutes are a refinement, asked second.
#
# The face is drawn by lib/clock.py in braille dots, and the hour hand advances
# with the minutes, the way a real one does.
#
# Sourced, never executed.

# tp_dots — size the face to the terminal. A 48-dot face is 12 character rows
# and simply does not fit a 20-row window alongside a header, a readout and a
# footer; drawing it anyway pushes the footer off the bottom and scrolls the
# whole page. Chosen from BOTH dimensions, since the face is square.
tp_dots() {
  local by_rows by_cols d
  by_rows=$(( (TUI_ROWS - 11) * 4 ))
  by_cols=$(( (TUI_COLS - 8) * 2 ))
  d="$by_rows"; [ "$by_cols" -lt "$d" ] && d="$by_cols"
  [ "$d" -gt 56 ] && d=56
  [ "$d" -lt 24 ] && d=24
  printf '%s' $(( (d / 8) * 8 ))
}

TIMEPICK_DOTS="${TIMEPICK_DOTS:-0}"

# tp_face HOUR MINUTE DOTS -> the clock rows, one per line
tp_face() { python3 "$SEC_BIN/lib/clock.py" "$1" "$2" "$3" 2>/dev/null; }

# tp_ampm HOUR -> a plain-language gloss, because 24-hour time is exactly where
# people mis-set a schedule and then wonder why nothing ran overnight.
tp_ampm() {
  local h="$1"
  if   [ "$h" -eq 0 ];  then printf 'midnight'
  elif [ "$h" -lt 6 ];  then printf '%d AM · overnight' "$h"
  elif [ "$h" -lt 12 ]; then printf '%d AM · morning' "$h"
  elif [ "$h" -eq 12 ]; then printf 'midday'
  elif [ "$h" -lt 18 ]; then printf '%d PM · afternoon' "$(( h - 12 ))"
  else                       printf '%d PM · evening' "$(( h - 12 ))"
  fi
}

# tp_draw HOUR MINUTE STAGE BUFFER
# STAGE is `hour` or `minute`; the active field is highlighted so there is never
# a question about which number the keyboard is currently driving.
tp_draw() {
  local h="$1" m="$2" stage="$3" buf="$4"
  local rows pad line n=0 hcol mcol dots

  tui_dims
  dots="${TIMEPICK_DOTS:-0}"
  [ "$dots" -gt 0 ] || dots="$(tp_dots)"
  printf '\033[2J\033[H'
  tui_blank
  printf '  %s%s%s  ' "$N_AMBER" '⠈⣿⠁' "$T_RS"
  tui_grad_violet "SCHEDULE"
  tui_padn "$TUI_COLS" $(( 2 + 3 + 2 + 8 )); printf '\n'
  if [ "$stage" = hour ]; then
    printf '  %sstep 1 of 2 — the hour, in 24-hour time%s' "$T_MUTE" "$T_RS"
    tui_padn "$TUI_COLS" 41
  else
    printf '  %sstep 2 of 2 — the minutes%s' "$T_MUTE" "$T_RS"
    tui_padn "$TUI_COLS" 27
  fi
  printf '\n'
  tui_hrule

  rows="$(tp_face "$h" "$m" "$dots")"
  # the face is dots/2 cells wide
  pad=$(( (TUI_COLS - dots / 2) / 2 )); [ "$pad" -lt 0 ] && pad=0

  tui_blank
  while IFS= read -r line; do
    printf '%*s%s%s%s' "$pad" '' "$T_ACCENT" "$line" "$T_RS"
    tui_padn "$TUI_COLS" $(( pad + dots / 2 )); printf '\n'
    n=$(( n + 1 ))
  done <<TPF
$rows
TPF
  tui_blank

  # the readout: the field being driven is bright, the other is dim
  if [ "$stage" = hour ]; then hcol="$T_B$T_ACCENT"; mcol="$T_DIM"
  else                         hcol="$T_DIM";        mcol="$T_B$T_ACCENT"; fi
  local readout; printf -v readout '%02d:%02d' "$h" "$m"
  local rpad=$(( (TUI_COLS - 5) / 2 )); [ "$rpad" -lt 0 ] && rpad=0
  printf '%*s%s%02d%s%s:%s%s%02d%s' "$rpad" '' \
    "$hcol" "$h" "$T_RS" "$T_LEAD" "$T_RS" "$mcol" "$m" "$T_RS"
  tui_padn "$TUI_COLS" $(( rpad + 5 )); printf '\n'

  local gloss; gloss="$(tp_ampm "$h")"
  local gpad=$(( (TUI_COLS - ${#gloss}) / 2 )); [ "$gpad" -lt 0 ] && gpad=0
  printf '%*s%s%s%s' "$gpad" '' "$T_MUTE" "$gloss" "$T_RS"
  tui_padn "$TUI_COLS" $(( gpad + ${#gloss} )); printf '\n'

  if [ -n "$buf" ]; then
    local bmsg="typing: $buf"
    local bpad=$(( (TUI_COLS - ${#bmsg}) / 2 )); [ "$bpad" -lt 0 ] && bpad=0
    printf '%*s%s%s%s' "$bpad" '' "$T_WARN" "$bmsg" "$T_RS"
    tui_padn "$TUI_COLS" $(( bpad + ${#bmsg} )); printf '\n'
  else
    tui_blank
  fi

  # fill to the footer so the page is full-bleed like every other screen
  local used=$(( 5 + n + 5 ))
  # tui_footer draws its own rule; adding one here doubled it.
  local fill=$(( TUI_ROWS - used - 2 ))
  while [ "$fill" -gt 0 ]; do tui_blank; fill=$(( fill - 1 )); done
  if [ "$stage" = hour ]; then
    tui_footer "type 0-23" "↑↓ ±1 hour" "↵ set the hour" "esc cancel"
  else
    tui_footer "type 0-59" "↑↓ ±1" "←→ ±5" "↵ confirm" "esc back to the hour"
  fi
  tui_clear_below
}

# tp_commit FIELD BUF VALUE MAX -> echoes the value the buffer implies.
# Two digits that would overflow the field are treated as the start of a fresh
# entry, so typing 2 then 5 into an hour gives 5, not a rejected 25 or a silent
# clamp to 23. Silent clamping is how you end up scheduled for a time you never
# chose.
tp_commit() {
  local buf="$1" max="$2" v
  v=$(( 10#${buf:-0} ))
  [ "$v" -le "$max" ] && { printf '%s' "$v"; return 0; }
  printf '%s' $(( 10#${buf: -1} ))
}

# clock_pick_time [HOUR] [MINUTE] -> "HOUR MINUTE" on stdout, non-zero if cancelled.
#
# stdout is the RETURN CHANNEL and nothing else. Everything drawn goes to
# /dev/tty — a screen that draws on its own return channel hands the caller a
# few kilobytes of escape sequences instead of an answer, which this program has
# already been bitten by once.
clock_pick_time() {
  local h="${1:-9}" m="${2:-0}" stage=hour buf="" key rc=0
  case "$h" in ''|*[!0-9]*) h=9 ;; esac
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  [ "$h" -gt 23 ] && h=9
  [ "$m" -gt 59 ] && m=0

  exec 3>&1 1>/dev/tty
  tui_begin

  while :; do
    tp_draw "$h" "$m" "$stage" "$buf"
    key="$(tui_readkey)" || { rc=1; break; }
    case "$key" in
      char:[0-9])
        buf="${buf}${key#char:}"
        [ "${#buf}" -gt 2 ] && buf="${key#char:}"
        if [ "$stage" = hour ]; then h="$(tp_commit "$buf" 23)"
        else                        m="$(tp_commit "$buf" 59)"; fi
        # two digits is a complete entry; a third would only be a new number
        [ "${#buf}" -eq 2 ] && buf=""
        ;;
      up)
        buf=""
        if [ "$stage" = hour ]; then h=$(( (h + 1) % 24 ))
        else                        m=$(( (m + 1) % 60 )); fi ;;
      down)
        buf=""
        if [ "$stage" = hour ]; then h=$(( (h + 23) % 24 ))
        else                        m=$(( (m + 59) % 60 )); fi ;;
      right)
        buf=""
        if [ "$stage" = hour ]; then h=$(( (h + 1) % 24 ))
        else                        m=$(( (m + 5) % 60 )); fi ;;
      left)
        buf=""
        if [ "$stage" = hour ]; then h=$(( (h + 23) % 24 ))
        else                        m=$(( (m + 55) % 60 )); fi ;;
      enter)
        buf=""
        if [ "$stage" = hour ]; then stage=minute
        else break; fi ;;
      quit|esc)
        # esc from the minutes goes BACK to the hour rather than throwing the
        # whole thing away; only esc at the first step cancels.
        if [ "$stage" = minute ]; then stage=hour; buf=""
        else rc=1; break; fi ;;
    esac
  done

  tui_end
  exec 1>&3 3>&-
  [ "$rc" -eq 0 ] || return 1
  printf '%s %s' "$h" "$m"
}
