#!/usr/bin/env bash
# lib/alerts.sh — proactive expiry alerts.
#
# Every credential that has ever bitten someone did so on a day nobody was
# looking at a dashboard. `secretsd expiring` is correct and useless if you only
# run it after the outage. This runs the same scan on a schedule and comes to
# YOU: a desktop notification, a written report, and a terminal banner the next
# time you open the program.
#
# WHAT IT LOOKS AT — three sources, because expiry lives in three places:
#   1. manifest `expires:` fields — the dates you recorded yourself
#   2. certificate files — read from the PEM, authoritative, no bookkeeping
#   3. credentials with NO recorded expiry — reported as UNKNOWN, not as fine.
#      An unknown expiry is a finding. Silence about it is how the DoD email CA
#      on this machine sat 494 days expired without anyone noticing.
#
# WHAT IT WILL NOT DO: rotate anything, delete anything, or "renew" anything.
# It tells you, repeatedly, and it keeps telling you until you act. That is the
# whole enforcement model of this program — the user keeps final say, and the
# program keeps nagging.
#
# Sourced, never executed.

ALERT_STATE="$SEC_ROOT/state/alerts.state"
ALERT_REPORT="$SEC_ROOT/state/expiry-report.md"
ALERT_LOG="$SEC_ROOT/state/alerts.log"
ALERT_PLIST="$HOME/Library/LaunchAgents/com.secretsd.alerts.plist"

# Thresholds. A cert you have 60 days to replace is a calendar entry; one you
# have 7 days to replace is a problem; one that has expired is an outage you
# have not noticed yet.
ALERT_SOON="${SECRETSD_ALERT_SOON:-30}"
ALERT_URGENT="${SECRETSD_ALERT_URGENT:-7}"

alert_log() {
  mkdir -p "$(dirname "$ALERT_LOG")" 2>/dev/null
  printf '%s  %s\n' "$(date -u +%FT%TZ)" "$*" >> "$ALERT_LOG" 2>/dev/null
  chmod 600 "$ALERT_LOG" 2>/dev/null
}

# --- the scan ----------------------------------------------------------------
# Emits: severity|source|name|detail|days_left
#   severity: expired | urgent | soon | unknown
alert_scan() {
  local now n exp e left
  now="$(date +%s)"

  # 1 · manifest-recorded expiry
  #
  # This deliberately does NOT skip when the manifest is missing. A store with
  # no manifest has NO recorded expiry for anything, which is the worst case,
  # not a clean one — and an early return here would report it as silence. That
  # is exactly the failure this whole file exists to prevent, so the loop runs
  # regardless and sec_manifest_field simply returns empty for every key.
  if true; then
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      exp="$(sec_manifest_field "$n" expires 2>/dev/null)"
      case "$exp" in
        none) ;;                       # explicitly declared as never expiring
        ""|TODO|*TODO*)
          printf 'unknown|manifest|%s|no expiry recorded — nobody knows when this dies|\n' "$n" ;;
        *)
          e="$(sec_epoch_of "$exp")"
          if [ -z "$e" ]; then
            printf 'unknown|manifest|%s|expiry "%s" is not a date this can parse|\n' "$n" "$exp"
          else
            left=$(( (e - now) / 86400 ))
            if   [ "$left" -lt 0 ];              then printf 'expired|manifest|%s|expired on %s|%s\n' "$n" "$exp" "$left"
            elif [ "$left" -le "$ALERT_URGENT" ]; then printf 'urgent|manifest|%s|expires %s|%s\n'  "$n" "$exp" "$left"
            elif [ "$left" -le "$ALERT_SOON" ];   then printf 'soon|manifest|%s|expires %s|%s\n'    "$n" "$exp" "$left"
            fi
          fi ;;
      esac
    done <<AMAN
$(sec_names)
AMAN
  fi

  # 2 · certificates on disk — the PEM is the truth, no bookkeeping required
  local f d subj
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    d="$(certs_days_left "$f" 2>/dev/null)"
    case "$d" in ''|*[!0-9-]*) continue ;; esac
    subj="$(basename "$f")"
    if   [ "$d" -lt 0 ];               then printf 'expired|cert|%s|expired %s day(s) ago — %s|%s\n' "$subj" "$(( -d ))" "$f" "$d"
    elif [ "$d" -le "$ALERT_URGENT" ]; then printf 'urgent|cert|%s|expires in %s day(s) — %s|%s\n'   "$subj" "$d" "$f" "$d"
    elif [ "$d" -le "$ALERT_SOON" ];   then printf 'soon|cert|%s|expires in %s day(s) — %s|%s\n'     "$subj" "$d" "$f" "$d"
    fi
  done <<ACERT
$(certs_find 2>/dev/null)
ACERT
}

alert_counts() {   # stdin: scan records -> "expired urgent soon unknown"
  awk -F'|' '
    $1=="expired"{e++} $1=="urgent"{u++} $1=="soon"{s++} $1=="unknown"{k++}
    END{printf "%d %d %d %d", e+0, u+0, s+0, k+0}'
}

# --- delivery ----------------------------------------------------------------
# A notification is best-effort by nature: the user may have Do Not Disturb on,
# or notifications denied. The written report is the reliable channel, so the
# report is always produced and the notification is a bonus.
alert_notify() {   # $1 title  $2 body
  case "$(uname -s)" in
    Darwin)
      command -v terminal-notifier >/dev/null 2>&1 && {
        terminal-notifier -title "$1" -message "$2" -group com.secretsd.alerts >/dev/null 2>&1 && return 0; }
      command -v osascript >/dev/null 2>&1 && {
        osascript -e "display notification \"$(printf '%s' "$2" | sed 's/"/\\\\"/g')\" with title \"$(printf '%s' "$1" | sed 's/"/\\\\"/g')\"" >/dev/null 2>&1 && return 0; }
      ;;
    Linux)
      command -v notify-send >/dev/null 2>&1 && { notify-send "$1" "$2" >/dev/null 2>&1 && return 0; } ;;
  esac
  return 1
}

alert_write_report() {   # stdin: scan records
  local recs; recs="$(cat)"
  mkdir -p "$(dirname "$ALERT_REPORT")" 2>/dev/null
  {
    printf '# Credential expiry — %s\n\n' "$(date -u +%FT%TZ)"
    printf 'Host: `%s`\n\n' "$(hostname -s 2>/dev/null)"
    local sev label
    for sev in expired urgent soon unknown; do
      case "$sev" in
        expired) label="EXPIRED — already broken, you just have not hit it yet" ;;
        urgent)  label="URGENT — inside $ALERT_URGENT days" ;;
        soon)    label="SOON — inside $ALERT_SOON days" ;;
        unknown) label="EXPIRY UNKNOWN — no date recorded, which is itself a finding" ;;
      esac
      local body
      body="$(printf '%s\n' "$recs" | awk -F'|' -v s="$sev" '$1==s {printf "- **%s** (%s) — %s\n", $3, $2, $4}')"
      [ -n "$body" ] || continue
      printf '## %s\n\n%s\n\n' "$label" "$body"
    done
    printf -- '---\n\nsecretsd does not rotate or renew anything for you. It reports, and it keeps\nreporting until the finding is gone.\n'
  } > "$ALERT_REPORT"
  chmod 600 "$ALERT_REPORT" 2>/dev/null
}

# alert_run — the scheduled entry point. Quiet when there is nothing to say.
alert_run() {
  local recs c expired urgent soon unknown
  recs="$(alert_scan)"
  c="$(printf '%s\n' "$recs" | alert_counts)"
  expired="$(printf '%s' "$c" | cut -d' ' -f1)"
  urgent="$(printf '%s'  "$c" | cut -d' ' -f2)"
  soon="$(printf '%s'    "$c" | cut -d' ' -f3)"
  unknown="$(printf '%s' "$c" | cut -d' ' -f4)"

  printf '%s\n' "$recs" | alert_write_report

  mkdir -p "$(dirname "$ALERT_STATE")" 2>/dev/null
  {
    printf 'checked:  %s\n' "$(date -u +%FT%TZ)"
    printf 'expired:  %s\n' "$expired"
    printf 'urgent:   %s\n' "$urgent"
    printf 'soon:     %s\n' "$soon"
    printf 'unknown:  %s\n' "$unknown"
  } > "$ALERT_STATE"
  chmod 600 "$ALERT_STATE" 2>/dev/null

  local actionable=$(( expired + urgent + soon ))
  if [ "$actionable" -gt 0 ]; then
    local title body
    if [ "$expired" -gt 0 ]; then title="secretsd — $expired credential(s) EXPIRED"
    elif [ "$urgent" -gt 0 ]; then title="secretsd — $urgent expiring within $ALERT_URGENT days"
    else title="secretsd — $soon expiring within $ALERT_SOON days"; fi
    body="$expired expired · $urgent urgent · $soon soon · $unknown with no recorded expiry. Run: secretsd expiring"
    if alert_notify "$title" "$body"; then alert_log "notified: $title"
    else alert_log "notification unavailable; report written to $ALERT_REPORT"; fi
  else
    alert_log "clean — nothing expired or expiring within $ALERT_SOON days ($unknown unknown)"
  fi

  printf '%s\n' "$recs"
  [ "$expired" -gt 0 ] && return 2
  [ "$actionable" -gt 0 ] && return 1
  return 0
}

# alert_banner — the one-line nag printed at the top of the dashboard.
# Reads the cached state, so opening the program never waits on a scan.
alert_banner() {
  [ -f "$ALERT_STATE" ] || return 0
  local expired urgent soon
  expired="$(mon_field "$(cat "$ALERT_STATE")" expired 2>/dev/null)"
  urgent="$(mon_field  "$(cat "$ALERT_STATE")" urgent  2>/dev/null)"
  soon="$(mon_field    "$(cat "$ALERT_STATE")" soon    2>/dev/null)"
  expired="${expired:-0}"; urgent="${urgent:-0}"; soon="${soon:-0}"
  if [ "$expired" -gt 0 ]; then
    printf '  %s  %s credential(s) are past their expiry date — secretsd expiring\n' \
      "$(tui_badge EXPIRED bad)" "$expired"
  elif [ "$urgent" -gt 0 ]; then
    printf '  %s  %s credential(s) expire within %s days — secretsd expiring\n' \
      "$(tui_badge URGENT warn)" "$urgent" "$ALERT_URGENT"
  elif [ "$soon" -gt 0 ]; then
    printf '  %s%s credential(s) expire within %s days%s\n' "$T_DIM" "$soon" "$ALERT_SOON" "$T_RS"
  fi
}

# --- scheduling --------------------------------------------------------------
alert_schedule_install() {   # $1 hour-of-day (0-23)
  local hour="${1:-9}"
  mkdir -p "$HOME/Library/LaunchAgents" 2>/dev/null
  cat > "$ALERT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.secretsd.alerts</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SEC_SELF</string>
    <string>alerts</string>
    <string>run</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SECRETSD_HOME</key><string>$SEC_ROOT</string>
    <key>SOPS_AGE_KEY_FILE</key><string>$SOPS_AGE_KEY_FILE</string>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>$hour</integer><key>Minute</key><integer>0</integer></dict>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>$SEC_ROOT/state/alerts.out</string>
  <key>StandardErrorPath</key><string>$SEC_ROOT/state/alerts.err</string>
</dict></plist>
PLIST
  launchctl unload "$ALERT_PLIST" >/dev/null 2>&1
  launchctl load   "$ALERT_PLIST" >/dev/null 2>&1
  launchctl list 2>/dev/null | grep -q 'com.secretsd.alerts'
}

alert_scheduled() { launchctl list 2>/dev/null | grep -q 'com.secretsd.alerts'; }

alert_schedule_remove() {
  launchctl unload "$ALERT_PLIST" >/dev/null 2>&1
  rm -f "$ALERT_PLIST" 2>/dev/null
  ! alert_scheduled
}

alert_schedule_hour() {
  [ -f "$ALERT_PLIST" ] || return 1
  awk '/<key>Hour<\/key>/{getline; gsub(/[^0-9]/,""); print; exit}' "$ALERT_PLIST" 2>/dev/null
}

# --- screen ------------------------------------------------------------------
alerts_screen() {
  ui_interactive || { alert_run >/dev/null; return $?; }

  while :; do
    local expired=0 urgent=0 soon=0 unknown=0 checked="never"
    if [ -f "$ALERT_STATE" ]; then
      local st; st="$(cat "$ALERT_STATE")"
      checked="$(mon_field "$st" checked)"
      expired="$(mon_field "$st" expired)"; urgent="$(mon_field "$st" urgent)"
      soon="$(mon_field "$st" soon)";       unknown="$(mon_field "$st" unknown)"
    fi

    tui_page "EXPIRY ALERTS" "it comes to you, instead of waiting to be asked"
    printf '\n'
    tui_kv "last checked" "${checked:-never}"
    tui_kv "expired"      "${expired:-0}" "$([ "${expired:-0}" -gt 0 ] && printf '%s' "$T_ERR"  || printf '%s' "$T_OK")"
    tui_kv "urgent (≤${ALERT_URGENT}d)" "${urgent:-0}"  "$([ "${urgent:-0}" -gt 0 ]  && printf '%s' "$T_WARN" || printf '%s' "$T_OK")"
    tui_kv "soon (≤${ALERT_SOON}d)"     "${soon:-0}"    "$([ "${soon:-0}" -gt 0 ]    && printf '%s' "$T_WARN" || printf '%s' "$T_OK")"
    tui_kv "expiry unknown"             "${unknown:-0}" "$T_DIM"
    printf '\n'
    if alert_scheduled; then
      tui_kv "schedule" "daily at $(alert_schedule_hour):00 — verified loaded in launchctl" "$T_OK"
    else
      tui_kv "schedule" "not scheduled — nothing will remind you" "$T_WARN"
    fi
    [ -f "$ALERT_REPORT" ] && tui_kv "report" "$ALERT_REPORT" "$T_DIM"
    printf '\n'
    ui_note "This never rotates or renews anything. It reports, and keeps reporting."
    printf '\n'

    local pick
    pick="$(tui_menu 'EXPIRY ALERTS' \
      "s|scan now|run the full scan and show what it finds" \
      "r|read the report|the written report from the last scan" \
      "e|schedule daily|install the launchd agent (verified after install)" \
      "x|remove the schedule|stop the daily check" \
      "q|back|")" || return 0

    case "$pick" in
      s)
        ui_clear; printf '\n  '; tui_grad_violet 'scanning manifest expiry and certificates on disk…'; printf '\n\n'
        local recs; recs="$(alert_run)"; local rc=$?
        if [ -z "$(printf '%s' "$recs" | tr -d '[:space:]')" ]; then
          ui_ok "nothing expired, nothing expiring, and every expiry is recorded"
        else
          local sev label
          for sev in expired urgent soon unknown; do
            case "$sev" in
              expired) label="EXPIRED" ;;
              urgent)  label="URGENT (≤${ALERT_URGENT}d)" ;;
              soon)    label="SOON (≤${ALERT_SOON}d)" ;;
              unknown) label="EXPIRY UNKNOWN" ;;
            esac
            local body; body="$(printf '%s\n' "$recs" | awk -F'|' -v s="$sev" '$1==s')"
            [ -n "$body" ] || continue
            ui_rule "$label"
            printf '%s\n' "$body" | head -20 | awk -F'|' '{printf "   %-40s %s\n", substr($3,1,40), $4}'
            local more; more="$(printf '%s\n' "$body" | sec_nlines)"
            [ "$more" -gt 20 ] && printf '   %s… and %s more%s\n' "$T_DIM" "$(( more - 20 ))" "$T_RS"
          done
          printf '\n'
          ui_note "written to $ALERT_REPORT"
        fi
        printf '\n'; ui_pause ;;
      r)
        if [ -f "$ALERT_REPORT" ]; then
          ui_clear; printf '\n'
          if command -v glow >/dev/null 2>&1; then glow -p "$ALERT_REPORT"
          else sed 's/^/  /' "$ALERT_REPORT" | ${PAGER:-less -R}; fi
        else
          ui_warn "no report yet — run a scan first"; ui_pause
        fi ;;
      e)
        if [ "$(uname -s)" != "Darwin" ]; then
          ui_err "scheduling here is launchd, which is macOS only"
          ui_note "on Linux, add a cron entry:  0 9 * * *  $SEC_SELF alerts run"
          ui_pause; continue
        fi
        local hour
        hour="$(ui_ask 'hour of day to check, 0-23' "$(alert_schedule_hour 2>/dev/null || printf '9')")" || continue
        case "$hour" in ''|*[!0-9]*) ui_err "not a number"; ui_pause; continue ;; esac
        [ "$hour" -ge 0 ] && [ "$hour" -le 23 ] || { ui_err "0-23"; ui_pause; continue; }
        if alert_schedule_install "$hour"; then
          ui_ok "scheduled daily at ${hour}:00 — verified loaded in launchctl"
          launchctl list 2>/dev/null | grep 'com.secretsd.alerts' | sed 's/^/     /'
        else
          ui_err "launchctl did not report the agent as loaded"
          ui_note "check: launchctl load $ALERT_PLIST"
        fi
        ui_pause ;;
      x)
        if alert_schedule_remove; then ui_ok "removed — verified gone from launchctl"
        else ui_err "still present in launchctl"; fi
        ui_pause ;;
      q|"") return 0 ;;
    esac
  done
}
