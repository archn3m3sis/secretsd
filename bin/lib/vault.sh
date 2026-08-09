#!/usr/bin/env bash
# lib/vault.sh — vault (encrypted database) selection and lifecycle.
#
# The screen you land on before any module. Pick which SOPS database to work
# with, create a new one, choose exactly which hosts can decrypt it, and set its
# backup policy. Every encrypted database is a separate trust boundary — that is
# the whole point of having more than one, and why recipients are chosen per
# vault rather than inherited blindly from the default creation rule.
#
# Vault METADATA (labels, backup policy) lives in secrets/VAULTS.yaml in plain
# text. It holds no secret values, so you can read your storage and backup
# posture without decrypting anything.
#
# Sourced, never executed.

SEC_VAULTS="$SEC_SECRETS/VAULTS.yaml"
: "${SEC_BACKUP_DIR:=$HOME/.local/share/secrets-backups}"

# --- discovery ----------------------------------------------------------------
# vault_paths — every SOPS database this layer knows about, one path per line
vault_paths() {
  local f
  for f in "$SEC_SECRETS"/*.enc.env "$SEC_SECRETS"/*.enc.yaml "$SEC_SECRETS"/*.enc.json \
           "$SEC_ENC_DIR"/*.enc.env "$SEC_ENC_DIR"/*.enc.yaml "$SEC_ENC_DIR"/*.enc.json; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done
}

vault_name() { printf '%s' "$(basename "$1")"; }

# vault_can_decrypt PATH -> 0 if this host holds a usable key
vault_can_decrypt() { sops exec-env "$1" 'true' >/dev/null 2>&1; }

# vault_mtime PATH -> human-ish age
vault_mtime() {
  local t now d
  t="$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null)"
  [ -n "$t" ] || { printf 'unknown'; return; }
  now="$(date +%s)"; d=$(( now - t ))
  if   [ "$d" -lt 60 ];    then printf 'just now'
  elif [ "$d" -lt 3600 ];  then printf '%dm ago' $(( d / 60 ))
  elif [ "$d" -lt 86400 ]; then printf '%dh ago' $(( d / 3600 ))
  else printf '%dd ago' $(( d / 86400 )); fi
}

vault_size() {
  local b; b="$(stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null)"
  [ -n "$b" ] || { printf '?'; return; }
  if [ "$b" -lt 1024 ]; then printf '%sB' "$b"; else printf '%sK' $(( b / 1024 )); fi
}

# --- host <-> recipient mapping, read from .sops.yaml -------------------------
# The creation rule carries a `# recipients: hostA · hostB · ...` comment listing
# the hosts in the SAME order as the age keys beneath it. Pair them positionally.
vault_hosts() {   # -> "host|agekey" per line
  local cfg="$SEC_ROOT/.sops.yaml" names keys i host key
  [ -f "$cfg" ] || return 0
  names="$(grep -m1 '# recipients:' "$cfg" | sed 's/.*# recipients: *//')"
  keys="$(grep -oE 'age1[0-9a-z]{50,}' "$cfg")"
  i=1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    host="$(printf '%s' "$names" | awk -F' · ' -v n="$i" '{print $n}')"
    [ -n "$host" ] || host="recipient-$i"
    printf '%s|%s\n' "$host" "$key"
    i=$(( i + 1 ))
  done <<EOF
$keys
EOF
}

# vault_recipient_hosts PATH -> host names that can decrypt this file
vault_recipient_hosts() {
  local onfile host key
  onfile="$(sec_file_recipients "$1")"
  while IFS='|' read -r host key; do
    [ -n "$key" ] || continue
    printf '%s\n' "$onfile" | grep -qx "$key" && printf '%s\n' "$host"
  done <<EOF
$(vault_hosts)
EOF
}

# --- metadata (plaintext, no secret values) -----------------------------------
vault_meta() {   # $1 vault basename  $2 field -> value
  [ -f "$SEC_VAULTS" ] || return 0
  awk -v v="$1" -v want="$2" '
    /^[^[:space:]#][^:]*:[[:space:]]*$/ { k=$0; sub(/:[[:space:]]*$/,"",k); next }
    k == v && $1 == want":" { $1=""; sub(/^[[:space:]]+/,""); sub(/[[:space:]]+$/,""); print; exit }
  ' "$SEC_VAULTS"
}

vault_meta_set() {   # $1 vault  $2 field  $3 value
  local v="$1" f="$2" val="$3" tmp="$TMPD/vaults.yaml"
  touch "$SEC_VAULTS"
  if ! grep -qE "^$v:" "$SEC_VAULTS" 2>/dev/null; then
    { echo "$v:"; echo "  $f: $val"; echo ""; } >> "$SEC_VAULTS"
    return 0
  fi
  if awk -v v="$v" -v f="$f" '
       /^[^[:space:]#][^:]*:[[:space:]]*$/ { k=$0; sub(/:[[:space:]]*$/,"",k) }
       k == v && $1 == f":" { found=1 }
       END { exit !found }' "$SEC_VAULTS"; then
    awk -v v="$v" -v f="$f" -v val="$val" '
      /^[^[:space:]#][^:]*:[[:space:]]*$/ { k=$0; sub(/:[[:space:]]*$/,"",k) }
      (k == v && $1 == f":") { print "  " f ": " val; next }
      { print }' "$SEC_VAULTS" > "$tmp" && cat "$tmp" > "$SEC_VAULTS"
  else
    awk -v v="$v" -v f="$f" -v val="$val" '
      { print }
      $0 == v":" { print "  " f ": " val }' "$SEC_VAULTS" > "$tmp" && cat "$tmp" > "$SEC_VAULTS"
  fi
}

# --- backup -------------------------------------------------------------------
# Encrypted blobs are safe to copy anywhere — the age recipients still gate them.
vault_backup_run() {   # $1 vault path
  local path="$1" name dest keep stamp out n
  name="$(vault_name "$path")"
  dest="$(vault_meta "$name" backup_dest)"; [ -n "$dest" ] || dest="$SEC_BACKUP_DIR"
  keep="$(vault_meta "$name" backup_keep)"; case "$keep" in ''|*[!0-9]*) keep=14 ;; esac

  mkdir -p "$dest" 2>/dev/null || { ui_err "cannot create $dest"; return 1; }
  stamp="$(date +%Y%m%d-%H%M%S)"
  out="$dest/${name}.${stamp}.bak"

  ui_info "copying $name -> $out"
  cp -p "$path" "$out" || { ui_err "backup failed"; return 1; }

  # PROVE it: the copy must be byte-identical and must still decrypt
  if cmp -s "$path" "$out"; then ui_ok "byte-identical copy verified"
  else ui_err "copy differs from source — backup NOT trustworthy"; rm -f "$out"; return 1; fi
  if vault_can_decrypt "$out"; then ui_ok "backup decrypts on this host"
  else ui_warn "backup does not decrypt here (expected if you hold no key for it)"; fi

  # retention
  n="$(ls -1t "$dest/${name}."*.bak 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${n:-0}" -gt "$keep" ]; then
    ls -1t "$dest/${name}."*.bak 2>/dev/null | tail -n +"$(( keep + 1 ))" | while IFS= read -r old; do
      rm -f "$old"; ui_info "pruned $(basename "$old")"
    done
  fi
  vault_meta_set "$name" backup_last "$(date -u +%FT%TZ)"
  n="$(ls -1 "$dest/${name}."*.bak 2>/dev/null | wc -l | tr -d ' ')"
  ui_ok "$n backup(s) retained in $dest (keep $keep)"
  sec_log_start "backup"; sec_log "backup $name -> $out"
  return 0
}

# --- creation -----------------------------------------------------------------
vault_create() {
  tui_page "NEW VAULT" "create an encrypted database and choose who can open it"

  local name kind path
  name="$(ui_ask 'Vault name' 'e.g. certs, logins, pii')" || return 1
  [ -n "$name" ] || { ui_warn "cancelled"; return 1; }
  printf '%s' "$name" | grep -qE '^[a-z][a-z0-9-]*$' || {
    ui_err "use lowercase letters, digits and hyphens (it becomes a filename)"; return 1; }

  kind="$(ui_choose 'Storage format' \
    'dotenv  — flat KEY=value, best for tokens and API keys' \
    'yaml    — structured records, best for people, hosts, certificates')" || return 1
  case "$kind" in
    dotenv*) path="$SEC_ENC_DIR/${name}.enc.env" ;;
    *)       path="$SEC_ENC_DIR/${name}.enc.yaml" ;;
  esac

  if [ -e "$path" ]; then ui_err "already exists: $path"; return 1; fi

  # --- recipients: who can decrypt this vault --------------------------------
  ui_rule "Who may decrypt this vault"
  ui_note "Each host you include can open it independently. Include only what you must."
  local picked hosts sel keys=""
  hosts="$(vault_hosts | awk -F'|' '{printf "%-22s %s\n", $1, substr($2,1,18)"…"}')"
  [ -n "$hosts" ] || { ui_err "no recipients found in .sops.yaml"; return 1; }
  picked="$(printf '%s\n' "$hosts" | ui_filter_multi 'tab to mark hosts · enter to confirm')" || return 1
  [ -n "$picked" ] || { ui_warn "no hosts selected — nothing created"; return 1; }

  while IFS= read -r sel; do
    [ -n "$sel" ] || continue
    sel="${sel%% *}"
    local k; k="$(vault_hosts | awk -F'|' -v h="$sel" '$1==h {print $2}')"
    [ -n "$k" ] && keys="$keys,$k"
  done <<EOF
$picked
EOF
  keys="${keys#,}"
  [ -n "$keys" ] || { ui_err "could not resolve any age keys"; return 1; }

  local nrec; nrec="$(printf '%s' "$keys" | tr ',' '\n' | grep -c .)"
  ui_info "$nrec recipient(s) selected"

  # --- create, encrypt, verify ------------------------------------------------
  mkdir -p "$(dirname "$path")"
  local seed="$TMPD/seed.${path##*.}"
  case "$path" in
    *.enc.env)  printf 'SOPS_SELFTEST=ok\n' > "$seed" ;;
    *)          printf 'SOPS_SELFTEST: ok\n' > "$seed" ;;
  esac

  ui_info "encrypting to $nrec recipient(s) ..."
  if ! sops --encrypt --age "$keys" "$seed" > "$path" 2>>"${SEC_LOG:-/dev/null}"; then
    rm -f "$path"; ui_err "sops could not create the vault — see the run log"; return 1
  fi
  chmod 600 "$path"
  rm -f "$seed"

  # PROVE it decrypts and PROVE the recipients are the ones we asked for
  if vault_can_decrypt "$path"; then ui_ok "vault decrypts on this host"
  else ui_warn "vault created but this host cannot decrypt it (correct if you excluded yourself)"; fi
  local onfile; onfile="$(sec_file_recipients "$path" | grep -c .)"
  if [ "$onfile" = "$nrec" ]; then ui_ok "$onfile recipient(s) recorded on the file — matches your selection"
  else ui_err "file carries $onfile recipient(s) but $nrec were selected"; fi

  # --- pin the recipients so future edits cannot silently re-key --------------
  vault_pin_rule "$path" "$keys"

  vault_meta_set "$(vault_name "$path")" created "$(date +%F)"
  vault_meta_set "$(vault_name "$path")" backup_dest "$SEC_BACKUP_DIR"
  vault_meta_set "$(vault_name "$path")" backup_keep "14"

  sec_log_start "vault"; sec_log "created vault $path with $nrec recipients"
  ui_ok "created $path"
  ui_pause
}

# vault_pin_rule PATH KEYS — add a .sops.yaml creation rule for this exact file,
# so `sops <file>` re-encrypts to the SAME recipients instead of falling through
# to the catch-all rule and silently widening who can read it.
vault_pin_rule() {
  local path="$1" keys="$2" rel cfg="$SEC_ROOT/.sops.yaml"
  rel="${path#$SEC_ROOT/}"
  local esc; esc="$(printf '%s' "$rel" | sed 's/\./\\./g; s/\//[\\\\\/]/g')"
  if grep -qF "$rel" "$cfg" 2>/dev/null; then ui_info "creation rule already present"; return 0; fi
  cp -p "$cfg" "$cfg.bak-$(date +%Y%m%d-%H%M%S)"
  local tmp="$TMPD/sops.yaml"
  awk -v pat="$esc" -v keys="$keys" '
    /^creation_rules:/ && !done {
      print
      print "  # pinned by `secrets` — this vault has its own recipient set"
      print "  - path_regex: " pat "$"
      print "    age: " keys
      done=1; next
    }
    { print }
  ' "$cfg" > "$tmp" && cat "$tmp" > "$cfg"
  if grep -qF "$rel" "$cfg"; then ui_ok "pinned recipients in .sops.yaml (rule placed before the catch-all)"
  else ui_err "could not pin the creation rule — edit .sops.yaml by hand"; fi
}

# --- encryption panel ---------------------------------------------------------
vault_encryption() {
  local path="$1" name; name="$(vault_name "$path")"
  local act
  while :; do
    TUI_MENU_ICON=""
    act="$(tui_menu "ENCRYPTION · $name" \
      "$(sec_file_recipients "$path" | sec_nlines) age recipient(s) · SOPS + age" \
      "Re-key to .sops.yaml|rewrite key material to the declared recipients; values unchanged" \
      "Verify this host can decrypt|prove the age key here still opens it" \
      "Show who can open it|hosts with a key on this file, and hosts without" \
      "Back|return to the vault list")" || break
    case "$act" in
      "Re-key"*)
        ui_warn "this rewrites the file's key material; the secret values are unchanged"
        ui_confirm "Run sops updatekeys on $name?" || continue
        sec_log_start "rekey"; sec_log "updatekeys $path"
        if sops updatekeys -y "$path"; then
          ui_ok "re-keyed"
          if vault_can_decrypt "$path"; then ui_ok "still decrypts on this host"
          else ui_err "THIS HOST CAN NO LONGER DECRYPT IT"; fi
        else ui_err "updatekeys failed"; fi
        ui_pause ;;
      "Verify"*)
        tui_page "VERIFY · $name" "can this host open it?"
        if vault_can_decrypt "$path"; then ui_ok "decrypts OK on $(hostname -s)"
        else ui_err "cannot decrypt on $(hostname -s)"; fi
        ui_pause ;;
      "Show who"*)
        tui_page "RECIPIENTS · $name" "$path"
        printf '   %sCAN OPEN%s\n' "$T_B$T_OK" "$T_RS"
        vault_recipient_hosts "$path" | sed "s/^/      · /"
        printf '\n   %sCANNOT%s\n' "$T_B$T_DIM" "$T_RS"
        comm -23 <(vault_hosts | cut -d"|" -f1 | sort) <(vault_recipient_hosts "$path" | sort) | sed "s/^/      · /"
        printf '\n   %sthat asymmetry IS the trust boundary — it is not a fault%s\n' "$T_DIM" "$T_RS"
        ui_pause ;;
      *) break ;;
    esac
  done
}

# --- backup panel -------------------------------------------------------------
vault_backup_panel() {
  local path="$1" name; name="$(vault_name "$path")"
  local act dest keep last n
  while :; do
    dest="$(vault_meta "$name" backup_dest)"; [ -n "$dest" ] || dest="$SEC_BACKUP_DIR"
    keep="$(vault_meta "$name" backup_keep)"; [ -n "$keep" ] || keep=14
    last="$(vault_meta "$name" backup_last)"; [ -n "$last" ] || last="never"
    n="$(ls -1 "$dest/${name}."*.bak 2>/dev/null | wc -l | tr -d ' ')"

    TUI_MENU_ICON=""
    act="$(tui_menu "BACKUP · $name" \
      "$dest · keep $keep · last $last · ${n:-0} on disk" \
      "Back up now|copy, verify byte-identical, confirm it still decrypts, prune" \
      "Change destination|where copies are written" \
      "Change retention|how many copies are kept" \
      "List backups|what is on disk right now" \
      "Back|return to the vault list")" || break
    case "$act" in
      "Back up now")      tui_page "BACKUP · $name" "$dest"; vault_backup_run "$path"; ui_pause ;;
      "Change destination")
        local d; d="$(ui_ask 'Backup directory' "$dest")" || continue
        [ -n "$d" ] && { vault_meta_set "$name" backup_dest "$d"; ui_ok "destination set to $d"; }
        ui_pause ;;
      "Change retention")
        local k; k="$(ui_ask 'Copies to keep' "$keep")" || continue
        case "$k" in ''|*[!0-9]*) ui_err "must be a number" ;; *) vault_meta_set "$name" backup_keep "$k"; ui_ok "retention set to $k" ;; esac
        ui_pause ;;
      "List backups")
        tui_page "BACKUPS · $name" "$dest"
        ls -1lt "$dest/${name}."*.bak 2>/dev/null | sed 's/^/   /' || ui_info "none yet"
        ui_pause ;;
      *) break ;;
    esac
  done
}
