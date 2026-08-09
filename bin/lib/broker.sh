#!/usr/bin/env bash
# lib/broker.sh — archive, purge, and MERGE sessions through a broker.
#
# THE MERGE
#   Two finished sessions each hold context the other lacks. `claude -p --resume
#   <uuid>` answers WITH that session's full history, so the sessions can genuinely
#   be put in conversation — this is not a summary of two text files.
#
#   Three rounds:
#     1 POSITION    each session states its own scope, decisions, open threads
#                   and artifacts, without seeing the other
#     2 RECONCILE   each session is shown the other's position and asked what
#                   should carry forward, what conflicts, and what supersedes what
#     3 BROKER      a fresh instance, party to neither, reads both rounds and
#                   writes one consolidated brief plus an explicit merge plan
#
#   The result seeds a NEW named session. The originals are never modified —
#   merging is additive, and if the brief is wrong you still have both parents.
#
# EVERY ROUND ANNOUNCES ITSELF BEFORE IT RUNS and reports how long it took. A
# merge is several model calls; silence for a minute is indistinguishable from a
# hang, so it never goes quiet.
#
# Sourced, never executed.

BROKER_DIR="$SEC_SECRETS/merges"
BROKER_MAXWAIT="${BROKER_MAXWAIT:-240}"

broker_have() { command -v claude >/dev/null 2>&1; }

# broker_ask UUID PROMPT LABEL -> answer on stdout, progress on the terminal
broker_ask() {
  local uuid="$1" prompt="$2" label="$3" out start elapsed
  start="$(date +%s)"
  printf '   %s· %s%s ' "$T_DIM" "$label" "$T_RS" >&2
  out="$(claude -p --resume "$uuid" "$prompt" --output-format text 2>/dev/null)"
  elapsed=$(( $(date +%s) - start ))
  if [ -n "$out" ]; then
    printf '%sdone in %ss, %s words%s\n' "$T_OK" "$elapsed" "$(printf '%s' "$out" | wc -w | tr -d ' ')" "$T_RS" >&2
  else
    printf '%sno answer after %ss%s\n' "$T_ERR" "$elapsed" "$T_RS" >&2
  fi
  printf '%s' "$out"
}

# broker_fresh PROMPT LABEL -> answer from an instance with no prior context
broker_fresh() {
  local prompt="$1" label="$2" out start elapsed
  start="$(date +%s)"
  printf '   %s· %s%s ' "$T_DIM" "$label" "$T_RS" >&2
  out="$(claude -p "$prompt" --output-format text 2>/dev/null)"
  elapsed=$(( $(date +%s) - start ))
  if [ -n "$out" ]; then
    printf '%sdone in %ss%s\n' "$T_OK" "$elapsed" "$T_RS" >&2
  else
    printf '%sno answer after %ss%s\n' "$T_ERR" "$elapsed" "$T_RS" >&2
  fi
  printf '%s' "$out"
}

Q_POSITION='You are being consulted as one party to a session merge. Answer from THIS
session'"'"'s history only. Be specific and factual; do not use tools. Give me, in under
250 words: (1) the objective of this session, (2) the decisions that were actually
settled, (3) what is still open or unfinished, (4) any files, hosts or artifacts it
produced or depends on. If something was tried and rejected, say so and why.'

# broker_merge UUID_A NAME_A UUID_B NAME_B -> writes a brief, echoes its path
broker_merge() {
  local ua="$1" na="$2" ub="$3" nb="$4"
  local pa pb ra rb brief stamp file
  mkdir -p "$BROKER_DIR" 2>/dev/null; chmod 700 "$BROKER_DIR" 2>/dev/null
  stamp="$(date +%Y%m%d-%H%M%S)"
  file="$BROKER_DIR/merge-$stamp.md"

  printf '\n'
  tui_section "ROUND 1 · POSITION"
  printf '   %seach session states its own scope, unaware of the other%s\n\n' "$T_DIM" "$T_RS"
  pa="$(broker_ask "$ua" "$Q_POSITION" "$(tui_fit "$na" 44)")"
  pb="$(broker_ask "$ub" "$Q_POSITION" "$(tui_fit "$nb" 44)")"
  if [ -z "$pa" ] || [ -z "$pb" ]; then
    ui_err "one of the sessions did not answer — merge abandoned, nothing changed"
    return 1
  fi

  printf '\n'
  tui_section "ROUND 2 · RECONCILE"
  printf '   %seach session now sees the other and argues what should carry forward%s\n\n' "$T_DIM" "$T_RS"
  ra="$(broker_ask "$ua" "Another session is being merged with yours. Here is its position:

--- OTHER SESSION ($nb) ---
$pb
--- END ---

In under 250 words, and from your own history: what of YOURS must carry into the merged
session, what of theirs supersedes yours, where do you actually conflict, and what would
be lost if we simply concatenated the two? Be concrete. Do not use tools." "$(tui_fit "$na" 44)")"

  rb="$(broker_ask "$ub" "Another session is being merged with yours. Here is its position:

--- OTHER SESSION ($na) ---
$pa
--- END ---

In under 250 words, and from your own history: what of YOURS must carry into the merged
session, what of theirs supersedes yours, where do you actually conflict, and what would
be lost if we simply concatenated the two? Be concrete. Do not use tools." "$(tui_fit "$nb" 44)")"

  printf '\n'
  tui_section "ROUND 3 · BROKER"
  printf '   %sa third instance, party to neither, writes the consolidated brief%s\n\n' "$T_DIM" "$T_RS"
  brief="$(broker_fresh "You are brokering a merge of two Claude Code sessions. You have no stake in
either. Below are both sessions' opening positions and their responses to each other.

=== SESSION A: $na ===
POSITION:
$pa

RESPONSE TO B:
$ra

=== SESSION B: $nb ===
POSITION:
$pb

RESPONSE TO A:
$rb

Write the briefing document that should seed a single merged session. Use exactly these
markdown sections and nothing else:

## Objective
One paragraph: what the merged session is for, reconciling both.

## Settled
Bullets. Decisions already made that must not be relitigated. Attribute each to A or B.

## Open
Bullets. What is genuinely unfinished, ordered by what blocks what.

## Conflicts and resolution
Bullets. Where A and B disagreed, and which position should win, with the reason. If
they did not actually conflict, say so plainly rather than inventing tension.

## Artifacts
Bullets. Files, hosts, credentials, paths either session depends on.

## Do not repeat
Bullets. Approaches already tried and rejected, with why — so the merged session does
not walk back into them.

Be specific. Prefer omission to invention: if the positions do not support a claim, leave
it out. Do not use tools." "consolidating")"

  [ -n "$brief" ] || { ui_err "the broker produced nothing — merge abandoned"; return 1; }

  {
    printf '# Merged session brief\n\n'
    printf -- '- **A** %s (`%s`)\n' "$na" "$ua"
    printf -- '- **B** %s (`%s`)\n' "$nb" "$ub"
    printf -- '- brokered %s on %s\n\n' "$(date -u +%FT%TZ)" "$(hostname -s)"
    printf -- '---\n\n%s\n\n' "$brief"
    printf -- '---\n\n<details><summary>negotiation transcript</summary>\n\n'
    printf -- '### A position\n\n%s\n\n### B position\n\n%s\n\n' "$pa" "$pb"
    printf -- '### A on B\n\n%s\n\n### B on A\n\n%s\n\n</details>\n' "$ra" "$rb"
  } > "$file"
  chmod 600 "$file"
  printf '%s' "$file"
}

# --- archive / purge ----------------------------------------------------------
BROKER_ARCHIVE="$SEC_SECRETS/archived-sessions"

broker_archive() {   # $1 uuid  $2 transcript path
  local uuid="$1" tr="$2" sub
  mkdir -p "$BROKER_ARCHIVE" 2>/dev/null; chmod 700 "$BROKER_ARCHIVE"
  [ -f "$tr" ] || { ui_err "no transcript at $tr"; return 1; }
  cp -p "$tr" "$BROKER_ARCHIVE/$uuid.jsonl" || { ui_err "copy failed"; return 1; }
  sub="$(dirname "$tr")/$uuid"
  if [ -d "$sub" ]; then
    cp -R "$sub" "$BROKER_ARCHIVE/$uuid.subagents" 2>/dev/null
  fi
  if cmp -s "$tr" "$BROKER_ARCHIVE/$uuid.jsonl"; then
    rm -f "$tr"
    [ -d "$sub" ] && rm -rf "$sub"
    ui_ok "archived to $BROKER_ARCHIVE (byte-identical copy verified before removal)"
    return 0
  fi
  ui_err "archive copy differs from the original — nothing was removed"
  rm -f "$BROKER_ARCHIVE/$uuid.jsonl"
  return 1
}

broker_purge() {   # $1 uuid  $2 transcript path
  local uuid="$1" tr="$2" sub n=0
  sub="$(dirname "$tr")/$uuid"
  [ -f "$tr" ] && n=1
  [ -d "$sub" ] && n=$(( n + $(find "$sub" -name '*.jsonl' | sec_nlines) ))
  rm -f "$tr"; [ -d "$sub" ] && rm -rf "$sub"
  if [ -f "$tr" ]; then ui_err "could not remove the transcript"; return 1; fi
  ui_ok "purged $n transcript file(s) — this is not recoverable"
  return 0
}

# --- the merge / archive / purge screen ---------------------------------------
broker_screen() {
  ui_interactive || return 0
  broker_have || { tui_page "SESSION BROKER" "claude CLI not on PATH"; ui_pause; return 0; }

  local -a B_ID B_NAME B_PROJ B_PATH B_TR B_WHEN B_MSGS B_MARK B_LINE
  local n=0 uuid cwd title when msgs sub

  ui_clear; printf '\n  '; tui_grad_violet 'reading sessions…'; printf '\n'
  while IFS='|' read -r uuid cwd title when msgs sub; do
    [ -n "$uuid" ] || continue
    B_ID[$n]="$uuid"; B_NAME[$n]="$title"; B_PROJ[$n]="$(basename "${cwd:-unknown}")"
    B_PATH[$n]="$cwd"; B_TR[$n]="$(ws_transcript_path "$cwd" "$uuid")"
    B_WHEN[$n]="$when"; B_MSGS[$n]="$msgs"; B_MARK[$n]=0
    n=$(( n + 1 ))
  done <<BRK
$(ws_scan_sessions)
BRK
  [ "$n" -gt 0 ] || { tui_page "SESSION BROKER" "no sessions found"; ui_pause; return 0; }

  local sel=0 key prev curline host i marked=0
  host="$(hostname -s 2>/dev/null || echo host)"

  draw_brk() {
    local k="$1" on="$2" dot dlab hue
    if [ "${B_MARK[$k]}" = "1" ]; then dot=ok; dlab="MARKED FOR MERGE"; hue="$N_CYAN"
    elif [ -f "${B_TR[$k]}" ];    then dot=none; dlab="${B_MSGS[$k]} prompts"; hue="$T_DIM"
    else                               dot=err;  dlab="transcript missing"; hue="$T_ERR"; fi
    printf '\033[%d;1H' "${B_LINE[$k]}"
    tui_modrow "$on" "$(tui_icon_top sessions)" "$hue" \
      "$(tui_fit "${B_NAME[$k]}" 44)" "${B_PROJ[$k]}" "$dot" "$dlab"
    tui_moddesc "$on" "$(tui_fit "${B_ID[$k]:0:8}… · $(ws_when_ago "${B_WHEN[$k]}")" $(( TUI_COLS - 14 )))" \
      "$(tui_icon_bot sessions)" "$hue"
  }

  draw_brks() {
    tui_home
    tui_header "$host" "$n session(s) · $marked marked · merge is additive, originals are never modified"
    curline=4
    local shown=0 maxrows start=0
    maxrows=$(( (TUI_ROWS - 6) / 3 )); [ "$maxrows" -lt 1 ] && maxrows=1
    [ "$sel" -ge "$maxrows" ] && start=$(( sel - maxrows + 1 ))
    i="$start"
    while [ "$i" -lt "$n" ] && [ "$shown" -lt "$maxrows" ]; do
      B_LINE[$i]="$(( curline + 1 ))"
      draw_brk "$i" "$([ "$i" = "$sel" ] && echo 1 || echo 0)"
      curline=$(( curline + 2 ))
      [ "$shown" -lt $(( maxrows - 1 )) ] && { tui_blank; curline=$(( curline + 1 )); }
      i=$(( i + 1 )); shown=$(( shown + 1 ))
    done
    local pad=$(( TUI_ROWS - curline - 2 )); [ "$pad" -lt 0 ] && pad=0
    i=0; while [ "$i" -lt "$pad" ]; do tui_blank; i=$(( i + 1 )); done
    tui_footer "↑↓ move" "space mark" "m merge" "j janitor" "A archive" "X purge" "esc back"
    tui_clear_below
  }

  tui_begin
  trap 'tui_end; cleanup' EXIT INT TERM
  tui_dims; draw_brks

  while :; do
    key="$(tui_readkey)" || break
    prev="$sel"
    case "$key" in
      up)   sel=$(( sel - 1 )); [ "$sel" -lt 0 ] && sel=$(( n - 1 )) ;;
      down) sel=$(( sel + 1 )); [ "$sel" -ge "$n" ] && sel=0 ;;

      "char: ")
        if [ "${B_MARK[$sel]}" = "1" ]; then B_MARK[$sel]=0; marked=$(( marked - 1 ))
        else B_MARK[$sel]=1; marked=$(( marked + 1 )); fi
        tui_dims; draw_brks; continue ;;

      char:m)
        tui_end
        local a=-1 b=-1 j=0
        while [ "$j" -lt "$n" ]; do
          if [ "${B_MARK[$j]}" = "1" ]; then
            if [ "$a" -lt 0 ]; then a="$j"; elif [ "$b" -lt 0 ]; then b="$j"; fi
          fi
          j=$(( j + 1 ))
        done
        tui_page "MERGE SESSIONS" "two sessions, put in conversation through a broker"
        if [ "$a" -lt 0 ] || [ "$b" -lt 0 ]; then
          ui_warn "mark exactly two sessions first — space toggles a mark"
          ui_pause; tui_begin; tui_dims; draw_brks; continue
        fi
        tui_kv "A" "$(tui_fit "${B_NAME[$a]}" $(( TUI_COLS - 24 )))"
        tui_kv "B" "$(tui_fit "${B_NAME[$b]}" $(( TUI_COLS - 24 )))"
        printf '\n'
        tui_section "WHAT WILL HAPPEN"
        printf '   %s1  each session states its own position — 2 model calls%s\n' "$T_MUTE" "$T_RS"
        printf '   %s2  each is shown the other and argues what carries forward — 2 calls%s\n' "$T_MUTE" "$T_RS"
        printf '   %s3  a neutral instance writes the consolidated brief — 1 call%s\n' "$T_MUTE" "$T_RS"
        printf '\n'
        ui_warn "Five model calls against your subscription, roughly a minute in total."
        ui_note "Neither original session is modified. If the brief is wrong you still have both."
        printf '\n'
        if ui_confirm "Broker a merge of these two?"; then
          local bf
          bf="$(broker_merge "${B_ID[$a]}" "${B_NAME[$a]}" "${B_ID[$b]}" "${B_NAME[$b]}")"
          if [ -n "$bf" ] && [ -f "$bf" ]; then
            printf '\n'
            ui_ok "brief written to ${bf#$SEC_ROOT/}"
            tui_section "CONSOLIDATED BRIEF"
            sed -n '/^## Objective/,/^## Artifacts/p' "$bf" | head -40 | sed 's/^/   /'
            printf '\n'
            local nm nu
            nm="$(ui_ask 'Name the merged session' "merge: ${B_NAME[$a]:0:28} + ${B_NAME[$b]:0:28}")"
            [ -n "$nm" ] || nm="merged $(date +%F)"
            nu="$(uuidgen | tr 'A-Z' 'a-z')"
            ws_record_session "$nm" "$nu" "${B_PROJ[$a]}" "${B_PATH[$a]}" "merged"
            ws_session_note "$nu" "$bf" "${B_ID[$a]}" "${B_ID[$b]}"
            ui_ok "recorded '$nm' as a merged session"
            sec_log_start broker; sec_log "merged ${B_ID[$a]} + ${B_ID[$b]} -> $nu"
            printf '\n'
            if ui_confirm "Launch it now, seeded with the brief?"; then
              ( cd "${B_PATH[$a]:-$HOME}" && claude --session-id "$nu" --name "$nm" "$(cat "$bf")" )
            else
              ui_note "start it later with:"
              printf '     %sclaude --session-id %s --name "%s" "$(cat %s)"%s\n' \
                "$T_ACCENT" "$nu" "$nm" "$bf" "$T_RS"
            fi
          else
            ui_err "no brief was produced — nothing recorded"
          fi
        else ui_info "no merge performed"; fi
        ui_pause
        tui_begin; tui_dims; draw_brks; continue ;;

      char:j)
        tui_end; janitor_screen; tui_begin; tui_dims; draw_brks; continue ;;
      char:A)
        tui_end
        tui_page "ARCHIVE · $(tui_fit "${B_NAME[$sel]}" 40)" "${B_TR[$sel]}"
        ui_note "The transcript and any subagent transcripts move to:"
        printf '     %s%s%s\n\n' "$T_ACCENT" "$BROKER_ARCHIVE" "$T_RS"
        ui_note "The copy is byte-compared before the original is removed. Reversible."
        printf '\n'
        if ui_confirm "Archive this session?"; then
          broker_archive "${B_ID[$sel]}" "${B_TR[$sel]}" && ws_adopt_invalidate
        else ui_info "kept"; fi
        ui_pause
        tui_begin; tui_dims; draw_brks; continue ;;

      char:X)
        tui_end
        tui_page "PURGE · $(tui_fit "${B_NAME[$sel]}" 40)" "permanent"
        tui_kv "transcript" "$(tui_fit "${B_TR[$sel]}" $(( TUI_COLS - 24 )))"
        tui_kv "prompts"    "${B_MSGS[$sel]}"
        printf '\n'
        ui_err "This deletes the transcript outright. There is no undo."
        ui_note "If you only want it out of the way, use A to archive instead."
        printf '\n'
        if ui_confirm "Type-through check: purge '${B_NAME[$sel]}' permanently?"; then
          if ui_confirm "Really? This cannot be recovered."; then
            broker_purge "${B_ID[$sel]}" "${B_TR[$sel]}" && ws_adopt_invalidate
          else ui_info "kept"; fi
        else ui_info "kept"; fi
        ui_pause
        tui_begin; tui_dims; draw_brks; continue ;;

      quit|esc) break ;;
      *) continue ;;
    esac
    draw_brk "$prev" 0; draw_brk "$sel" 1
  done
  tui_end
  trap 'cleanup' EXIT INT TERM
  return 0
}

# ws_session_note UUID BRIEF PARENT_A PARENT_B — extra provenance for a merge
ws_session_note() {
  printf '  brief:      %s\n  parent_a:   %s\n  parent_b:   %s\n\n' "$2" "$3" "$4" >> "$SEC_SESSIONS"
}

# --- the session janitor ------------------------------------------------------
# The same trick as the broker, turned on the whole estate: ask each session
# whether it is still worth keeping. A session knows things a file listing never
# will — whether its conclusions were written down elsewhere, whether it ended
# mid-thought, whether it duplicates work another session already finished.
#
# It RECOMMENDS. It never acts. Every verdict is a suggestion you accept or
# ignore per session, because deleting someone's history on a model's say-so is
# exactly the kind of "help" this program refuses to do.

JAN_Q='You are being asked whether this session is still worth keeping on disk.
Answer from this session'"'"'s own history. Do not use tools. Reply in EXACTLY this form
and nothing else:

VERDICT: KEEP|ARCHIVE|PURGE
TOPIC: <six words or fewer>
REASON: <one sentence, max 25 words>

Use KEEP if the work is unfinished, or holds decisions or context not recorded anywhere
else. Use ARCHIVE if the work concluded and its outcome was written to files, commits or
documentation, so the transcript is only history. Use PURGE only if the session achieved
nothing worth remembering — a false start, a trivial question, or an aborted attempt.'

jan_field() { printf '%s' "$1" | awk -F': *' -v k="$2" '$1==k {sub(/^[^:]*: */,""); print; exit}'; }

# janitor_screen — survey a bounded batch, then let you act one at a time
janitor_screen() {
  ui_interactive || return 0
  broker_have || { tui_page "JANITOR" "claude CLI not on PATH"; ui_pause; return 0; }

  local -a J_ID J_NAME J_PATH J_TR J_WHEN J_MSGS J_VERDICT J_TOPIC J_REASON J_LINE
  local n=0 uuid cwd title when msgs sub

  while IFS='|' read -r uuid cwd title when msgs sub; do
    [ -n "$uuid" ] || continue
    J_ID[$n]="$uuid"; J_NAME[$n]="$title"; J_PATH[$n]="$cwd"
    J_TR[$n]="$(ws_transcript_path "$cwd" "$uuid")"
    J_WHEN[$n]="$when"; J_MSGS[$n]="$msgs"
    J_VERDICT[$n]=""; J_TOPIC[$n]=""; J_REASON[$n]=""
    n=$(( n + 1 ))
  done <<JANL
$(ws_scan_sessions)
JANL
  [ "$n" -gt 0 ] || { tui_page "JANITOR" "no sessions found"; ui_pause; return 0; }

  tui_page "SESSION JANITOR" "$n session(s) on disk"
  printf '\n'
  tui_section "HOW IT WORKS"
  printf '   %sEach session is asked, with its own history in front of it, whether it is\n' "$T_MUTE"
  printf '   still worth keeping — and why. One model call per session.%s\n\n' "$T_RS"
  ui_warn "That is one call per session against your subscription, ~8s each."
  ui_note "It only ever RECOMMENDS. Nothing is archived or deleted without you."
  printf '\n'

  local batch scope
  batch="$(tui_menu "HOW MANY TO SURVEY" "start small — you can always run it again" \
    "Oldest 5|about 40 seconds" \
    "Oldest 15|about 2 minutes" \
    "Everything untouched for 30+ days|however many that is" \
    "Cancel|survey nothing")" || return 0
  case "$batch" in
    "Oldest 5")  scope=5 ;;
    "Oldest 15") scope=15 ;;
    "Everything"*) scope=-1 ;;
    *) return 0 ;;
  esac

  # oldest first — the far end of the list is where the dead wood is
  local -a ORDER
  local c=0 i="$(( n - 1 ))"
  while [ "$i" -ge 0 ]; do
    if [ "$scope" -eq -1 ]; then
      local age=$(( ( $(date +%s) - ${J_WHEN[$i]:-0} ) / 86400 ))
      [ "$age" -ge 30 ] && { ORDER[$c]="$i"; c=$(( c + 1 )); }
    else
      [ "$c" -lt "$scope" ] && { ORDER[$c]="$i"; c=$(( c + 1 )); }
    fi
    i=$(( i - 1 ))
  done
  [ "$c" -gt 0 ] || { ui_info "nothing matches that scope"; ui_pause; return 0; }

  ui_clear
  tui_page "SURVEYING $c SESSION(S)" "each answers for itself · nothing is changed"
  printf '\n'

  local k idx ans start elapsed keep=0 arch=0 purge=0
  k=0
  while [ "$k" -lt "$c" ]; do
    idx="${ORDER[$k]}"
    printf '   %s[%s/%s]%s %-46s ' "$T_DIM" "$(( k + 1 ))" "$c" "$T_RS" \
      "$(tui_fit "${J_NAME[$idx]}" 46)"
    start="$(date +%s)"
    ans="$(claude -p --resume "${J_ID[$idx]}" "$JAN_Q" --output-format text 2>/dev/null)"
    elapsed=$(( $(date +%s) - start ))
    if [ -n "$ans" ]; then
      J_VERDICT[$idx]="$(jan_field "$ans" VERDICT)"
      J_TOPIC[$idx]="$(jan_field "$ans" TOPIC)"
      J_REASON[$idx]="$(jan_field "$ans" REASON)"
      case "${J_VERDICT[$idx]}" in
        KEEP)    keep=$(( keep + 1 ));  printf '%sKEEP%s    %ss\n' "$T_OK" "$T_RS" "$elapsed" ;;
        ARCHIVE) arch=$(( arch + 1 ));  printf '%sARCHIVE%s %ss\n' "$T_WARN" "$T_RS" "$elapsed" ;;
        PURGE)   purge=$(( purge + 1 )); printf '%sPURGE%s   %ss\n' "$T_ERR" "$T_RS" "$elapsed" ;;
        *)       J_VERDICT[$idx]="KEEP"; keep=$(( keep + 1 ))
                 printf '%sunclear, defaulting to KEEP%s\n' "$T_DIM" "$T_RS" ;;
      esac
    else
      J_VERDICT[$idx]="KEEP"; J_REASON[$idx]="no answer — kept by default"
      keep=$(( keep + 1 ))
      printf '%sno answer, keeping%s\n' "$T_DIM" "$T_RS"
    fi
    k=$(( k + 1 ))
  done

  printf '\n'
  tui_kv "keep"    "$keep"
  tui_kv "archive" "$arch" "$T_WARN"
  tui_kv "purge"   "$purge" "$T_ERR"
  printf '\n'
  ui_note "Nothing has been touched. Act on each below, or walk away."
  ui_pause

  # --- act on the recommendations, one at a time ------------------------------
  local -a R
  local rc=0
  k=0
  while [ "$k" -lt "$c" ]; do
    idx="${ORDER[$k]}"
    case "${J_VERDICT[$idx]}" in ARCHIVE|PURGE) R[$rc]="$idx"; rc=$(( rc + 1 )) ;; esac
    k=$(( k + 1 ))
  done
  if [ "$rc" -eq 0 ]; then
    tui_page "JANITOR" "every surveyed session recommended KEEP"
    ui_ok "nothing to clean up"
    ui_pause; return 0
  fi

  local sel=0 key prev curline host
  host="$(hostname -s 2>/dev/null || echo host)"

  draw_j() {
    local m="$1" on="$2" idx2 dot hue
    idx2="${R[$m]}"
    if [ "${J_VERDICT[$idx2]}" = "PURGE" ]; then dot=err; hue="$T_ERR"
    else dot=warn; hue="$T_WARN"; fi
    printf '\033[%d;1H' "${J_LINE[$m]}"
    tui_modrow "$on" "$(tui_icon_top sessions)" "$hue" \
      "$(tui_fit "${J_TOPIC[$idx2]:-${J_NAME[$idx2]}}" 42)" "${J_MSGS[$idx2]}p" \
      "$dot" "${J_VERDICT[$idx2]}"
    tui_moddesc "$on" "$(tui_fit "${J_REASON[$idx2]}" $(( TUI_COLS - 14 )))" \
      "$(tui_icon_bot sessions)" "$hue"
  }
  draw_js() {
    tui_home
    tui_header "$host" "$rc recommendation(s) · you decide each one"
    curline=4
    local shown=0 maxrows start2=0 i2
    maxrows=$(( (TUI_ROWS - 6) / 3 )); [ "$maxrows" -lt 1 ] && maxrows=1
    [ "$sel" -ge "$maxrows" ] && start2=$(( sel - maxrows + 1 ))
    i2="$start2"
    while [ "$i2" -lt "$rc" ] && [ "$shown" -lt "$maxrows" ]; do
      J_LINE[$i2]="$(( curline + 1 ))"
      draw_j "$i2" "$([ "$i2" = "$sel" ] && echo 1 || echo 0)"
      curline=$(( curline + 2 ))
      [ "$shown" -lt $(( maxrows - 1 )) ] && { tui_blank; curline=$(( curline + 1 )); }
      i2=$(( i2 + 1 )); shown=$(( shown + 1 ))
    done
    local pad=$(( TUI_ROWS - curline - 2 )); [ "$pad" -lt 0 ] && pad=0
    i2=0; while [ "$i2" -lt "$pad" ]; do tui_blank; i2=$(( i2 + 1 )); done
    tui_footer "↑↓ move" "↵ why" "A archive it" "X purge it" "esc leave everything"
    tui_clear_below
  }

  tui_begin
  trap 'tui_end; cleanup' EXIT INT TERM
  tui_dims; draw_js
  while :; do
    key="$(tui_readkey)" || break
    prev="$sel"
    local ix="${R[$sel]}"
    case "$key" in
      up)   sel=$(( sel - 1 )); [ "$sel" -lt 0 ] && sel=$(( rc - 1 )) ;;
      down) sel=$(( sel + 1 )); [ "$sel" -ge "$rc" ] && sel=0 ;;
      enter|right)
        tui_end
        tui_page "${J_VERDICT[$ix]} · $(tui_fit "${J_NAME[$ix]}" 40)" "the session's own verdict on itself"
        tui_kv "topic"   "${J_TOPIC[$ix]}"
        tui_kv "reason"  "$(tui_fit "${J_REASON[$ix]}" $(( TUI_COLS - 24 )))"
        tui_kv "prompts" "${J_MSGS[$ix]}"
        tui_kv "last"    "$(ws_when_ago "${J_WHEN[$ix]}")"
        tui_kv "file"    "$(tui_fit "${J_TR[$ix]}" $(( TUI_COLS - 24 )))"
        ui_pause; tui_begin; tui_dims; draw_js; continue ;;
      char:A)
        tui_end
        tui_page "ARCHIVE · $(tui_fit "${J_NAME[$ix]}" 40)" "reversible"
        ui_confirm "Archive this session?" && { broker_archive "${J_ID[$ix]}" "${J_TR[$ix]}" && ws_adopt_invalidate; } || ui_info "kept"
        ui_pause; tui_begin; tui_dims; draw_js; continue ;;
      char:X)
        tui_end
        tui_page "PURGE · $(tui_fit "${J_NAME[$ix]}" 40)" "permanent"
        ui_err "The session recommended PURGE, but it cannot see what you might still want."
        ui_confirm "Delete it permanently?" && { ui_confirm "Really? No undo." \
          && { broker_purge "${J_ID[$ix]}" "${J_TR[$ix]}" && ws_adopt_invalidate; } || ui_info "kept"; } || ui_info "kept"
        ui_pause; tui_begin; tui_dims; draw_js; continue ;;
      quit|esc) break ;;
      *) continue ;;
    esac
    draw_j "$prev" 0; draw_j "$sel" 1
  done
  tui_end
  trap 'cleanup' EXIT INT TERM
  return 0
}
