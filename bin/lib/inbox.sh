#!/usr/bin/env bash
# lib/inbox.sh — provenance and the agent-authored secret inbox.
#
# THE MECHANISM
#   An agent working a project never handles a secret VALUE. It calls
#     secrets record NAME --agent A --project P --reason "why"
#   which records who created a credential, for what, and when — and marks it
#   unseen. The value itself was generated locally and encrypted; the key NAME is
#   the most the agent, the chat, or the transcript ever knows.
#
#   You open the inbox later and read the trail: which agent, which project, what
#   for. Nothing personal ever left the terminal to produce that record.
#
# PROVENANCE.yaml is PLAINTEXT and holds no values — only names and attribution.
# Sourced, never executed.

SEC_PROV="$SEC_SECRETS/PROVENANCE.yaml"

prov_keys() {
  [ -f "$SEC_PROV" ] || return 0
  grep -oE '^[A-Za-z_][A-Za-z0-9_]*:' "$SEC_PROV" 2>/dev/null | sed 's/:$//'
}

prov_field() {   # $1 key  $2 field
  [ -f "$SEC_PROV" ] || return 0
  awk -v k="$1" -v want="$2" '
    /^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/ { c=$0; sub(/:[[:space:]]*$/,"",c); next }
    c == k && $1 == want":" { $1=""; sub(/^[[:space:]]+/,""); sub(/[[:space:]]+$/,""); print; exit }
  ' "$SEC_PROV"
}

prov_set() {     # $1 key  $2 field  $3 value
  local k="$1" f="$2" v="$3" tmp="$TMPD/prov.yaml"
  touch "$SEC_PROV"
  if ! grep -qE "^$k:" "$SEC_PROV" 2>/dev/null; then
    { echo "$k:"; echo "  $f: $v"; } >> "$SEC_PROV"
    return 0
  fi
  if awk -v k="$k" -v f="$f" '
       /^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/ { c=$0; sub(/:[[:space:]]*$/,"",c) }
       c == k && $1 == f":" { found=1 } END { exit !found }' "$SEC_PROV"; then
    awk -v k="$k" -v f="$f" -v v="$v" '
      /^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/ { c=$0; sub(/:[[:space:]]*$/,"",c) }
      (c == k && $1 == f":") { print "  " f ": " v; next }
      { print }' "$SEC_PROV" > "$tmp" && cat "$tmp" > "$SEC_PROV"
  else
    awk -v k="$k" -v f="$f" -v v="$v" '
      { print } $0 == k":" { print "  " f ": " v }' "$SEC_PROV" > "$tmp" && cat "$tmp" > "$SEC_PROV"
  fi
}

prov_unseen_count() {
  local k c=0
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    [ "$(prov_field "$k" seen)" = "false" ] && c=$(( c + 1 ))
  done <<EOF
$(prov_keys)
EOF
  printf '%s' "$c"
}

# secrets record NAME --agent A --project P --reason "..."
prov_record() {
  local name="${1:-}"; shift 2>/dev/null || true
  [ -n "$name" ] || sec_die "usage: secrets record NAME --agent A --project P --reason \"why\""
  sec_valid_name "$name" || sec_die "invalid key name '$name'"
  local agent="unknown" project="unspecified" reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --agent)   shift; agent="${1:-unknown}"; shift ;;
      --project) shift; project="${1:-unspecified}"; shift ;;
      --reason)  shift; reason="${1:-}"; shift ;;
      *) sec_die "unknown flag '$1'" ;;
    esac
  done
  sec_has "$name" || ui_warn "'$name' is not in the store yet — recording provenance anyway"
  prov_set "$name" agent   "$agent"
  prov_set "$name" project "$project"
  prov_set "$name" reason  "${reason:-not stated}"
  prov_set "$name" created "$(date -u +%FT%TZ)"
  prov_set "$name" seen    "false"
  sec_log_start "record"; sec_log "provenance $name by $agent for $project"
  ui_ok "recorded provenance for '$name' — it will appear in the inbox as unread"
}

prov_age() {   # $1 iso8601 -> "3h ago"
  local t now d
  # TZ=UTC is mandatory: `date -j -f` interprets the stamp in the LOCAL zone, so a
  # UTC timestamp reads as hours in the future and every age comes out negative.
  t="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || date -d "$1" +%s 2>/dev/null)"
  [ -n "$t" ] || { printf 'unknown'; return; }
  now="$(date +%s)"; d=$(( now - t ))
  [ "$d" -lt 0 ] && d=0
  if   [ "$d" -lt 60 ];    then printf 'just now'
  elif [ "$d" -lt 3600 ];  then printf '%dm ago' $(( d / 60 ))
  elif [ "$d" -lt 86400 ]; then printf '%dh ago' $(( d / 3600 ))
  else printf '%dd ago' $(( d / 86400 )); fi
}

# --- the screen ---------------------------------------------------------------
inbox_screen() {
  ui_interactive || { ui_needs_tty inbox; return 1; }
  local -a I_KEY I_AGENT I_PROJ I_REASON I_AGE I_SEEN I_LINE
  local n=0 k
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    I_KEY[$n]="$k"
    I_AGENT[$n]="$(prov_field "$k" agent)"
    I_PROJ[$n]="$(prov_field "$k" project)"
    I_REASON[$n]="$(prov_field "$k" reason)"
    I_AGE[$n]="$(prov_age "$(prov_field "$k" created)")"
    I_SEEN[$n]="$(prov_field "$k" seen)"
    n=$(( n + 1 ))
  done <<EOF
$(prov_keys)
EOF

  if [ "$n" -eq 0 ]; then
    TUI_PAGE_MARK="$(tui_glyph inbox)"
    tui_page "AGENT INBOX" "credentials an agent created for you — nothing here yet"
    printf '\n'
    printf '   %sNothing yet.%s\n\n' "$T_MUTE" "$T_RS"
    printf '   %sWhen an agent needs a credential while working a project, it generates one\n' "$T_DIM"
    printf '   into the vault and records why — it never sees or prints the value:%s\n\n' "$T_RS"
    printf '     %ssecrets record STRIPE_TEST_KEY \\\\%s\n' "$T_ACCENT" "$T_RS"
    printf '     %s  --agent claude-opus-5 --project developer-portfolio \\\\%s\n' "$T_ACCENT" "$T_RS"
    printf '     %s  --reason "checkout flow integration test"%s\n\n' "$T_ACCENT" "$T_RS"
    printf '   %sThe entry then shows up here, unread, with its full attribution.%s\n' "$T_DIM" "$T_RS"
    printf '   %sThe key name is the most anyone outside this terminal ever learns.%s\n' "$T_DIM" "$T_RS"
    ui_pause
    return 0
  fi

  local sel=0 key prev i curline host unseen
  host="$(hostname -s 2>/dev/null || echo host)"
  unseen="$(prov_unseen_count)"

  draw_msg() {
    local m="$1" on="$2" dot dotcol lead meta reason
    printf '\033[%d;1H' "${I_LINE[$m]}"
    if [ "${I_SEEN[$m]}" = "false" ]; then dot='●'; dotcol="$N_CYAN"; else dot='○'; dotcol="$T_DIM"; fi
    lead=$(( TUI_COLS - 8 - ${#I_KEY[$m]} - ${#I_AGE[$m]} - 4 ))
    [ "$lead" -lt 1 ] && lead=1
    meta="$(tui_fit "${I_AGENT[$m]} · ${I_PROJ[$m]}" $(( TUI_COLS - 10 )))"
    reason="$(tui_fit "${I_REASON[$m]}" $(( TUI_COLS - 10 )))"
    if [ "$on" = "1" ]; then
      printf '%s  %s▌%s %s%s %s%s%s ' "$T_SELBG" "$T_ACCENT" "$T_SELBG" "$dotcol" "$dot" \
        "$T_B$T_TEXT" "${I_KEY[$m]}" "$T_SELBG"
      printf '%s' "$T_LEAD"; tui_repeat '·' "$lead"
      printf '%s %s%s%s' "$T_SELBG" "$T_MUTE" "${I_AGE[$m]}" "$T_RS"
      printf '\n'
      printf '%s        %s%s%s' "$T_SELBG" "$T_DIM" "$meta" "$T_SELBG"
      tui_padn "$TUI_COLS" $(( 8 + ${#meta} )); printf '%s\n' "$T_RS"
      printf '%s        %s%s%s' "$T_SELBG" "$T_LEAD" "$reason" "$T_SELBG"
      tui_padn "$TUI_COLS" $(( 8 + ${#reason} )); printf '%s\n' "$T_RS"
    else
      printf '    %s%s %s%s%s ' "$dotcol" "$dot" "$T_MUTE" "${I_KEY[$m]}" "$T_RS"
      printf '%s' "$T_LEAD"; tui_repeat '·' "$lead"
      printf ' %s%s%s\n' "$T_DIM" "${I_AGE[$m]}" "$T_RS"
      printf '        %s%s · %s%s' "$T_LEAD" "${I_AGENT[$m]}" "${I_PROJ[$m]}" "$T_RS"
      tui_padn "$TUI_COLS" $(( 8 + ${#I_AGENT[$m]} + 3 + ${#I_PROJ[$m]} )); printf '\n'
      printf '        %s%s%s' "$T_LEAD" "${I_REASON[$m]}" "$T_RS"
      tui_padn "$TUI_COLS" $(( 8 + ${#I_REASON[$m]} )); printf '\n'
    fi
  }

  draw_inbox() {
    tui_home
    tui_header "$host" "$n credential(s) authored by agents · $unseen unread · values never left this machine" "AGENT INBOX" inbox
    curline=4
    i=0
    while [ "$i" -lt "$n" ]; do
      I_LINE[$i]="$(( curline + 1 ))"
      draw_msg "$i" "$([ "$i" = "$sel" ] && echo 1 || echo 0)"
      curline=$(( curline + 3 ))
      if [ "$i" -lt $(( n - 1 )) ]; then tui_blank; curline=$(( curline + 1 )); fi
      i=$(( i + 1 ))
    done
    local pad=$(( TUI_ROWS - curline - 2 )); [ "$pad" -lt 0 ] && pad=0
    i=0; while [ "$i" -lt "$pad" ]; do tui_blank; i=$(( i + 1 )); done
    tui_footer "↑↓ move" "↵ mark read" "c copy" "esc back"
    tui_clear_below
  }

  tui_begin
  trap 'tui_end; cleanup' EXIT INT TERM
  tui_dims; draw_inbox

  while :; do
    key="$(tui_readkey)" || break
    prev="$sel"
    case "$key" in
      up)   sel=$(( sel - 1 )); [ "$sel" -lt 0 ] && sel=$(( n - 1 )) ;;
      down) sel=$(( sel + 1 )); [ "$sel" -ge "$n" ] && sel=0 ;;
      enter|right)
        prov_set "${I_KEY[$sel]}" seen "true"; I_SEEN[$sel]="true"
        unseen="$(prov_unseen_count)"
        tui_dims; draw_inbox; continue ;;
      char:c)
        tui_end; api_copy "${I_KEY[$sel]}"; ui_pause
        tui_begin; tui_dims; draw_inbox; continue ;;
      quit|esc) break ;;
      *) continue ;;
    esac
    draw_msg "$prev" 0; draw_msg "$sel" 1
  done
  tui_end
  trap 'cleanup' EXIT INT TERM
  return 0
}
