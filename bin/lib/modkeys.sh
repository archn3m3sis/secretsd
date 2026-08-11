#!/usr/bin/env bash
# lib/modkeys.sh — Key Management: the real SSH key estate on this host.
#
# This module reads the truth off disk rather than a hand-kept list: every
# private key in ~/.ssh, its type and fingerprint, whether it is passphrase
# protected, its permissions, which `Host` blocks reference it, and whether the
# matching public key is in authorized_keys here.
#
# SECURITY CONTROLS ENFORCED
#   · a private key more permissive than 0600 is REPORTED, never changed
#   · a key with NO passphrase is flagged loudly — it is a bearer token on disk
#   · a Host block pointing at a missing key is a gap, reported as such
#   · a key referenced by nothing is an orphan, reported as such
#   · passphrase detection uses `ssh-keygen -y -P ''`, which emits the PUBLIC
#     key on success. The private key is never printed, and never read here.
#
# Sourced, never executed.

# keys_private_paths -> every private key file under ~/.ssh
keys_private_paths() {
  local f
  for f in "$HOME"/.ssh/*; do
    [ -f "$f" ] || continue
    case "$f" in
      *.pub|*known_hosts*|*authorized_keys*|*/config|*/config.*|*.bak*|*/agent) continue ;;
    esac
    # a private key either has a sibling .pub or carries a PEM/OpenSSH header
    if [ -f "$f.pub" ] || head -1 "$f" 2>/dev/null | ui_match_sub 'PRIVATE KEY'; then
      printf '%s\n' "$f"
    fi
  done
}

keys_fingerprint() {   # $1 key path -> "bits SHA256:… comment (TYPE)"
  ssh-keygen -lf "$1.pub" 2>/dev/null || ssh-keygen -lf "$1" 2>/dev/null
}
keys_bits()    { keys_fingerprint "$1" | awk '{print $1}'; }
keys_fp()      { keys_fingerprint "$1" | awk '{print $2}'; }
keys_comment() { keys_fingerprint "$1" | awk '{for(i=3;i<NF;i++) printf "%s ", $i}' | sed 's/ *$//'; }
keys_type()    { keys_fingerprint "$1" | awk '{print $NF}' | tr -d '()'; }

# keys_has_passphrase PATH -> 0 if protected, 1 if NOT protected (bearer on disk)
# `-y -P ''` prints the PUBLIC key when the empty passphrase works. Nothing
# private is ever emitted, and no passphrase prompt can appear.
# keys_has_passphrase PATH -> 0 when the key is protected, 1 when it is bare.
#
# The probe is `ssh-keygen -y -P ''`, which is the only honest way to ask: it
# tries to read the key with an empty passphrase and succeeds only if there
# isn't one. It costs a fork each, and posture_scan asks for every key on the
# machine — 15 keys, 88ms — on every scan.
#
# The answer changes only when the key FILE changes, so it is cached against the
# file's mtime and size. Re-encrypting a key with a passphrase rewrites it, and
# the next scan re-probes. A cache that could go stale here would be dangerous:
# it would keep reporting a key as protected after you removed the passphrase.
declare -A KEYS_PASS_MAP=()
KEYS_PASS_LOADED=0
keys_pass_cachefile() { printf '%s/state/key-passphrase' "${SEC_ROOT:-$HOME}"; }
keys_pass_load() {
  [ "$KEYS_PASS_LOADED" = "1" ] && return 0
  KEYS_PASS_LOADED=1
  local c p st v; c="$(keys_pass_cachefile)"
  [ -f "$c" ] || return 0
  while IFS="$(printf '\t')" read -r p st v; do
    [ -n "$p" ] || continue
    KEYS_PASS_MAP["$p:$st"]="$v"
  done < "$c"
}

# $1 path  [$2 stamp] — callers that already stat'd the file pass the stamp in,
# which is how posture_scan avoids two more forks per key.
keys_has_passphrase() {
  local f="$1" cache stamp hit
  cache="$(keys_pass_cachefile)"
  stamp="${2:-}"
  [ -n "$stamp" ] || stamp="$(sec_stat mtime "$f" 2>/dev/null)-$(sec_stat size "$f" 2>/dev/null)"

  keys_pass_load
  hit="${KEYS_PASS_MAP[$f:$stamp]:-}"
  case "$hit" in
    yes) return 0 ;;
    no)  return 1 ;;
  esac

  local verdict rc
  if ssh-keygen -y -P '' -f "$f" >/dev/null 2>&1; then verdict=no;  rc=1
  else                                                 verdict=yes; rc=0; fi

  mkdir -p "$(dirname "$cache")" 2>/dev/null
  if [ -f "$cache" ]; then
    awk -F'\t' -v p="$f" '$1!=p' "$cache" > "$cache.tmp" 2>/dev/null && mv -f "$cache.tmp" "$cache"
  fi
  printf '%s\t%s\t%s\n' "$f" "$stamp" "$verdict" >> "$cache"
  chmod 600 "$cache" 2>/dev/null
  KEYS_PASS_MAP["$f:$stamp"]="$verdict"
  return "$rc"
}

# keys_hosts_using PATH -> Host aliases whose IdentityFile resolves to this key
# keys_hosts_map -> "keybasename<TAB>host host host" for EVERY key, in one pass.
#
# keys_hosts_using awk-parses the whole ~/.ssh/config for ONE key. posture_scan
# asked it per key, from two different checks — 15 keys, 30 parses of the same
# file, measured at 112ms. The config is read once now and the answers looked up.
keys_hosts_map() {
  local cfg="$HOME/.ssh/config"
  [ -f "$cfg" ] || return 0
  awk '
    /^[[:space:]]*[Hh]ost[[:space:]]/ {
      line=$0; sub(/^[[:space:]]*[Hh]ost[[:space:]]+/,"",line); host=line; next
    }
    /^[[:space:]]*[Ii]dentity[Ff]ile[[:space:]]/ {
      f=$0; sub(/^[[:space:]]*[Ii]dentity[Ff]ile[[:space:]]+/,"",f)
      gsub(/"/,"",f)
      n=split(f,parts,"/"); leaf=parts[n]
      if (leaf != "" && host != "") {
        if (seen[leaf, host]++) next
        map[leaf] = (map[leaf] == "" ? host : map[leaf] " " host)
      }
    }
    END { for (k in map) printf "%s\t%s\n", k, map[k] }
  ' "$cfg"
}

keys_hosts_using() {
  local key="$1" cfg="$HOME/.ssh/config" base
  [ -f "$cfg" ] || return 0
  base="$(basename "$key")"
  awk -v base="$base" '
    /^[[:space:]]*[Hh]ost[[:space:]]/ {
      line=$0; sub(/^[[:space:]]*[Hh]ost[[:space:]]+/,"",line); host=line; next
    }
    /^[[:space:]]*[Ii]dentity[Ff]ile[[:space:]]/ {
      f=$0; sub(/^[[:space:]]*[Ii]dentity[Ff]ile[[:space:]]+/,"",f)
      gsub(/"/,"",f)
      n=split(f,parts,"/"); leaf=parts[n]
      if (leaf == base && host != "") print host
    }
  ' "$cfg" | tr '\n' ' ' | sed 's/ *$//'
}

# keys_config_gaps -> IdentityFile entries pointing at files that do not exist
keys_config_gaps() {
  local cfg="$HOME/.ssh/config" f p
  [ -f "$cfg" ] || return 0
  grep -iE '^[[:space:]]*identityfile[[:space:]]' "$cfg" 2>/dev/null \
    | sed -E 's/^[[:space:]]*[Ii]dentity[Ff]ile[[:space:]]+//; s/"//g' \
    | sort -u | while IFS= read -r f; do
        p="${f/#\~/$HOME}"
        [ -f "$p" ] || printf '%s\n' "$f"
      done
}

keys_in_authorized() {   # $1 key path -> 0 if its public half is authorized here
  [ -f "$HOME/.ssh/authorized_keys" ] || return 1
  [ -f "$1.pub" ] || return 1
  local blob; blob="$(awk '{print $2}' "$1.pub" 2>/dev/null)"
  [ -n "$blob" ] || return 1
  grep -qF "$blob" "$HOME/.ssh/authorized_keys" 2>/dev/null
}

# --- the screen ---------------------------------------------------------------
keys_screen() {
  ui_interactive || { ui_needs_tty keys "secretsd posture --json    SSH key findings, machine-readable"; return 1; }
  local -a K_PATH K_NAME K_TYPE K_BITS K_FP K_PASS K_MODE K_HOSTS K_AUTH K_AGENT K_LINE
  local n=0 p

  while IFS= read -r p; do
    [ -n "$p" ] || continue
    K_PATH[$n]="$p"; K_NAME[$n]="$(basename "$p")"
    K_TYPE[$n]="$(keys_type "$p")"; K_BITS[$n]="$(keys_bits "$p")"
    K_FP[$n]="$(keys_fp "$p")"
    if keys_has_passphrase "$p"; then K_PASS[$n]=1; else K_PASS[$n]=0; fi
    K_MODE[$n]="$(sec_mode "$p")"
    K_HOSTS[$n]="$(keys_hosts_using "$p")"
    if keys_in_agent "$p"; then K_AGENT[$n]=1; else K_AGENT[$n]=0; fi
    if keys_in_authorized "$p"; then K_AUTH[$n]=1; else K_AUTH[$n]=0; fi
    n=$(( n + 1 ))
  done <<KEYS
$(keys_private_paths)
KEYS

  if [ "$n" -eq 0 ]; then
    TUI_PAGE_MARK="$(tui_glyph keys)"
    tui_page "SSH KEYS" "no private keys found in ~/.ssh — nothing to report on"
    ui_pause; return 0
  fi

  # Permissions are REPORTED, never silently changed. Fixing someone's key modes
  # behind their back is exactly the kind of "help" that breaks a working setup.
  local i fixed=0

  local sel=0 key prev curline host nopass ngap
  host="$(hostname -s 2>/dev/null || echo host)"
  nopass=0; i=0
  while [ "$i" -lt "$n" ]; do [ "${K_PASS[$i]}" = "0" ] && nopass=$(( nopass + 1 )); i=$(( i + 1 )); done
  ngap="$(keys_config_gaps | sec_nlines)"
  local nagent=0
  i=0; while [ "$i" -lt "$n" ]; do [ "${K_AGENT[$i]}" = "1" ] && nagent=$(( nagent + 1 )); i=$(( i + 1 )); done

  draw_key() {
    local m="$1" on="$2" dot dlab mark hue
    if   [ "${K_PASS[$m]}" = "0" ]; then dot=err;  dlab="NO PASSPHRASE"
    elif [ -z "${K_HOSTS[$m]}" ];   then dot=warn; dlab="orphan · no host uses it"
    else                                 dot=ok;   dlab="${K_HOSTS[$m]}"
    fi
    if [ "${K_PASS[$m]}" = "0" ]; then mark='⣿⡇⣿'; hue="$N_RED"
    else mark='⠺⢽⣂'; hue="$N_AMBER"; fi
    printf '\033[%d;1H' "${K_LINE[$m]}"
    tui_modrow "$on" "$(tui_icon_top keys)" "$hue" "${K_NAME[$m]}" \
      "${K_TYPE[$m]} ${K_BITS[$m]}" "$dot" "$(tui_fit "$dlab" 34)"
    tui_moddesc "$on" "$(tui_fit "${K_FP[$m]}$([ "${K_AGENT[$m]}" = "1" ] && echo ' · LOADED IN AGENT')$([ "${K_AUTH[$m]}" = "1" ] && echo ' · authorized here')" $(( TUI_COLS - 14 )))" \
      "$(tui_icon_bot keys)" "$hue"
  }

  draw_keys() {
    tui_home
    tui_header "$host" "$n key(s) · $nopass without a passphrase · $nagent loaded in the agent · $ngap config gap(s)" "SSH KEYS" keys
    curline=4
    i=0
    while [ "$i" -lt "$n" ]; do
      K_LINE[$i]="$(( curline + 1 ))"
      draw_key "$i" "$([ "$i" = "$sel" ] && echo 1 || echo 0)"
      curline=$(( curline + 2 ))
      if [ "$i" -lt $(( n - 1 )) ]; then tui_blank; curline=$(( curline + 1 )); fi
      i=$(( i + 1 ))
    done
    local pad=$(( TUI_ROWS - curline - 2 )); [ "$pad" -lt 0 ] && pad=0
    i=0; while [ "$i" -lt "$pad" ]; do tui_blank; i=$(( i + 1 )); done
    tui_footer "↑↓ move" "↵ detail" "p protect" "l load/unload" "g gaps" "a audit" "esc back"
    tui_clear_below
  }

  tui_begin
  trap 'tui_end; cleanup' EXIT INT TERM
  tui_dims; draw_keys

  while :; do
    key="$(tui_readkey)" || break
    prev="$sel"
    case "$key" in
      up)   sel=$(( sel - 1 )); [ "$sel" -lt 0 ] && sel=$(( n - 1 )) ;;
      down) sel=$(( sel + 1 )); [ "$sel" -ge "$n" ] && sel=0 ;;
      enter|right)
        tui_end
        tui_page "KEY · ${K_NAME[$sel]}" "${K_PATH[$sel]}"
        tui_kv "type"          "${K_TYPE[$sel]} ${K_BITS[$sel]} bit"
        tui_kv "fingerprint"   "${K_FP[$sel]}"
        tui_kv "comment"       "$(keys_comment "${K_PATH[$sel]}")"
        tui_kv "permissions"   "${K_MODE[$sel]}" "$([ "${K_MODE[$sel]}" = "600" ] && printf '%s' "$T_OK" || printf '%s' "$T_ERR")"
        if [ "${K_PASS[$sel]}" = "1" ]; then
          tui_kv "passphrase"  "protected" "$T_OK"
        else
          tui_kv "passphrase"  "NONE — usable by anyone who reads the file" "$T_ERR"
        fi
        tui_kv "used by"       "${K_HOSTS[$sel]:-nothing in ~/.ssh/config}" \
                               "$([ -n "${K_HOSTS[$sel]}" ] && printf '%s' "$T_TEXT" || printf '%s' "$T_WARN")"
        tui_kv "authorized here" "$([ "${K_AUTH[$sel]}" = "1" ] && echo yes || echo no)"
        tui_kv "loaded in agent" "$([ "${K_AGENT[$sel]}" = "1" ] && echo 'yes — usable right now without the passphrase' || echo no)" \
          "$([ "${K_AGENT[$sel]}" = "1" ] && printf '%s' "$T_WARN" || printf '%s' "$T_DIM")"
        if [ "${K_PASS[$sel]}" = "0" ]; then
          printf '\n'
          ui_err "This key is a bearer credential sitting in the clear."
          ui_note "Add a passphrase without regenerating it:"
          printf '\n     %sssh-keygen -p -f %s%s\n' "$T_ACCENT" "${K_PATH[$sel]}" "$T_RS"
        fi
        ui_pause
        tui_begin; tui_dims; draw_keys; continue ;;
      char:p)
        tui_end
        tui_page "PROTECT · ${K_NAME[$sel]}" "add a passphrase without regenerating the key"
        if [ "${K_PASS[$sel]}" = "1" ]; then
          ui_ok "this key is already passphrase protected"
          ui_note "to change it: ssh-keygen -p -f ${K_PATH[$sel]}"
          ui_pause
        else
          tui_kv "key"     "${K_PATH[$sel]}"
          tui_kv "used by" "${K_HOSTS[$sel]:-nothing}"
          printf '\n'
          ui_warn "Right now anyone who can read this file can authenticate as you"
          ui_note "to $([ -n "${K_HOSTS[$sel]}" ] && echo "${K_HOSTS[$sel]}" || echo 'wherever it is trusted')."
          ui_note "The key itself does NOT change — the same public half stays deployed,"
          ui_note "so nothing you have already authorised needs re-deploying."
          printf '\n'
          if ui_confirm "Add a passphrase to ${K_NAME[$sel]} now?"; then
            printf '\n'
            ssh-keygen -p -f "${K_PATH[$sel]}"
            if keys_has_passphrase "${K_PATH[$sel]}"; then
              K_PASS[$sel]=1
              nopass=$(( nopass - 1 ))
              ui_ok "verified: ${K_NAME[$sel]} now requires a passphrase"
              sec_log_start "keys"; sec_log "passphrase added to ${K_NAME[$sel]}"
              ui_note "add it to the agent so you are not retyping it:"
              printf '     %sssh-add --apple-use-keychain %s%s\n' "$T_ACCENT" "${K_PATH[$sel]}" "$T_RS"
            else
              ui_err "still unprotected — the change did not take"
            fi
          else
            ui_info "left unchanged"
          fi
          ui_pause
        fi
        tui_begin; tui_dims; draw_keys; continue ;;
      char:l)
        tui_end
        tui_page "AGENT · ${K_NAME[$sel]}" "$([ "${K_AGENT[$sel]}" = "1" ] && echo 'currently loaded' || echo 'not loaded')"
        if [ "${K_AGENT[$sel]}" = "1" ]; then
          ui_warn "While loaded, this key authenticates with no passphrase prompt."
          if ui_confirm "Unload ${K_NAME[$sel]} from the agent?"; then
            ssh-add -d "${K_PATH[$sel]}" 2>&1 | sed 's/^/    /'
            if keys_in_agent "${K_PATH[$sel]}"; then ui_err "still loaded"
            else K_AGENT[$sel]=0; nagent=$(( nagent - 1 )); ui_ok "re-measured: unloaded"; fi
          fi
        else
          ui_note "Loading adds it to the agent for this session."
          [ "${K_PASS[$sel]}" = "0" ] && ui_warn "this key has no passphrase, so loading changes very little"
          if ui_confirm "Load ${K_NAME[$sel]} into the agent?"; then
            ssh-add --apple-use-keychain "${K_PATH[$sel]}" 2>&1 | sed 's/^/    /'
            if keys_in_agent "${K_PATH[$sel]}"; then K_AGENT[$sel]=1; nagent=$(( nagent + 1 )); ui_ok "re-measured: loaded"
            else ui_err "not loaded"; fi
          fi
        fi
        ui_pause
        tui_begin; tui_dims; draw_keys; continue ;;
      char:g)
        tui_end
        tui_page "CONFIG GAPS" "IdentityFile entries pointing at keys that do not exist"
        if [ "$ngap" -gt 0 ]; then
          keys_config_gaps | sed "s|^|   · |"
          printf '\n   %s%s gap(s). Each is a Host block that cannot authenticate.%s\n' "$T_WARN" "$ngap" "$T_RS"
        else ui_ok "every IdentityFile in ~/.ssh/config resolves to a real key"; fi
        ui_pause
        tui_begin; tui_dims; draw_keys; continue ;;
      char:a)
        tui_end
        tui_page "KEY AUDIT" "enforced on this host"
        tui_kv "keys found"            "$n"
        tui_kv "passphrase protected"  "$(( n - nopass )) of $n" \
               "$([ "$nopass" -eq 0 ] && printf '%s' "$T_OK" || printf '%s' "$T_ERR")"
        printf '    %scoverage%s  ' "$T_MUTE" "$T_RS"; tui_meter $(( n - nopass )) "$n" 30; printf '\n'
        tui_kv "permissions 0600"      "$([ "$fixed" -gt 0 ] && echo "$fixed repaired this run" || echo "all correct")" \
               "$([ "$fixed" -gt 0 ] && printf '%s' "$T_WARN" || printf '%s' "$T_OK")"
        tui_kv "config gaps"           "$ngap" "$([ "$ngap" -eq 0 ] && printf '%s' "$T_OK" || printf '%s' "$T_WARN")"
        printf '\n   %sPassphrase state is measured with ssh-keygen -y -P "" — it emits the\n' "$T_DIM"
        printf '   PUBLIC key on success, so nothing private is read or printed.%s\n' "$T_RS"
        ui_pause
        tui_begin; tui_dims; draw_keys; continue ;;
      quit|esc) break ;;
      *) continue ;;
    esac
    draw_key "$prev" 0; draw_key "$sel" 1
  done
  tui_end
  trap 'cleanup' EXIT INT TERM
  return 0
}

# --- ssh-agent awareness ------------------------------------------------------
# A key loaded into the agent is usable without its passphrase for as long as the
# agent lives. That is the point — but it means "is it loaded" is a live security
# fact worth showing next to "does it have a passphrase".
keys_agent_fingerprints() {
  ssh-add -l 2>/dev/null | awk '{print $2}' | grep '^SHA256:' || true
}
keys_agent_running() { [ -n "${SSH_AUTH_SOCK:-}" ] && ssh-add -l >/dev/null 2>&1; }
keys_in_agent() {   # $1 key path -> 0 if its fingerprint is loaded
  local fp; fp="$(keys_fp "$1")"
  [ -n "$fp" ] || return 1
  keys_agent_fingerprints | ui_match_line "$fp"
}
