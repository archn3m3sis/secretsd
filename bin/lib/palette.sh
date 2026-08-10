#!/usr/bin/env bash
# lib/palette.sh — the command palette: one key, everything.
#
# `/` anywhere on the home screen opens a single fuzzy field that searches
# EVERY module at once — credential names, SSH keys, configured hosts,
# certificates, auth/environment/login/PII record ids, projects, named sessions,
# vaults — plus the verbs (rotate, copy, backup, probe, launch…).
#
# Results are typed. Choosing one does the obvious thing for that type rather
# than dumping you at the top of a module: a credential opens its actions, a host
# opens its detail, a project offers a launch, a verb runs.
#
# NOTHING SECRET IS SEARCHED OR SHOWN. The index is built from names, ids, hosts
# and paths only — never from a decrypted value.
#
# Sourced, never executed.

# pal_index -> "TYPE|LABEL|CONTEXT|TARGET"
pal_index() {
  local x

  # credentials — names only
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    printf 'cred|%s|%s|%s\n' "$x" "$(sec_manifest_field "$x" provider | sed 's/^TODO$/undocumented/')" "$x"
  done <<PI1
$(sec_names)
PI1

  # ssh keys
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    printf 'key|%s|%s|%s\n' "$(basename "$x")" "$(keys_hosts_using "$x" | cut -c1-40)" "$x"
  done <<PI2
$(keys_private_paths)
PI2

  # configured hosts
  while IFS='|' read -r a hn u p i; do
    [ -n "$a" ] || continue
    printf 'host|%s|%s|%s\n' "$a" "${hn:-$a}" "$a"
  done <<PI3
$(mach_hosts)
PI3

  # certificates
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    local d; d="$(certs_days_left "$x" 2>/dev/null)" || continue
    printf 'cert|%s|%s days left|%s\n' "$(certs_field "$x" cn | cut -c1-46)" "$d" "$x"
  done <<PI4
$(certs_find 2>/dev/null | head -40)
PI4

  # records across the four record modules
  local mod file
  for mod in auth:$SEC_DIR_DIR/authmap.yaml env:$SEC_DIR_DIR/environments.yaml \
             logins:$SEC_ENC_DIR/logins.enc.yaml pii:$SEC_ENC_DIR/pii.enc.yaml; do
    file="${mod#*:}"; mod="${mod%%:*}"
    [ -e "$file" ] || continue
    while IFS= read -r x; do
      [ -n "$x" ] || continue
      printf '%s|%s|%s record|%s\n' "$mod" "$x" "$mod" "$x"
    done <<PI5
$(rec_ids "$file")
PI5
  done

  # projects
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    printf 'proj|%s|%s|%s\n' "$(basename "$x")" "${x/#$HOME/~}" "$x"
  done <<PI6
$(ws_discover 2>/dev/null | sort -u)
PI6

  # named sessions
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    printf 'sess|%s|%s|%s\n' "$(ws_session_field "$x" name)" "$(ws_session_field "$x" project)" "$x"
  done <<PI7
$(ws_session_ids)
PI7

  # vaults
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    printf 'vault|%s|%s|%s\n' "$(vault_name "$x")" "$(sec_file_recipients "$x" | sec_nlines) recipients" "$x"
  done <<PI8
$(vault_paths)
PI8

  # verbs — the things you do, not the things you have
  printf 'verb|add a credential|store a new secret|add\n'
  printf 'verb|generate a password|strong random value, straight into the vault|gen\n'
  printf 'verb|rotate a credential|guided replacement + date stamp|rotate\n'
  printf 'verb|run posture scan|find common exposures on this host|posture\n'
  printf 'verb|run doctor|full health check of the store|doctor\n'
  printf 'verb|back up a vault|copy, verify, prune|backup\n'
  printf 'verb|probe all hosts|TCP reachability, never authenticates|probe\n'
  printf 'verb|launch Claude Code|named session in a project|launch\n'
  printf 'verb|prune run logs|keep the 400 newest|prune\n'
}

pal_type_glyph() {
  case "$1" in
    cred)  printf '%s⠭⠪⠅%s' "$N_CYAN" "$T_RS" ;;
    key)   printf '%s⠺⢽⣂%s' "$N_AMBER" "$T_RS" ;;
    host)  printf '%s⠯⣭⠽%s' "$N_GREEN" "$T_RS" ;;
    cert)  printf '%s⠺⣭⠗%s' "$N_ORANGE" "$T_RS" ;;
    proj)  printf '%s⠽⢂⣒%s' "$N_GREEN" "$T_RS" ;;
    sess)  printf '%s⡗⠦⢄%s' "$N_BLUE" "$T_RS" ;;
    vault) printf '%s⣿⣿⣿%s' "$N_CYAN" "$T_RS" ;;
    verb)  printf '%s⡇⡇⡇%s' "$T_ACCENT" "$T_RS" ;;
    *)     printf '%s⣠⣿⣄%s' "$N_MAGENTA" "$T_RS" ;;
  esac
}

# --- the palette --------------------------------------------------------------
palette_screen() {
  ui_interactive || { ui_needs_tty find "secretsd names             list every credential name"; return 1; }
  local idx pick type label ctx target

  ui_clear
  printf '\n  '; tui_grad_violet 'indexing everything…'; printf '\n'
  idx="$(pal_index 2>/dev/null)"
  [ -n "$idx" ] || { ui_err "nothing to index"; ui_pause; return 0; }

  pick="$(printf '%s\n' "$idx" \
    | awk -F'|' '{printf "%-7s %-42s %s\n", $1, $2, $3}' \
    | ui_filter "$(printf '%s items · type to narrow' "$(printf '%s\n' "$idx" | sec_nlines)")")" || return 0
  [ -n "$pick" ] || return 0

  type="$(printf '%s' "$pick" | awk '{print $1}')"
  label="$(printf '%s' "$pick" | cut -c9- | sed 's/  *$//' | awk '{$1=$1};1')"
  # resolve back to the original row to recover the exact target
  target="$(printf '%s\n' "$idx" | awk -F'|' -v t="$type" -v l="$label" \
             '$1==t && index(l, $2)==1 {print $4; exit}')"
  [ -n "$target" ] || target="$(printf '%s\n' "$idx" | awk -F'|' -v t="$type" '$1==t {print $4; exit}')"

  case "$type" in
    cred)  key_actions "$target" ;;
    key)   tui_page "KEY · $(basename "$target")" "$target"
           tui_kv "fingerprint" "$(keys_fp "$target")"
           tui_kv "used by"     "$(keys_hosts_using "$target" || echo nothing)"
           if keys_has_passphrase "$target"; then tui_kv passphrase protected "$T_OK"
           else tui_kv passphrase "NONE" "$T_ERR"; fi
           ui_pause ;;
    host)  tui_page "HOST · $target" "from ~/.ssh/config"
           mach_hosts | awk -F'|' -v a="$target" '$1==a {
             printf "    hostname %s\n    user %s\n    port %s\n    key %s\n", $2,$3,$4,$5 }'
           printf '\n'
           if ui_confirm "Probe $target now (TCP only)?"; then
             local hn pt
             hn="$(mach_hosts | awk -F'|' -v a="$target" '$1==a {print ($2==""?$1:$2)}')"
             pt="$(mach_hosts | awk -F'|' -v a="$target" '$1==a {print ($4==""?22:$4)}')"
             mach_reachable "$hn" "$pt" && ui_ok "reachable" || ui_warn "no answer"
           fi
           ui_pause ;;
    cert)  tui_page "CERTIFICATE" "$target"
           tui_kv "subject" "$(tui_fit "$(certs_field "$target" subject)" $(( TUI_COLS - 24 )))"
           tui_kv "expires" "$(certs_field "$target" notAfter)"
           tui_kv "days left" "$(certs_days_left "$target")"
           ui_pause ;;
    proj)  tui_page "PROJECT · $(basename "$target")" "$target"
           ui_confirm "Launch a named Claude Code session here?" \
             && ws_launch_clean "$target" "$(basename "$target")" || ui_pause ;;
    sess)  tui_page "SESSION · $(ws_session_field "$target" name)" "$(ws_session_field "$target" project)"
           tui_kv "id" "$target"
           tui_kv "transcript" "$(tui_fit "$(ws_session_field "$target" transcript)" $(( TUI_COLS - 24 )))"
           local sp; sp="$(ws_session_field "$target" path)"
           if [ -d "$sp" ] && ui_confirm "Resume it?"; then ( cd "$sp" && claude --resume "$target" ); fi
           ui_pause ;;
    vault) vault_encryption "$target" ;;
    auth|env|logins|pii)
           case "$type" in
             auth)   rec_screen auth "AUTH MAPPING" "$SEC_DIR_DIR/authmap.yaml" "" "target method credential_key url notes" method ;;
             env)    env_screen ;;
             logins) logins_screen ;;
             pii)    pii_screen ;;
           esac ;;
    verb)
      case "$target" in
        add)     api_add_loop; ui_pause ;;
        gen)     gen_screen ;;
        rotate)  api_rotate ;;
        posture) posture_screen ;;
        doctor)  do_doctor; ui_pause ;;
        backup)  vault_backup_panel "$SEC_STORE" ;;
        probe)   machines_screen ;;
        launch)  ws_screen ;;
        prune)   tui_page "PRUNE LOGS" "keep the 400 newest"
                 ui_ok "pruned $(sec_log_prune 400) file(s)"; ui_pause ;;
      esac ;;
  esac
  return 0
}
