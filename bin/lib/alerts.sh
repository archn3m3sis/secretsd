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
alert_schedule_install() {   # $1 hour-of-day (0-23)  $2 minute (0-59)
  local hour="${1:-9}" minute="${2:-0}"
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
  <dict><key>Hour</key><integer>$hour</integer><key>Minute</key><integer>$minute</integer></dict>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>$SEC_ROOT/state/alerts.out</string>
  <key>StandardErrorPath</key><string>$SEC_ROOT/state/alerts.err</string>
</dict></plist>
PLIST
  launchctl unload "$ALERT_PLIST" >/dev/null 2>&1
  launchctl load   "$ALERT_PLIST" >/dev/null 2>&1
  launchctl list 2>/dev/null | ui_match_sub 'com.secretsd.alerts'
}

alert_scheduled() { launchctl list 2>/dev/null | ui_match_sub 'com.secretsd.alerts'; }

alert_schedule_remove() {
  launchctl unload "$ALERT_PLIST" >/dev/null 2>&1
  rm -f "$ALERT_PLIST" 2>/dev/null
  ! alert_scheduled
}

# The plist writes <key>Hour</key><integer>N</integer> on ONE line, so reading
# the NEXT line (the obvious approach, and the first one here) always returned
# empty and the screen showed "daily at :00".
alert_schedule_hour() {
  [ -f "$ALERT_PLIST" ] || return 1
  ui_plist_int "$ALERT_PLIST" Hour
}
alert_schedule_min() {
  [ -f "$ALERT_PLIST" ] || return 1
  ui_plist_int "$ALERT_PLIST" Minute || printf '0'
}
# alert_schedule_at -> "HH:MM" of the installed schedule
alert_schedule_at() {
  local h m
  h="$(alert_schedule_hour)" || return 1
  m="$(alert_schedule_min)"; m="${m:-0}"
  printf '%02d:%02d' "$h" "$m"
}

# --- screen ------------------------------------------------------------------
# alert_report_text — the plain-text report, for anything that is not a TUI:
# a pipe, a redirect, CI, or a shell with no controlling terminal. This exists
# because the first version sent the non-interactive path to /dev/null and
# "succeeded" in total silence, which is indistinguishable from doing nothing.
alert_report_text() {
  local recs="$1" rc="$2" sev label body more
  printf '\n  CREDENTIAL EXPIRY — %s\n' "$(date '+%Y-%m-%d %H:%M %Z')"
  printf '  host %s · thresholds: urgent ≤%sd, soon ≤%sd\n\n' \
    "$(hostname -s 2>/dev/null)" "$ALERT_URGENT" "$ALERT_SOON"

  for sev in expired urgent soon; do
    case "$sev" in
      expired) label="EXPIRED — already broken, you just have not hit it yet" ;;
      urgent)  label="URGENT — inside $ALERT_URGENT days" ;;
      soon)    label="SOON — inside $ALERT_SOON days" ;;
    esac
    body="$(printf '%s\n' "$recs" | awk -F'|' -v s="$sev" '$1==s')"
    [ -n "$body" ] || continue
    printf '  %s\n' "$label"
    printf '%s\n' "$body" | awk -F'|' '{printf "    %-28s %s\n", substr($3,1,28), $4}'
    printf '\n'
  done

  body="$(printf '%s\n' "$recs" | awk -F'|' '$1=="unknown"')"
  if [ -n "$body" ]; then
    more="$(printf '%s\n' "$body" | sec_nlines)"
    printf '  NO EXPIRY RECORDED — %s credential(s), which is itself a finding\n' "$more"
    printf '%s\n' "$body" | head -8 | awk -F'|' '{printf "    %s\n", $3}'
    [ "$more" -gt 8 ] && printf '    … and %s more\n' "$(( more - 8 ))"
    printf '\n'
  fi

  case "$rc" in
    0) printf '  Nothing expired and nothing due.\n' ;;
    *) printf '  Full report: %s\n' "$ALERT_REPORT" ;;
  esac
  printf '  This never rotates or renews anything. It reports, and keeps reporting.\n\n'
}

alerts_screen() {
  # No terminal (a pipe, `!` from an editor, cron, CI): run the scan and PRINT
  # the result. Never exit silently — a command that does its work and shows
  # nothing is indistinguishable from a command that did nothing at all.
  if ! ui_interactive; then
    local recs rc
    recs="$(alert_run)"; rc=$?
    alert_report_text "$recs" "$rc"
    return $rc
  fi

  while :; do
    local expired=0 urgent=0 soon=0 unknown=0 checked="never"
    if [ -f "$ALERT_STATE" ]; then
      local st; st="$(cat "$ALERT_STATE")"
      checked="$(mon_field "$st" checked)"
      expired="$(mon_field "$st" expired)"; urgent="$(mon_field "$st" urgent)"
      soon="$(mon_field "$st" soon)";       unknown="$(mon_field "$st" unknown)"
    fi

    TUI_MENU_ICON=alerts
    TUI_MENU_PANEL="$(
      {
        printf 'expired\t%s\t%s\n' "${expired:-0}" \
          "$([ "${expired:-0}" -gt 0 ] && printf '%s' "$T_ERR"  || printf '%s' "$T_OK")"
        printf 'urgent  (≤%sd)\t%s\t%s\n' "$ALERT_URGENT" "${urgent:-0}" \
          "$([ "${urgent:-0}" -gt 0 ] && printf '%s' "$T_WARN" || printf '%s' "$T_OK")"
        printf 'soon  (≤%sd)\t%s\t%s\n' "$ALERT_SOON" "${soon:-0}" \
          "$([ "${soon:-0}" -gt 0 ] && printf '%s' "$T_WARN" || printf '%s' "$T_OK")"
        printf 'no expiry recorded\t%s\t%s\n' "${unknown:-0}" \
          "$([ "${unknown:-0}" -gt 0 ] && printf '%s' "$T_WARN" || printf '%s' "$T_OK")"
        printf 'last checked\t%s\t%s\n' "${checked:-never}" "$T_MUTE"
        if alert_scheduled; then
          printf 'schedule\tdaily at %s, verified in launchctl\t%s\n' "$(alert_schedule_at)" "$T_OK"
        else
          printf 'schedule\tnot scheduled — nothing will remind you\t%s\n' "$T_WARN"
        fi
      } | tui_kvgroup
    )"

    # The subtitle is the one-line verdict; the panel below carries the numbers.
    local pick summary
    if   [ "${expired:-0}" -gt 0 ]; then summary="$expired expired — already broken, you have just not hit it yet"
    elif [ "${urgent:-0}" -gt 0 ];  then summary="$urgent expiring within $ALERT_URGENT days"
    elif [ "${soon:-0}" -gt 0 ];    then summary="$soon expiring within $ALERT_SOON days"
    elif [ -n "$checked" ];         then summary="nothing expired and nothing due"
    else summary="never scanned — nothing is watching this yet"; fi

    pick="$(tui_menu "EXPIRY ALERTS" "$summary" \
      "Scan now|read every certificate and recorded date, and say what is dying" \
      "Read the report|the written report from the last scan" \
      "Schedule it daily|a launchd agent that checks and notifies without being asked" \
      "Stop the schedule|remove the daily check" \
      "Back|change nothing")" || return 0

    case "$pick" in
      "Scan now")
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
      "Read the report")
        if [ ! -f "$ALERT_REPORT" ]; then
          ui_warn "no report yet — run a scan first"; ui_pause; continue
        fi
        # Rendered, not dumped. Piping raw markdown into a pager shows the
        # reader literal ## and ** and makes the program look unfinished at the
        # exact moment it is delivering its most important output.
        TUI_PAGE_MARK='⠈⣿⠁'
        tui_page "EXPIRY REPORT" "${ALERT_REPORT#$SEC_ROOT/}"
        printf '\n'
        {
          while IFS= read -r line; do
            case "$line" in
              '# '*)   ;;                                  # the page header already says this
              '## '*)  printf '\n  %s%s%s\n' "$T_B$T_ACCENT" "${line#\#\# }" "$T_RS" ;;
              '- '*)
                line="${line#- }"
                line="${line//\*\*/}"
                printf '     %s•%s %s\n' "$T_LEAD" "$T_RS" "$(tui_fit "$line" $(( TUI_COLS - 8 )))" ;;
              'Host: '*) printf '  %s%s%s\n' "$T_MUTE" "${line//\`/}" "$T_RS" ;;
              '---')   ;;
              '')      ;;
              *)       printf '  %s%s%s\n' "$T_MUTE" "$(tui_fit "$line" $(( TUI_COLS - 4 )))" "$T_RS" ;;
            esac
          done < "$ALERT_REPORT"
        } | ${PAGER:-less -R -F -X}
        ;;
      "Schedule it daily")
        if [ "$(uname -s)" != "Darwin" ]; then
          ui_err "scheduling here is launchd, which is macOS only"
          ui_note "on Linux, add a cron entry:  0 9 * * *  $SEC_SELF alerts run"
          ui_pause; continue
        fi
        local picked hour minute
        picked="$(clock_pick_time "$(alert_schedule_hour 2>/dev/null || printf '9')" \
                                  "$(alert_schedule_min  2>/dev/null || printf '0')")" || continue
        hour="${picked%% *}"; minute="${picked##* }"
        tui_page "SCHEDULE" "$(printf 'daily at %02d:%02d' "$hour" "$minute")"
        printf '\n'
        if alert_schedule_install "$hour" "$minute"; then
          ui_ok "$(printf 'scheduled daily at %02d:%02d' "$hour" "$minute")"
          ui_note "verified loaded in launchctl:"
          launchctl list 2>/dev/null | ui_grep_show 'com.secretsd.alerts' | sed 's/^/     /'
          sec_log_start alerts
          sec_log "$(printf 'expiry alerts scheduled daily at %02d:%02d' "$hour" "$minute")"
        else
          ui_err "launchctl did not report the agent as loaded"
          ui_note "check by hand: launchctl load $ALERT_PLIST"
        fi
        ui_pause ;;
      "Stop the schedule")
        if alert_schedule_remove; then ui_ok "removed — verified gone from launchctl"
        else ui_err "still present in launchctl"; fi
        ui_pause ;;
      *) return 0 ;;
    esac
  done
}
