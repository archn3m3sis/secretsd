#!/usr/bin/env bash
# lib/moddns.sh — Domain Management (Cloudflare).
#
# THE TOKEN IS NEVER EXPORTED. Every API call runs inside
# `secrets run --only <token> -- curl …`, so the value exists only in that one
# child process, for the length of one request. It never enters your shell, never
# appears in `ps` output as an argument, and never reaches a log — the token is
# read from the child's environment by curl itself via a config on stdin.
#
# WRITES ARE GUARDED. Nothing is changed without showing the exact before and
# after, and asking. Every write re-reads the record afterwards and reports what
# the zone actually holds now, not what the API returned.
#
# Sourced, never executed.

export DNS_TOKEN_KEY="${DNS_TOKEN_KEY:-CF_DNS_EDIT_TOKEN}"
DNS_API="https://api.cloudflare.com/client/v4"

# dns_api METHOD PATH [JSON_BODY] -> raw JSON on stdout
# curl reads the Authorization header from a config on stdin so the token is
# never a command-line argument (argv is world-readable via ps).
dns_api() {
  local method="$1" path="$2" body="${3:-}"
  local script="$TMPD/dnscall.sh"
  cat > "$script" <<'CALL'
set -u
tok="$(eval "printf '%s' \"\${$DNS_TOKEN_KEY}\"")"
[ -n "$tok" ] || { echo '{"success":false,"errors":[{"message":"token not in store"}]}'; exit 1; }
if [ -n "${DNS_BODY:-}" ]; then
  printf 'header = "Authorization: Bearer %s"\n' "$tok" | \
    curl -sS --config - -X "$DNS_METHOD" \
      -H "Content-Type: application/json" \
      --data "$DNS_BODY" \
      "$DNS_URL"
else
  printf 'header = "Authorization: Bearer %s"\n' "$tok" | \
    curl -sS --config - -X "$DNS_METHOD" \
      -H "Content-Type: application/json" \
      "$DNS_URL"
fi
CALL
  # DNS_TOKEN_KEY is already exported at file scope; re-assigning it in the
  # prefix made shellcheck think the expansion below could not see it.
  DNS_METHOD="$method" DNS_URL="$DNS_API$path" DNS_BODY="$body" \
    "$SEC_SELF" run --only "$DNS_TOKEN_KEY" -- bash "$script" 2>/dev/null
}

dns_ok()   { printf '%s' "$1" | jq -e '.success == true' >/dev/null 2>&1; }
dns_err()  { printf '%s' "$1" | jq -r '.errors[]?.message' 2>/dev/null | head -3; }

dns_zones() {   # -> "id|name|status"
  local r; r="$(dns_api GET '/zones?per_page=50')"
  dns_ok "$r" || return 1
  printf '%s' "$r" | jq -r '.result[] | "\(.id)|\(.name)|\(.status)"' 2>/dev/null
}

dns_records() {  # $1 zone id -> "id|type|name|content|proxied|ttl"
  local r; r="$(dns_api GET "/zones/$1/dns_records?per_page=200")"
  dns_ok "$r" || return 1
  printf '%s' "$r" | jq -r '.result[] | "\(.id)|\(.type)|\(.name)|\(.content)|\(.proxied)|\(.ttl)"' 2>/dev/null
}

dns_record_get() {   # $1 zone  $2 record -> pretty JSON
  dns_api GET "/zones/$1/dns_records/$2" | jq -r '.result | {type,name,content,proxied,ttl}' 2>/dev/null
}

dns_screen() {
  ui_interactive || return 0

  if ! sec_has "$DNS_TOKEN_KEY"; then
    tui_page "DOMAIN MANAGEMENT" "no Cloudflare token in the vault"
    printf '\n'
    ui_err "'$DNS_TOKEN_KEY' is not in this store"
    ui_note "add it, scoped to DNS edit on the zones you want to manage:"
    printf '\n     %ssecrets add %s%s\n\n' "$T_ACCENT" "$DNS_TOKEN_KEY" "$T_RS"
    ui_pause; return 0
  fi

  ui_clear; printf '\n  '; tui_grad_violet 'querying Cloudflare…'; printf '\n'

  local -a Z_ID Z_NAME Z_STATUS Z_LINE
  local n=0 zid zname zstat
  while IFS='|' read -r zid zname zstat; do
    [ -n "$zid" ] || continue
    Z_ID[$n]="$zid"; Z_NAME[$n]="$zname"; Z_STATUS[$n]="$zstat"; n=$(( n + 1 ))
  done <<ZONES
$(dns_zones)
ZONES

  if [ "$n" -eq 0 ]; then
    tui_page "DOMAIN MANAGEMENT" "could not list zones"
    printf '\n'
    ui_err "Cloudflare returned no zones"
    ui_note "the token may lack Zone:Read, or this host may have no egress"
    ui_note "verify with:  secrets run --only $DNS_TOKEN_KEY -- sh -c 'curl -sS -H \"Authorization: Bearer \$$DNS_TOKEN_KEY\" $DNS_API/user/tokens/verify | jq .'"
    ui_pause; return 0
  fi

  local sel=0 key prev curline host i
  host="$(hostname -s 2>/dev/null || echo host)"

  draw_zone() {
    local k="$1" on="$2" dot
    [ "${Z_STATUS[$k]}" = "active" ] && dot=ok || dot=warn
    printf '\033[%d;1H' "${Z_LINE[$k]}"
    tui_modrow "$on" "$(tui_glyph dns)" "$(tui_hue dns)" "$(tui_fit "${Z_NAME[$k]}" 34)" \
      "" "$dot" "${Z_STATUS[$k]}"
    tui_moddesc "$on" "$(tui_fit "zone ${Z_ID[$k]}" $(( TUI_COLS - 12 )))"
  }

  draw_zones() {
    tui_home
    tui_header "$host" "$n zone(s) · token injected per call, never exported"
    curline=4
    i=0
    while [ "$i" -lt "$n" ]; do
      Z_LINE[$i]="$(( curline + 1 ))"
      draw_zone "$i" "$([ "$i" = "$sel" ] && echo 1 || echo 0)"
      curline=$(( curline + 2 ))
      [ "$i" -lt $(( n - 1 )) ] && { tui_blank; curline=$(( curline + 1 )); }
      i=$(( i + 1 ))
    done
    local pad=$(( TUI_ROWS - curline - 2 )); [ "$pad" -lt 0 ] && pad=0
    i=0; while [ "$i" -lt "$pad" ]; do tui_blank; i=$(( i + 1 )); done
    tui_footer "↑↓ move" "↵ records" "esc back"
    tui_clear_below
  }

  # --- records within a zone --------------------------------------------------
  dns_zone_records() {
    local zi="$1" zn="$2"
    local -a R_ID R_TYPE R_NAME R_CONTENT R_PROX R_TTL R_LINE
    local m=0 rid rtype rname rcontent rprox rttl rsel=0 rk rprev j rcurline

    tui_end; ui_clear; printf '\n  '; tui_grad_violet "reading $zn…"; printf '\n'
    while IFS='|' read -r rid rtype rname rcontent rprox rttl; do
      [ -n "$rid" ] || continue
      R_ID[$m]="$rid"; R_TYPE[$m]="$rtype"; R_NAME[$m]="$rname"
      R_CONTENT[$m]="$rcontent"; R_PROX[$m]="$rprox"; R_TTL[$m]="$rttl"
      m=$(( m + 1 ))
    done <<RECS
$(dns_records "$zi")
RECS

    if [ "$m" -eq 0 ]; then
      tui_page "RECORDS · $zn" "none returned"
      ui_note "the token may lack DNS:Read on this zone"
      ui_pause; return 0
    fi

    draw_rec_row() {
      local k="$1" on="$2" dot
      [ "${R_PROX[$k]}" = "true" ] && dot=ok || dot=none
      printf '\033[%d;1H' "${R_LINE[$k]}"
      tui_modrow "$on" "$(tui_glyph dns)" "$(tui_hue dns)" \
        "$(tui_fit "${R_NAME[$k]}" 34)" "${R_TYPE[$k]}" "$dot" \
        "$([ "${R_PROX[$k]}" = "true" ] && echo proxied || echo direct)"
      tui_moddesc "$on" "$(tui_fit "${R_CONTENT[$k]} · ttl ${R_TTL[$k]}" $(( TUI_COLS - 12 )))"
    }
    draw_recs_z() {
      tui_home
      tui_header "$host" "$zn · $m record(s) · writes show a before/after diff and ask"
      rcurline=4
      j=0
      while [ "$j" -lt "$m" ]; do
        R_LINE[$j]="$(( rcurline + 1 ))"
        draw_rec_row "$j" "$([ "$j" = "$rsel" ] && echo 1 || echo 0)"
        rcurline=$(( rcurline + 2 ))
        [ "$j" -lt $(( m - 1 )) ] && { tui_blank; rcurline=$(( rcurline + 1 )); }
        j=$(( j + 1 ))
      done
      local pad=$(( TUI_ROWS - rcurline - 2 )); [ "$pad" -lt 0 ] && pad=0
      j=0; while [ "$j" -lt "$pad" ]; do tui_blank; j=$(( j + 1 )); done
      tui_footer "↑↓ move" "↵ detail" "e edit content" "esc back"
      tui_clear_below
    }

    tui_begin; tui_dims; draw_recs_z
    while :; do
      rk="$(tui_readkey)" || break
      rprev="$rsel"
      case "$rk" in
        up)   rsel=$(( rsel - 1 )); [ "$rsel" -lt 0 ] && rsel=$(( m - 1 )) ;;
        down) rsel=$(( rsel + 1 )); [ "$rsel" -ge "$m" ] && rsel=0 ;;
        enter|right)
          tui_end
          tui_page "RECORD · ${R_NAME[$rsel]}" "$zn"
          tui_kv "type"    "${R_TYPE[$rsel]}"
          tui_kv "name"    "${R_NAME[$rsel]}"
          tui_kv "content" "$(tui_fit "${R_CONTENT[$rsel]}" $(( TUI_COLS - 24 )))"
          tui_kv "proxied" "${R_PROX[$rsel]}"
          tui_kv "ttl"     "${R_TTL[$rsel]}"
          tui_kv "id"      "${R_ID[$rsel]}"
          ui_pause
          tui_begin; tui_dims; draw_recs_z; continue ;;
        char:e)
          tui_end
          tui_page "EDIT · ${R_NAME[$rsel]}" "$zn · ${R_TYPE[$rsel]}"
          local newc
          newc="$(ui_ask "New content for ${R_NAME[$rsel]}" "${R_CONTENT[$rsel]}")" || { tui_begin; tui_dims; draw_recs_z; continue; }
          if [ -z "$newc" ] || [ "$newc" = "${R_CONTENT[$rsel]}" ]; then
            ui_info "unchanged"; ui_pause; tui_begin; tui_dims; draw_recs_z; continue
          fi
          printf '\n'
          tui_section "BEFORE"
          printf '    %s%s %s %s%s\n' "$T_DIM" "${R_TYPE[$rsel]}" "${R_NAME[$rsel]}" "${R_CONTENT[$rsel]}" "$T_RS"
          tui_section "AFTER"
          printf '    %s%s %s %s%s\n' "$T_OK" "${R_TYPE[$rsel]}" "${R_NAME[$rsel]}" "$newc" "$T_RS"
          printf '\n'
          if ui_confirm "Apply this change to live DNS?"; then
            local body resp
            body="$(jq -nc --arg t "${R_TYPE[$rsel]}" --arg n "${R_NAME[$rsel]}" \
                       --arg c "$newc" --argjson p "${R_PROX[$rsel]}" --argjson ttl "${R_TTL[$rsel]}" \
                       '{type:$t,name:$n,content:$c,proxied:$p,ttl:$ttl}')"
            resp="$(dns_api PUT "/zones/$zi/dns_records/${R_ID[$rsel]}" "$body")"
            if dns_ok "$resp"; then
              # re-read: report what the zone actually holds, not what PUT returned
              local now
              now="$(dns_record_get "$zi" "${R_ID[$rsel]}" | jq -r '.content' 2>/dev/null)"
              if [ "$now" = "$newc" ]; then
                R_CONTENT[$rsel]="$newc"
                ui_ok "re-read from Cloudflare: content is now $now"
                sec_log_start dns; sec_log "updated ${R_TYPE[$rsel]} ${R_NAME[$rsel]} in $zn"
              else
                ui_err "API accepted it but the zone reads back as: ${now:-unknown}"
              fi
            else
              ui_err "Cloudflare rejected the change"
              dns_err "$resp" | sed 's/^/     /'
            fi
          else ui_info "not applied"; fi
          ui_pause
          tui_begin; tui_dims; draw_recs_z; continue ;;
        quit|esc|left) break ;;
        *) continue ;;
      esac
      draw_rec_row "$rprev" 0; draw_rec_row "$rsel" 1
    done
    tui_end
  }

  tui_begin
  trap 'tui_end; cleanup' EXIT INT TERM
  tui_dims; draw_zones

  while :; do
    key="$(tui_readkey)" || break
    prev="$sel"
    case "$key" in
      up)   sel=$(( sel - 1 )); [ "$sel" -lt 0 ] && sel=$(( n - 1 )) ;;
      down) sel=$(( sel + 1 )); [ "$sel" -ge "$n" ] && sel=0 ;;
      enter|right)
        dns_zone_records "${Z_ID[$sel]}" "${Z_NAME[$sel]}"
        tui_begin; tui_dims; draw_zones; continue ;;
      quit|esc) break ;;
      *) continue ;;
    esac
    draw_zone "$prev" 0; draw_zone "$sel" 1
  done
  tui_end
  trap 'cleanup' EXIT INT TERM
  return 0
}
