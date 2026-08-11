#!/usr/bin/env bash
# lib/posture.sh — the findings engine.
#
# Everything this utility tripped over while being built is a problem power users
# have in the wild: world-readable metadata, SSH keys with no passphrase, orphan
# keys, plaintext .env files beside real work, credentials pasted into shell
# history, stale config backups holding old secrets, unbounded logs. None of it
# is exotic. All of it is detectable, most of it is fixable without judgement.
#
# CONTRACT
#   · a finding states the REAL impact, not a rule number
#   · a finding is either AUTO (safe to fix unattended) or GUIDED (needs you)
#   · nothing is reported fixed unless it was re-measured afterwards
#   · no fix is destructive without confirmation, and none touches a secret VALUE
#
# Finding record:  SEV|ID|KIND|TITLE|DETAIL|TARGET
#   SEV   crit | high | med | low
#   KIND  auto | guided | info
#
# Sourced, never executed.

posture_emit() { printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "${6:-}"; }

# --- detections ---------------------------------------------------------------
posture_scan() {
  local f m n p

  # --- SSH keys: enumerate ONCE, stat ONCE, parse the config ONCE ------------
  #
  # Checks 1, 2 and 4 all walk the same key list. This used to call
  # keys_private_paths three times, sec_mode/sec_mode_bad twice per key, and
  # keys_hosts_using once per key from two different checks — each of those an
  # awk parse of the entire ~/.ssh/config. Measured at ~260ms of the scan.
  local -a KEYS=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    KEYS+=("$f")
  done <<SCANK
$(keys_private_paths)
SCANK

  local -A KHOSTS=() KMODE=() KSTAMP=()
  local kb kh sp sm so smt sz
  while IFS="$(printf '\t')" read -r kb kh; do
    [ -n "$kb" ] || continue
    KHOSTS["$kb"]="$kh"
  done <<KMAP
$(keys_hosts_map)
KMAP

  if [ "${#KEYS[@]}" -gt 0 ]; then
    while IFS="$(printf '\t')" read -r sp sm so smt sz; do
      [ -n "$sp" ] || continue
      KMODE["$sp"]="$sm"; KSTAMP["$sp"]="$smt-$sz"
    done <<KSTAT
$(sec_stat_batch "${KEYS[@]}")
KSTAT
  fi

  local uses base mode
  for f in ${KEYS[@]+"${KEYS[@]}"}; do
    base="${f##*/}"
    uses="${KHOSTS[$base]:-}"
    mode="${KMODE[$f]:-}"

    # 1. no passphrase — a bearer credential on disk
    if ! keys_has_passphrase "$f" "${KSTAMP[$f]:-}"; then
      posture_emit crit ssh-nopass guided "SSH key has no passphrase" \
        "$base authenticates to ${uses:-nothing configured} with no secret to unlock it" "$f"
    fi

    # 2. readable by anyone else on the host
    case "$mode" in
      ''|600|400|000) ;;
      *[1-7][0-7]|*[0-7][1-7])
        posture_emit crit ssh-perms auto "SSH private key is readable by others" \
          "$base is mode $mode; anyone on this host can take it" "$f" ;;
    esac

    # 4. kept and trusted somewhere, but referenced by nothing
    if [ -z "$uses" ]; then
      posture_emit low ssh-orphan info "SSH key is referenced by nothing" \
        "$base is not used by any Host block, but may still be authorised somewhere" "$f"
    fi
  done

  # 3. IdentityFile entries pointing at keys that do not exist
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    posture_emit med ssh-gap info "SSH config points at a missing key" \
      "$f is referenced by ~/.ssh/config but does not exist — those hosts cannot authenticate" "$f"
  done <<SCAN3
$(keys_config_gaps)
SCAN3

  # 5. ForwardAgent — lets any host you reach use your keys against other hosts
  if grep -qiE '^[[:space:]]*forwardagent[[:space:]]+yes' "$HOME/.ssh/config" 2>/dev/null; then
    posture_emit high ssh-fwdagent guided "SSH agent forwarding is enabled" \
      "any host you connect to can use your loaded keys to reach everything else you trust" "$HOME/.ssh/config"
  fi

  # 6. Stale SSH config backups — old configs list hosts, ports, users, key paths
  n="$(ls -1 "$HOME"/.ssh/config.bak* 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${n:-0}" -gt 0 ]; then
    posture_emit low ssh-cfgbak guided "$n stale ~/.ssh/config backup(s)" \
      "each is a full map of your hosts, users, ports and key paths, kept indefinitely" ""
  fi

  # 7. age private key material
  if [ -f "$SOPS_AGE_KEY_FILE" ] && sec_mode_bad "$SOPS_AGE_KEY_FILE"; then
    posture_emit crit age-perms auto "age private key is readable by others" \
      "$SOPS_AGE_KEY_FILE is mode $(sec_mode "$SOPS_AGE_KEY_FILE") — it decrypts every vault" "$SOPS_AGE_KEY_FILE"
  fi

  # 8. Metadata files: no values, but a complete map of your access surface
  for f in "$SEC_SECRETS"/*.yaml "$SEC_SECRETS"/*.md; do
    [ -f "$f" ] || continue
    if sec_mode_bad "$f"; then
      posture_emit med meta-perms auto "Credential metadata is world-readable" \
        "${f##*/} is mode $(sec_mode "$f") and maps what you hold and where it is used" "$f"
    fi
  done

  # 9. Plaintext .env files sitting in real project directories
  while IFS= read -r p; do
    [ -d "$p" ] || continue
    for f in "$p"/.env "$p"/.env.local "$p"/.env.production; do
      [ -f "$f" ] || continue
      if grep -qE '^[A-Za-z_][A-Za-z0-9_]*=.{12,}' "$f" 2>/dev/null; then
        posture_emit high proj-dotenv guided "Plaintext .env in a project" \
          "${p##*/}/${f##*/} holds $(grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' "$f") value(s) in the clear, next to code" "$f"
      fi
    done
  done <<SCAN9
$(ws_discover 2>/dev/null | sort -u)
SCAN9

  # 10. Credentials pasted into shell history — extremely common, rarely noticed
  for f in "$HOME/.zsh_history" "$HOME/.bash_history"; do
    [ -f "$f" ] || continue
    n="$(grep -ciE '(api[_-]?key|secret|token|passwd|password)[=: ][A-Za-z0-9_./+-]{16,}' "$f" 2>/dev/null || true)"
    if [ "${n:-0}" -gt 0 ]; then
      posture_emit high shell-history guided "$n credential-shaped line(s) in shell history" \
        "${f##*/} contains what look like pasted secrets; history is plaintext and long-lived" "$f"
    fi
  done

  # 11. Run-log volume
  n="$(sec_log_count)"
  if [ "${n:-0}" -gt 1000 ]; then
    posture_emit low logs-bloat auto "Run logs are unbounded" \
      "$n log files retained; they accumulate forever without pruning" ""
  fi

  # 12. Recipient drift between the store and .sops.yaml
  sec_config_recipients > "$TMPD/p_cfg" 2>/dev/null
  sec_file_recipients "$SEC_STORE" > "$TMPD/p_file" 2>/dev/null
  if [ -n "$(comm -3 "$TMPD/p_cfg" "$TMPD/p_file" 2>/dev/null)" ]; then
    posture_emit high sops-drift guided "Store recipients differ from .sops.yaml" \
      "a host you think can decrypt may not, or one you removed may still be able to" "$SEC_STORE"
  fi

  # 13. Exposure rotation still outstanding
  if [ -f "$SEC_ROTATE" ]; then
    n="$(grep '^- \[ \]' "$SEC_ROTATE" 2>/dev/null | sec_nlines)"
    if [ "${n:-0}" -gt 0 ]; then
      posture_emit crit rotate-pending guided "$n credential(s) exposed and not yet rotated" \
        "these were readable in plaintext; deleting the file did not un-expose them" "$SEC_ROTATE"
    fi
  fi

  # 14. Undocumented credentials
  sec_manifest_keys > "$TMPD/p_mk" 2>/dev/null; sec_names > "$TMPD/p_sk" 2>/dev/null
  n="$(comm -23 "$TMPD/p_sk" "$TMPD/p_mk" 2>/dev/null | sec_nlines)"
  if [ "${n:-0}" -gt 0 ]; then
    posture_emit med undocumented auto "$n credential(s) with no record of purpose" \
      "you cannot rotate or revoke what you cannot say the purpose of" ""
  fi
}


# --- cached scan --------------------------------------------------------------
# A full scan shells out to ssh-keygen once per key and openssl once per cert.
# That is fine on demand and far too slow to run while painting a menu, so the
# home screen reads a short-lived cache instead. TTL is deliberately small: a
# stale posture is worse than a slow one, just not while drawing a row.
SEC_POSTURE_CACHE="$SEC_SECRETS/.posture-cache"
SEC_POSTURE_TTL="${SEC_POSTURE_TTL:-300}"

# posture_refresh_bg — rescan detached, replacing the cache atomically.
# The lock is a mkdir, which is atomic on every filesystem this will ever see;
# without it, opening several terminals at once starts several scans that all
# write the same file.
posture_refresh_bg() {
  local lock="$SEC_POSTURE_CACHE.lock"
  mkdir "$lock" 2>/dev/null || return 0        # a refresh is already running
  (
    trap 'rmdir "$lock" 2>/dev/null' EXIT
    local tmp="$SEC_POSTURE_CACHE.$$"
    if posture_scan > "$tmp" 2>/dev/null; then
      chmod 600 "$tmp" 2>/dev/null
      mv -f "$tmp" "$SEC_POSTURE_CACHE" 2>/dev/null
    else
      rm -f "$tmp" 2>/dev/null
    fi
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# posture_scan_cached — NEVER makes the caller wait for a rescan.
#
# The dashboard used to block on this. The scan takes about half a second (15
# ssh-keygen probes, a stat per key, an ~/.ssh/config parse per key), and with a
# 300-second TTL that meant every launch after a five-minute gap paid it: 0.4s
# normally, 1.0s at random. Unpredictable is worse than slow — you stop trusting
# that the program has started.
#
# Now a present cache is served immediately, however old, and a stale one
# triggers a detached refresh for next time. Only a FIRST run with no cache at
# all scans synchronously, because showing nothing would be a lie.
posture_scan_cached() {
  local age now mtime
  if [ -f "$SEC_POSTURE_CACHE" ]; then
    cat "$SEC_POSTURE_CACHE"
    mtime="$(sec_stat mtime "$SEC_POSTURE_CACHE")"
    now="$(date +%s)"; age=$(( now - ${mtime:-0} ))
    [ "$age" -ge "$SEC_POSTURE_TTL" ] && posture_refresh_bg
    return 0
  fi
  posture_scan > "$SEC_POSTURE_CACHE" 2>/dev/null
  chmod 600 "$SEC_POSTURE_CACHE" 2>/dev/null
  cat "$SEC_POSTURE_CACHE"
}

# posture_cache_age -> seconds since the cache was written, or empty
posture_cache_age() {
  [ -f "$SEC_POSTURE_CACHE" ] || return 1
  local m; m="$(sec_stat mtime "$SEC_POSTURE_CACHE")"
  [ -n "$m" ] || return 1
  printf '%s' $(( $(date +%s) - m ))
}
posture_invalidate() { rm -f "$SEC_POSTURE_CACHE" 2>/dev/null; }

# --- fixes --------------------------------------------------------------------
# Each returns 0 only after RE-MEASURING. No fix reports success on exit code.
posture_fix() {   # $1 id  $2 target -> 0 fixed, 1 not fixed, 2 needs you
  local id="$1" t="$2"
  case "$id" in
    ssh-perms|age-perms|meta-perms)
      chmod 600 "$t" 2>/dev/null
      [ -d "$t" ] && chmod 700 "$t" 2>/dev/null
      sec_mode_bad "$t" && return 1
      return 0 ;;
    logs-bloat)
      sec_log_prune 400 >/dev/null
      [ "$(sec_log_count)" -le 400 ] && return 0
      return 1 ;;
    undocumented)
      do_manifest >/dev/null 2>&1
      sec_manifest_keys > "$TMPD/f_mk"; sec_names > "$TMPD/f_sk"
      [ "$(comm -23 "$TMPD/f_sk" "$TMPD/f_mk" | sec_nlines)" = "0" ] && return 0
      return 1 ;;
    *) return 2 ;;
  esac
}

# posture_guidance ID TARGET — what YOU have to do, spelled out
posture_guidance() {
  case "$1" in
    ssh-nopass)
      printf 'Add a passphrase in place. The public half does not change, so nothing\n'
      printf 'you have already authorised needs re-deploying:\n\n'
      printf '    ssh-keygen -p -f %s\n' "$2"
      printf '    ssh-add --apple-use-keychain %s\n' "$2" ;;
    ssh-fwdagent)
      printf 'Agent forwarding lets the far host use your keys. Prefer ProxyJump, which\n'
      printf 'keeps the keys on this machine:\n\n'
      printf '    # in ~/.ssh/config, replace   ForwardAgent yes\n'
      printf '    # with                        ProxyJump <bastion-host>\n' ;;
    ssh-cfgbak)
      printf 'Review then remove. Each old config maps your hosts, users and key paths:\n\n'
      printf '    ls -la ~/.ssh/config.bak*\n'
      printf '    rm ~/.ssh/config.bak*\n' ;;
    proj-dotenv)
      printf 'Move these into the vault and inject them at run time instead:\n\n'
      printf '    secrets add MYKEY            # paste the value once, hidden\n'
      printf '    secrets run --only MYKEY -- npm run dev\n\n'
      printf 'Then delete %s and add it to .gitignore.\n' "$2" ;;
    shell-history)
      printf 'Find and prune the offending lines, then stop pasting secrets at a prompt:\n\n'
      printf "    grep -nE '(api[_-]?key|token|password)[=: ]' %s | less\n" "$2"
      printf '    # zsh: prefix a command with a space to keep it out of history\n'
      printf '    setopt HIST_IGNORE_SPACE\n' ;;
    sops-drift)
      printf 'Re-key the store to exactly the recipients declared in .sops.yaml:\n\n'
      printf '    sops updatekeys %s\n' "$2"
      printf '    secrets check      # prove this host still decrypts\n' ;;
    rotate-pending)
      printf 'Rotate each credential at its provider, then tick it off:\n\n'
      printf '    secrets rotate NAME    # guided; stamps the date and clears the flag\n\n'
      printf 'The list is %s\n' "$2" ;;
    ssh-gap)
      printf 'Either create the key or remove the IdentityFile line pointing at it:\n\n'
      printf '    grep -n "%s" ~/.ssh/config\n' "$2" ;;
    ssh-orphan)
      printf 'Confirm nothing still trusts it, then retire it:\n\n'
      printf '    ssh-keygen -lf %s.pub      # fingerprint to search for\n' "$2"
      printf '    # check authorized_keys on hosts that might still hold it\n' ;;
    *) printf 'No automated guidance for this finding.\n' ;;
  esac
}

posture_sev_rank() {
  case "$1" in crit) printf 0 ;; high) printf 1 ;; med) printf 2 ;; *) printf 3 ;; esac
}
posture_sev_colour() {
  case "$1" in
    crit) printf '%s' "$T_ERR" ;; high) printf '%s' "$N_ORANGE" ;;
    med)  printf '%s' "$T_WARN" ;; *)   printf '%s' "$T_DIM" ;;
  esac
}

# --- the screen ---------------------------------------------------------------
# Findings, worst first. Nothing here acts on its own: AUTO findings still need
# you to press f, GUIDED findings only ever show you the commands. The program
# keeps reporting every launch until you decide — it never decides for you.
posture_screen() {
  ui_interactive || { ui_needs_tty posture "secretsd posture --json    every finding, machine-readable"; return 1; }
  local -a P_SEV P_ID P_KIND P_TITLE P_DETAIL P_TARGET P_STATE O_LINE
  local n=0 line sev id kind title detail target

  ui_clear
  printf '\n  '; tui_grad_violet "scanning posture…"; printf '\n'

  while IFS='|' read -r sev id kind title detail target; do
    [ -n "$id" ] || continue
    P_SEV[$n]="$sev"; P_ID[$n]="$id"; P_KIND[$n]="$kind"
    P_TITLE[$n]="$title"; P_DETAIL[$n]="$detail"; P_TARGET[$n]="$target"
    P_STATE[$n]="open"
    n=$(( n + 1 ))
  done <<POSTURE
$(posture_invalidate; posture_scan | sort -t'|' -k1,1)
POSTURE

  # worst first: crit, high, med, low
  local -a O_SEV O_ID O_KIND O_TITLE O_DETAIL O_TARGET O_STATE
  local m=0 want i
  for want in crit high med low; do
    i=0
    while [ "$i" -lt "$n" ]; do
      if [ "${P_SEV[$i]}" = "$want" ]; then
        O_SEV[$m]="${P_SEV[$i]}"; O_ID[$m]="${P_ID[$i]}"; O_KIND[$m]="${P_KIND[$i]}"
        O_TITLE[$m]="${P_TITLE[$i]}"; O_DETAIL[$m]="${P_DETAIL[$i]}"
        O_TARGET[$m]="${P_TARGET[$i]}"; O_STATE[$m]="open"
        m=$(( m + 1 ))
      fi
      i=$(( i + 1 ))
    done
  done
  n="$m"

  if [ "$n" -eq 0 ]; then
    tui_page "POSTURE" "nothing outstanding"
    printf '\n'; ui_ok "every check passes on this host"
    ui_pause; return 0
  fi

  local sel=0 key prev curline host ncrit=0 nhigh=0
  host="$(hostname -s 2>/dev/null || echo host)"
  i=0
  while [ "$i" -lt "$n" ]; do
    [ "${O_SEV[$i]}" = "crit" ] && ncrit=$(( ncrit + 1 ))
    [ "${O_SEV[$i]}" = "high" ] && nhigh=$(( nhigh + 1 ))
    i=$(( i + 1 ))
  done

  draw_finding() {
    local k="$1" on="$2" c mark hue dot dlab
    c="$(posture_sev_colour "${O_SEV[$k]}")"
    case "${O_SEV[$k]}" in
      crit) mark='⣿⣿⣿'; hue="$T_ERR";    dot=err ;;
      high) mark='⣿⣿⡀'; hue="$N_ORANGE"; dot=err ;;
      med)  mark='⣿⡀⡀'; hue="$T_WARN";   dot=warn ;;
      *)    mark='⡀⡀⡀'; hue="$T_DIM";    dot=none ;;
    esac
    if [ "${O_STATE[$k]}" = "fixed" ]; then mark='⣿⣿⣿'; hue="$T_OK"; dot=ok; dlab="RESOLVED"
    else dlab="$(printf '%s · %s' "${O_SEV[$k]}" "${O_KIND[$k]}")"; fi
    printf '\033[%d;1H' "${O_LINE[$k]}"
    tui_modrow "$on" "$mark" "$hue" "$(tui_fit "${O_TITLE[$k]}" 40)" "" "$dot" "$dlab"
    tui_moddesc "$on" "$(tui_fit "${O_DETAIL[$k]}" $(( TUI_COLS - 12 )))"
  }

  draw_posture() {
    tui_home
    tui_header "$host" "$n finding(s) · $ncrit critical · $nhigh high · nothing is changed without you" "SECURITY POSTURE" posture
    curline=4
    i=0
    while [ "$i" -lt "$n" ]; do
      O_LINE[$i]="$(( curline + 1 ))"
      draw_finding "$i" "$([ "$i" = "$sel" ] && echo 1 || echo 0)"
      curline=$(( curline + 2 ))
      if [ "$i" -lt $(( n - 1 )) ]; then tui_blank; curline=$(( curline + 1 )); fi
      i=$(( i + 1 ))
    done
    local pad=$(( TUI_ROWS - curline - 2 )); [ "$pad" -lt 0 ] && pad=0
    i=0; while [ "$i" -lt "$pad" ]; do tui_blank; i=$(( i + 1 )); done
    tui_footer "↑↓ move" "↵ explain" "f fix this" "esc back"
    tui_clear_below
  }

  tui_begin
  trap 'tui_end; cleanup' EXIT INT TERM
  tui_dims; draw_posture

  while :; do
    key="$(tui_readkey)" || break
    prev="$sel"
    case "$key" in
      up)   sel=$(( sel - 1 )); [ "$sel" -lt 0 ] && sel=$(( n - 1 )) ;;
      down) sel=$(( sel + 1 )); [ "$sel" -ge "$n" ] && sel=0 ;;
      enter|right)
        tui_end
        tui_page "$(printf '%s' "${O_TITLE[$sel]}" | tr '[:lower:]' '[:upper:]')" \
                 "severity ${O_SEV[$sel]} · ${O_KIND[$sel]}"
        tui_kv "what"   "$(tui_fit "${O_DETAIL[$sel]}" $(( TUI_COLS - 24 )))"
        [ -n "${O_TARGET[$sel]}" ] && tui_kv "where" "$(tui_fit "${O_TARGET[$sel]}" $(( TUI_COLS - 24 )))"
        tui_kv "status" "${O_STATE[$sel]}"
        tui_section "WHAT TO DO"
        posture_guidance "${O_ID[$sel]}" "${O_TARGET[$sel]}" | sed 's/^/   /'
        printf '\n'
        if [ "${O_KIND[$sel]}" = "auto" ]; then
          ui_note "This one can be applied for you — press f on the list. It will be"
          ui_note "re-measured afterwards and only then reported as resolved."
        else
          ui_note "This one needs you. Nothing here will be run on your behalf."
        fi
        ui_pause
        tui_begin; tui_dims; draw_posture; continue ;;
      char:f)
        tui_end
        tui_page "FIX · ${O_TITLE[$sel]}" "${O_TARGET[$sel]:-this host}"
        if [ "${O_STATE[$sel]}" = "fixed" ]; then
          ui_ok "already resolved in this session"; ui_pause
        elif [ "${O_KIND[$sel]}" != "auto" ]; then
          # guided: the program still runs it, but only after you say yes
          posture_act "${O_ID[$sel]}" "${O_TARGET[$sel]}"
          case $? in
            0) O_STATE[$sel]="fixed" ;;
            1) ui_warn "still open" ;;
            2) ;;
          esac
          ui_pause
        else
          tui_kv "action" "$(posture_action_label "${O_ID[$sel]}")"
          [ -n "${O_TARGET[$sel]}" ] && tui_kv "target" "${O_TARGET[$sel]}"
          printf '\n'
          if ui_confirm "Apply this change?"; then
            if posture_fix "${O_ID[$sel]}" "${O_TARGET[$sel]}"; then
              O_STATE[$sel]="fixed"
              ui_ok "applied and re-measured — the condition is gone"
              sec_log_start "posture"; sec_log "fixed ${O_ID[$sel]} ${O_TARGET[$sel]}"
            else
              ui_err "the change did not take — nothing is being claimed as fixed"
            fi
          else
            ui_info "left as it was"
          fi
          ui_pause
        fi
        tui_begin; tui_dims; draw_posture; continue ;;
      quit|esc) break ;;
      *) continue ;;
    esac
    draw_finding "$prev" 0; draw_finding "$sel" 1
  done
  tui_end
  trap 'cleanup' EXIT INT TERM
  return 0
}

posture_action_label() {
  case "$1" in
    ssh-perms|age-perms|meta-perms) printf 'chmod 600 (700 if a directory)' ;;
    logs-bloat)   printf 'keep the 400 newest run logs, delete the rest' ;;
    undocumented) printf 'scaffold a manifest entry for each undocumented credential' ;;
    *) printf 'no automated action' ;;
  esac
}

# --- guided actions -----------------------------------------------------------
# A guided finding is one the program should not decide about — but that is no
# reason to make you retype commands. Each action below explains the change,
# asks once, runs it, and RE-MEASURES. Nothing runs without a yes, and nothing
# is called fixed on the strength of an exit code.
#
# Returns: 0 resolved · 1 attempted and still open · 2 declined/no action
posture_act() {
  local id="$1" t="$2"
  case "$id" in

    # ---- add a passphrase to an SSH key, in place ---------------------------
    ssh-nopass)
      tui_kv "key"     "$t"
      tui_kv "used by" "$(keys_hosts_using "$t" || echo 'nothing configured')"
      tui_kv "change"  "ssh-keygen -p -f $(basename "$t")"
      printf '\n'
      ui_note "The key material does NOT change — the same public half stays deployed,"
      ui_note "so nothing you have already authorised needs re-authorising."
      ui_warn "You will be asked for a new passphrase twice. There is no old one."
      printf '\n'
      ui_confirm "Add a passphrase to $(basename "$t") now?" || { ui_info "left unchanged"; return 2; }
      printf '\n'
      ssh-keygen -p -f "$t"
      printf '\n'
      if keys_has_passphrase "$t"; then
        ui_ok "re-measured: $(basename "$t") now requires a passphrase"
        sec_log_start posture; sec_log "passphrase added to $t"
        ui_note "load it once so you are not retyping it all day:"
        printf '     %sssh-add --apple-use-keychain %s%s\n' "$T_ACCENT" "$t" "$T_RS"
        return 0
      fi
      ui_err "still unprotected — the change did not take"
      return 1 ;;

    # ---- retire stale ~/.ssh/config backups ---------------------------------
    ssh-cfgbak)
      local n; n="$(ls -1 "$HOME"/.ssh/config.bak* 2>/dev/null | wc -l | tr -d ' ')"
      printf '   %sthese files each map your hosts, users, ports and key paths:%s\n\n' "$T_DIM" "$T_RS"
      ls -lt "$HOME"/.ssh/config.bak* 2>/dev/null | awk '{printf "     %s %s %s  %s\n", $6,$7,$8,$9}'
      printf '\n'
      ui_warn "This deletes $n file(s). Your live ~/.ssh/config is not touched."
      ui_confirm "Delete all $n stale config backup(s)?" || { ui_info "kept"; return 2; }
      rm -f "$HOME"/.ssh/config.bak*
      local left; left="$(ls -1 "$HOME"/.ssh/config.bak* 2>/dev/null | wc -l | tr -d ' ')"
      if [ "${left:-0}" -eq 0 ]; then
        ui_ok "re-measured: 0 stale backups remain"
        sec_log_start posture; sec_log "removed $n ssh config backups"
        return 0
      fi
      ui_err "$left still present"; return 1 ;;

    # ---- rotate the exposed credentials -------------------------------------
    rotate-pending)
      local pend; pend="$(grep '^- \[ \]' "$SEC_ROTATE" 2>/dev/null | sed 's/^- \[ \] //')"
      printf '   %sstill to rotate:%s\n\n' "$T_DIM" "$T_RS"
      printf '%s\n' "$pend" | head -12 | sed 's/^/     · /'
      [ "$(printf '%s\n' "$pend" | sec_nlines)" -gt 12 ] && printf '     … and more\n'
      printf '\n'
      ui_note "Rotation is per-credential: create the replacement at the provider,"
      ui_note "paste it here, then revoke the old one. Each one ticks itself off."
      printf '\n'
      ui_confirm "Start rotating now?" || { ui_info "not now"; return 2; }
      local one
      while :; do
        one="$(printf '%s\n' "$pend" | ui_filter 'credential to rotate')" || break
        [ -n "$one" ] || break
        api_rotate "$one"
        pend="$(grep '^- \[ \]' "$SEC_ROTATE" 2>/dev/null | sed 's/^- \[ \] //')"
        [ -z "$pend" ] && break
        ui_confirm "Rotate another?" || break
      done
      if [ -z "$(grep '^- \[ \]' "$SEC_ROTATE" 2>/dev/null)" ]; then
        ui_ok "re-measured: nothing left pending rotation"; return 0
      fi
      ui_info "$(grep '^- \[ \]' "$SEC_ROTATE" | sec_nlines) still pending"
      return 1 ;;

    # ---- re-key the store to the declared recipients ------------------------
    sops-drift)
      sec_config_recipients > "$TMPD/a_cfg"; sec_file_recipients "$t" > "$TMPD/a_file"
      printf '   %sdeclared in .sops.yaml but NOT on the file:%s\n' "$T_DIM" "$T_RS"
      comm -23 "$TMPD/a_cfg" "$TMPD/a_file" | sed 's/^/     + /' || true
      printf '   %son the file but NOT declared:%s\n' "$T_DIM" "$T_RS"
      comm -13 "$TMPD/a_cfg" "$TMPD/a_file" | sed 's/^/     - /' || true
      printf '\n'
      ui_warn "Re-keying rewrites who can decrypt. Secret values are unchanged."
      ui_confirm "Run sops updatekeys on $(basename "$t")?" || { ui_info "left as it was"; return 2; }
      sops updatekeys -y "$t" || { ui_err "updatekeys failed"; return 1; }
      sec_file_recipients "$t" > "$TMPD/a_after"
      if [ -z "$(comm -3 "$TMPD/a_cfg" "$TMPD/a_after")" ] && vault_can_decrypt "$t"; then
        ui_ok "re-measured: recipients match .sops.yaml and this host still decrypts"
        sec_log_start posture; sec_log "updatekeys $t"
        return 0
      fi
      ui_err "recipients still differ, or this host can no longer decrypt"
      return 1 ;;

    # ---- prune credential-shaped lines from shell history -------------------
    shell-history)
      local pat='(api[_-]?key|secret|token|passwd|password)[=: ][A-Za-z0-9_./+-]{16,}'
      local hits; hits="$(grep -ciE "$pat" "$t" 2>/dev/null)"
      printf '   %s%s matching line(s) in %s%s\n\n' "$T_MUTE" "$hits" "$t" "$T_RS"
      printf '   %spreview (values masked):%s\n' "$T_DIM" "$T_RS"
      grep -nEi "$pat" "$t" 2>/dev/null | head -6 \
        | sed -E 's/([=: ])[A-Za-z0-9_./+-]{16,}/\1••••••••••••••••/g' | sed 's/^/     /'
      printf '\n'
      ui_warn "This rewrites $t, keeping a 0600 backup beside it first."
      ui_confirm "Remove those $hits line(s) from history?" || { ui_info "history untouched"; return 2; }
      local bak="$t.pre-scrub-$(date +%Y%m%d-%H%M%S)"
      cp -p "$t" "$bak" && chmod 600 "$bak"
      grep -vEi "$pat" "$t" > "$TMPD/hist" && cat "$TMPD/hist" > "$t"
      local after; after="$(grep -ciE "$pat" "$t" 2>/dev/null)"
      if [ "${after:-0}" -eq 0 ]; then
        ui_ok "re-measured: 0 credential-shaped lines remain"
        ui_note "backup kept at $bak — delete it once you are happy"
        ui_note "stop future ones with: setopt HIST_IGNORE_SPACE (then prefix commands with a space)"
        sec_log_start posture; sec_log "scrubbed $hits lines from $(basename "$t")"
        return 0
      fi
      ui_err "$after still match"; return 1 ;;

    # ---- move a project .env into the vault ---------------------------------
    proj-dotenv)
      local names; names="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$t" 2>/dev/null | sed 's/=$//' | sort -u)"
      printf '   %skeys in %s:%s\n\n' "$T_DIM" "$t" "$T_RS"
      printf '%s\n' "$names" | sed 's/^/     · /'
      printf '\n'
      ui_note "These will be read from the file and written into the vault, encrypted."
      ui_note "Values are never printed. Afterwards you run the app with:"
      printf '     %ssecrets run --only KEY1,KEY2 -- your-command%s\n\n' "$T_ACCENT" "$T_RS"
      ui_confirm "Import these into the vault now?" || { ui_info "nothing imported"; return 2; }
      local k v imported=0
      while IFS= read -r k; do
        [ -n "$k" ] || continue
        v="$(grep -m1 "^$k=" "$t" | cut -d= -f2- | sed 's/^"//; s/"$//')"
        [ -n "$v" ] || continue
        if sec_has "$k"; then
          ui_warn "$k already in the vault — skipped (rotate it deliberately instead)"
          continue
        fi
        if sec_put "$k" "$v"; then imported=$(( imported + 1 )); ui_ok "imported $k"; fi
        unset v
      done <<DOTENV
$names
DOTENV
      ui_ok "$imported credential(s) now encrypted in the vault"
      printf '\n'
      ui_warn "The plaintext file still exists at $t"
      if ui_confirm "Delete $(basename "$t") now that it is in the vault?"; then
        rm -f "$t"
        [ -f "$t" ] && { ui_err "could not delete"; return 1; }
        ui_ok "re-measured: plaintext file is gone"
        ui_note "add it to .gitignore so it cannot come back:"
        printf '     %secho "%s" >> %s/.gitignore%s\n' "$T_ACCENT" "$(basename "$t")" "$(dirname "$t")" "$T_RS"
        sec_log_start posture; sec_log "imported $imported keys from $t and removed it"
        return 0
      fi
      ui_info "left in place — the finding stays open until it is gone"
      return 1 ;;

    # ---- config gap: open the config where it is referenced -----------------
    ssh-gap)
      printf '   %sreferenced at:%s\n\n' "$T_DIM" "$T_RS"
      grep -n "$(basename "$t")" "$HOME/.ssh/config" 2>/dev/null | sed 's/^/     /'
      printf '\n'
      ui_note "Either create the key or remove the IdentityFile line."
      ui_confirm "Open ~/.ssh/config in your editor?" || return 2
      "${SECRET_EDITOR:-${EDITOR:-vi}}" "$HOME/.ssh/config"
      if [ "$(keys_config_gaps | grep -cF "$t")" = "0" ]; then
        ui_ok "re-measured: that gap is gone"; return 0
      fi
      ui_info "still referenced"; return 1 ;;

    # ---- orphan key: archive rather than delete -----------------------------
    ssh-orphan)
      local arch="$HOME/.ssh/retired"
      tui_kv "key"         "$t"
      tui_kv "fingerprint" "$(keys_fp "$t")"
      printf '\n'
      ui_warn "It may still be authorised on hosts you cannot see from here."
      ui_note "Archiving moves it to $arch — reversible, unlike deleting."
      ui_note "Check the fingerprint against authorized_keys on any host you suspect first."
      printf '\n'
      ui_confirm "Archive $(basename "$t") and its public half?" || { ui_info "kept in place"; return 2; }
      mkdir -p "$arch" && chmod 700 "$arch"
      mv "$t" "$arch/" 2>/dev/null
      [ -f "$t.pub" ] && mv "$t.pub" "$arch/" 2>/dev/null
      if [ ! -f "$t" ]; then
        ui_ok "re-measured: moved to $arch"
        sec_log_start posture; sec_log "archived orphan key $t"
        return 0
      fi
      ui_err "could not move it"; return 1 ;;

    ssh-fwdagent)
      printf '   %sForwardAgent lines in your config:%s\n\n' "$T_DIM" "$T_RS"
      grep -niE '^[[:space:]]*forwardagent' "$HOME/.ssh/config" | sed 's/^/     /'
      printf '\n'
      ui_note "ProxyJump is the safe replacement — it keeps keys on this machine."
      ui_confirm "Open ~/.ssh/config to change it?" || return 2
      "${SECRET_EDITOR:-${EDITOR:-vi}}" "$HOME/.ssh/config"
      if ! grep -qiE '^[[:space:]]*forwardagent[[:space:]]+yes' "$HOME/.ssh/config"; then
        ui_ok "re-measured: agent forwarding is no longer enabled"; return 0
      fi
      ui_info "still enabled"; return 1 ;;

    *) return 2 ;;
  esac
}
