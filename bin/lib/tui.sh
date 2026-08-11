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
    alerts)   printf '⠈⣿⠁' ;;   keychain) printf '⠺⢽⣂' ;;
    vaults)   printf '⣏⣿⣹' ;;   workspace) printf '⠙⣶⠋' ;;
    inbox)    printf '⣠⣿⣄' ;;   sessions)  printf '⡴⠶⢦' ;;
    pkm)      printf '⢾⣝⡷' ;;   posture)   printf '⣿⣿⡀' ;;
    doctor)   printf '⠯⣿⠽' ;;   recovery)  printf '⣏⣿⣹' ;;
    guard)    printf '⡱⠶⢎' ;;   monitor)   printf '⡴⠶⢦' ;;
    broker)   printf '⠭⠪⠅' ;;   profiles)  printf '⡱⠶⢎' ;;
    import)   printf '⠺⢽⣂' ;;   gen)       printf '⠭⠪⠅' ;;
    yubikey)  printf '⡴⣭⢦' ;;   notes)     printf '⢾⣝⡷' ;;
    *)        printf '⠿⠿⠿' ;;
  esac
}
tui_hue() {
  case "$1" in
    api)      printf '%s' "$N_CYAN" ;;    pii)    printf '%s' "$N_MAGENTA" ;;
    keys)     printf '%s' "$N_AMBER" ;;   auth)   printf '%s' "$N_VIOLET" ;;
    machines) printf '%s' "$N_GREEN" ;;   certs)  printf '%s' "$N_ORANGE" ;;
    env)      printf '%s' "$N_BLUE" ;;    dns)    printf '%s' "$N_TEAL" ;;
    logins)   printf '%s' "$N_RED" ;;     alerts)   printf '%s' "$N_AMBER" ;;
    keychain) printf '%s' "$N_BLUE" ;;    vaults)   printf '%s' "$N_CYAN" ;;
    workspace) printf '%s' "$N_GREEN" ;;  inbox)    printf '%s' "$N_MAGENTA" ;;
    sessions) printf '%s' "$N_BLUE" ;;    pkm)      printf '%s' "$N_VIOLET" ;;
    posture)  printf '%s' "$N_RED" ;;     doctor)   printf '%s' "$N_ORANGE" ;;
    recovery) printf '%s' "$N_RED" ;;     guard)    printf '%s' "$N_GREEN" ;;
    monitor)  printf '%s' "$N_CYAN" ;;    broker)   printf '%s' "$N_TEAL" ;;
    profiles) printf '%s' "$N_VIOLET" ;;  import)   printf '%s' "$N_TEAL" ;;
    gen)      printf '%s' "$N_AMBER" ;;   yubikey)  printf '%s' "$N_AMBER" ;;
    notes)    printf '%s' "$N_VIOLET" ;;
    *)      printf '%s' "$T_DIM" ;;
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
  # grouped so bash's own failed-redirect message is silenced too, not just stty's
  sz="$( { stty size </dev/tty; } 2>/dev/null )"   # "ROWS COLS"
  if [ -n "$sz" ]; then
    TUI_ROWS="${sz%% *}"; TUI_COLS="${sz##* }"
  else
    TUI_COLS="$(tput cols)"; TUI_ROWS="$(tput lines)"
  fi
  case "$TUI_COLS" in ''|*[!0-9]*) TUI_COLS=80 ;; esac
  case "$TUI_ROWS" in ''|*[!0-9]*) TUI_ROWS=24 ;; esac
  [ "$TUI_COLS" -lt 40 ] && TUI_COLS=40
  [ "$TUI_ROWS" -lt 10 ] && TUI_ROWS=10
  tui_bg_build "$TUI_COLS"
  return 0
}

# --- screen control -----------------------------------------------------------
# --- entering and leaving full-screen mode ------------------------------------
#
# ECHO MUST BE OFF FOR THE WHOLE SESSION, not just while a read is running.
#
# `read -rsn1` silences echo only for the moment it is reading. Every keystroke
# that arrives while the program is REDRAWING is echoed by the terminal driver
# instead — so holding an arrow key printed raw `^[[B` and `^[[A` down the side
# of the screen, wherever the cursor happened to be left by the last absolutely
# positioned write. The faster you cycle, the more of them you get.
#
# The original terminal settings are captured once and restored on the way out,
# so this cannot leave a shell with echo disabled. tui_begin is called many
# times as screens nest; only the FIRST call captures, or the second would save
# the already-modified state and restore the wrong thing.
TUI_STTY_SAVED=""
tui_begin() {
  if [ -z "$TUI_STTY_SAVED" ]; then
    TUI_STTY_SAVED="$( { stty -g </dev/tty; } 2>/dev/null )"
  fi
  { stty -echo </dev/tty; } 2>/dev/null
  printf '\033[?1049h\033[?25l\033[2J\033[H'
}
tui_end() {
  printf '\033[?25h\033[?1049l'
  tui_stty_restore
}

# Restoring is separate so the EXIT trap can call it too: a crash between
# tui_begin and tui_end must not hand the user a shell that does not echo.
tui_stty_restore() {
  [ -n "$TUI_STTY_SAVED" ] || return 0
  { stty "$TUI_STTY_SAVED" </dev/tty; } 2>/dev/null
}
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
# tui_header HOST STATLINE [TITLE] [MODULE-ID]
#
# Only the home grid is "S E C R E T S". Every other screen used to wear that
# same wordmark, which meant nine different modules all introduced themselves
# with the program's name and buried what you were actually looking at in the
# subtitle. Pass a title and the screen says what it is.
tui_header() {
  local host="$1" stat="$2" wm="${3:-S E C R E T S}" modid="${4:-}"
  local mark='⣿⣿⣿'
  [ -n "$modid" ] && mark="$(tui_glyph "$modid")"
  tui_blank
  printf '  '
  if [ -n "$modid" ]; then printf '%s%s%s' "$(tui_hue "$modid")" "$mark" "$T_RS"
  else tui_grad_violet "$mark"; fi
  printf '  %s' "$T_B"; tui_grad_violet "$wm"
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
# tui_modrow SELECTED MARK HUE LABEL COUNT DOTSTATE DOTLABEL [INDENT]
# INDENT nests a row under its category in the accordion. It is added to the
# left and taken off the leader, so every value still lands in the same column
# whatever depth its row sits at.
tui_modrow() {
  local sel="$1" mark="$2" hue="$3" label="$4" count="$5" dot="$6" dlab="$7" indent="${8:-0}"
  local dotcol glyph leader llen rlen pad

  case "$dot" in
    ok)   dotcol="$T_OK";   glyph='●' ;;
    warn) dotcol="$T_WARN"; glyph='●' ;;
    err)  dotcol="$T_ERR";  glyph='●' ;;
    *)    dotcol="$T_DIM";  glyph='○' ;;
  esac

  # icon width is measured, never assumed: a 4-cell mark with a hardcoded 3 here
  # overruns the line, the terminal wraps it, and every absolutely-positioned row
  # below shifts by one — which looks like a mysterious blank line, not an overflow
  llen=$(( 2 + 1 + 1 + ${#mark} + 2 + ${#label} + indent ))
  rlen=$(( ${#count} + 2 + 1 + 1 + ${#dlab} + 2 ))
  leader=$(( TUI_COLS - llen - rlen - 2 ))

  # A row that does not fit must SHRINK, never wrap. A wrapped row pushes every
  # absolutely-positioned row below it out of place and the whole grid stops
  # matching its line map — which is what happened to the category rows at 70
  # columns, where the label, the value and the state together ran past the edge
  # and the next module row was drawn over the overflow.
  #
  # The right-hand state label goes first: it is the least specific of the
  # three. Then the value. The label itself is never cut, because a row you
  # cannot identify is worse than one you cannot read the detail of.
  if [ "$leader" -lt 2 ]; then
    dlab="$(tui_fit "$dlab" $(( ${#dlab} + leader - 2 )))"
    rlen=$(( ${#count} + 2 + 1 + 1 + ${#dlab} + 2 ))
    leader=$(( TUI_COLS - llen - rlen - 2 ))
  fi
  if [ "$leader" -lt 2 ]; then
    count="$(tui_fit "$count" $(( ${#count} + leader - 2 )))"
    rlen=$(( ${#count} + 2 + 1 + 1 + ${#dlab} + 2 ))
    leader=$(( TUI_COLS - llen - rlen - 2 ))
  fi
  [ "$leader" -lt 1 ] && leader=1
  [ "$leader" -lt 1 ] && leader=1

  # Row is built as PLAIN text plus a parallel colour map, then painted column by
  # column. That is what lets the selected row carry a gradient mask underneath
  # arbitrary coloured segments — a flat background cannot fade, and per-segment
  # escapes cannot line up with a gradient that varies per column.
  local txt="" map="" seg
  _add() { txt="$txt$1"; seg=0; while [ "$seg" -lt "${#1}" ]; do map="$map$2"; seg=$(( seg + 1 )); done; }

  if [ "$sel" = "1" ]; then _add "  " "n"; _add "▌" "a"; _add " " "n"
  else                      _add "    " "n"; fi
  if [ "$indent" -gt 0 ]; then printf -v pad "%${indent}s" ''; _add "$pad" "n"; fi
  _add "$mark" "h"; _add "  " "n"
  _add "$label" "t"; _add " " "n"
  local _lead=""; [ "$leader" -gt 0 ] && { printf -v _lead "%${leader}s" ''; _lead="${_lead// /·}"; }
  _add "$_lead" "l"
  _add " " "n"; _add "$count" "t"; _add "  " "n"
  _add "$glyph" "d"; _add " " "n"; _add "$dlab" "m"
  _add "  " "n"
  unset -f _add

  # The title colour depends on whether the ROW is selected, not on the column,
  # so it is resolved ONCE. It used to be a command substitution inside the
  # per-character loop: a subshell for every title character, of every row, on
  # every repaint — measured as the largest single cost in painting the screen.
  local fg_t
  if [ "$sel" = "1" ]; then fg_t="$T_B$T_TEXT"; else fg_t="$T_MUTE"; fi

  # Build the whole row into ONE string and write it in a single printf. Writing
  # character by character means a write syscall per column per row; at 120
  # columns and 30 rows that is 3,600 writes to paint one screen.
  local n="${#txt}" i=0 code prev="" fg step=4 out=""
  while [ "$i" -lt "$n" ]; do
    if [ "$sel" = "1" ] && [ $(( i % step )) -eq 0 ]; then
      out="$out${TUI_BG_RAMP[$i]:-}"
      prev=""
    fi
    code="${map:$i:1}"
    case "$code" in
      a) fg="$T_ACCENT" ;;
      h) fg="$hue" ;;
      t) fg="$fg_t" ;;
      l) fg="$T_LEAD" ;;
      d) fg="$dotcol" ;;
      m) fg="$T_MUTE" ;;
      *) fg="$T_DIM" ;;
    esac
    if [ "$fg" != "$prev" ]; then out="$out$fg"; prev="$fg"; fi
    out="$out${txt:$i:1}"
    i=$(( i + 1 ))
  done
  printf '%s%s\n' "$out" "$T_RS"
}

# tui_moddesc SELECTED TEXT — the secondary description line under a module row
# tui_moddesc SELECTED TEXT [ICON_BOTTOM_ROW] [HUE]
# When an icon bottom row is supplied it is painted in the same column as the
# icon above it, so the mark reads as one 8x8 pictogram across both lines.
# One printf per row, not six. Every separate printf is a write syscall, and a
# full repaint issues one of these per module.
tui_moddesc() {
  local sel="$1" text="$2" icon="${3:-}" hue="${4:-}" indent="${5:-0}" bg='' lead pad used out ind=''
  [ "$indent" -gt 0 ] && printf -v ind "%${indent}s" ''

  [ "$sel" = "1" ] && bg="$T_SELBG"
  if [ -n "$icon" ]; then
    if [ "$sel" = "1" ]; then lead="  ${T_ACCENT}▌${bg} "; else lead="    "; fi
    used=$(( 4 + ${#ind} + ${#icon} + 2 + ${#text} ))
    out="${bg}${lead}${ind}${hue}${icon}${bg}  ${T_DIM}${text}${T_RS}${bg}"
  else
    used=$(( 9 + ${#ind} + ${#text} ))
    out="${bg}         ${ind}${T_DIM}${text}${T_RS}${bg}"
  fi
  pad=$(( TUI_COLS - used )); [ "$pad" -lt 0 ] && pad=0
  printf -v lead "%${pad}s" ''
  printf '%s%s%s\n' "$out" "$lead" "$T_RS"
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

  # TUI_MENU_PANEL — pre-rendered, already-padded status lines drawn between the
  # header and the choices. Screens used to draw a panel with tui_page/tui_kv and
  # THEN call tui_menu, which repaints the whole screen over it: the panel only
  # survived as scrollback behind the menu. One screen, one paint.
  local pn=0
  if [ -n "${TUI_MENU_PANEL:-}" ]; then
    pn=$(( $(printf '%s\n' "$TUI_MENU_PANEL" | wc -l | tr -d ' ') + 1 ))
  fi

  while :; do
    tui_dims
    avail=$(( TUI_ROWS - 6 - pn ))
    [ "$avail" -lt "$n" ] && avail="$n"
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

      if [ -n "${TUI_MENU_PANEL:-}" ]; then
        printf '%s\n' "$TUI_MENU_PANEL"
        tui_hrule
      fi

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
          # accumulate, then write once — see tui_modrow
          local rout=""
          j=0
          while [ "$j" -lt "${#rtxt}" ]; do
            [ $(( j % 4 )) -eq 0 ] && { rout="$rout${TUI_BG_RAMP[$j]:-}"; prevfg=""; }
            code="${rmap:$j:1}"
            case "$code" in a) fgc="$T_ACCENT" ;; t) fgc="$T_B$T_TEXT" ;; *) fgc="$T_DIM" ;; esac
            [ "$fgc" != "$prevfg" ] && { rout="$rout$fgc"; prevfg="$fgc"; }
            rout="$rout${rtxt:$j:1}"
            j=$(( j + 1 ))
          done
          printf '%s%s\n' "$rout" "$T_RS"
          if [ "$mode" = detail ]; then
            local dtxt="       $desc"
            dtxt="$dtxt$(tui_repeat ' ' $(( TUI_COLS - ${#dtxt} > 0 ? TUI_COLS - ${#dtxt} : 0 )))"
            local dout=""
            j=0
            while [ "$j" -lt "${#dtxt}" ]; do
              [ $(( j % 4 )) -eq 0 ] && dout="$dout${TUI_BG_RAMP[$j]:-}$T_MUTE"
              dout="$dout${dtxt:$j:1}"
              j=$(( j + 1 ))
            done
            printf '%s%s\n' "$dout" "$T_RS"
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
# tui_page TITLE [SUBTITLE]
#
# The header a drill-in screen wears. It used to be two bare printf lines, which
# is why every secondary screen looked like a text dump next to the dashboard's
# framed, full-bleed layout. Now it carries the same furniture: the module mark,
# a gradient title, the host on the right, and a rule under it.
tui_page() {
  tui_dims
  printf '\033[2J\033[H'
  tui_blank

  local title="$1" sub="${2:-}" host mark used
  host="$(hostname -s 2>/dev/null || printf '')"
  mark="${TUI_PAGE_MARK:-⣿⣿⣿}"

  printf '  %s%s%s  ' "$T_ACCENT" "$mark" "$T_RS"
  tui_grad_violet "$title"
  used=$(( 2 + ${#mark} + 2 + ${#title} ))
  if [ -n "$host" ] && [ $(( used + ${#host} + 4 )) -lt "$TUI_COLS" ]; then
    tui_padn $(( TUI_COLS - ${#host} - 2 )) "$used"
    printf '%s%s%s' "$T_DIM" "$host" "$T_RS"
    used=$(( TUI_COLS - 2 ))
  fi
  tui_padn "$TUI_COLS" "$used"; printf '\n'

  if [ -n "$sub" ]; then
    sub="$(tui_fit "$sub" $(( TUI_COLS - 4 )))"
    printf '  %s%s%s' "$T_MUTE" "$sub" "$T_RS"
    tui_padn "$TUI_COLS" $(( 2 + ${#sub} )); printf '\n'
  fi
  tui_hrule
  TUI_PAGE_MARK=""
}

# tui_pagefoot HINT… — close a page the way the dashboard closes: pad to the
# bottom of the terminal, then a rule and a hint bar. Without this a short panel
# leaves the rest of the screen as raw scrollback, which is most of why these
# screens looked unfinished next to the home grid.
tui_pagefoot() {
  local used="${1:-0}"; shift 2>/dev/null || true
  tui_dims
  local pad=$(( TUI_ROWS - used - 2 ))
  while [ "$pad" -gt 0 ]; do tui_blank; pad=$(( pad - 1 )); done
  tui_hrule
  local out="" h
  for h in "$@"; do out="$out   $h"; done
  out="$(tui_fit "$out" $(( TUI_COLS - 2 )))"
  printf ' %s%s%s' "$T_DIM" "$out" "$T_RS"
  tui_padn "$TUI_COLS" $(( 1 + ${#out} )); printf '\n'
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
# TUI_BG_RAMP — the mask gradient, computed ONCE per terminal width.
#
# tui_bg_at was called inside a command substitution every fourth column of every
# masked row. A 120-column row is 30 subshells, and a full repaint of the
# dashboard fired hundreds. The colour depends only on (column, width), so it is
# computed once and looked up thereafter.
TUI_BG_RAMP=()
TUI_BG_RAMP_W=0
tui_bg_build() {
  local w="$1" i r g b d
  [ "$w" = "$TUI_BG_RAMP_W" ] && return 0
  TUI_BG_RAMP=(); TUI_BG_RAMP_W="$w"
  if [ "${COLORTERM:-}" != "truecolor" ] && [ "${COLORTERM:-}" != "24bit" ]; then
    i=0; while [ "$i" -le "$w" ]; do TUI_BG_RAMP[$i]="$T_SELBG"; i=$(( i + 4 )); done
    return 0
  fi
  d="$w"; [ "$d" -lt 1 ] && d=1
  i=0
  while [ "$i" -le "$w" ]; do
    r=$(( TUI_MASK_R1 + (TUI_MASK_R2 - TUI_MASK_R1) * i / d ))
    g=$(( TUI_MASK_G1 + (TUI_MASK_G2 - TUI_MASK_G1) * i / d ))
    b=$(( TUI_MASK_B1 + (TUI_MASK_B2 - TUI_MASK_B1) * i / d ))
    printf -v "TUI_BG_RAMP[$i]" '\033[48;2;%d;%d;%dm' "$r" "$g" "$b"
    i=$(( i + 4 ))
  done
}

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
      printf '%s' "${TUI_BG_RAMP[$pos]:-$(tui_bg_at "$pos" "$w")}"
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
# tui_kv KEY VALUE [COLOUR]
#
# Every value on a screen aligns on ONE column. The leader used to be measured
# backwards from the VALUE's length, so a short value and a long one started in
# different places and the whole panel read as ragged — the single thing that
# makes a terminal report look unfinished.
#
# The value column is TUI_KVCOL (a fraction of the width, clamped), the leader
# fills the gap, and anything too long is truncated rather than wrapped, because
# a wrapped row breaks the absolute positioning every screen below it relies on.
tui_kv() {
  local k="$1" v="$2" c="${3:-$T_TEXT}" kcol lead vmax
  kcol="${TUI_KVCOL:-0}"
  if [ "$kcol" -le 0 ]; then
    kcol=$(( TUI_COLS / 3 ))
    [ "$kcol" -lt 22 ] && kcol=22
    [ "$kcol" -gt 40 ] && kcol=40
  fi
  k="$(tui_fit "$k" $(( kcol - 2 )))"
  lead=$(( kcol - ${#k} - 1 ))
  [ "$lead" -lt 1 ] && lead=1
  vmax=$(( TUI_COLS - 6 - kcol - 2 ))
  [ "$vmax" -lt 8 ] && vmax=8
  v="$(tui_fit "$v" "$vmax")"
  printf '    %s%s %s' "$T_MUTE" "$k" "$T_LEAD"
  tui_repeat '·' "$lead"
  printf '  %s%s%s' "$c" "$v" "$T_RS"
  tui_padn "$TUI_COLS" $(( 4 + ${#k} + 1 + lead + 2 + ${#v} )); printf '\n'
}

# tui_kvgroup — align a whole block to its OWN longest key instead of the
# global column. Feed it "key<TAB>value<TAB>colour" lines on stdin. Screens with
# a few short labels look cramped against a one-third-width column; this lets a
# panel size itself.
tui_kvgroup() {
  local rows k v c w=0
  rows="$(cat)"
  while IFS="$(printf '\t')" read -r k v c; do
    [ -n "$k" ] || continue
    [ "${#k}" -gt "$w" ] && w="${#k}"
  done <<KVG
$rows
KVG
  w=$(( w + 3 ))
  [ "$w" -lt 18 ] && w=18
  [ "$w" -gt $(( TUI_COLS / 2 )) ] && w=$(( TUI_COLS / 2 ))
  local old="${TUI_KVCOL:-0}"
  TUI_KVCOL="$w"
  while IFS="$(printf '\t')" read -r k v c; do
    [ -n "$k" ] || continue
    tui_kv "$k" "$v" "$c"
  done <<KVG2
$rows
KVG2
  TUI_KVCOL="$old"
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
    monitor)  printf '⣠⠞⠳⣄' ;;
    alerts)   printf '⠀⣰⣆⠀' ;;  keychain) printf '⡎⠭⢱⠀' ;;
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
    alerts)   printf '⠀⠈⠁⠀' ;;  keychain) printf '⠈⠛⡓⡆' ;;
    *)        printf '⣇⣀⣀⣸' ;;
  esac
}
