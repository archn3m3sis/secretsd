#!/usr/bin/env bash
# lib/audit.sh — the audit trail, and the keyboard map.
#
# Every mutating action in this program writes a timestamped line to run-logs/.
# That is only useful if you can read it back, so this browses it: what was done,
# when, and to which credential — by NAME, never by value.
#
# The help overlay is here too because the same principle applies: a tool with
# forty keystrokes and no map is not effortless, it is just dense.
#
# Sourced, never executed.

# --- audit --------------------------------------------------------------------
# audit_events -> "EPOCH|WHEN|KIND|DETAIL"
audit_events() {
  local f line ts kind detail
  # `ls -t` already orders files newest-first and lines within a file are
  # chronological, so ordering is free. The previous version forked `date` once
  # per log line purely to sort by an epoch it already had in order — hundreds of
  # processes to reproduce information the filesystem was handing over for nothing.
  for f in $(ls -t "$SEC_ROOT/run-logs"/secret_*.log 2>/dev/null | head -300); do
    kind="$(grep -m1 '=== ' "$f" 2>/dev/null | sed 's/.*=== //; s/ ===.*//')"
    [ -n "$kind" ] || kind=session
    tail -r "$f" 2>/dev/null | while IFS= read -r line; do
      case "$line" in *'==='*) continue ;; esac
      ts="${line%%  *}"; detail="${line#*  }"
      [ -n "$detail" ] || continue
      [ "$detail" = "$line" ] && continue
      printf '0|%s|%s|%s\n' "$ts" "$kind" "$detail"
    done
  done | head -300
}

audit_kind_colour() {
  case "$1" in
    rm|delete)        printf '%s' "$T_ERR" ;;
    add|gen|rotate)   printf '%s' "$N_GREEN" ;;
    copy)             printf '%s' "$N_AMBER" ;;
    run|launch)       printf '%s' "$N_CYAN" ;;
    rekey|posture)    printf '%s' "$N_ORANGE" ;;
    *)                printf '%s' "$T_DIM" ;;
  esac
}

audit_screen() {
  ui_interactive || { ui_needs_tty audit "secretsd logs prune [KEEP]   prune the run-log directory"; return 1; }
  local -a E_WHEN E_KIND E_DETAIL E_LINE
  local n=0 ep when kind detail

  ui_clear; printf '\n  '; tui_grad_violet 'reading the trail…'; printf '\n'

  while IFS='|' read -r ep when kind detail; do
    [ -n "$when" ] || continue
    E_WHEN[$n]="$when"; E_KIND[$n]="$kind"; E_DETAIL[$n]="$detail"
    n=$(( n + 1 ))
  done <<AUD
$(audit_events)
AUD

  if [ "$n" -eq 0 ]; then
    tui_page "AUDIT TRAIL" "nothing recorded yet"
    printf '\n'
    ui_info "Only mutating actions are logged — reads leave no trace by design."
    ui_note "Add, rotate, copy, remove, re-key, launch or back up something and it appears here."
    ui_pause; return 0
  fi

  local sel=0 key prev curline host i
  host="$(hostname -s 2>/dev/null || echo host)"

  draw_event() {
    local k="$1" on="$2" c ago
    c="$(audit_kind_colour "${E_KIND[$k]}")"
    ago="$(prov_age "${E_WHEN[$k]}")"
    printf '\033[%d;1H' "${E_LINE[$k]}"
    tui_modrow "$on" "$(tui_icon_top posture)" "$c" \
      "$(tui_fit "${E_DETAIL[$k]}" 46)" "${E_KIND[$k]}" ok "$ago"
    tui_moddesc "$on" "${E_WHEN[$k]}" "$(tui_icon_bot posture)" "$c"
  }

  draw_audit() {
    tui_home
    tui_header "$host" "$n recorded action(s) · names and verbs only, never values"
    curline=4
    local shown=0 maxrows
    maxrows=$(( (TUI_ROWS - 6) / 3 ))
    i=0
    while [ "$i" -lt "$n" ] && [ "$shown" -lt "$maxrows" ]; do
      E_LINE[$i]="$(( curline + 1 ))"
      draw_event "$i" "$([ "$i" = "$sel" ] && echo 1 || echo 0)"
      curline=$(( curline + 2 ))
      [ "$shown" -lt $(( maxrows - 1 )) ] && { tui_blank; curline=$(( curline + 1 )); }
      i=$(( i + 1 )); shown=$(( shown + 1 ))
    done
    local pad=$(( TUI_ROWS - curline - 2 )); [ "$pad" -lt 0 ] && pad=0
    i=0; while [ "$i" -lt "$pad" ]; do tui_blank; i=$(( i + 1 )); done
    tui_footer "↑↓ move" "esc back"
    tui_clear_below
  }

  tui_begin
  trap 'tui_end; cleanup' EXIT INT TERM
  tui_dims; draw_audit

  while :; do
    key="$(tui_readkey)" || break
    prev="$sel"
    case "$key" in
      up)   sel=$(( sel - 1 )); [ "$sel" -lt 0 ] && sel=0 ;;
      down) sel=$(( sel + 1 )); [ "$sel" -ge "$n" ] && sel=$(( n - 1 )) ;;
      quit|esc) break ;;
      *) continue ;;
    esac
    tui_dims; draw_audit
  done
  tui_end
  trap 'cleanup' EXIT INT TERM
  return 0
}

# --- keyboard map -------------------------------------------------------------
help_screen() {
  ui_interactive || { sec_help; return 0; }
  tui_dims
  tui_begin
  trap 'tui_end; cleanup' EXIT INT TERM
  tui_home
  tui_header "$(hostname -s)" "every keystroke in the program"

  tui_section "EVERYWHERE"
  tui_kv "↑ ↓  or  j k" "move"
  tui_kv "↵  or  →"     "open / confirm"
  tui_kv "esc  or  ←"   "back"
  tui_kv "q"            "quit"

  tui_section "HOME"
  tui_kv "/" "find anything — one field over every module"
  tui_kv "g" "generate a credential straight into the vault"

  tui_section "CREDENTIALS"
  tui_kv "c" "copy a value to the clipboard (auto-clears)"
  tui_kv "t" "TOTP code to the clipboard, seed never shown"
  tui_kv "r" "reveal one masked field"
  tui_kv "e" "edit a field"
  tui_kv "a / d" "add / delete a record"

  tui_section "KEYS · MACHINES · POSTURE"
  tui_kv "p" "protect a key with a passphrase · or probe a host"
  tui_kv "l" "load or unload a key from the ssh-agent"
  tui_kv "P" "probe every host (TCP only, never authenticates)"
  tui_kv "f" "fix the selected finding, after confirming"
  tui_kv "a" "audit summary"

  tui_section "WORKSPACE · VAULTS"
  tui_kv "↵" "launch a named Claude Code session (no secrets in it)"
  tui_kv "s" "launch scoped to one credential profile"
  tui_kv "n" "new vault · or named sessions from the workspace"
  tui_kv "e / b" "encryption · backup panel"

  local used=$(( 4 + 6 + 4 + 4 + 3 + 4 + 6 + 4 + 6 + 4 + 5 ))
  local pad=$(( TUI_ROWS - used - 2 )); [ "$pad" -lt 0 ] && pad=0
  local i=0; while [ "$i" -lt "$pad" ]; do tui_blank; i=$(( i + 1 )); done
  tui_footer "any key to go back"
  tui_clear_below
  tui_readkey >/dev/null
  tui_end
  trap 'cleanup' EXIT INT TERM
  return 0
}
