#!/usr/bin/env bash
# lib/profiles.sh — session profiles: specialist roles that survey your sessions.
#
# The broker proved that `claude -p --resume <uuid>` answers WITH a session's own
# history. A profile is that mechanism pointed at one specific question, asked of
# many sessions, and then synthesised.
#
# Each profile declares:
#   · the question it asks every session, in a fixed reply format
#   · how the answers are cross-referenced
#   · the artifact it writes, which is markdown you can file in your notes
#
# THE PROFILES
#   collision   Cross-Utility Scout. Asks what each session PLANS to build and
#               what it claims — ports, hostnames, paths, schemas, env vars,
#               subnets — then finds the claims that collide. Two architecture
#               sessions running in parallel will not discover they both took
#               :8080 or both named a host `svc-01` until something breaks;
#               this finds it while both are still plans.
#   conventions Convention Warden. On first run it interviews YOU for the
#               standard. After that it audits every session against the
#               standard you set and reports deviations — not opinions.
#   decisions   Decision Archaeologist. Extracts what was decided and WHY,
#               into an ADR-style log. The rationale is the part that always
#               gets lost.
#   assumptions Dependency Cartographer. What does each session assume already
#               exists? Unmet assumptions are the most common cause of a plan
#               that works on paper and fails on contact.
#   debt        Debt Collector. What did each session leave unfinished, and what
#               did it explicitly defer with "we'll fix that later"?
#   overlap     Duplicate Detector. Which sessions are solving the same problem?
#               Feeds straight into the merge broker.
#
# Every profile REPORTS. None of them change anything.
#
# Sourced, never executed.

PROF_REPORTS="$SEC_ROOT/secrets/reports"
SEC_CONVENTIONS="$SEC_ROOT/secrets/CONVENTIONS.yaml"

# id|glyph|hue-var|title|blurb
prof_list() {
  cat <<'PROFS'
collision|⡏⣇⣸⢹|N_CYAN|Cross-Utility Scout|what each session claims, and where those claims collide
conventions|⡏⠭⠭⢹|N_AMBER|Convention Warden|audits sessions against the standard you define
decisions|⠺⣭⠗|N_GREEN|Decision Archaeologist|what was decided, and the reasoning behind it
assumptions|⣴⣹⣏⣦|N_VIOLET|Dependency Cartographer|what each session assumes already exists
debt|⣰⣉⣉⣆|N_ORANGE|Debt Collector|what was left unfinished or deliberately deferred
overlap|⣠⠞⠳⣄|N_MAGENTA|Duplicate Detector|which sessions are solving the same problem
PROFS
}
prof_field() { prof_list | awk -F'|' -v id="$1" -v f="$2" '$1==id {print $f}'; }

# --- the questions ------------------------------------------------------------
# Each demands a fixed shape so the answers can be cross-referenced mechanically
# rather than by another model guessing at prose.
prof_question() {
  case "$1" in
    collision) cat <<'Q'
You are being surveyed as one of several parallel workstreams. Answer ONLY from this
session's history. Do not use tools. If this session did not plan or build anything
concrete, reply exactly: NOTHING CLAIMED

Otherwise reply in EXACTLY this format, one item per line, omitting any section with
nothing in it:

SCOPE: <one line: what this session is building or changing>
PORTS: <comma-separated ports this claims, or omit>
HOSTS: <hostnames or VM names this creates or renames, or omit>
PATHS: <filesystem paths, mount points or data directories it owns, or omit>
NAMES: <service, container, database, bucket or repo names it creates, or omit>
ENVVARS: <environment variable or credential NAMES it introduces, or omit>
NETWORK: <subnets, VLANs, or IP ranges it allocates, or omit>
SCHEMA: <database tables, API routes or message topics it defines, or omit>
DEPENDS: <things it expects to already exist, or omit>
Q
;;
    conventions) cat <<'Q'
You are being audited for naming conventions. Answer ONLY from this session's history.
Do not use tools. If nothing was named in this session, reply exactly: NOTHING NAMED

Otherwise list every identifier this session CREATED, one per line, in exactly this form:

<CATEGORY>: <the exact name used>

where CATEGORY is one of: HOST, SERVICE, FILE, SCRIPT, BRANCH, ENVVAR, DATABASE,
CONTAINER, REPO, DIRECTORY. Report the name exactly as written, including case and
separators. Do not comment on whether it is good. Do not invent names that were only
discussed hypothetically.
Q
;;
    decisions) cat <<'Q'
Answer ONLY from this session's history. Do not use tools. If nothing was decided,
reply exactly: NO DECISIONS

Otherwise, for each decision that was actually settled (not merely discussed), write:

DECISION: <what was decided, one line>
BECAUSE: <the reason it was chosen, one line>
INSTEAD-OF: <the alternative that was rejected, or "no alternative considered">
REVISIT-IF: <the condition that would reopen it, or "settled">

Maximum five decisions, most consequential first.
Q
;;
    assumptions) cat <<'Q'
Answer ONLY from this session's history. Do not use tools. If it assumed nothing,
reply exactly: NO ASSUMPTIONS

List everything this session assumed ALREADY EXISTS and did not itself create — hosts,
services, credentials, files, DNS names, network paths, accounts. One per line:

ASSUMES: <the thing> | <why it needs it> | <VERIFIED or UNVERIFIED in this session>

Mark VERIFIED only if the session actually checked it existed.
Q
;;
    debt) cat <<'Q'
Answer ONLY from this session's history. Do not use tools. If nothing was left open,
reply exactly: NO DEBT

List what was left unfinished or deliberately deferred. One per line:

DEBT: <what is unfinished> | <BLOCKING or DEFERRED or UNKNOWN> | <what it would take to close>

BLOCKING means something else cannot proceed until it is done.
Q
;;
    overlap) cat <<'Q'
Answer ONLY from this session's history. Do not use tools.

Reply in exactly this form:

TOPIC: <five words or fewer naming the problem domain>
ARTIFACTS: <the main files, hosts or systems touched, comma separated>
STAGE: <PLANNING or BUILDING or DEBUGGING or DONE>
ONE-LINE: <what this session was actually trying to achieve>
Q
;;
  esac
}

# --- synthesis ----------------------------------------------------------------
prof_synthesis_prompt() {
  local id="$1"
  case "$id" in
    collision) cat <<'S'
You are cross-referencing several parallel workstreams for COLLISIONS. Below are their
declared claims. Your job is to find where two or more sessions claim the SAME resource,
or claim things that cannot coexist.

Write markdown with exactly these sections:

## Direct collisions
Bullets. Two or more sessions claiming the identical port, hostname, path, name, env var,
subnet or schema object. Name the sessions and the exact clashing value. If there are
none, write "None found." and do not pad.

## Likely collisions
Bullets. Claims that are not identical but will conflict in practice — overlapping subnets,
a path inside another session's directory, two services on one host competing for the same
resource, near-identical names that will confuse operators.

## Unclaimed dependencies
Bullets. Things one session DEPENDS on that no surveyed session claims to create.

## Sequencing
Bullets. Where one workstream must land before another, and why.

Be specific and quote the actual values. Do not invent conflicts to appear useful — if the
workstreams are genuinely independent, say so plainly.
S
;;
    conventions) cat <<'S'
You are auditing names against a defined standard. The approved standard is given first,
then the names each session actually created.

Write markdown with exactly these sections:

## Deviations
A table with columns: Name | Category | Session | Rule broken | Suggested correction.
Only include names that actually violate the stated standard.

## Ambiguous
Bullets. Names the standard does not cover, so the standard needs extending.

## Conforming
One line stating how many names conformed. Do not list them.

Judge ONLY against the stated standard. Do not substitute your own preferences — if the
standard permits something you would not choose, it conforms.
S
;;
    decisions) cat <<'S'
Consolidate these into a single decision log. Write markdown:

## Decisions
For each, a level-3 heading with the decision, then Because / Instead of / Revisit if.
Merge duplicates across sessions, and note when two sessions decided the SAME thing
differently — that is a conflict worth surfacing at the top.

## Conflicting decisions
Bullets, or "None." Sessions that settled the same question in incompatible ways.
S
;;
    assumptions) cat <<'S'
Build a dependency map. Write markdown:

## Assumed but never verified
Bullets, worst first — things multiple sessions depend on that nobody checked.

## Assumed and verified
Bullets, brief.

## Provided by another session
Bullets. Assumptions that another surveyed session actually creates — say which.

## Orphan dependencies
Bullets. Assumed by someone, created by nobody, verified by nobody. These are the ones
that break a deployment.
S
;;
    debt) cat <<'S'
Consolidate into one debt register. Write markdown:

## Blocking
Table: Item | Session | What it takes to close. Ordered by what unblocks the most.

## Deferred
Table: Item | Session | Why it was deferred.

## Unknown state
Bullets.
S
;;
    overlap) cat <<'S'
Group these sessions by what they were actually working on. Write markdown:

## Clusters
For each group of two or more sessions on the same problem: a level-3 heading naming the
topic, the sessions in it, and one line on whether merging them would help or whether they
are sequential stages of the same work.

## Singletons
One line listing topics covered by only one session.

## Merge candidates
Bullets, strongest first: pairs worth putting through the merge broker, and why.
S
;;
  esac
}

# --- conventions: the standard is YOURS ---------------------------------------
prof_conventions_exist() { [ -f "$SEC_CONVENTIONS" ]; }

prof_conventions_interview() {
  tui_page "DEFINE YOUR CONVENTIONS" "asked once — the warden audits against this, not its own taste"
  printf '\n'
  ui_note "Leave any answer blank to say \"no rule\" — the warden will then report"
  ui_note "names in that category as ambiguous rather than wrong."
  printf '\n'

  local host svc file script branch envvar db repo
  host="$(ui_ask   'HOSTS       e.g. <type>-<owner>-<floor>-<nn>, lowercase' '')"
  svc="$(ui_ask    'SERVICES    e.g. lowercase-hyphenated, no abbreviations' '')"
  file="$(ui_ask   'FILES       e.g. all lowercase, hyphens not underscores' '')"
  script="$(ui_ask 'SCRIPTS     e.g. NN-verb-noun.sh' '')"
  branch="$(ui_ask 'BRANCHES    e.g. type/short-description' '')"
  envvar="$(ui_ask 'ENV VARS    e.g. SCREAMING_SNAKE, provider-prefixed' '')"
  db="$(ui_ask     'DATABASES   e.g. snake_case, plural tables' '')"
  repo="$(ui_ask   'REPOS       e.g. lowercase, no org prefix' '')"

  {
    printf '# CONVENTIONS.yaml — the naming standard the Convention Warden audits against.\n'
    printf '# This is YOUR standard. The warden does not substitute its own preferences.\n'
    printf '# Blank means "no rule defined"; those names are reported as ambiguous.\n\n'
    printf 'defined:    %s\n' "$(date -u +%FT%TZ)"
    printf 'host:       %s\n' "${host:-}"
    printf 'service:    %s\n' "${svc:-}"
    printf 'file:       %s\n' "${file:-}"
    printf 'script:     %s\n' "${script:-}"
    printf 'branch:     %s\n' "${branch:-}"
    printf 'envvar:     %s\n' "${envvar:-}"
    printf 'database:   %s\n' "${db:-}"
    printf 'repo:       %s\n' "${repo:-}"
  } > "$SEC_CONVENTIONS"
  chmod 600 "$SEC_CONVENTIONS"
  printf '\n'
  ui_ok "written to ${SEC_CONVENTIONS#$SEC_ROOT/}"
  ui_note "edit that file any time — the warden re-reads it on every run"
  sec_log_start profiles; sec_log "conventions defined"
}

prof_conventions_text() {
  [ -f "$SEC_CONVENTIONS" ] || return 1
  grep -vE '^\s*#|^\s*$' "$SEC_CONVENTIONS" | sed 's/^/  /'
}

# --- running a profile --------------------------------------------------------
# prof_run ID N_SESSIONS — surveys, synthesises, writes a report, echoes its path
prof_run() {
  local id="$1" want="$2"
  local -a S_ID S_NAME
  local n=0 uuid cwd title when msgs sub

  while IFS='|' read -r uuid cwd title when msgs sub; do
    [ -n "$uuid" ] || continue
    [ "$n" -ge "$want" ] && break
    S_ID[$n]="$uuid"; S_NAME[$n]="$title"; n=$(( n + 1 ))
  done <<PS
$(ws_scan_sessions)
PS
  [ "$n" -gt 0 ] || { ui_err "no sessions to survey"; return 1; }

  local q collected="" ans i start elapsed answered=0 skipped=0
  q="$(prof_question "$id")"

  tui_page "$(prof_field "$id" 4)" "surveying $n session(s) — one model call each"
  printf '\n'
  i=0
  while [ "$i" -lt "$n" ]; do
    printf '   %s[%s/%s]%s %-44s ' "$T_DIM" "$(( i + 1 ))" "$n" "$T_RS" \
      "$(tui_fit "${S_NAME[$i]}" 44)"
    start="$(date +%s)"
    ans="$(claude -p --resume "${S_ID[$i]}" "$q" --output-format text 2>/dev/null)"
    elapsed=$(( $(date +%s) - start ))
    case "$ans" in
      ""|*"NOTHING CLAIMED"*|*"NOTHING NAMED"*|*"NO DECISIONS"*|*"NO ASSUMPTIONS"*|*"NO DEBT"*)
        skipped=$(( skipped + 1 ))
        printf '%snothing to report  %ss%s\n' "$T_DIM" "$elapsed" "$T_RS" ;;
      *)
        answered=$(( answered + 1 ))
        collected="$collected

=== SESSION: ${S_NAME[$i]} (${S_ID[$i]:0:8}) ===
$ans"
        printf '%sreported  %ss%s\n' "$T_OK" "$elapsed" "$T_RS" ;;
    esac
    i=$(( i + 1 ))
  done

  printf '\n'
  tui_kv "sessions surveyed" "$n"
  tui_kv "with something to report" "$answered"
  tui_kv "nothing to report" "$skipped" "$T_DIM"
  if [ "$answered" -lt 1 ]; then
    printf '\n'; ui_info "nothing to cross-reference"; return 1
  fi

  printf '\n'
  tui_section "SYNTHESISING"
  local prefix="" synth report stamp
  if [ "$id" = "conventions" ]; then
    prefix="THE APPROVED STANDARD (audit against THIS, not your own preferences):

$(prof_conventions_text)

NAMES CREATED, BY SESSION:
"
  fi
  printf '   %s· cross-referencing %s report(s)%s ' "$T_DIM" "$answered" "$T_RS"
  start="$(date +%s)"
  synth="$(claude -p "$(prof_synthesis_prompt "$id")

$prefix$collected" --output-format text 2>/dev/null)"
  elapsed=$(( $(date +%s) - start ))
  if [ -n "$synth" ]; then printf '%sdone in %ss%s\n' "$T_OK" "$elapsed" "$T_RS"
  else printf '%sno output%s\n' "$T_ERR" "$T_RS"; return 1; fi

  mkdir -p "$PROF_REPORTS" 2>/dev/null; chmod 700 "$PROF_REPORTS" 2>/dev/null
  stamp="$(date +%Y%m%d-%H%M%S)"
  report="$PROF_REPORTS/$id-$stamp.md"
  {
    printf '# %s\n\n' "$(prof_field "$id" 4)"
    printf -- '- %s\n' "$(prof_field "$id" 5)"
    printf -- '- surveyed %s session(s) on %s, %s reported\n' "$n" "$(date -u +%FT%TZ)" "$answered"
    printf -- '- host: %s\n\n---\n\n' "$(hostname -s)"
    printf '%s\n\n---\n\n' "$synth"
    printf '<details><summary>raw session reports</summary>\n%s\n\n</details>\n' "$collected"
  } > "$report"
  chmod 600 "$report"
  sec_log_start profiles; sec_log "$id surveyed $n sessions -> $(basename "$report")"
  printf '%s' "$report"
}

# --- the screen ---------------------------------------------------------------
profiles_screen() {
  ui_interactive || return 0
  broker_have || { tui_page "SESSION PROFILES" "claude CLI not on PATH"; ui_pause; return 0; }

  local -a P_ID P_TITLE P_BLURB P_GLYPH P_HUEV P_LINE
  local n=0 id glyph huev title blurb
  while IFS='|' read -r id glyph huev title blurb; do
    [ -n "$id" ] || continue
    P_ID[$n]="$id"; P_GLYPH[$n]="$glyph"; P_HUEV[$n]="$huev"
    P_TITLE[$n]="$title"; P_BLURB[$n]="$blurb"; n=$(( n + 1 ))
  done <<PL
$(prof_list)
PL

  local sel=0 key prev curline host i
  host="$(hostname -s 2>/dev/null || echo host)"

  draw_prof() {
    local k="$1" on="$2" hue dot dlab
    eval "hue=\"\${${P_HUEV[$k]}}\""
    if [ "${P_ID[$k]}" = "conventions" ] && ! prof_conventions_exist; then
      dot=warn; dlab="standard not set"
    else dot=ok; dlab="ready"; fi
    printf '\033[%d;1H' "${P_LINE[$k]}"
    tui_modrow "$on" "${P_GLYPH[$k]}" "$hue" "$(tui_fit "${P_TITLE[$k]}" 34)" "" "$dot" "$dlab"
    tui_moddesc "$on" "$(tui_fit "${P_BLURB[$k]}" $(( TUI_COLS - 12 )))"
  }
  draw_profs() {
    tui_home
    tui_header "$host" "$n profile(s) · each surveys your sessions and writes a report · nothing is changed"
    curline=4
    i=0
    while [ "$i" -lt "$n" ]; do
      P_LINE[$i]="$(( curline + 1 ))"
      draw_prof "$i" "$([ "$i" = "$sel" ] && echo 1 || echo 0)"
      curline=$(( curline + 2 ))
      [ "$i" -lt $(( n - 1 )) ] && { tui_blank; curline=$(( curline + 1 )); }
      i=$(( i + 1 ))
    done
    local pad=$(( TUI_ROWS - curline - 2 )); [ "$pad" -lt 0 ] && pad=0
    i=0; while [ "$i" -lt "$pad" ]; do tui_blank; i=$(( i + 1 )); done
    tui_footer "↑↓ move" "↵ run" "c conventions" "r reports" "esc back"
    tui_clear_below
  }

  tui_begin
  trap 'tui_end; cleanup' EXIT INT TERM
  tui_dims; draw_profs

  while :; do
    key="$(tui_readkey)" || break
    prev="$sel"
    case "$key" in
      up)   sel=$(( sel - 1 )); [ "$sel" -lt 0 ] && sel=$(( n - 1 )) ;;
      down) sel=$(( sel + 1 )); [ "$sel" -ge "$n" ] && sel=0 ;;
      enter|right)
        tui_end
        if [ "${P_ID[$sel]}" = "conventions" ] && ! prof_conventions_exist; then
          prof_conventions_interview
          ui_pause
        fi
        tui_page "${P_TITLE[$sel]}" "${P_BLURB[$sel]}"
        printf '\n'
        local scope howmany
        scope="$(tui_menu "HOW MANY SESSIONS" "one model call each, about 8 seconds apiece" \
          "Most recent 5|roughly a minute" \
          "Most recent 10|roughly 90 seconds" \
          "Most recent 25|roughly four minutes" \
          "Cancel|survey nothing")" || { tui_begin; tui_dims; draw_profs; continue; }
        case "$scope" in
          "Most recent 5")  howmany=5 ;;
          "Most recent 10") howmany=10 ;;
          "Most recent 25") howmany=25 ;;
          *) tui_begin; tui_dims; draw_profs; continue ;;
        esac
        local rep
        rep="$(prof_run "${P_ID[$sel]}" "$howmany")"
        if [ -n "$rep" ] && [ -f "$rep" ]; then
          printf '\n'
          ui_ok "report written to ${rep#$SEC_ROOT/}"
          printf '\n'
          sed -n '/^## /,$p' "$rep" | sed -n '1,44p' | sed 's/^/   /'
          printf '\n'
          ui_note "full report, including every raw session reply:"
          printf '     %s%s%s\n' "$T_ACCENT" "$rep" "$T_RS"
        else
          ui_info "no report produced"
        fi
        ui_pause
        tui_begin; tui_dims; draw_profs; continue ;;
      char:c)
        tui_end
        if prof_conventions_exist; then
          tui_page "YOUR CONVENTIONS" "${SEC_CONVENTIONS#$SEC_ROOT/}"
          prof_conventions_text
          printf '\n'
          ui_confirm "Redefine them?" && prof_conventions_interview
        else
          prof_conventions_interview
        fi
        ui_pause
        tui_begin; tui_dims; draw_profs; continue ;;
      char:r)
        tui_end
        tui_page "REPORTS" "${PROF_REPORTS#$SEC_ROOT/}"
        if [ -d "$PROF_REPORTS" ] && [ -n "$(ls -A "$PROF_REPORTS" 2>/dev/null)" ]; then
          ls -1t "$PROF_REPORTS" | head -20 | sed 's/^/   /'
          printf '\n'
          ui_note "these are plain markdown — file them in your notes vault"
        else
          ui_info "none yet"
        fi
        ui_pause
        tui_begin; tui_dims; draw_profs; continue ;;
      quit|esc) break ;;
      *) continue ;;
    esac
    draw_prof "$prev" 0; draw_prof "$sel" 1
  done
  tui_end
  trap 'cleanup' EXIT INT TERM
  return 0
}
