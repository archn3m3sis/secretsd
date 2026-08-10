#!/usr/bin/env bash
# lib/modcerts.sh — Certificate Management.
#
# Expiry is PARSED FROM THE CERTIFICATE, never from a field someone typed. A
# hand-maintained expiry date is wrong the moment anything is reissued, and the
# report then reads green while the service is already down.
#
# Sourced, never executed.

CERTS_ROOTS="${CERTS_ROOTS:-$HOME/icn-phase3 $HOME/.local/share/certs $HOME/certs $SEC_SECRETS}"

certs_find() {
  local r
  for r in $CERTS_ROOTS; do
    [ -d "$r" ] || continue
    find "$r" -maxdepth 3 \( -name '*.crt' -o -name '*.pem' -o -name '*.cer' \) -type f 2>/dev/null
  done | sort -u
}

# certs_field PATH FIELD — subject | issuer | notAfter | notBefore
certs_field() {
  case "$2" in
    subject)  openssl x509 -in "$1" -noout -subject 2>/dev/null | sed 's/^subject=//; s/^ *//' ;;
    issuer)   openssl x509 -in "$1" -noout -issuer  2>/dev/null | sed 's/^issuer=//; s/^ *//' ;;
    notAfter) openssl x509 -in "$1" -noout -enddate 2>/dev/null | sed 's/^notAfter=//' ;;
    cn)       openssl x509 -in "$1" -noout -subject 2>/dev/null | sed -E 's/.*CN ?= ?([^,\/]*).*/\1/' ;;
  esac
}

# certs_count PATH — how many certificates are in the file (bundles are common)
# grep -c prints 0 AND exits non-zero when there are no matches, so the idiom
# `grep -c ... || printf 0` emits "0\n0" and every downstream [ ] test dies with
# "integer expected". Count lines instead.
certs_count() { grep -c 'BEGIN CERTIFICATE' "$1" 2>/dev/null | head -1; }

# certs_days_left PATH -> integer days (negative = already expired), or empty
certs_days_left() {
  local end epoch now
  end="$(certs_field "$1" notAfter)"
  [ -n "$end" ] || return 1
  epoch="$(TZ=UTC date -j -f '%b %e %T %Y %Z' "$end" +%s 2>/dev/null \
           || date -d "$end" +%s 2>/dev/null)"
  [ -n "$epoch" ] || return 1
  now="$(date +%s)"
  printf '%s' $(( (epoch - now) / 86400 ))
}

# certs_scan_batch -> "path\tcn\tnotAfter_epoch\tcount\tstatus" for every
# certificate found, from a single python process.
# certs_scan_batch [--with-piv]
#
# PIV is OPT-IN because reading it means probing the YubiKey, which costs a
# quarter-second of ykman start-up and touches hardware that may not be present.
# The certificates screen asks for it — you opened the module, you want the full
# picture. The scheduled expiry scan does NOT: it runs unattended, on a timer,
# and should not reach for a device nobody is holding. Set SECRETSD_SCAN_PIV=1
# to include it there anyway.
certs_scan_batch() {
  local list
  if [ "${1:-}" = "--with-piv" ] || [ "${SECRETSD_SCAN_PIV:-0}" = "1" ]; then
    list="$(certs_find; certs_piv_export)"
  else
    list="$(certs_find)"
  fi
  [ -n "$list" ] || return 0
  printf '%s\n' "$list" | tr '\n' '\0' | xargs -0 python3 "$SEC_BIN/lib/certscan.py" 2>/dev/null
}

# certs_epoch_human EPOCH -> the same shape openssl prints, so the detail view
# reads identically whichever path produced it
certs_epoch_human() {
  TZ=UTC date -r "$1" '+%b %e %H:%M:%S %Y GMT' 2>/dev/null \
    || TZ=UTC date -d "@$1" '+%b %e %H:%M:%S %Y GMT' 2>/dev/null
}

certs_screen() {
  ui_interactive || { ui_needs_tty certs "secretsd alerts            certificate expiry, as text"; return 1; }
  local -a C_PATH C_CN C_DAYS C_END C_N C_LINE
  local n=0 f d

  ui_clear; printf '\n  '; tui_grad_violet 'reading certificates…'; printf '\n'

  # ONE process for the whole scan. This loop used to call openssl once per
  # FIELD per certificate — subject, enddate, and enddate again from inside
  # certs_days_left — plus date twice and grep once. Measured on a real machine:
  # 58 certificates, 2.855 seconds, every time this screen was opened. The same
  # scan through certscan.py measures 0.023 seconds.
  local now cn epoch cnt st
  now="$(date +%s)"
  while IFS="$(printf '\t')" read -r f cn epoch cnt st; do
    [ -n "$f" ] || continue
    if [ "$st" != ok ]; then
      # Anything the DER walker cannot read falls back to openssl for that ONE
      # file. A certificate that silently drops off an expiry report is exactly
      # the one that takes something down.
      d="$(certs_days_left "$f")" || d=""
      [ -n "$d" ] || continue
      C_PATH[$n]="$f"
      C_CN[$n]="$(certs_field "$f" cn)"; [ -n "${C_CN[$n]}" ] || C_CN[$n]="$(basename "$f")"
      C_DAYS[$n]="$d"
      C_END[$n]="$(certs_field "$f" notAfter)"
      C_N[$n]="${cnt:-1}"
      n=$(( n + 1 )); continue
    fi
    C_PATH[$n]="$f"
    C_CN[$n]="${cn:-$(basename "$f")}"
    C_DAYS[$n]=$(( (epoch - now) / 86400 ))
    C_END[$n]="$(certs_epoch_human "$epoch")"
    C_N[$n]="${cnt:-1}"
    n=$(( n + 1 ))
  done <<CERTS
$(certs_scan_batch --with-piv)
CERTS

  if [ "$n" -eq 0 ]; then
    TUI_PAGE_MARK="$(tui_glyph certs)"
    tui_page "CERTIFICATES" "no parseable certificates found in the searched roots"
    printf '\n'
    ui_info "searched:"; for f in $CERTS_ROOTS; do printf '     %s\n' "$f"; done
    ui_note "set CERTS_ROOTS to point it elsewhere"
    ui_pause; return 0
  fi

  # soonest expiry first — that is the only order that matters here
  local -a S_PATH S_CN S_DAYS S_END S_N
  local m=0 i best bi
  local -a used
  i=0; while [ "$i" -lt "$n" ]; do used[$i]=0; i=$(( i + 1 )); done
  while [ "$m" -lt "$n" ]; do
    best=999999; bi=-1; i=0
    while [ "$i" -lt "$n" ]; do
      if [ "${used[$i]}" = "0" ] && [ "${C_DAYS[$i]}" -lt "$best" ]; then best="${C_DAYS[$i]}"; bi="$i"; fi
      i=$(( i + 1 ))
    done
    [ "$bi" -lt 0 ] && break
    used[$bi]=1
    S_PATH[$m]="${C_PATH[$bi]}"; S_CN[$m]="${C_CN[$bi]}"; S_DAYS[$m]="${C_DAYS[$bi]}"
    S_END[$m]="${C_END[$bi]}"; S_N[$m]="${C_N[$bi]}"
    m=$(( m + 1 ))
  done

  local sel=0 key prev curline host nexp=0 nsoon=0
  host="$(hostname -s 2>/dev/null || echo host)"
  i=0
  while [ "$i" -lt "$n" ]; do
    [ "${S_DAYS[$i]}" -lt 0 ] && nexp=$(( nexp + 1 ))
    [ "${S_DAYS[$i]}" -ge 0 ] && [ "${S_DAYS[$i]}" -le 30 ] && nsoon=$(( nsoon + 1 ))
    i=$(( i + 1 ))
  done

  draw_cert() {
    local k="$1" on="$2" dot dlab hue mark days
    days="${S_DAYS[$k]}"
    if   [ "$days" -lt 0 ];   then dot=err;  dlab="EXPIRED $(( -days ))d ago"; hue="$T_ERR";    mark='⣿⣿⣿'
    elif [ "$days" -le 30 ];  then dot=warn; dlab="$days days left";           hue="$N_ORANGE"; mark='⠺⣭⠗'
    elif [ "$days" -le 90 ];  then dot=warn; dlab="$days days left";           hue="$N_AMBER";  mark='⠺⣭⠗'
    else                           dot=ok;   dlab="$days days left";           hue="$N_GREEN";  mark='⠺⣭⠗'
    fi
    printf '\033[%d;1H' "${C_LINE[$k]}"
    local src
    if certs_is_piv "${S_PATH[$k]}"; then
      src="YubiKey PIV slot $(certs_piv_slot "${S_PATH[$k]}") · private key never leaves the hardware"
      mark="$(tui_icon_top yubikey)"
    else
      src="${S_PATH[$k]/#$HOME/~}"
      mark="$(tui_icon_top certs)"
    fi
    tui_modrow "$on" "$mark" "$hue" "$(tui_fit "${S_CN[$k]}" 38)" \
      "$([ "${S_N[$k]}" -gt 1 ] && echo "${S_N[$k]} certs" || echo "1 cert")" "$dot" "$dlab"
    tui_moddesc "$on" "$(tui_fit "$src · expires ${S_END[$k]}" $(( TUI_COLS - 14 )))" \
      "$(certs_is_piv "${S_PATH[$k]}" && tui_icon_bot yubikey || tui_icon_bot certs)" "$hue"
  }

  draw_certs() {
    tui_home
    tui_header "$host" "$n certificate file(s) · $nexp expired · $nsoon within 30 days · parsed from the certs" "CERTIFICATES" certs
    curline=4
    i=0
    while [ "$i" -lt "$n" ]; do
      C_LINE[$i]="$(( curline + 1 ))"
      draw_cert "$i" "$([ "$i" = "$sel" ] && echo 1 || echo 0)"
      curline=$(( curline + 2 ))
      [ "$i" -lt $(( n - 1 )) ] && { tui_blank; curline=$(( curline + 1 )); }
      i=$(( i + 1 ))
    done
    local pad=$(( TUI_ROWS - curline - 2 )); [ "$pad" -lt 0 ] && pad=0
    i=0; while [ "$i" -lt "$pad" ]; do tui_blank; i=$(( i + 1 )); done
    tui_footer "↑↓ move" "↵ detail" "esc back"
    tui_clear_below
  }

  tui_begin
  trap 'tui_end; cleanup' EXIT INT TERM
  tui_dims; draw_certs

  while :; do
    key="$(tui_readkey)" || break
    prev="$sel"
    case "$key" in
      up)   sel=$(( sel - 1 )); [ "$sel" -lt 0 ] && sel=$(( n - 1 )) ;;
      down) sel=$(( sel + 1 )); [ "$sel" -ge "$n" ] && sel=0 ;;
      enter|right)
        tui_end
        tui_page "CERTIFICATE · $(tui_fit "${S_CN[$sel]}" 40)" "${S_PATH[$sel]}"
        tui_kv "common name" "$(tui_fit "${S_CN[$sel]}" $(( TUI_COLS - 24 )))"
        tui_kv "subject"     "$(tui_fit "$(certs_field "${S_PATH[$sel]}" subject)" $(( TUI_COLS - 24 )))"
        tui_kv "issuer"      "$(tui_fit "$(certs_field "${S_PATH[$sel]}" issuer)" $(( TUI_COLS - 24 )))"
        tui_kv "expires"     "${S_END[$sel]}" \
          "$([ "${S_DAYS[$sel]}" -lt 0 ] && printf '%s' "$T_ERR" || printf '%s' "$T_TEXT")"
        tui_kv "days left"   "${S_DAYS[$sel]}" \
          "$([ "${S_DAYS[$sel]}" -lt 30 ] && printf '%s' "$T_ERR" || printf '%s' "$T_OK")"
        tui_kv "certs in file" "${S_N[$sel]}"
        printf '\n    %slifetime remaining%s  ' "$T_MUTE" "$T_RS"
        tui_meter "$([ "${S_DAYS[$sel]}" -lt 0 ] && echo 0 || echo "${S_DAYS[$sel]}")" 365 30
        printf '\n\n'
        ui_note "inspect it fully with:"
        printf '     %sopenssl x509 -in %s -noout -text%s\n' "$T_ACCENT" "${S_PATH[$sel]}" "$T_RS"
        ui_pause
        tui_begin; tui_dims; draw_certs; continue ;;
      quit|esc) break ;;
      *) continue ;;
    esac
    draw_cert "$prev" 0; draw_cert "$sel" 1
  done
  tui_end
  trap 'cleanup' EXIT INT TERM
  return 0
}

# --- certificates held on a YubiKey (PIV) -------------------------------------
# Exported to the scratch dir and parsed with the same code path as disk certs —
# a certificate is public material, so exporting it costs nothing. The private
# key never leaves the hardware and is never touched here.
# certs_piv_export — certificates living in the YubiKey's PIV slots.
#
# `ykman list` costs about a quarter of a second of Python start-up, and this
# used to run it TWICE, throwing the first result away. Measured at 0.470s with
# no YubiKey even plugged in.
certs_piv_export() {
  command -v ykman >/dev/null 2>&1 || return 0
  local devs; devs="$(ykman list 2>/dev/null)" || return 0
  [ -n "$devs" ] || return 0
  local slot out
  for slot in 9a 9c 9d 9e; do
    out="$TMPD/piv-$slot.pem"
    if ykman piv certificates export "$slot" "$out" >/dev/null 2>&1 && [ -s "$out" ]; then
      printf '%s\n' "$out"
    fi
  done
}
certs_is_piv() { case "$1" in "$TMPD"/piv-*.pem) return 0 ;; *) return 1 ;; esac; }
certs_piv_slot() { printf '%s' "$1" | sed -E 's|.*/piv-([0-9a-f]+)\.pem|\1|'; }
