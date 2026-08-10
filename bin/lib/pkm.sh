#!/usr/bin/env bash
# lib/pkm.sh — personal knowledge management (PKM) pairing.
#
# `secrets` is a credential companion for agentic workflows and note vaults:
# it bridges the secure informational gap between man and machine. Which note
# system you keep decides where the human-readable half of that bridge lives, so
# it is the first thing the program asks.
#
# The Obsidian mark is NOT hand-drawn. It is rasterised from Obsidian's own
# published SVG path data onto the braille dot grid (2 dots wide x 4 tall per
# cell, which is very close to square in a normal terminal), then reduced to its
# silhouette and true internal facet creases. The region map colours each facet
# separately, which is what makes it read as the actual crystal rather than a
# generic gem.
#
# Sourced, never executed.

SEC_PKM="$SEC_SECRETS/PKM.yaml"

# --- Obsidian crystal: 22 cells wide x 10 rows (44 x 40 dots) -----------------
# Deliberately stretched wider than the source aspect: at 10 rows the natural
# width is 16 cells, which reads cramped beside the list. Height is fixed.
OBS_ART=(
  "⠀⠀⠀⠀⠀⠀⠀⠀⣠⠴⠋⠉⠉⣷⣄⠀⠀⠀⠀⠀⠀⠀"
  "⠀⠀⠀⠀⢀⣠⠔⠋⠀⠀⠀⠀⢠⠏⠈⠑⢤⡀⠀⠀⠀⠀"
  "⠀⠀⠀⢀⡏⠀⠀⠀⠀⠀⠀⣴⠋⠀⠀⠀⠀⠙⢦⠀⠀⠀"
  "⠀⠀⠀⢸⠀⠀⠀⠀⠀⠀⢰⠇⠀⠀⠀⠀⠀⠀⢸⠀⠀⠀"
  "⠀⠀⣠⠛⠲⣄⡀⠀⠀⠀⠸⡆⠀⠀⠀⠀⠀⠀⠘⣆⠀⠀"
  "⠀⡴⠃⠀⠀⠀⠹⣆⠀⠀⢀⣻⡀⠀⠀⠀⠀⠀⠀⠈⠣⡀"
  "⡜⠁⠀⠀⠀⠀⠀⢸⠉⠉⠉⠉⠉⠉⠛⠲⢤⡀⠀⠀⢀⡼"
  "⠳⢄⡀⠀⠀⠀⠀⣸⠀⠀⠀⠀⠀⠀⠀⠀⠀⠙⢦⣠⠊⠀"
  "⠀⠀⠙⠲⣄⠀⢠⠏⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡞⠁⠀⠀"
  "⠀⠀⠀⠀⠈⠙⠛⠒⠒⠒⠦⠤⠤⣄⣀⣀⣀⡼⠁⠀⠀⠀"
)
# facet each cell belongs to: 4 top · 3 right · 2 left · 1 bottom
OBS_REG=(
  "........4444443......."
  ".....444444443333....."
  "....444444443333333..."
  "...4444444433333333..."
  "..222444444333333333.."
  ".222222444443333333333"
  "2222222211111113333333"
  "222222221111111111333."
  "..22222111111111111..."
  ".....2111111111111...."
)

# facet -> colour (Obsidian's violet family, tonally separated)
pkm_facet_colour() {
  case "$1" in
    4) printf '%s' "$N_VIOLET" ;;                                   # top, lightest
    3) printf '%s' "${PKM_V_MID}" ;;                                # right
    2) printf '%s' "${PKM_V_DEEP}" ;;                               # left
    1) printf '%s' "${PKM_V_DARK}" ;;                               # bottom
    *) printf '%s' "$T_LEAD" ;;
  esac
}
if [ "${COLORTERM:-}" = "truecolor" ] || [ "${COLORTERM:-}" = "24bit" ]; then
  PKM_V_MID=$'\033[38;2;139;108;240m'
  PKM_V_DEEP=$'\033[38;2;109;77;226m'
  PKM_V_DARK=$'\033[38;2;83;54;190m'
else
  PKM_V_MID=$'\033[38;5;99m'; PKM_V_DEEP=$'\033[38;5;93m'; PKM_V_DARK=$'\033[38;5;57m'
fi

# pkm_draw_obsidian LINE COL — paint the crystal, one colour run per facet
pkm_draw_obsidian() {
  local line="$1" col="$2" r i ch reg prev out
  r=0
  while [ "$r" -lt ${#OBS_ART[@]} ]; do
    out=""; prev=""
    i=0
    while [ "$i" -lt 22 ]; do
      ch="${OBS_ART[$r]:$i:1}"
      reg="${OBS_REG[$r]:$i:1}"
      local c; c="$(pkm_facet_colour "$reg")"
      [ "$c" != "$prev" ] && { out="$out$c"; prev="$c"; }
      out="$out$ch"
      i=$(( i + 1 ))
    done
    printf '\033[%d;%dH%s%s' "$(( line + r ))" "$col" "$out" "$T_RS"
    r=$(( r + 1 ))
  done
}

# --- the systems --------------------------------------------------------------
# id|mark|label|state|detect-hint
pkm_systems() {
  cat <<'SYS'
obsidian|⢴⣿⡦|Obsidian|active|markdown vault with frontmatter and tags
plaintext|⣗⣓⣳|Plain markdown|active|a folder of .md — Notepad, or any editor
apple-notes|⣏⣿⣯|Apple Notes|active|via osascript, into a named folder
joplin|⢭⣹⠏|Joplin|active|local clipper API on 127.0.0.1:41184
cherrytree|⠴⣿⠦|CherryTree|soon|its .ctb is a live SQLite doc — unsafe to write into
notion|⣿⠢⣿|Notion|soon|hosted, needs egress and a token
SYS
}

pkm_field() { pkm_systems | awk -F'|' -v id="$1" -v f="$2" '$1==id {print $f}'; }

# --- detection ----------------------------------------------------------------
pkm_detect_obsidian() {
  local d
  for d in "$HOME/notes"/*/ "$HOME/Documents"/*/ "$HOME/obsidian"/*/ "$HOME/vaults"/*/; do
    [ -d "$d/.obsidian" ] && { printf '%s' "${d%/}"; return 0; }
  done
  return 1
}

pkm_get() {   # $1 field
  [ -f "$SEC_PKM" ] || return 0
  awk -v f="$1" '$1 == f":" { $1=""; sub(/^[ \t]+/,""); sub(/[ \t]+$/,""); print; exit }' "$SEC_PKM"
}
pkm_set() {   # $1 field  $2 value
  local tmp="$TMPD/pkm.yaml"
  touch "$SEC_PKM"
  if grep -qE "^$1:" "$SEC_PKM" 2>/dev/null; then
    awk -v f="$1" -v v="$2" '$1 == f":" { print f ": " v; next } { print }' "$SEC_PKM" > "$tmp" \
      && cat "$tmp" > "$SEC_PKM"
  else
    printf '%s: %s\n' "$1" "$2" >> "$SEC_PKM"
  fi
}

# --- the screen ---------------------------------------------------------------
pkm_screen() {
  ui_interactive || { ui_needs_tty pkm; return 1; }
  local -a P_ID P_MARK P_LABEL P_STATE P_NOTE P_LINE
  local n=0 id mark label state note
  while IFS='|' read -r id mark label state note; do
    [ -n "$id" ] || continue
    P_ID[$n]="$id"; P_MARK[$n]="$mark"; P_LABEL[$n]="$label"
    P_STATE[$n]="$state"; P_NOTE[$n]="$note"
    n=$(( n + 1 ))
  done <<EOF
$(pkm_systems)
EOF

  local obsvault; obsvault="$(pkm_detect_obsidian 2>/dev/null)"
  [ -n "$obsvault" ] && P_NOTE[0]="detected at ${obsvault/#$HOME/~}"

  local sel=0 key i prev logocol logoline curline
  local host; host="$(hostname -s 2>/dev/null || echo host)"

  draw_pkm_row() {
    local k="$1" on="$2" col dim
    printf '\033[%d;1H' "${P_LINE[$k]}"
    if [ "${P_STATE[$k]}" = active ]; then col="$N_VIOLET"; else col="$T_DIM"; fi
    if [ "$on" = "1" ]; then
      printf '%s  %s▌%s %s%s%s  %s%s%s' "$T_SELBG" "$T_ACCENT" "$T_SELBG" \
        "$col" "${P_MARK[$k]}" "$T_SELBG" "$T_B$T_TEXT" "${P_LABEL[$k]}" "$T_SELBG"
      tui_padn "$logocol" $(( 2 + 1 + 1 + 3 + 2 + ${#P_LABEL[$k]} ))
      printf '%s\n' "$T_RS"
      printf '%s      %s%s%s' "$T_SELBG" "$T_DIM" "${P_NOTE[$k]}" "$T_SELBG"
      tui_padn "$logocol" $(( 6 + ${#P_NOTE[$k]} ))
      printf '%s\n' "$T_RS"
    else
      printf '    %s%s%s  %s%s%s' "$col" "${P_MARK[$k]}" "$T_RS" "$T_MUTE" "${P_LABEL[$k]}" "$T_RS"
      tui_padn "$logocol" $(( 4 + 3 + 2 + ${#P_LABEL[$k]} )); printf '\n'
      printf '      %s%s%s' "$T_LEAD" "${P_NOTE[$k]}" "$T_RS"
      tui_padn "$logocol" $(( 6 + ${#P_NOTE[$k]} )); printf '\n'
    fi
  }

  draw_pkm() {
    tui_home
    tui_header "$host" "bridging the secure informational gap between man and machine" "KNOWLEDGE SYSTEM" pkm
    curline=4
    printf '  %s%sKNOWLEDGE SYSTEM%s' "$T_B" "$T_ACCENT" "$T_RS"
    tui_padn "$TUI_COLS" 18; printf '\n'
    printf '  %spair the vault you already keep — the credential half stays encrypted%s' "$T_DIM" "$T_RS"
    tui_padn "$TUI_COLS" 70; printf '\n'
    tui_blank
    curline=$(( curline + 3 ))
    i=0
    while [ "$i" -lt "$n" ]; do
      P_LINE[$i]="$(( curline + 1 ))"
      draw_pkm_row "$i" "$([ "$i" = "$sel" ] && echo 1 || echo 0)"
      curline=$(( curline + 2 ))
      if [ "$i" -lt $(( n - 1 )) ]; then tui_blank; curline=$(( curline + 1 )); fi
      i=$(( i + 1 ))
    done
    local pad=$(( TUI_ROWS - curline - 2 ))
    [ "$pad" -lt 0 ] && pad=0
    i=0; while [ "$i" -lt "$pad" ]; do tui_blank; i=$(( i + 1 )); done
    tui_footer "↑↓ move" "↵ pair" "s skip" "q quit"
    tui_clear_below
    # The crystal is painted LAST and by absolute position. Painted earlier, the
    # sequential blank-line padding that follows overwrites it — and worse, the
    # cursor left mid-screen by the absolute writes made the padding wipe the
    # bottom half of the system list.
    pkm_draw_obsidian "$logoline" "$logocol"
  }

  tui_begin
  trap 'tui_end; cleanup' EXIT INT TERM
  tui_dims
  logocol=$(( TUI_COLS - 26 )); [ "$logocol" -lt 44 ] && logocol=$(( TUI_COLS - 23 ))
  logoline=6
  draw_pkm

  while :; do
    key="$(tui_readkey)" || break
    prev="$sel"
    case "$key" in
      up)   sel=$(( sel - 1 )); [ "$sel" -lt 0 ] && sel=$(( n - 1 )) ;;
      down) sel=$(( sel + 1 )); [ "$sel" -ge "$n" ] && sel=0 ;;
      enter|right)
        if [ "${P_STATE[$sel]}" = active ]; then
          pkm_set system "${P_ID[$sel]}"
          case "${P_ID[$sel]}" in
            obsidian)
              [ -n "$obsvault" ] && pkm_set vault "$obsvault" ;;
            plaintext)
              tui_end
              local d; d="$(ui_ask 'Folder for the notes' "$HOME/notes")"
              [ -n "$d" ] || d="$HOME/notes"
              case "$d" in "~"*) d="$HOME${d#\~}" ;; esac
              mkdir -p "$d" && pkm_set vault "$d" ;;
            joplin)
              tui_end
              ui_note "Joplin → Tools → Options → Web Clipper → copy the authorisation token"
              local t; t="$(ui_ask 'Joplin API token' '')"
              [ -n "$t" ] && pkm_set joplin_token "$t" ;;
          esac
          pkm_set paired "$(date +%F)"
          tui_end
          ui_ok "paired with ${P_LABEL[$sel]}"
          [ -n "$obsvault" ] && ui_info "vault: $obsvault"
          sec_log_start "pkm"; sec_log "paired ${P_ID[$sel]}"
          ui_pause
          return 0
        else
          tui_end
          ui_warn "${P_LABEL[$sel]} is listed but not wired up yet"
          ui_note "${P_NOTE[$sel]}"
          ui_note "Obsidian is the one that works today — pick it, or press s to skip."
          ui_pause; tui_begin; tui_dims; draw_pkm; continue
        fi ;;
      char:s) pkm_set system none; tui_end; return 0 ;;
      quit|esc) tui_end; return 1 ;;
      *) continue ;;
    esac
    draw_pkm_row "$prev" 0
    draw_pkm_row "$sel" 1
  done
  tui_end
  trap 'cleanup' EXIT INT TERM
  return 0
}
