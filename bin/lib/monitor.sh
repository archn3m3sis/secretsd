#!/usr/bin/env bash
# lib/monitor.sh — the Monitor: walks sessions and restarts the ones that stalled.
#
# Agents stop. Not because the work is done — because they hit something they
# could have reasonably guessed at, asked a question nobody answered, and then
# sat there. The session is alive, the context is intact, the next step is
# obvious from its own history, and it is simply waiting for a human to say
# "carry on".
#
# The Monitor is that human, on a schedule.
#
# HOW IT DECIDES
#   It asks each session, with its own history in front of it, to classify
#   itself: COMPLETE, BLOCKED, or STALLED. The distinction that matters is
#   BLOCKED versus STALLED — blocked means it genuinely needs something only
#   you can provide (a password, a physical action, a decision with no
#   defensible default). Stalled means it stopped on something it could have
#   made an educated guess about and proceeded.
#
#   Only STALLED sessions get nudged. Nudging a genuinely blocked session is
#   how you get an agent inventing a credential rather than waiting for one.
#
# ON A SCHEDULE
#   `secretsd monitor --sweep` is the whole thing, non-interactive: classify,
#   nudge what is stalled, append to a log. Point cron or a launchd agent at it
#   and the loop runs without you.
#
# Sourced, never executed.

MON_LOG="$SEC_ROOT/secrets/monitor.log"
MON_STATE="$SEC_ROOT/secrets/monitor-state.yaml"
MON_MAX_NUDGES="${MON_MAX_NUDGES:-3}"

MON_CLASSIFY='You are being checked by a monitor that restarts stalled work. Answer ONLY
from this session'"'"'s own history. Do not use tools. Reply in EXACTLY this form and
nothing else:

STATE: COMPLETE|BLOCKED|STALLED
NEXT: <the single next action, one line — or "none" if COMPLETE>
NEEDS: <what only a human can provide, or "nothing">

Definitions, and be strict about the middle one:
COMPLETE — the objective was met, or the work was explicitly abandoned.
BLOCKED  — progress genuinely requires something only a human can give: a
           password or passphrase, a physical action, access you do not have,
           or a decision where no default is defensible.
STALLED  — work is unfinished and the next step is inferable from your own
           history. This includes stopping to ask a question you could have
           answered yourself with a reasonable assumption, waiting for
           confirmation on something low-risk and reversible, or simply
           having stopped mid-task.

If you stopped because you asked a question that has a sensible default,
that is STALLED, not BLOCKED.'

mon_field() { printf '%s' "$1" | awk -F': *' -v k="$2" '$1==k {sub(/^[^:]*: */,""); print; exit}'; }

mon_nudge_count() {   # $1 uuid
  [ -f "$MON_STATE" ] || { printf '0'; return; }
  awk -v u="$1" '$1 == u":" {found=1; next} found && $1 == "nudges:" {print $2; exit}' "$MON_STATE" 2>/dev/null | tr -d ' ' | grep -E '^[0-9]+$' || printf '0'
}
mon_record() {   # $1 uuid  $2 state  $3 nudges
  local tmp="$TMPD/mon.yaml"
  touch "$MON_STATE"; chmod 600 "$MON_STATE"
  if grep -qE "^$1:" "$MON_STATE" 2>/dev/null; then
    awk -v u="$1" -v s="$2" -v n="$3" -v t="$(date -u +%FT%TZ)" '
      /^[0-9a-f-]{36}:/ { c=($0 == u":") }
      c && $1=="state:"  { print "  state:  " s; next }
      c && $1=="nudges:" { print "  nudges: " n; next }
      c && $1=="last:"   { print "  last:   " t; next }
      { print }' "$MON_STATE" > "$tmp" && cat "$tmp" > "$MON_STATE"
  else
    { printf '%s:\n  state:  %s\n  nudges: %s\n  last:   %s\n' "$1" "$2" "$3" "$(date -u +%FT%TZ)"; } >> "$MON_STATE"
  fi
}

mon_log() { printf '%s  %s\n' "$(date -u +%FT%TZ)" "$*" >> "$MON_LOG" 2>/dev/null; chmod 600 "$MON_LOG" 2>/dev/null; }

# mon_nudge UUID NEXT — tell the session to carry on, with its own next step quoted
mon_nudge() {
  local uuid="$1" next="$2" out
  out="$(claude -p --resume "$uuid" "You stopped, and the work is not finished.

Your own assessment of the next action was: $next

Continue from there now. You do not need permission to proceed. Where you would
normally stop to ask a low-risk, reversible question, make the most defensible
assumption instead, state the assumption plainly, and keep going. Only stop if you
genuinely require something a human must supply — a credential, a physical action,
or a decision with no defensible default.

Work until the objective is met or you hit a real blocker." --output-format text 2>/dev/null)"
  [ -n "$out" ] && return 0
  return 1
}

# --- one sweep ----------------------------------------------------------------
# mon_sweep LIMIT QUIET -> classifies and nudges. Prints progress unless QUIET=1.
mon_sweep() {
  local limit="${1:-10}" quiet="${2:-0}"
  local -a S_ID S_NAME
  local n=0 uuid cwd title when msgs sub

  while IFS='|' read -r uuid cwd title when msgs sub; do
    [ -n "$uuid" ] || continue
    [ "$n" -ge "$limit" ] && break
    S_ID[$n]="$uuid"; S_NAME[$n]="$title"; n=$(( n + 1 ))
  done <<MS
$(ws_scan_sessions)
MS
  [ "$n" -gt 0 ] || { [ "$quiet" = 1 ] || ui_err "no sessions"; return 1; }

  local i ans state next needs nudges complete=0 blocked=0 stalled=0 nudged=0 capped=0
  i=0
  while [ "$i" -lt "$n" ]; do
    [ "$quiet" = 1 ] || printf '   %s[%s/%s]%s %-42s ' "$T_DIM" "$(( i + 1 ))" "$n" "$T_RS" \
      "$(tui_fit "${S_NAME[$i]}" 42)"
    ans="$(claude -p --resume "${S_ID[$i]}" "$MON_CLASSIFY" --output-format text 2>/dev/null)"
    state="$(mon_field "$ans" STATE)"
    next="$(mon_field "$ans" NEXT)"
    needs="$(mon_field "$ans" NEEDS)"
    nudges="$(mon_nudge_count "${S_ID[$i]}")"

    case "$state" in
      COMPLETE)
        complete=$(( complete + 1 )); mon_record "${S_ID[$i]}" COMPLETE "$nudges"
        mon_log "COMPLETE ${S_ID[$i]} ${S_NAME[$i]}"
        [ "$quiet" = 1 ] || printf '%scomplete%s\n' "$T_OK" "$T_RS" ;;
      BLOCKED)
        blocked=$(( blocked + 1 )); mon_record "${S_ID[$i]}" BLOCKED "$nudges"
        mon_log "BLOCKED ${S_ID[$i]} needs: $needs"
        [ "$quiet" = 1 ] || printf '%sblocked — needs you%s\n' "$T_WARN" "$T_RS" ;;
      STALLED)
        stalled=$(( stalled + 1 ))
        if [ "$MON_MAX_NUDGES" -eq 0 ]; then
          capped=$(( capped + 1 ))
          mon_record "${S_ID[$i]}" STALLED "$nudges"
          mon_log "CLASSIFY-ONLY ${S_ID[$i]} stalled, nudging disabled"
          [ "$quiet" = 1 ] || printf '%sstalled (nudging disabled)%s\n' "$T_DIM" "$T_RS"
        elif [ "${nudges:-0}" -ge "$MON_MAX_NUDGES" ]; then
          capped=$(( capped + 1 ))
          mon_record "${S_ID[$i]}" STALLED "$nudges"
          mon_log "CAPPED ${S_ID[$i]} nudged $nudges times already, limit is $MON_MAX_NUDGES"
          [ "$quiet" = 1 ] || printf '%sstalled, nudged %s times already%s\n' "$T_ERR" "$nudges" "$T_RS"
        else
          [ "$quiet" = 1 ] || printf '%sstalled — nudging%s ' "$T_WARN" "$T_RS"
          if mon_nudge "${S_ID[$i]}" "$next"; then
            nudged=$(( nudged + 1 ))
            mon_record "${S_ID[$i]}" NUDGED "$(( nudges + 1 ))"
            mon_log "NUDGED ${S_ID[$i]} (#$(( nudges + 1 ))) next: $next"
            [ "$quiet" = 1 ] || printf '%sresumed%s\n' "$T_OK" "$T_RS"
          else
            mon_record "${S_ID[$i]}" STALLED "$nudges"
            mon_log "NUDGE-FAILED ${S_ID[$i]}"
            [ "$quiet" = 1 ] || printf '%sno response%s\n' "$T_ERR" "$T_RS"
          fi
        fi ;;
      *)
        mon_log "UNCLEAR ${S_ID[$i]}"
        [ "$quiet" = 1 ] || printf '%sunclear, left alone%s\n' "$T_DIM" "$T_RS" ;;
    esac
    i=$(( i + 1 ))
  done

  mon_log "SWEEP surveyed=$n complete=$complete blocked=$blocked stalled=$stalled nudged=$nudged capped=$capped"
  if [ "$quiet" = 1 ]; then
    printf 'surveyed=%s complete=%s blocked=%s stalled=%s nudged=%s capped=%s\n' \
      "$n" "$complete" "$blocked" "$stalled" "$nudged" "$capped"
  else
    printf '\n'
    tui_kv "complete"        "$complete" "$T_OK"
    tui_kv "blocked on you"  "$blocked" "$T_WARN"
    tui_kv "stalled"         "$stalled"
    tui_kv "nudged back to work" "$nudged" "$T_OK"
    [ "$capped" -gt 0 ] && tui_kv "hit the nudge limit" "$capped" "$T_ERR"
  fi
  return 0
}

# --- scheduling ---------------------------------------------------------------
MON_PLIST="$HOME/Library/LaunchAgents/com.secretsd.monitor.plist"

mon_schedule_install() {   # $1 interval seconds
  local secs="${1:-3600}"
  mkdir -p "$(dirname "$MON_PLIST")"
  cat > "$MON_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.secretsd.monitor</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SEC_SELF</string>
    <string>monitor</string>
    <string>--sweep</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SECRETSD_HOME</key><string>$SEC_ROOT</string>
    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StartInterval</key><integer>$secs</integer>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>$SEC_ROOT/secrets/monitor-launchd.log</string>
  <key>StandardErrorPath</key><string>$SEC_ROOT/secrets/monitor-launchd.log</string>
</dict></plist>
PLIST
  chmod 600 "$MON_PLIST"
  launchctl unload "$MON_PLIST" >/dev/null 2>&1
  launchctl load "$MON_PLIST" >/dev/null 2>&1
  launchctl list 2>/dev/null | grep -q 'com.secretsd.monitor'
}
mon_scheduled() { launchctl list 2>/dev/null | grep -q 'com.secretsd.monitor'; }
mon_schedule_remove() {
  launchctl unload "$MON_PLIST" >/dev/null 2>&1
  rm -f "$MON_PLIST"
  ! mon_scheduled
}

# --- the screen ---------------------------------------------------------------
monitor_screen() {
  ui_interactive || return 0
  broker_have || { tui_page "MONITOR" "claude CLI not on PATH"; ui_pause; return 0; }

  local act sched
  while :; do
    mon_scheduled && sched="running every $(( $(grep -A1 StartInterval "$MON_PLIST" 2>/dev/null | grep -oE '[0-9]+' | tail -1) / 60 )) minutes" || sched="not scheduled"

    tui_page "THE MONITOR" "walks your sessions and restarts the ones that stalled"
    tui_kv "schedule" "$sched" "$(mon_scheduled && printf '%s' "$T_OK" || printf '%s' "$T_DIM")"
    tui_kv "nudge limit per session" "$MON_MAX_NUDGES"
    [ -f "$MON_LOG" ] && tui_kv "log entries" "$(wc -l < "$MON_LOG" | tr -d ' ')"
    printf '\n'
    printf '   %sIt only nudges sessions that stopped on something they could have made\n' "$T_MUTE"
    printf '   an educated guess about. A session genuinely waiting on you — a password,\n'
    printf '   a physical action, a decision with no default — is left alone.%s\n' "$T_RS"
    printf '\n'

    act="$(tui_menu "MONITOR" "$sched" \
      "Sweep now|classify recent sessions and nudge the stalled ones" \
      "Schedule it|run the sweep automatically on an interval" \
      "Stop the schedule|remove the launchd agent" \
      "View the log|what it has done so far" \
      "Back|change nothing")" || break

    case "$act" in
      "Sweep now")
        tui_page "SWEEP" "one classify call per session, ~40s each"
        local howmany
        howmany="$(tui_menu "HOW MANY" "recent sessions first" \
          "5 sessions|about 4 minutes" \
          "10 sessions|about 8 minutes" \
          "25 sessions|about 20 minutes" \
          "Cancel|nothing")" || continue
        case "$howmany" in
          "5 sessions")  howmany=5 ;;
          "10 sessions") howmany=10 ;;
          "25 sessions") howmany=25 ;;
          *) continue ;;
        esac
        tui_page "SWEEPING" "classifying, then nudging what is merely stalled"
        printf '\n'
        mon_sweep "$howmany" 0
        ui_pause ;;
      "Schedule it")
        tui_page "SCHEDULE THE MONITOR" "a launchd agent that runs the sweep for you"
        local iv
        iv="$(tui_menu "HOW OFTEN" "each run costs one model call per session surveyed" \
          "Every 30 minutes|tight loop, for active work" \
          "Every hour|the sensible default" \
          "Every 4 hours|background upkeep" \
          "Cancel|no schedule")" || continue
        case "$iv" in
          "Every 30 minutes") iv=1800 ;;
          "Every hour")       iv=3600 ;;
          "Every 4 hours")    iv=14400 ;;
          *) continue ;;
        esac
        if mon_schedule_install "$iv"; then
          ui_ok "scheduled — verified loaded in launchctl"
          ui_note "it writes to ${MON_LOG#$SEC_ROOT/}"
          sec_log_start monitor; sec_log "monitor scheduled every ${iv}s"
        else
          ui_err "launchctl did not report the agent as loaded"
        fi
        ui_pause ;;
      "Stop the schedule")
        if mon_schedule_remove; then ui_ok "removed — verified gone from launchctl"
        else ui_err "still present in launchctl"; fi
        ui_pause ;;
      "View the log")
        tui_page "MONITOR LOG" "${MON_LOG#$SEC_ROOT/}"
        if [ -f "$MON_LOG" ]; then tail -30 "$MON_LOG" | sed 's/^/   /'
        else ui_info "nothing yet"; fi
        ui_pause ;;
      *) break ;;
    esac
  done
  return 0
}
