#!/usr/bin/env bash
# lib/tui.sh — full-bleed dot-matrix interface for the `secrets` platform.
#
# DESIGN
#   Dot-matrix glyphs, never emoji. Each module mark is a 6x4 pixel bitmap drawn
#   into three braille cells: real pixel art with a PREDICTABLE width. Emoji width
#   varies by terminal and font, and a single variation selector silently shifts
#   an entire column — which is why the grid could never be exact with them.
#
#   Monochrome type, one neon hue per module, leader dots running to the values.
#
#   FULL BLEED. Every line is padded to the terminal width and the module block is
#   distributed to fill the height, at ANY terminal size. Three density modes let
#   it breathe on a large terminal and stay readable on a small one:
#     roomy   row + description + blank line   (3 lines per module)
#     normal  row + description                (2 lines per module)
#     compact row only                         (1 line per module)
#
# Sourced, never executed.

# --- palette ------------------------------------------------------------------
if [ "${COLORTERM:-}" = "truecolor" ] || [ "${COLORTERM:-}" = "24bit" ]; then
  T_ACCENT=$'\033[38;2;167;139;250m'
  T_SELBG=$'\033[48;2;28;22;44m'
  T_OK=$'\033[38;2;52;211;153m'
  T_WARN=$'\033[38;2;251;191;36m'
  T_ERR=$'\033[38;2;248;113;113m'
  T_DIM=$'\033[38;2;92;97;110m'
  T_LEAD=$'\033[38;2;52;56;66m'      # leader dots, quieter than DIM
  T_TEXT=$'\033[38;2;236;238;242m'
  T_MUTE=$'\033[38;2;150;157;170m'
  N_CYAN=$'\033[38;2;34;211;238m';   N_MAGENTA=$'\033[38;2;244;114;182m'
  N_AMBER=$'\033[38;2;251;191;36m';  N_VIOLET=$'\033[38;2;167;139;250m'
  N_GREEN=$'\033[38;2;52;211;153m';  N_ORANGE=$'\033[38;2;251;146;60m'
  N_BLUE=$'\033[38;2;96;165;250m';   N_TEAL=$'\033[38;2;45;212;191m'
  N_RED=$'\033[38;2;248;113;113m'
else
  T_ACCENT=$'\033[38;5;141m'; T_SELBG=$'\033[48;5;235m'
  T_OK=$'\033[38;5;42m';  T_WARN=$'\033[38;5;214m'; T_ERR=$'\033[38;5;203m'
  T_DIM=$'\033[38;5;242m'; T_LEAD=$'\033[38;5;237m'
  T_TEXT=$'\033[38;5;255m'; T_MUTE=$'\033[38;5;250m'
  N_CYAN=$'\033[38;5;51m';    N_MAGENTA=$'\033[38;5;205m'; N_AMBER=$'\033[38;5;214m'
  N_VIOLET=$'\033[38;5;141m'; N_GREEN=$'\033[38;5;48m';    N_ORANGE=$'\033[38;5;208m'
  N_BLUE=$'\033[38;5;75m';    N_TEAL=$'\033[38;5;44m';     N_RED=$'\033[38;5;203m'
fi
T_B=$'\033[1m'; T_RS=$'\033[0m'

# --- dot-matrix marks (6x4 dots -> 3 braille cells, width 3, always) ----------
tui_glyph() {
  case "$1" in
    api)      printf '⠭⠪⠅' ;;
    pii)      printf '⣠⣿⣄' ;;
    keys)     printf '⠺⢽⣂' ;;
    auth)     printf '⡱⠶⢎' ;;
    machines) printf '⠯⣭⠽' ;;
    certs)    printf '⠺⣭⠗' ;;
    env)      printf '⣏⣉⣹' ;;
    dns)      printf '⢾⣝⡷' ;;
    logins)   printf '⡴⣭⢦' ;;
    *)        printf '⠿⠿⠿' ;;
  esac
}
tui_hue() {
  case "$1" in
    api)      printf '%s' "$N_CYAN" ;;    pii)    printf '%s' "$N_MAGENTA" ;;
    keys)     printf '%s' "$N_AMBER" ;;   auth)   printf '%s' "$N_VIOLET" ;;
    machines) printf '%s' "$N_GREEN" ;;   certs)  printf '%s' "$N_ORANGE" ;;
    env)      printf '%s' "$N_BLUE" ;;    dns)    printf '%s' "$N_TEAL" ;;
    logins)   printf '%s' "$N_RED" ;;     *)      printf '%s' "$T_DIM" ;;
  esac
}

# --- dimensions ---------------------------------------------------------------
TUI_COLS=80; TUI_ROWS=24
# NEVER write `tput cols 2>/dev/null`. ncurses tput queries the window size on
# STDERR — send stderr to /dev/null and it cannot ask the terminal, so it falls
# back to terminfo's static 80x24 and reports it with exit code 0. The layout
# then renders 80 columns wide inside a 200-column window and looks broken for
# no visible reason. Ask the tty directly instead; keep tput as the fallback,
# unredirected.
tui_dims() {
  local sz
  sz="$(stty size </dev/tty 2>/dev/null)"        # "ROWS COLS"
  if [ -n "$sz" ]; then
    TUI_ROWS="${sz%% *}"; TUI_COLS="${sz##* }"
  else
    TUI_COLS="$(tput cols)"; TUI_ROWS="$(tput lines)"
  fi
  case "$TUI_COLS" in ''|*[!0-9]*) TUI_COLS=80 ;; esac
  case "$TUI_ROWS" in ''|*[!0-9]*) TUI_ROWS=24 ;; esac
  [ "$TUI_COLS" -lt 40 ] && TUI_COLS=40
  [ "$TUI_ROWS" -lt 10 ] && TUI_ROWS=10
  return 0
}

# --- screen control -----------------------------------------------------------
tui_begin() { printf '\033[?1049h\033[?25l\033[2J\033[H'; }
tui_end()   { printf '\033[?25h\033[?1049l'; }
tui_home()  { printf '\033[H'; }
tui_clear_below() { printf '\033[J'; }

tui_blank() { printf '%*s\n' "$TUI_COLS" ''; }
tui_padn()  { local n=$(( $1 - $2 )); [ "$n" -lt 0 ] && n=0; printf '%*s' "$n" ''; }


# tui_fit STRING WIDTH — truncate to WIDTH visible characters with an ellipsis.
# Detail lines must never wrap: a wrapped line pushes every absolutely-positioned
# row below it out of place, and the whole grid stops matching its line map.
tui_fit() {
  local str="$1" w="$2"
  [ "$w" -lt 4 ] && { printf '%s' ""; return; }
  if [ "${#str}" -le "$w" ]; then printf '%s' "$str"
  else printf '%s…' "${str:0:$(( w - 1 ))}"; fi
}

# tui_repeat CHAR N — pure bash, no subprocess. The animation redraws a leader
# many times per keypress; forking sed per row made it visibly sluggish.
tui_repeat() {
  [ "$2" -gt 0 ] || return 0
  local s; printf -v s "%${2}s" ''
  printf '%s' "${s// /$1}"
}

tui_hrule() {
  printf '%s' "$T_LEAD"; tui_repeat '─' "$TUI_COLS"; printf '%s\n' "$T_RS"
}

# --- key input ----------------------------------------------------------------
tui_readkey() {
  local k
  IFS= read -rsn1 k </dev/tty 2>/dev/null || return 1
  tui_decode_key "$k"
}

# --- header -------------------------------------------------------------------
# tui_header HOST STATLINE
tui_header() {
  local host="$1" stat="$2" wm="S E C R E T S"
  tui_blank
  printf '  '; tui_grad_violet '⣿⣿⣿'; printf '  %s' "$T_B"; tui_grad_violet "$wm"
  tui_padn "$TUI_COLS" $(( 2 + 3 + 2 + ${#wm} + ${#host} + 2 ))
  printf '%s%s%s  \n' "$T_DIM" "$host" "$T_RS"
  printf '  %s' "$T_MUTE"
  printf '%s' "$stat"
  printf '%s' "$T_RS"
  tui_padn "$TUI_COLS" $(( 2 + ${#stat} ))
  printf '\n'
  tui_hrule
}

# --- module row ---------------------------------------------------------------
# tui_modrow SELECTED ID LABEL COUNT DOTSTATE DOTLABEL
# NOTE: glyph and hue are passed in, not looked up. Every $( ) here is a fork,
# and a fork per row per redraw is exactly what made navigation flicker.
tui_modrow() {
  local sel="$1" mark="$2" hue="$3" label="$4" count="$5" dot="$6" dlab="$7"
  local dotcol glyph leader llen rlen

  case "$dot" in
    ok)   dotcol="$T_OK";   glyph='●' ;;
    warn) dotcol="$T_WARN"; glyph='●' ;;
    err)  dotcol="$T_ERR";  glyph='●' ;;
    *)    dotcol="$T_DIM";  glyph='○' ;;
  esac

  # icon width is measured, never assumed: a 4-cell mark with a hardcoded 3 here
  # overruns the line, the terminal wraps it, and every absolutely-positioned row
  # below shifts by one — which looks like a mysterious blank line, not an overflow
  llen=$(( 2 + 1 + 1 + ${#mark} + 2 + ${#label} ))
  rlen=$(( ${#count} + 2 + 1 + 1 + ${#dlab} + 2 ))
  leader=$(( TUI_COLS - llen - rlen - 2 ))
  [ "$leader" -lt 1 ] && leader=1

  # Row is built as PLAIN text plus a parallel colour map, then painted column by
  # column. That is what lets the selected row carry a gradient mask underneath
  # arbitrary coloured segments — a flat background cannot fade, and per-segment
  # escapes cannot line up with a gradient that varies per column.
  local txt="" map="" seg
  _add() { txt="$txt$1"; seg=0; while [ "$seg" -lt "${#1}" ]; do map="$map$2"; seg=$(( seg + 1 )); done; }

  if [ "$sel" = "1" ]; then _add "  " "n"; _add "▌" "a"; _add " " "n"
  else                      _add "    " "n"; fi
  _add "$mark" "h"; _add "  " "n"
  _add "$label" "t"; _add " " "n"
  _add "$(tui_repeat '·' "$leader")" "l"
  _add " " "n"; _add "$count" "t"; _add "  " "n"
  _add "$glyph" "d"; _add " " "n"; _add "$dlab" "m"
  _add "$(tui_repeat ' ' 2)" "n"
  unset -f _add

  local n="${#txt}" i=0 code prev="" fg step=4
  while [ "$i" -lt "$n" ]; do
    if [ "$sel" = "1" ] && [ $(( i % step )) -eq 0 ]; then
      printf '%s' "$(tui_bg_at "$i" "$TUI_COLS")"
      prev=""
    fi
    code="${map:$i:1}"
    case "$code" in
      a) fg="$T_ACCENT" ;;
      h) fg="$hue" ;;
      t) fg="$([ "$sel" = "1" ] && printf '%s' "$T_B$T_TEXT" || printf '%s' "$T_MUTE")" ;;
      l) fg="$T_LEAD" ;;
      d) fg="$dotcol" ;;
      m) fg="$T_MUTE" ;;
      *) fg="$T_DIM" ;;
    esac
    [ "$fg" != "$prev" ] && { printf '%s' "$fg"; prev="$fg"; }
    printf '%s' "${txt:$i:1}"
    i=$(( i + 1 ))
  done
  printf '%s\n' "$T_RS"
}

# tui_moddesc SELECTED TEXT — the secondary description line under a module row
# tui_moddesc SELECTED TEXT [ICON_BOTTOM_ROW] [HUE]
# When an icon bottom row is supplied it is painted in the same column as the
# icon above it, so the mark reads as one 8x8 pictogram across both lines.
tui_moddesc() {
  local sel="$1" text="$2" icon="${3:-}" hue="${4:-}" bg=''
  [ "$sel" = "1" ] && bg="$T_SELBG"
  printf '%s' "$bg"
  if [ -n "$icon" ]; then
    if [ "$sel" = "1" ]; then printf '  %s▌%s ' "$T_ACCENT" "$bg"; else printf '    '; fi
    printf '%s%s%s  ' "$hue" "$icon" "$bg"
    printf '%s%s%s' "$T_DIM" "$text" "$T_RS$bg"
    tui_padn "$TUI_COLS" $(( 4 + ${#icon} + 2 + ${#text} ))
  else
    printf '         %s%s%s' "$T_DIM" "$text" "$T_RS$bg"
    tui_padn "$TUI_COLS" $(( 9 + ${#text} ))
  fi
  printf '%s\n' "$T_RS"
}

# --- footer -------------------------------------------------------------------
tui_footer() {
  local pair k l used=2
  tui_hrule
  printf '  '
  for pair in "$@"; do
    k="${pair%% *}"; l="${pair#* }"
    printf '%s%s%s %s%s%s   ' "$T_ACCENT" "$k" "$T_RS" "$T_DIM" "$l" "$T_RS"
    used=$(( used + ${#k} + 1 + ${#l} + 3 ))
  done
  tui_padn "$TUI_COLS" "$used"
  # NO trailing newline: this is the last row of the screen, and a newline there
  # scrolls the entire display up by one line, pushing the header off the top.
}


# --- leader-dot wave ----------------------------------------------------------
# tui_wave LINE COL LEN DIRECTION [SELECTED]
# A crest travels along the leader dots, lifting each one as it passes:
# left-to-right when moving DOWN the list, right-to-left when moving UP.
# Height is real — the dots rise through braille rows (⠄ low, ⠂ mid, ⠁ top,
# ˙ peak) — and the crest is lit in the accent colour so the motion reads even
# on a small terminal.
TUI_LEAD_COL=0; TUI_LEAD_LEN=0
tui_wave() {
  local line="$1" col="$2" len="$3" dir="$4" selected="${5:-1}"
  [ "$len" -gt 0 ] || return 0
  [ "$line" -gt 0 ] || return 0

  local frames=11 f i d crest span out prev c ch bg=''
  [ "$selected" = "1" ] && bg="$T_SELBG"
  span=$(( len + 10 ))

  f=0
  while [ "$f" -lt "$frames" ]; do
    if [ "$dir" = "up" ]; then crest=$(( len + 4 - f * span / frames ))
    else                       crest=$(( f * span / frames - 5 )); fi

    out=""; prev=""
    i=0
    while [ "$i" -lt "$len" ]; do
      d=$(( i - crest )); [ "$d" -lt 0 ] && d=$(( -d ))
      case "$d" in
        0)       ch='˙'; c="$T_ACCENT" ;;
        1)       ch='⠁'; c="$T_ACCENT" ;;
        2)       ch='⠂'; c="$T_MUTE" ;;
        3)       ch='⠄'; c="$T_MUTE" ;;
        *)       ch='·'; c="$T_LEAD" ;;
      esac
      [ "$c" != "$prev" ] && { out="$out$c"; prev="$c"; }
      out="$out$ch"
      i=$(( i + 1 ))
    done

    printf '\033[%d;%dH%s%s' "$line" "$col" "$bg$out" "$T_RS" >/dev/tty
    sleep 0.012
    f=$(( f + 1 ))
  done

  # settle: restore the plain leader
  printf '\033[%d;%dH%s%s%s' "$line" "$col" "$bg$T_LEAD" "$(tui_repeat '·' "$len")" "$T_RS" >/dev/tty
}

# --- generic full-bleed menu --------------------------------------------------
# tui_menu TITLE SUBTITLE ITEM...  -> echoes the chosen item on stdout,
# draws to /dev/tty (callers capture stdout, so drawing must not go there).
TUI_CHOICE=0
TUI_MENU_ICON=""     # optional module id -> dot-matrix glyph beside the title
tui_menu() {
  local title="$1" subtitle="$2"; shift 2
  local n=$# sel=1 key i item label desc avail block gapn padrows extra g mode
  [ "$n" -gt 0 ] || return 1
  TUI_CHOICE=0
  tui_begin >/dev/tty

  while :; do
    tui_dims
    avail=$(( TUI_ROWS - 6 ))
    if [ $(( n * 2 )) -le "$avail" ]; then mode=detail; block=$(( n * 2 ))
    else                                   mode=plain;  block=$n
    fi
    gapn=0
    if [ "$n" -gt 1 ]; then
      gapn=$(( (avail - block) / (n - 1) ))
      [ "$gapn" -lt 0 ] && gapn=0
      [ "$gapn" -gt 2 ] && gapn=2
    fi
    padrows=$(( avail - block - gapn * (n - 1) ))
    [ "$padrows" -lt 0 ] && padrows=0
    extra=0
    if [ "$n" -gt 1 ] && [ "$padrows" -gt 0 ] && [ "$padrows" -lt "$n" ]; then
      extra="$padrows"; padrows=0
    fi

    {
      tui_home
      tui_blank
      if [ -n "$TUI_MENU_ICON" ]; then
        printf '  %s%s%s  %s%s%s%s' "$(tui_hue "$TUI_MENU_ICON")" "$(tui_glyph "$TUI_MENU_ICON")" \
          "$T_RS" "$T_B" "$T_TEXT" "$title" "$T_RS"
        tui_padn "$TUI_COLS" $(( 2 + 3 + 2 + ${#title} ))
      else
        printf '  %s%s%s%s' "$T_B" "$T_ACCENT" "$title" "$T_RS"
        tui_padn "$TUI_COLS" $(( 2 + ${#title} ))
      fi
      printf '\n'
      printf '  %s%s%s' "$T_DIM" "$subtitle" "$T_RS"
      tui_padn "$TUI_COLS" $(( 2 + ${#subtitle} )); printf '\n'
      tui_hrule

      i=1
      for item in "$@"; do
        label="${item%%|*}"
        if [ "$item" = "$label" ]; then desc=""; else desc="${item#*|}"; fi
        if [ "$i" = "$sel" ]; then
          # same gradient mask as the dashboard rows: plain text + colour map,
          # painted column by column so the fade sits under the whole row
          local rtxt rmap j code fgc prevfg=""
          rtxt="  ▌  $label"; rmap="nnannn"
          j=0; while [ "$j" -lt "${#label}" ]; do rmap="${rmap}t"; j=$(( j + 1 )); done
          rtxt="$rtxt$(tui_repeat ' ' $(( TUI_COLS - 5 - ${#label} )))"
          j=${#rmap}; while [ "$j" -lt "${#rtxt}" ]; do rmap="${rmap}n"; j=$(( j + 1 )); done
          j=0
          while [ "$j" -lt "${#rtxt}" ]; do
            [ $(( j % 4 )) -eq 0 ] && { printf '%s' "$(tui_bg_at "$j" "$TUI_COLS")"; prevfg=""; }
            code="${rmap:$j:1}"
            case "$code" in a) fgc="$T_ACCENT" ;; t) fgc="$T_B$T_TEXT" ;; *) fgc="$T_DIM" ;; esac
            [ "$fgc" != "$prevfg" ] && { printf '%s' "$fgc"; prevfg="$fgc"; }
            printf '%s' "${rtxt:$j:1}"
            j=$(( j + 1 ))
          done
          printf '%s\n' "$T_RS"
          if [ "$mode" = detail ]; then
            local dtxt="       $desc"
            dtxt="$dtxt$(tui_repeat ' ' $(( TUI_COLS - ${#dtxt} > 0 ? TUI_COLS - ${#dtxt} : 0 )))"
            j=0
            while [ "$j" -lt "${#dtxt}" ]; do
              [ $(( j % 4 )) -eq 0 ] && printf '%s%s' "$(tui_bg_at "$j" "$TUI_COLS")" "$T_MUTE"
              printf '%s' "${dtxt:$j:1}"
              j=$(( j + 1 ))
            done
            printf '%s\n' "$T_RS"
          fi
        else
          printf '     %s%s%s' "$T_MUTE" "$label" "$T_RS"
          tui_padn "$TUI_COLS" $(( 5 + ${#label} )); printf '\n'
          if [ "$mode" = detail ]; then
            printf '       %s%s%s' "$T_LEAD" "$desc" "$T_RS"
            tui_padn "$TUI_COLS" $(( 7 + ${#desc} )); printf '\n'
          fi
        fi
        if [ "$i" -lt "$n" ]; then
          g=0; while [ "$g" -lt "$gapn" ]; do tui_blank; g=$(( g + 1 )); done
          [ "$i" -le "$extra" ] && tui_blank
        fi
        i=$(( i + 1 ))
      done

      g=0; while [ "$g" -lt "$padrows" ]; do tui_blank; g=$(( g + 1 )); done
      tui_footer "↑↓ move" "↵ select" "esc back"
      tui_clear_below
    } >/dev/tty

    key="$(tui_readkey)" || { tui_end >/dev/tty; return 1; }
    case "$key" in
      up)   sel=$(( sel - 1 )); [ "$sel" -lt 1 ] && sel="$n" ;;
      down) sel=$(( sel + 1 )); [ "$sel" -gt "$n" ] && sel=1 ;;
      enter|right)
            TUI_CHOICE="$sel"; tui_end >/dev/tty
            eval "item=\"\${$sel}\""
            printf '%s' "${item%%|*}"; return 0 ;;
      quit|esc|left) tui_end >/dev/tty; return 1 ;;
    esac
  done
}

# tui_page TITLE SUBTITLE — full-width titled page for non-menu output
tui_page() {
  tui_dims
  printf '\033[2J\033[H'
  tui_blank
  printf '  %s%s%s%s' "$T_B" "$T_ACCENT" "$1" "$T_RS"
  tui_padn "$TUI_COLS" $(( 2 + ${#1} )); printf '\n'
  if [ -n "${2:-}" ]; then
    printf '  %s%s%s' "$T_DIM" "$2" "$T_RS"
    tui_padn "$TUI_COLS" $(( 2 + ${#2} )); printf '\n'
  fi
  tui_hrule
}

# --- vibrant text ------------------------------------------------------------
# tui_grad TEXT R1 G1 B1 R2 G2 B2 — per-character colour ramp across the string.
# Falls back to a flat accent when the terminal has no truecolor.
tui_grad() {
  local s="$1" r1="$2" g1="$3" b1="$4" r2="$5" g2="$6" b2="$7"
  local n="${#s}" i d r g b
  [ "$n" -eq 0 ] && return 0
  if [ "${COLORTERM:-}" != "truecolor" ] && [ "${COLORTERM:-}" != "24bit" ]; then
    printf '%s%s%s' "$T_ACCENT" "$s" "$T_RS"; return 0
  fi
  d=$(( n - 1 )); [ "$d" -lt 1 ] && d=1
  i=0
  while [ "$i" -lt "$n" ]; do
    r=$(( r1 + (r2 - r1) * i / d ))
    g=$(( g1 + (g2 - g1) * i / d ))
    b=$(( b1 + (b2 - b1) * i / d ))
    printf '\033[38;2;%d;%d;%dm%s' "$r" "$g" "$b" "${s:$i:1}"
    i=$(( i + 1 ))
  done
  printf '%s' "$T_RS"
}

# tui_grad_violet TEXT — the house ramp: violet -> cyan
tui_grad_violet() { tui_grad "$1" 167 139 250 34 211 238; }
# tui_grad_hot TEXT — attention ramp: amber -> magenta
tui_grad_hot()    { tui_grad "$1" 251 191 36 244 114 182; }

# --- selection mask ----------------------------------------------------------
# tui_bg_at POS WIDTH — background colour for column POS of a masked row.
# The mask is a real gradient that fades left-to-right, so the active row reads
# as lit rather than as a flat block of colour.
TUI_MASK_R1=44; TUI_MASK_G1=32; TUI_MASK_B1=78
TUI_MASK_R2=16; TUI_MASK_G2=14; TUI_MASK_B2=22
tui_bg_at() {
  local pos="$1" w="$2" r g b d
  if [ "${COLORTERM:-}" != "truecolor" ] && [ "${COLORTERM:-}" != "24bit" ]; then
    printf '%s' "$T_SELBG"; return 0
  fi
  d="$w"; [ "$d" -lt 1 ] && d=1
  [ "$pos" -gt "$d" ] && pos="$d"
  r=$(( TUI_MASK_R1 + (TUI_MASK_R2 - TUI_MASK_R1) * pos / d ))
  g=$(( TUI_MASK_G1 + (TUI_MASK_G2 - TUI_MASK_G1) * pos / d ))
  b=$(( TUI_MASK_B1 + (TUI_MASK_B2 - TUI_MASK_B1) * pos / d ))
  printf '\033[48;2;%d;%d;%dm' "$r" "$g" "$b"
}

# tui_mask_span FROM TO WIDTH TEXT — paint TEXT starting at column FROM with the
# gradient mask underneath, one bg step every few columns (stepping keeps the
# escape count sane without a visible band).
tui_mask_span() {
  local from="$1" w="$2" text="$3" fg="$4"
  local n="${#text}" i step=4 pos
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ $(( i % step )) -eq 0 ]; then
      pos=$(( from + i ))
      printf '%s' "$(tui_bg_at "$pos" "$w")"
    fi
    printf '%s%s' "$fg" "${text:$i:1}"
    i=$(( i + 1 ))
  done
}

# tui_decode_key CHAR — turn a raw first byte into a logical key name.
# Split out of tui_readkey so the security layer can wrap the READ with an idle
# timeout while reusing exactly the same decoding.
tui_decode_key() {
  local k="$1" rest
  case "$k" in
    $'\033')
      if [ "${BASH_VERSINFO[0]:-3}" -ge 4 ]; then
        IFS= read -rsn2 -t 0.05 rest </dev/tty 2>/dev/null
      else
        IFS= read -rsn2 rest </dev/tty 2>/dev/null
      fi
      case "$rest" in
        '[A') printf 'up' ;;    '[B') printf 'down' ;;
        '[C') printf 'right' ;; '[D') printf 'left' ;;
        '')   printf 'esc' ;;   *)    printf 'other' ;;
      esac ;;
    ''|$'\n') printf 'enter' ;;
    q|Q) printf 'quit' ;;
    j|J) printf 'down' ;;
    k|K) printf 'up' ;;
    /)   printf 'search' ;;
    *)   printf 'char:%s' "$k" ;;
  esac
}

# --- meters and detail rows ---------------------------------------------------
# tui_meter VALUE TOTAL WIDTH — a gradient-filled bar. Coverage numbers are
# easier to act on when you can see the shortfall.
tui_meter() {
  local v="$1" t="$2" w="${3:-24}" filled i r g b
  [ "$t" -gt 0 ] || t=1
  filled=$(( v * w / t )); [ "$filled" -gt "$w" ] && filled="$w"
  i=0
  while [ "$i" -lt "$w" ]; do
    if [ "$i" -lt "$filled" ]; then
      if [ "${COLORTERM:-}" = "truecolor" ] || [ "${COLORTERM:-}" = "24bit" ]; then
        r=$(( 167 + (34 - 167) * i / w )); g=$(( 139 + (211 - 139) * i / w )); b=$(( 250 + (238 - 250) * i / w ))
        printf '\033[38;2;%d;%d;%dm█' "$r" "$g" "$b"
      else printf '%s█' "$T_ACCENT"; fi
    else
      printf '%s░' "$T_LEAD"
    fi
    i=$(( i + 1 ))
  done
  printf '%s' "$T_RS"
}

# tui_kv LABEL VALUE [COLOUR] — a detail row with leader dots to the value
tui_kv() {
  local k="$1" v="$2" c="${3:-$T_TEXT}" lead
  lead=$(( TUI_COLS - 6 - ${#k} - ${#v} - 4 ))
  [ "$lead" -lt 1 ] && lead=1
  printf '    %s%s %s' "$T_MUTE" "$k" "$T_LEAD"
  tui_repeat '·' "$lead"
  printf ' %s%s%s\n' "$c" "$v" "$T_RS"
}

# tui_badge TEXT STATE — a small inline status chip
tui_badge() {
  local t="$1" st="$2" c
  case "$st" in
    ok)   c="$T_OK" ;;   warn) c="$T_WARN" ;;
    err)  c="$T_ERR" ;;  *)    c="$T_DIM" ;;
  esac
  printf '%s[ %s ]%s' "$c" "$t" "$T_RS"
}

# tui_section TITLE — a gradient section heading
tui_section() {
  printf '\n  '; tui_grad_violet "$1"; printf '\n\n'
}

# --- two-row module marks (8x8 dots = 4 cells wide, 2 rows tall) --------------
# A one-line 6x4 mark can only ever be a suggestion of a shape. Module rows
# already occupy two lines (title + description), so the mark spans both: 8x8
# dots is enough resolution for an actual pictogram rather than a smudge.
tui_icon_top() {
  case "$1" in
    api)      printf '⣰⠉⠀⣏' ;;  pii)      printf '⠀⣺⣗⠀' ;;
    keys)     printf '⡎⠭⢱⠀' ;;  auth)     printf '⡏⣇⣸⢹' ;;
    machines) printf '⠯⠿⠿⠽' ;;  certs)    printf '⡏⠭⠭⢹' ;;
    env)      printf '⡎⠉⠉⢱' ;;  dns)      printf '⣴⣹⣏⣦' ;;
    logins)   printf '⣰⣉⣉⣆' ;;  vault)    printf '⡏⣩⣍⢹' ;;
    claude)   printf '⠙⣦⣴⠋' ;;  session)  printf '⣠⠞⠳⣄' ;;
    yubikey)  printf '⣰⣉⣉⣆' ;;
    vaults)   printf '⡏⣩⣍⢹' ;;  workspace) printf '⠙⣦⣴⠋' ;;
    inbox)    printf '⠀⣺⣗⠀' ;;  sessions)  printf '⣠⠞⠳⣄' ;;
    pkm)      printf '⣴⣹⣏⣦' ;;  posture)   printf '⡏⠭⠭⢹' ;;
    doctor)   printf '⠯⠿⠿⠽' ;;
    recovery) printf '⡏⣩⣍⢹' ;;  guard) printf '⡏⠭⠭⢹' ;;
    monitor)  printf '⡗⠦⢄' ;;
    *)        printf '⡏⠉⠉⢹' ;;
  esac
}
tui_icon_bot() {
  case "$1" in
    api)      printf '⠹⣀⠀⣏' ;;  pii)      printf '⣾⠿⠿⣷' ;;
    keys)     printf '⠈⠛⡓⡆' ;;  auth)     printf '⣇⡏⢹⣸' ;;
    machines) printf '⠯⣿⣿⠽' ;;  certs)    printf '⠉⢯⡽⠉' ;;
    env)      printf '⢇⣀⣀⡸' ;;  dns)      printf '⠙⠼⠧⠋' ;;
    logins)   printf '⣇⣘⣃⣸' ;;  vault)    printf '⣇⣙⣋⣸' ;;
    claude)   printf '⣠⠟⠻⣄' ;;  session)  printf '⠙⢦⡴⠋' ;;
    yubikey)  printf '⣇⣘⣃⣸' ;;
    vaults)   printf '⣇⣙⣋⣸' ;;  workspace) printf '⣠⠟⠻⣄' ;;
    inbox)    printf '⣾⠿⠿⣷' ;;  sessions)  printf '⠙⢦⡴⠋' ;;
    pkm)      printf '⠙⠼⠧⠋' ;;  posture)   printf '⠉⢯⡽⠉' ;;
    doctor)   printf '⠯⣿⣿⠽' ;;
    recovery) printf '⣇⣙⣋⣸' ;;  guard) printf '⠉⢯⡽⠉' ;;
    monitor)  printf '⠙⢦⡴⠋' ;;
    *)        printf '⣇⣀⣀⣸' ;;
  esac
}
