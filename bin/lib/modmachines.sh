#!/usr/bin/env bash
# lib/modmachines.sh — Machine Management.
#
# A READER over what already defines your fleet: ~/.ssh/config. It does not
# become a second source of truth — it reports the hosts you have declared, the
# key each uses, whether that key exists, and (on demand) whether the host is
# reachable right now.
#
# REACHABILITY IS A BARE TCP PROBE. It never authenticates. Probing with ssh
# would count as a failed login attempt against faillock on hardened hosts and
# can lock the account out — that lesson is already written down, and this module
# does not repeat it.
#
# Sourced, never executed.

mach_hosts() {   # -> "alias|hostname|user|port|identityfile"
  local cfg="$HOME/.ssh/config"
  [ -f "$cfg" ] || return 0
  awk '
    function flush() {
      if (alias != "" && alias !~ /\*/)
        printf "%s|%s|%s|%s|%s\n", alias, hn, user, port, idf
      alias=""; hn=""; user=""; port=""; idf=""
    }
    /^[[:space:]]*[Hh]ost[[:space:]]/ {
      flush(); line=$0
      sub(/^[[:space:]]*[Hh]ost[[:space:]]+/,"",line)
      split(line, a, /[[:space:]]+/); alias=a[1]; next
    }
    /^[[:space:]]*[Hh]ost[Nn]ame[[:space:]]/     { hn=$2; next }
    /^[[:space:]]*[Uu]ser[[:space:]]/            { user=$2; next }
    /^[[:space:]]*[Pp]ort[[:space:]]/            { port=$2; next }
    /^[[:space:]]*[Ii]dentity[Ff]ile[[:space:]]/ { idf=$2; next }
    END { flush() }
  ' "$cfg"
}

# mach_reachable HOST PORT -> 0 if the port answers. TCP only, no auth, 2s cap.
mach_reachable() {
  local h="$1" p="${2:-22}"
  [ -n "$h" ] || return 1
  if command -v nc >/dev/null 2>&1; then
    nc -z -G 2 -w 2 "$h" "$p" >/dev/null 2>&1 && return 0
    return 1
  fi
  # bash /dev/tcp fallback, still no authentication
  (exec 3<>"/dev/tcp/$h/$p") >/dev/null 2>&1 && { exec 3>&- 2>/dev/null; return 0; }
  return 1
}

machines_screen() {
  ui_interactive || { ui_needs_tty machines; return 1; }
  local -a M_ALIAS M_HN M_USER M_PORT M_IDF M_KEYOK M_REACH M_LINE
  local n=0 alias hn user port idf p

  while IFS='|' read -r alias hn user port idf; do
    [ -n "$alias" ] || continue
    M_ALIAS[$n]="$alias"; M_HN[$n]="${hn:-$alias}"
    M_USER[$n]="${user:-$(id -un)}"; M_PORT[$n]="${port:-22}"
    M_IDF[$n]="$idf"
    if [ -n "$idf" ]; then
      p="${idf/#\~/$HOME}"
      [ -f "$p" ] && M_KEYOK[$n]=1 || M_KEYOK[$n]=0
    else M_KEYOK[$n]=2; fi          # 2 = no key declared
    M_REACH[$n]=-1                   # unprobed
    n=$(( n + 1 ))
  done <<HOSTS
$(mach_hosts)
HOSTS

  if [ "$n" -eq 0 ]; then
    TUI_PAGE_MARK="$(tui_glyph machines)"
    tui_page "MACHINES" "no Host entries in ~/.ssh/config"
    ui_pause; return 0
  fi

  local sel=0 key prev curline host i nbad=0
  host="$(hostname -s 2>/dev/null || echo host)"
  i=0; while [ "$i" -lt "$n" ]; do [ "${M_KEYOK[$i]}" = "0" ] && nbad=$(( nbad + 1 )); i=$(( i + 1 )); done

  draw_mach() {
    local k="$1" on="$2" dot dlab hue mark
    case "${M_REACH[$k]}" in
      1) dot=ok;   dlab="reachable";   hue="$N_GREEN" ;;
      0) dot=err;  dlab="no answer";   hue="$T_DIM" ;;
      *) dot=none; dlab="unprobed";    hue="$N_GREEN" ;;
    esac
    [ "${M_KEYOK[$k]}" = "0" ] && { dot=err; dlab="key missing"; hue="$T_ERR"; }
    mark='⠯⣭⠽'
    printf '\033[%d;1H' "${M_LINE[$k]}"
    tui_modrow "$on" "$mark" "$hue" "$(tui_fit "${M_ALIAS[$k]}" 30)" \
      "${M_USER[$k]}@${M_PORT[$k]}" "$dot" "$dlab"
    tui_moddesc "$on" "$(tui_fit "${M_HN[$k]} · $([ -n "${M_IDF[$k]}" ] && basename "${M_IDF[$k]}" || echo 'no key declared')" $(( TUI_COLS - 12 )))"
  }

  draw_machines() {
    tui_home
    tui_header "$host" "$n host(s) from ~/.ssh/config · $nbad with a missing key · probes are TCP only, never auth" "MACHINES" machines
    curline=4
    i=0
    while [ "$i" -lt "$n" ]; do
      M_LINE[$i]="$(( curline + 1 ))"
      draw_mach "$i" "$([ "$i" = "$sel" ] && echo 1 || echo 0)"
      curline=$(( curline + 2 ))
      [ "$i" -lt $(( n - 1 )) ] && { tui_blank; curline=$(( curline + 1 )); }
      i=$(( i + 1 ))
    done
    local pad=$(( TUI_ROWS - curline - 2 )); [ "$pad" -lt 0 ] && pad=0
    i=0; while [ "$i" -lt "$pad" ]; do tui_blank; i=$(( i + 1 )); done
    tui_footer "↑↓ move" "↵ detail" "p probe this" "P probe all" "esc back"
    tui_clear_below
  }

  tui_begin
  trap 'tui_end; cleanup' EXIT INT TERM
  tui_dims; draw_machines

  while :; do
    key="$(tui_readkey)" || break
    prev="$sel"
    case "$key" in
      up)   sel=$(( sel - 1 )); [ "$sel" -lt 0 ] && sel=$(( n - 1 )) ;;
      down) sel=$(( sel + 1 )); [ "$sel" -ge "$n" ] && sel=0 ;;
      char:p)
        mach_reachable "${M_HN[$sel]}" "${M_PORT[$sel]}" && M_REACH[$sel]=1 || M_REACH[$sel]=0
        draw_mach "$sel" 1; continue ;;
      char:P)
        tui_end
        tui_page "PROBE ALL" "bare TCP connect to each host — no authentication is attempted"
        i=0
        while [ "$i" -lt "$n" ]; do
          printf '   %-24s ' "${M_ALIAS[$i]}"
          if mach_reachable "${M_HN[$i]}" "${M_PORT[$i]}"; then
            M_REACH[$i]=1; printf '%s● reachable%s\n' "$T_OK" "$T_RS"
          else
            M_REACH[$i]=0; printf '%s○ no answer%s\n' "$T_DIM" "$T_RS"
          fi
          i=$(( i + 1 ))
        done
        printf '\n'
        ui_note "no answer usually means off-network, not down — this Mac has to be on"
        ui_note "on the right network, or on the VPN, for internal hosts to respond"
        ui_pause
        tui_begin; tui_dims; draw_machines; continue ;;
      enter|right)
        tui_end
        tui_page "HOST · ${M_ALIAS[$sel]}" "${M_HN[$sel]}"
        tui_kv "alias"     "${M_ALIAS[$sel]}"
        tui_kv "hostname"  "${M_HN[$sel]}"
        tui_kv "user"      "${M_USER[$sel]}"
        tui_kv "port"      "${M_PORT[$sel]}"
        if [ -n "${M_IDF[$sel]}" ]; then
          tui_kv "key" "${M_IDF[$sel]}" \
            "$([ "${M_KEYOK[$sel]}" = "1" ] && printf '%s' "$T_OK" || printf '%s' "$T_ERR")"
          local kp="${M_IDF[$sel]/#\~/$HOME}"
          if [ -f "$kp" ]; then
            tui_kv "fingerprint" "$(keys_fp "$kp")"
            if keys_has_passphrase "$kp"; then tui_kv "passphrase" "protected" "$T_OK"
            else tui_kv "passphrase" "NONE" "$T_ERR"; fi
          fi
        else
          tui_kv "key" "none declared — falls back to your default identities" "$T_WARN"
        fi
        printf '\n'
        ui_note "connect with:  ssh ${M_ALIAS[$sel]}"
        ui_pause
        tui_begin; tui_dims; draw_machines; continue ;;
      quit|esc) break ;;
      *) continue ;;
    esac
    draw_mach "$prev" 0; draw_mach "$sel" 1
  done
  tui_end
  trap 'cleanup' EXIT INT TERM
  return 0
}
