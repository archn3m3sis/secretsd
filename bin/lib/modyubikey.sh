#!/usr/bin/env bash
# lib/modyubikey.sh — YubiKey, wrapped.
#
# A hardware token is the one place a secret can live that a compromised host
# cannot read. This module wraps `ykman` so the good parts are one keystroke:
#
#   · list attached keys, firmware, form factor, enabled applications
#   · OATH accounts on the key, and a code copied to the clipboard in one stroke
#   · PIV slots and the certificates in them, with expiry parsed from the cert
#   · FIDO2 credential count and PIN state
#   · MOVE a TOTP seed OUT of the vault and ONTO the key — after which the seed
#     exists only in hardware and is deleted from the encrypted store
#
# The seed only ever passes from the vault to `ykman` inside one child process.
# It is never printed, never written to disk, and the vault copy is removed only
# after the key is re-read and confirmed to hold the account.
#
# Sourced, never executed.

yk_have() { command -v ykman >/dev/null 2>&1; }

yk_list() {   # -> one line per attached key
  yk_have || return 1
  ykman list 2>/dev/null
}
yk_present() { [ -n "$(yk_list)" ]; }

yk_info_field() {   # $1 label prefix from `ykman info`
  ykman info 2>/dev/null | awk -F: -v k="$1" 'index($0,k)==1 {sub(/^[^:]*: */,""); print; exit}'
}

yk_oath_accounts() { ykman oath accounts list 2>/dev/null; }

# yk_oath_code NAME -> the current code only
yk_oath_code() { ykman oath accounts code -s "$1" 2>/dev/null | tr -d ' \n'; }

yk_piv_slots() {
  ykman piv info 2>/dev/null | awk '
    /^Slot [0-9a-fA-F]+/ { slot=$2; sub(/:$/,"",slot); next }
    /Subject DN:/ { sub(/^[[:space:]]*Subject DN:[[:space:]]*/,""); if (slot!="") print slot "|" $0; slot="" }
  '
}

yk_fido_info() { ykman fido info 2>/dev/null; }

yubikey_screen() {
  ui_interactive || { ui_needs_tty yubikey; return 1; }

  if ! yk_have; then
    tui_page "YUBIKEY" "ykman is not installed"
    printf '\n'
    ui_err "the YubiKey Manager CLI is missing"
    ui_note "install it, then this module lights up:"
    printf '\n     %sbrew install ykman%s\n\n' "$T_ACCENT" "$T_RS"
    ui_pause; return 0
  fi

  ui_clear; printf '\n  '; tui_grad_violet 'looking for a YubiKey…'; printf '\n'

  if ! yk_present; then
    tui_page "YUBIKEY" "ykman $(ykman --version 2>/dev/null | awk '{print $NF}') · no key attached"
    printf '\n'
    ui_warn "no YubiKey is plugged in right now"
    ui_note "Plug one in and press enter. Nothing here reads the key until you do."
    printf '\n'
    tui_section "WHAT THIS MODULE DOES"
    printf '   %s· list attached keys, firmware and enabled applications%s\n' "$T_DIM" "$T_RS"
    printf '   %s· show OATH accounts and copy a code in one keystroke%s\n' "$T_DIM" "$T_RS"
    printf '   %s· show PIV slots and parse certificate expiry from the cert%s\n' "$T_DIM" "$T_RS"
    printf '   %s· move a TOTP seed out of the vault and onto the hardware%s\n' "$T_DIM" "$T_RS"
    ui_pause
    yk_present || return 0
  fi

  local -a A_NAME A_LINE
  local n=0 a
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    A_NAME[$n]="$a"; n=$(( n + 1 ))
  done <<OATH
$(yk_oath_accounts)
OATH

  local sel=0 key prev curline host dev fw serial
  host="$(hostname -s 2>/dev/null || echo host)"
  dev="$(yk_list | head -1)"
  serial="$(yk_info_field 'Serial number')"
  fw="$(yk_info_field 'Firmware version')"

  draw_acct() {
    local k="$1" on="$2"
    printf '\033[%d;1H' "${A_LINE[$k]}"
    tui_modrow "$on" '⣰⣉⣉⣆' "$N_AMBER" "$(tui_fit "${A_NAME[$k]}" 44)" "" ok "on hardware"
    tui_moddesc "$on" "press c for a code — the seed never leaves the key"
  }

  draw_yk() {
    tui_home
    tui_header "$host" "$(tui_fit "$dev" 60) · serial $serial · firmware $fw"
    curline=4
    if [ "$n" -eq 0 ]; then
      printf '  %sno OATH accounts on this key%s' "$T_DIM" "$T_RS"
      tui_padn "$TUI_COLS" 32; printf '\n'
      printf '  %spress m to move a TOTP seed from the vault onto the hardware%s' "$T_DIM" "$T_RS"
      tui_padn "$TUI_COLS" 62; printf '\n'
      curline=$(( curline + 2 ))
    else
      local i=0
      while [ "$i" -lt "$n" ]; do
        A_LINE[$i]="$(( curline + 1 ))"
        draw_acct "$i" "$([ "$i" = "$sel" ] && echo 1 || echo 0)"
        curline=$(( curline + 2 ))
        [ "$i" -lt $(( n - 1 )) ] && { tui_blank; curline=$(( curline + 1 )); }
        i=$(( i + 1 ))
      done
    fi
    local pad=$(( TUI_ROWS - curline - 2 )); [ "$pad" -lt 0 ] && pad=0
    local g=0; while [ "$g" -lt "$pad" ]; do tui_blank; g=$(( g + 1 )); done
    tui_footer "↑↓ move" "c code→clipboard" "m move seed here" "p PIV" "i info" "esc back"
    tui_clear_below
  }

  tui_begin
  trap 'tui_end; cleanup' EXIT INT TERM
  tui_dims; draw_yk

  while :; do
    key="$(tui_readkey)" || break
    prev="$sel"
    case "$key" in
      up)   [ "$n" -gt 0 ] && { sel=$(( sel - 1 )); [ "$sel" -lt 0 ] && sel=$(( n - 1 )); } ;;
      down) [ "$n" -gt 0 ] && { sel=$(( sel + 1 )); [ "$sel" -ge "$n" ] && sel=0; } ;;

      char:c)
        [ "$n" -gt 0 ] || continue
        tui_end
        tui_page "CODE · ${A_NAME[$sel]}" "generated on the key, not on this host"
        ui_info "touch the key if it is configured to require it…"
        local code; code="$(yk_oath_code "${A_NAME[$sel]}")"
        if [ -n "$code" ]; then
          printf '\n    '; tui_grad_violet "$code"; printf '\n\n'
          printf '%s' "$code" | pbcopy 2>/dev/null
          SEC_CLIP_HASH="$(printf '%s' "$code" | shasum -a 256 | cut -d' ' -f1)"
          tui_kv "valid for" "$(gen_totp_remaining) seconds"
          printf '    %svalidity%s  ' "$T_MUTE" "$T_RS"; tui_meter "$(gen_totp_remaining)" 30 30; printf '\n\n'
          ui_ok "copied — cleared on exit"
          unset code
        else
          ui_err "no code returned (touch timeout, or the account needs a password)"
        fi
        ui_pause
        tui_begin; tui_dims; draw_yk; continue ;;

      char:m)
        tui_end
        tui_page "MOVE A SEED TO HARDWARE" "after this the seed exists only on the key"
        ui_note "Pick a credential from the vault whose value is a base32 TOTP seed."
        printf '\n'
        local src; src="$(sec_names | ui_filter 'vault key holding a TOTP seed')" || { tui_begin; tui_dims; draw_yk; continue; }
        [ -n "$src" ] || { tui_begin; tui_dims; draw_yk; continue; }
        local label; label="$(ui_ask 'Account name on the key' "$src")"
        [ -n "$label" ] || label="$src"
        printf '\n'
        ui_warn "This writes the seed to the YubiKey, verifies it landed, and only"
        ui_warn "then deletes it from the vault. If verification fails, nothing is deleted."
        printf '\n'
        if ui_confirm "Move '$src' onto the key as '$label'?"; then
          # the seed goes vault -> ykman inside ONE child. It never reaches this shell.
          local mv="$TMPD/ykmove.sh"
          cat > "$mv" <<'YKM'
seed="$(eval "printf '%s' \"\${$YK_SRC}\"")"
[ -n "$seed" ] || exit 3
printf '%s' "$seed" | ykman oath accounts add -t "$YK_LABEL" - >/dev/null 2>&1 || exit 4
YKM
          if YK_SRC="$src" YK_LABEL="$label" "$SEC_SELF" run --only "$src" -- bash "$mv"; then
            if yk_oath_accounts | grep -qF "$label"; then
              ui_ok "verified: '$label' is now on the key"
              if ui_confirm "Delete the vault copy of '$src' now?"; then
                sec_unset "$src" && ui_ok "removed from the vault — the seed is hardware-only"
                sec_log_start yubikey; sec_log "moved $src to yubikey as $label"
              else
                ui_info "vault copy kept — the seed now exists in two places"
              fi
            else
              ui_err "the key does not list '$label' — vault copy left untouched"
            fi
          else
            ui_err "ykman refused the seed (is it valid base32?) — nothing was deleted"
          fi
          rm -f "$mv"
        else ui_info "nothing moved"; fi
        ui_pause
        # reload accounts
        n=0
        while IFS= read -r a; do [ -n "$a" ] && { A_NAME[$n]="$a"; n=$(( n + 1 )); }; done <<OATH2
$(yk_oath_accounts)
OATH2
        sel=0
        tui_begin; tui_dims; draw_yk; continue ;;

      char:p)
        tui_end
        tui_page "PIV SLOTS" "certificates held on the key"
        local slots; slots="$(yk_piv_slots)"
        if [ -n "$slots" ]; then
          printf '%s\n' "$slots" | while IFS='|' read -r sl dn; do
            tui_kv "slot $sl" "$(tui_fit "$dn" $(( TUI_COLS - 24 )))"
          done
        else
          ui_info "no certificates in any PIV slot"
        fi
        printf '\n'
        ui_note "full detail:  ykman piv info"
        ui_pause
        tui_begin; tui_dims; draw_yk; continue ;;

      char:i)
        tui_end
        tui_page "KEY INFO" "$dev"
        ykman info 2>/dev/null | sed 's/^/    /'
        printf '\n'
        tui_section "FIDO2"
        yk_fido_info 2>/dev/null | sed 's/^/    /' || printf '    %snot available%s\n' "$T_DIM" "$T_RS"
        ui_pause
        tui_begin; tui_dims; draw_yk; continue ;;

      quit|esc) break ;;
      *) continue ;;
    esac
    [ "$n" -gt 0 ] && { draw_acct "$prev" 0; draw_acct "$sel" 1; }
  done
  tui_end
  trap 'cleanup' EXIT INT TERM
  return 0
}
