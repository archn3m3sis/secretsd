#!/usr/bin/env bash
# lib/record.sh — the record engine behind Auth Mapping, Environments, Logins
# and PII.
#
# Four modules, one shape: a file of records, each a flat map of fields.
#
#   directory tier (plaintext YAML)  auth · env    — no secret values, ever
#   encrypted tier (SOPS + age)      logins · pii  — values, never on disk clear
#
# THE ENCRYPTED TIER IS NEVER DECRYPTED TO DISK. Reads go through
# `sops -d --output-type json` into a pipe; writes go through `sops set`, which
# edits the encrypted file in place. There is no temp file holding plaintext at
# any point, which is the whole reason this is not just "decrypt, edit, re-encrypt".
#
# SENSITIVE FIELDS ARE MASKED on screen by default. Revealing one is a deliberate
# keypress, and copying routes through the auto-clearing clipboard rather than
# printing.
#
# Sourced, never executed.

# --- which fields are secret --------------------------------------------------
rec_is_secret_field() {
  case "$1" in
    password|passphrase|secret|token|api_key|apikey|totp|totp_seed|recovery|recovery_codes|\
    private_key|key|pin|ssn|dob|account|routing|card|cvv|policy_number) return 0 ;;
    *) return 1 ;;
  esac
}

rec_mask() {   # $1 value -> a fixed-width mask, never a length hint
  [ -n "$1" ] || { printf '%s' "—"; return; }
  printf '••••••••••••'
}

# --- plaintext YAML backend ---------------------------------------------------
recp_ids()   { [ -f "$1" ] || return 0; grep -oE '^[A-Za-z0-9_.-]+:' "$1" 2>/dev/null | sed 's/:$//'; }
recp_fields(){ [ -f "$1" ] || return 0
  awk -v r="$2" '
    /^[A-Za-z0-9_.-]+:[[:space:]]*$/ { c=$0; sub(/:[[:space:]]*$/,"",c); next }
    c == r && /^[[:space:]]+[A-Za-z0-9_-]+:/ { f=$1; sub(/:$/,"",f); print f }
  ' "$1"; }
recp_get()   { [ -f "$1" ] || return 0
  awk -v r="$2" -v w="$3" '
    /^[A-Za-z0-9_.-]+:[[:space:]]*$/ { c=$0; sub(/:[[:space:]]*$/,"",c); next }
    c == r && $1 == w":" { $1=""; sub(/^[[:space:]]+/,""); sub(/[[:space:]]+$/,""); print; exit }
  ' "$1"; }
recp_set()   {   # file id field value
  local f="$1" r="$2" k="$3" v="$4" tmp="$TMPD/rec.yaml"
  touch "$f"; chmod 600 "$f"
  if ! grep -qE "^$r:" "$f" 2>/dev/null; then
    { echo "$r:"; echo "  $k: $v"; echo ""; } >> "$f"; return 0
  fi
  if awk -v r="$r" -v k="$k" '
      /^[A-Za-z0-9_.-]+:[[:space:]]*$/ { c=$0; sub(/:[[:space:]]*$/,"",c) }
      c == r && $1 == k":" { found=1 } END { exit !found }' "$f"; then
    awk -v r="$r" -v k="$k" -v v="$v" '
      /^[A-Za-z0-9_.-]+:[[:space:]]*$/ { c=$0; sub(/:[[:space:]]*$/,"",c) }
      (c == r && $1 == k":") { print "  " k ": " v; next }
      { print }' "$f" > "$tmp" && cat "$tmp" > "$f"
  else
    awk -v r="$r" -v k="$k" -v v="$v" '{ print } $0 == r":" { print "  " k ": " v }' "$f" > "$tmp" \
      && cat "$tmp" > "$f"
  fi
}
recp_delete() {   # file id
  local f="$1" r="$2" tmp="$TMPD/rec.yaml"
  awk -v r="$r" '
    /^[A-Za-z0-9_.-]+:[[:space:]]*$/ { c=$0; sub(/:[[:space:]]*$/,"",c) }
    c != r { print }' "$f" > "$tmp" && cat "$tmp" > "$f"
}

# --- encrypted backend (no plaintext ever reaches disk) ------------------------
rece_ids() {
  [ -f "$1" ] || return 0
  sops -d --output-type json "$1" 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for k in sorted(d):
    if k=="sops" or k.startswith("sops_"): continue
    if isinstance(d[k], dict): print(k)
' 2>/dev/null
}
rece_fields() {
  [ -f "$1" ] || return 0
  REC_ID="$2" sops -d --output-type json "$1" 2>/dev/null | python3 -c '
import json,os,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
r=d.get(os.environ["REC_ID"])
if isinstance(r,dict):
    for k in sorted(r): print(k)
' 2>/dev/null
}
# rece_get FILE ID FIELD — used ONLY for masked display and clipboard copy
rece_get() {
  [ -f "$1" ] || return 0
  REC_ID="$2" REC_F="$3" sops -d --output-type json "$1" 2>/dev/null | python3 -c '
import json,os,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
r=d.get(os.environ["REC_ID"]) or {}
v=r.get(os.environ["REC_F"])
if v is not None: sys.stdout.write(str(v))
' 2>/dev/null
}
rece_set() {   # file id field value — sops edits in place, nothing decrypts to disk
  local f="$1" r="$2" k="$3" v="$4" jv
  jv="$(printf '%s' "$v" | python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))')" || return 1
  sops set "$f" "[\"$r\"][\"$k\"]" "$jv" 2>>"${SEC_LOG:-/dev/null}"
}
rece_delete() { sops unset "$1" "[\"$2\"]" 2>>"${SEC_LOG:-/dev/null}"; }

# --- backend dispatch ---------------------------------------------------------
rec_enc() { case "$1" in *.enc.*) return 0 ;; *) return 1 ;; esac; }
rec_ids()    { if rec_enc "$1"; then rece_ids "$1"; else recp_ids "$1"; fi; }
rec_fields() { if rec_enc "$1"; then rece_fields "$1" "$2"; else recp_fields "$1" "$2"; fi; }
rec_get()    { if rec_enc "$1"; then rece_get "$1" "$2" "$3"; else recp_get "$1" "$2" "$3"; fi; }
rec_set()    { if rec_enc "$1"; then rece_set "$1" "$2" "$3" "$4"; else recp_set "$1" "$2" "$3" "$4"; fi; }
rec_delete() { if rec_enc "$1"; then rece_delete "$1" "$2"; else recp_delete "$1" "$2"; fi; }

# --- the shared screen --------------------------------------------------------
# rec_screen MODULE_ID TITLE FILE SUBTITLE "field1 field2 …" SUMMARY_FIELD
rec_screen() {
  local mid="$1" title="$2" file="$3" subtitle="$4" schema="$5" sumf="$6"
  ui_interactive || { ui_needs_tty record; return 1; }

  local -a R_ID R_LINE
  local n=0 r glyph hue
  glyph="$(tui_glyph "$mid")"; hue="$(tui_hue "$mid")"

  rec_reload() {
    n=0
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      R_ID[$n]="$r"; n=$(( n + 1 ))
    done <<RECS
$(rec_ids "$file")
RECS
  }
  rec_reload

  if [ "$n" -eq 0 ]; then
    tui_page "$title" "$subtitle"
    printf '\n'
    if rec_enc "$file" && [ ! -f "$file" ]; then
      ui_warn "this module's encrypted store does not exist yet"
      ui_note "create it first — you choose exactly which hosts can open it:"
      printf '\n     %ssecrets vaults    →  n  (new vault)%s\n\n' "$T_ACCENT" "$T_RS"
      if [ "$mid" = "pii" ]; then
        ui_err "For PII, select ONLY this Mac as a recipient."
        ui_note "Personal identity detail must not be readable by the server fleet."
      fi
    else
      ui_info "no records yet — press a to add the first one"
      printf '\n   %sfields: %s%s\n' "$T_DIM" "$schema" "$T_RS"
    fi
    ui_pause
    [ ! -f "$file" ] && return 0
  fi

  local sel=0 key prev curline host i reveal=""
  host="$(hostname -s 2>/dev/null || echo host)"

  draw_rec() {
    local k="$1" on="$2" sub
    sub="$(rec_get "$file" "${R_ID[$k]}" "$sumf")"
    [ -n "$sub" ] || sub="no ${sumf} recorded"
    printf '\033[%d;1H' "${R_LINE[$k]}"
    tui_modrow "$on" "$glyph" "$hue" "$(tui_fit "${R_ID[$k]}" 34)" "" ok \
      "$(tui_fit "$(rec_fields "$file" "${R_ID[$k]}" | sec_nlines) fields" 18)"
    tui_moddesc "$on" "$(tui_fit "$sub" $(( TUI_COLS - 12 )))"
  }

  draw_recs() {
    tui_home
    tui_header "$host" "$n record(s) · $subtitle"
    curline=4
    i=0
    while [ "$i" -lt "$n" ]; do
      R_LINE[$i]="$(( curline + 1 ))"
      draw_rec "$i" "$([ "$i" = "$sel" ] && echo 1 || echo 0)"
      curline=$(( curline + 2 ))
      [ "$i" -lt $(( n - 1 )) ] && { tui_blank; curline=$(( curline + 1 )); }
      i=$(( i + 1 ))
    done
    local pad=$(( TUI_ROWS - curline - 2 )); [ "$pad" -lt 0 ] && pad=0
    i=0; while [ "$i" -lt "$pad" ]; do tui_blank; i=$(( i + 1 )); done
    if [ "$mid" = "env" ]; then
      tui_footer "↑↓ move" "↵ open" "a add" "i seed from projects" "d delete" "esc back"
    else
      tui_footer "↑↓ move" "↵ open" "a add" "i import" "d delete" "esc back"
    fi
    tui_clear_below
  }

  rec_detail() {
    local id="$1" f v shown
    while :; do
      tui_page "$(printf '%s' "$id" | tr '[:lower:]' '[:upper:]')" \
               "$([ "$(rec_enc "$file"; echo $?)" = "0" ] && echo 'encrypted record' || echo 'directory record') · $(basename "$file")"
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        v="$(rec_get "$file" "$id" "$f")"
        if rec_is_secret_field "$f" && [ "$reveal" != "$id:$f" ]; then
          tui_kv "$f" "$(rec_mask "$v")" "$T_DIM"
        else
          tui_kv "$f" "$(tui_fit "${v:-—}" $(( TUI_COLS - 24 )))"
        fi
      done <<FIELDS
$(rec_fields "$file" "$id")
FIELDS
      printf '\n'
      shown="$(rec_fields "$file" "$id" | sec_nlines)"
      [ "$shown" = "0" ] && ui_info "this record has no fields yet"
      if [ -n "$(rec_get "$file" "$id" totp)" ]; then
        ui_note "t TOTP code → clipboard · e edit · c copy · r reveal · esc back"
      else
        ui_note "e edit a field · c copy a field to the clipboard · r reveal one · esc back"
      fi
      printf '\n'
      local a; a="$(tui_readkey)" || break
      case "$a" in
        char:e)
          local ef; ef="$( { rec_fields "$file" "$id"; printf '%s\n' $schema; } | sort -u | ui_filter 'field to edit')" || continue
          [ -n "$ef" ] || continue
          local nv
          if rec_is_secret_field "$ef"; then nv="$(ui_ask_secret "New value for $ef")"
          else nv="$(ui_ask "New value for $ef" "$(rec_get "$file" "$id" "$ef")")"; fi
          [ -n "$nv" ] || { ui_warn "empty — unchanged"; ui_pause; continue; }
          if rec_set "$file" "$id" "$ef" "$nv"; then
            unset nv; ui_ok "saved $ef"; sec_log_start rec; sec_log "$mid set $id.$ef"
          else unset nv; ui_err "could not save"; fi
          ui_pause ;;
        char:c)
          local cf; cf="$(rec_fields "$file" "$id" | ui_filter 'field to copy')" || continue
          [ -n "$cf" ] || continue
          local cv; cv="$(rec_get "$file" "$id" "$cf")"
          if [ -n "$cv" ]; then
            printf '%s' "$cv" | pbcopy 2>/dev/null || printf '%s' "$cv" | xclip -selection clipboard 2>/dev/null
            SEC_CLIP_HASH="$(printf '%s' "$cv" | shasum -a 256 | cut -d' ' -f1)"
            unset cv
            ui_ok "$cf copied — cleared on exit"
          else ui_warn "empty"; fi
          ui_pause ;;
        char:t)
          # One stroke: read the seed inside this process, compute the code,
          # put ONLY the code on the clipboard. The seed is never shown, never
          # copied, and is unset the moment the code exists.
          local seed code left
          seed="$(rec_get "$file" "$id" totp)"
          if [ -z "$seed" ]; then ui_warn "no totp seed on this record"; ui_pause; continue; fi
          code="$(gen_totp "$seed")"
          unset seed
          if [ -z "$code" ]; then
            ui_err "could not compute a code — is the seed valid base32?"
            ui_pause; continue
          fi
          left="$(gen_totp_remaining)"
          printf '%s' "$code" | pbcopy 2>/dev/null || printf '%s' "$code" | xclip -selection clipboard 2>/dev/null
          SEC_CLIP_HASH="$(printf '%s' "$code" | shasum -a 256 | cut -d' ' -f1)"
          printf '\n'
          printf '    '; tui_grad_violet "$code"; printf '\n\n'
          tui_kv "valid for" "$left seconds"
          printf '    %svalidity%s  ' "$T_MUTE" "$T_RS"; tui_meter "$left" 30 30; printf '\n\n'
          ui_ok "code copied to the clipboard — the seed was never shown or copied"
          unset code
          ui_pause ;;
        char:r)
          local rf; rf="$(rec_fields "$file" "$id" | ui_filter 'field to reveal')" || continue
          [ -n "$rf" ] && reveal="$id:$rf" ;;
        quit|esc|left) reveal=""; break ;;
      esac
    done
  }

  tui_begin
  trap 'tui_end; cleanup' EXIT INT TERM
  tui_dims; draw_recs

  while :; do
    key="$(tui_readkey)" || break
    prev="$sel"
    case "$key" in
      up)   sel=$(( sel - 1 )); [ "$sel" -lt 0 ] && sel=$(( n - 1 )) ;;
      down) sel=$(( sel + 1 )); [ "$sel" -ge "$n" ] && sel=0 ;;
      enter|right)
        [ "$n" -gt 0 ] || continue
        tui_end; rec_detail "${R_ID[$sel]}"; tui_begin; tui_dims; rec_reload; draw_recs; continue ;;
      char:a)
        tui_end
        tui_page "NEW RECORD · $title" "fields: $schema"
        local nid; nid="$(ui_ask 'Record name' 'e.g. github, srv1, kyle')" || { tui_begin; tui_dims; draw_recs; continue; }
        if [ -n "$nid" ] && printf '%s' "$nid" | grep -qE '^[A-Za-z0-9_.-]+$'; then
          local fld val added=0
          for fld in $schema; do
            if rec_is_secret_field "$fld"; then val="$(ui_ask_secret "$fld (blank to skip)")"
            else val="$(ui_ask "$fld (blank to skip)" "")"; fi
            [ -n "$val" ] || continue
            rec_set "$file" "$nid" "$fld" "$val" && added=$(( added + 1 ))
            unset val
          done
          if [ "$added" -gt 0 ]; then
            ui_ok "created '$nid' with $added field(s)"
            sec_log_start rec; sec_log "$mid add $nid"
          else ui_warn "nothing entered — not created"; fi
        else ui_err "invalid name"; fi
        ui_pause
        tui_begin; tui_dims; rec_reload; sel=0; draw_recs; continue ;;
      char:i)
        tui_end
        case "$mid" in
          logins) import_screen ;;
          env)    env_seed_screen ;;
          *)      tui_page "IMPORT" "$title"
                  ui_info "no importer for this module yet"
                  ui_note "logins imports from Bitwarden, 1Password, KeePass, Passbolt and pass"
                  ui_pause ;;
        esac
        tui_begin; tui_dims; rec_reload; sel=0; draw_recs; continue ;;
      char:d)
        [ "$n" -gt 0 ] || continue
        tui_end
        tui_page "DELETE · ${R_ID[$sel]}" "this cannot be undone"
        if ui_confirm "Delete record '${R_ID[$sel]}'?"; then
          rec_delete "$file" "${R_ID[$sel]}"
          if rec_ids "$file" | ui_match_line "${R_ID[$sel]}"; then ui_err "still present"
          else ui_ok "deleted"; sec_log_start rec; sec_log "$mid delete ${R_ID[$sel]}"; fi
        else ui_info "kept"; fi
        ui_pause
        tui_begin; tui_dims; rec_reload; sel=0; draw_recs; continue ;;
      quit|esc) break ;;
      *) continue ;;
    esac
    [ "$n" -gt 0 ] && { draw_rec "$prev" 0; draw_rec "$sel" 1; }
  done
  tui_end
  trap 'cleanup' EXIT INT TERM
  return 0
}

# --- the four modules ---------------------------------------------------------
auth_screen() {
  rec_screen auth "AUTH MAPPING" "$SEC_DIR_DIR/authmap.yaml" \
    "how you authenticate to what — plaintext by design, no values" \
    "target method credential_key url notes" method
}
env_screen() {
  rec_screen env "ENVIRONMENT MGMT" "$SEC_DIR_DIR/environments.yaml" \
    "projects, where they live, how they are served and backed up" \
    "location serving backup access notes" location
}
logins_screen() {
  rec_screen logins "LOGIN MANAGEMENT" "$SEC_ENC_DIR/logins.enc.yaml" \
    "accounts and passwords — encrypted, masked, never printed" \
    "url username password totp recovery_codes notes" username
}
pii_screen() {
  rec_screen pii "PII MANAGEMENT" "$SEC_ENC_DIR/pii.enc.yaml" \
    "identity records — encrypt these to THIS MAC ONLY" \
    "full_name dob ssn address phone email policy_number notes" full_name
}

# --- seeding Environments -----------------------------------------------------
# Environments is the module that ties the other eight together per project, so
# an empty one is useless. Everything here is already knowable: the projects are
# discovered, the git remote says where the code lives, the stack is detectable,
# and the manifest already records which credentials each project uses. Seeding
# writes what is TRUE and marks the rest TODO rather than inventing it.
env_seed_screen() {
  ui_interactive || { ui_needs_tty record; return 1; }
  local file="$SEC_DIR_DIR/environments.yaml"

  tui_page "SEED ENVIRONMENTS" "from discovered projects — facts only, no invention"
  printf '\n'

  local -a P_PATH P_NAME
  local n=0 p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    P_PATH[$n]="$p"; P_NAME[$n]="$(basename "$p")"; n=$(( n + 1 ))
  done <<SEEDP
$(ws_discover 2>/dev/null | sort -u)
SEEDP
  # curated entries too, even when they are not on this disk
  local cname cpath cnote
  while IFS='|' read -r cname cpath cnote; do
    [ -n "$cname" ] || continue
    cpath="${cpath/#\~/$HOME}"
    local dup=0 j=0
    while [ "$j" -lt "$n" ]; do [ "${P_NAME[$j]}" = "$cname" ] && dup=1; j=$(( j + 1 )); done
    [ "$dup" = "1" ] && continue
    P_PATH[$n]="$cpath"; P_NAME[$n]="$cname"; n=$(( n + 1 ))
  done <<SEEDC
$(ws_curated)
SEEDC

  if [ "$n" -eq 0 ]; then
    ui_warn "no projects discovered — nothing to seed from"
    ui_note "add roots to $(basename "$SEC_PROJECTS")"
    ui_pause; return 0
  fi

  local i existing=0 willadd=0
  [ -f "$file" ] && existing="$(rec_ids "$file" | sec_nlines)"
  i=0
  while [ "$i" -lt "$n" ]; do
    rec_ids "$file" 2>/dev/null | ui_match_line "${P_NAME[$i]}" || willadd=$(( willadd + 1 ))
    i=$(( i + 1 ))
  done

  tui_kv "projects found"  "$n"
  tui_kv "already recorded" "$existing"
  tui_kv "will be added"   "$willadd"
  printf '\n'
  tui_section "WHAT GETS FILLED IN"
  printf '   %slocation%s   the path on this host, or "not on this host"\n' "$T_MUTE" "$T_RS"
  printf '   %sserving%s    the git remote, when there is one\n' "$T_MUTE" "$T_RS"
  printf '   %saccess%s     credentials the manifest already maps to that project\n' "$T_MUTE" "$T_RS"
  printf '   %sbackup%s     TODO — only you know this, so it is not guessed\n' "$T_MUTE" "$T_RS"
  printf '\n'

  if [ "$willadd" -eq 0 ]; then
    ui_info "every discovered project already has a record"
    ui_pause; return 0
  fi
  ui_confirm "Seed $willadd environment record(s)?" || { ui_info "nothing written"; ui_pause; return 0; }

  local added=0 loc serve creds stack
  i=0
  while [ "$i" -lt "$n" ]; do
    if rec_ids "$file" 2>/dev/null | ui_match_line "${P_NAME[$i]}"; then i=$(( i + 1 )); continue; fi
    if [ -d "${P_PATH[$i]}" ]; then
      loc="${P_PATH[$i]/#$HOME/~}"
      stack="$(ws_stack "${P_PATH[$i]}")"
      serve="$(git -C "${P_PATH[$i]}" remote get-url origin 2>/dev/null)"
      [ -n "$serve" ] || serve="no git remote"
    else
      loc="not on this host"; stack="unknown"; serve="unknown"
    fi
    creds="$(ws_project_creds "${P_NAME[$i]}" | paste -sd, - )"
    [ -n "$creds" ] || creds="none mapped in $(basename "$SEC_MANIFEST")"

    rec_set "$file" "${P_NAME[$i]}" location "$loc"
    rec_set "$file" "${P_NAME[$i]}" stack    "$stack"
    rec_set "$file" "${P_NAME[$i]}" serving  "$serve"
    rec_set "$file" "${P_NAME[$i]}" access   "$creds"
    rec_set "$file" "${P_NAME[$i]}" backup   "TODO"
    added=$(( added + 1 ))
    i=$(( i + 1 ))
  done

  local now; now="$(rec_ids "$file" | sec_nlines)"
  ui_ok "re-read the file: $now environment record(s), $added newly seeded"
  sec_log_start env; sec_log "seeded $added environment records"
  ui_note "backup is TODO on each — fill it in with e on the record"
  ui_pause
}
