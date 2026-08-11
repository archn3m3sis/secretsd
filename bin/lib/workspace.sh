#!/usr/bin/env bash
# lib/workspace.sh — the project workspace and Claude Code launcher.
#
# WHAT THIS IS FOR
#   You work a project with an agent. The agent needs credentials but must never
#   see their VALUES — the key name is the most it ever learns. This screen is
#   where that contract is enforced at launch time:
#
#     clean launch   the agent's process gets NO secret material at all. It works
#                    from key names, and calls `secrets record` when it creates
#                    one. This is the default, and it is the right default.
#     scoped launch  the agent's process gets exactly the keys in that project's
#                    profile and nothing else — not the other 140. Values exist
#                    only inside that child process; they are never exported to
#                    your shell, printed, or written to a transcript.
#
#   Projects are DISCOVERED (git repositories under configured roots), not
#   hardcoded, so the list cannot drift from what is actually on disk.
#
# PROJECTS.yaml is plaintext: roots and per-project notes, no secret values.
# Sourced, never executed.

SEC_PROJECTS="$SEC_SECRETS/PROJECTS.yaml"

# --- roots --------------------------------------------------------------------
ws_roots() {
  local r
  if [ -f "$SEC_PROJECTS" ] && grep -q '^roots:' "$SEC_PROJECTS" 2>/dev/null; then
    # A leading ~ from the YAML is a literal character, not the shell's tilde.
    # Left unexpanded, every root fails `[ -d ]` and discovery silently finds
    # nothing while looking perfectly correct.
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      printf '%s\n' "${r/#\~/$HOME}"
    done <<ROOTS
$(awk '/^roots:/{f=1;next} /^[^[:space:]-]/{f=0} f && /^[[:space:]]*-[[:space:]]+/{
      sub(/^[[:space:]]*-[[:space:]]+/,""); sub(/[[:space:]]*#.*$/,""); print}' "$SEC_PROJECTS")
ROOTS
  else
    printf '%s\n' "$HOME/work" "$HOME/dev/projects" "$HOME/dev/industrial_projects"
  fi
}

# ws_discover -> one project path per line (a git repo under a root)
# ws_discover — the project list. CACHED in the scratch directory for the life
# of the process: it is a filesystem walk over every project root, and the
# dashboard alone asks three times (the project count, the commit-guard sweep,
# and the posture check for stray .env files). Projects do not appear while one
# screen is being drawn. TMPD is per-process and removed on exit, so the cache
# cannot outlive the run that made it.
ws_discover() {
  local cache="${TMPD:-${TMPDIR:-/tmp}}/ws-discover"
  if [ -s "$cache" ]; then printf '%s\n' "$(<"$cache")"; return 0; fi
  ws_discover_scan > "$cache" 2>/dev/null
  [ -s "$cache" ] || return 0
  printf '%s\n' "$(<"$cache")"
}

ws_discover_scan() {
  local root d
  while IFS= read -r root; do
    [ -d "$root" ] || continue
    # git repositories first
    find "$root" -maxdepth 2 -type d -name .git 2>/dev/null | sed 's|/\.git$||'
    # plus any immediate child that is clearly a project but not yet a repo —
    # a directory tracked only in your head is still a project you launch into
    for d in "$root"/*/; do
      [ -d "$d" ] || continue
      d="${d%/}"
      [ -d "$d/.git" ] && continue
      if [ -f "$d/package.json" ] || [ -f "$d/Cargo.toml" ] || [ -f "$d/go.mod" ] \
         || [ -f "$d/pyproject.toml" ] || [ -f "$d/build.zig" ] || [ -f "$d/CLAUDE.md" ] \
         || [ -d "$d/src" ] || [ -d "$d/docs" ]; then
        printf '%s\n' "$d"
      fi
    done
  done <<EOF
$(ws_roots)
EOF
}


# ws_curated -> "name|path|note" for entries pinned in PROJECTS.yaml.
# Discovery finds what is on disk; curation guarantees the projects you actually
# work on are listed even when they are a deliverables folder or not yet a repo.
ws_curated() {
  [ -f "$SEC_PROJECTS" ] || return 0
  awk '
    /^projects:/ { inp=1; next }
    /^[^[:space:]#-]/ { inp=0 }
    inp && /^[[:space:]]*-[[:space:]]*name:/ {
      if (name != "") print name "|" path "|" note
      name=$0; sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/,"",name); path=""; note=""; next
    }
    inp && /^[[:space:]]*path:/  { path=$0; sub(/^[[:space:]]*path:[[:space:]]*/,"",path); next }
    inp && /^[[:space:]]*note:/  { note=$0; sub(/^[[:space:]]*note:[[:space:]]*/,"",note); next }
    END { if (name != "") print name "|" path "|" note }
  ' "$SEC_PROJECTS"
}

# --- live repository state ----------------------------------------------------
ws_branch() {
  # `rev-parse --abbrev-ref HEAD` prints "HEAD" to stdout AND exits non-zero on a
  # repo with no commits, so a `||` fallback appends a second line and corrupts
  # the row. symbolic-ref is the honest question: what branch am I on?
  local b
  b="$(git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null)"
  [ -n "$b" ] || b="$(git -C "$1" rev-parse --short HEAD 2>/dev/null)"
  [ -n "$b" ] || b="no commits"
  printf '%s' "$b"
}
ws_dirty() {   # count of changed paths
  git -C "$1" status --porcelain 2>/dev/null | sec_nlines
}
ws_last_commit() {
  local t now d
  t="$(git -C "$1" log -1 --format=%ct 2>/dev/null)"
  [ -n "$t" ] || { printf 'never'; return; }
  now="$(date +%s)"; d=$(( now - t ))
  if   [ "$d" -lt 3600 ];   then printf '%dm ago' $(( d / 60 ))
  elif [ "$d" -lt 86400 ];  then printf '%dh ago' $(( d / 3600 ))
  else printf '%dd ago' $(( d / 86400 )); fi
}
ws_stack() {   # a one-word hint at what the project is
  local p="$1"
  [ -f "$p/package.json" ]      && { printf 'node';   return; }
  [ -f "$p/Cargo.toml" ]        && { printf 'rust';   return; }
  [ -f "$p/go.mod" ]            && { printf 'go';     return; }
  [ -f "$p/pyproject.toml" ] || [ -f "$p/requirements.txt" ] && { printf 'python'; return; }
  [ -f "$p/build.zig" ]         && { printf 'zig';    return; }
  [ -f "$p/Gemfile" ]           && { printf 'ruby';   return; }
  ls "$p"/*.ps1 >/dev/null 2>&1 && { printf 'powershell'; return; }
  printf 'mixed'
}

# --- credentials and agent activity per project -------------------------------
# Which credentials the manifest says this project uses.
ws_project_creds() {   # $1 project name
  [ -f "$SEC_MANIFEST" ] || return 0
  awk -v p="$1" '
    /^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/ { k=$0; sub(/:[[:space:]]*$/,"",k); next }
    k != "" && $1 == "used_by:" {
      line=$0; sub(/^[[:space:]]*used_by:[[:space:]]*/,"",line)
      if (index(tolower(line), tolower(p)) > 0) print k
    }
  ' "$SEC_MANIFEST"
}

# Unread agent-authored credentials attributed to this project.
ws_project_unread() {   # $1 project name
  local k c=0
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    if [ "$(prov_field "$k" project)" = "$1" ] && [ "$(prov_field "$k" seen)" = "false" ]; then
      c=$(( c + 1 ))
    fi
  done <<EOF
$(prov_keys)
EOF
  printf '%s' "$c"
}


# --- session naming -----------------------------------------------------------
# Claude Code identifies sessions by UUID. Those UUIDs are what land in the logs
# and in ~/.claude/projects/<encoded-path>/<uuid>.jsonl, and they tell you
# nothing. The launcher therefore REFUSES to start a session without a
# human-readable name: it mints the UUID itself, passes it with --session-id,
# sets the display name with --name, and records the mapping. From then on the
# name is the handle and the UUID is an implementation detail.
SEC_SESSIONS="$SEC_SECRETS/SESSIONS.yaml"

ws_encode_path() { printf '%s' "$1" | sed 's|/|-|g'; }

ws_transcript_path() {   # $1 project path  $2 uuid
  printf '%s/.claude/projects/%s/%s.jsonl' "$HOME" "$(ws_encode_path "$1")" "$2"
}

# ws_ask_session_name -> a non-empty, sanitised name on stdout; nonzero if cancelled
ws_ask_session_name() {
  local nm
  while :; do
    nm="$(ui_ask 'Session name (required)' 'e.g. portfolio hero rebuild')" || return 1
    nm="$(printf '%s' "$nm" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/"/'"'"'/g')"
    if [ -z "$nm" ]; then
      ui_warn "a session name is required — it is how you will find this run later"
      ui_confirm "Try again?" || return 1
      continue
    fi
    printf '%s' "$nm"; return 0
  done
}

ws_record_session() {   # $1 name  $2 uuid  $3 project  $4 path  $5 mode
  touch "$SEC_SESSIONS"
  {
    printf '%s:\n' "$2"
    printf '  name:       %s\n' "$1"
    printf '  project:    %s\n' "$3"
    printf '  path:       %s\n' "$4"
    printf '  mode:       %s\n' "$5"
    printf '  started:    %s\n' "$(date -u +%FT%TZ)"
    printf '  transcript: %s\n' "$(ws_transcript_path "$4" "$2")"
    printf '\n'
  } >> "$SEC_SESSIONS"
}

ws_session_ids() {
  [ -f "$SEC_SESSIONS" ] || return 0
  grep -oE '^[0-9a-f-]{36}:' "$SEC_SESSIONS" 2>/dev/null | sed 's/:$//'
}
ws_session_field() {   # $1 uuid  $2 field
  [ -f "$SEC_SESSIONS" ] || return 0
  awk -v u="$1" -v w="$2" '
    /^[0-9a-f-]{36}:[[:space:]]*$/ { c=$0; sub(/:[[:space:]]*$/,"",c); next }
    c == u && $1 == w":" { $1=""; sub(/^[[:space:]]+/,""); sub(/[[:space:]]+$/,""); print; exit }
  ' "$SEC_SESSIONS"
}

# --- launching ----------------------------------------------------------------
ws_have_claude() { command -v claude >/dev/null 2>&1; }

# ws_launch_clean PATH — Claude Code with NO secret material in its environment
ws_launch_clean() {
  local p="$1" proj="$2" nm uuid
  ws_have_claude || { ui_err "the 'claude' CLI is not on PATH"; ui_pause; return 1; }
  nm="$(ws_ask_session_name)" || { ui_info "cancelled — no session started"; ui_pause; return 1; }
  uuid="$(uuidgen | tr 'A-Z' 'a-z')"

  ws_record_session "$nm" "$uuid" "$proj" "$p" clean
  sec_log_start "launch"; sec_log "claude clean '$nm' ($uuid) in $p"

  ui_ok "session '$nm'"
  ui_info "id         $uuid"
  ui_info "transcript $(ws_transcript_path "$p" "$uuid")"
  ui_note "no secret material is in this process — the agent works from key names"
  ui_note "it can create credentials for you with: secrets record NAME --agent … --project …"
  printf '\n'
  ( cd "$p" && claude --session-id "$uuid" --name "$nm" )
  ui_info "session '$nm' ended — back in the workspace"
  ui_pause
}

# ws_launch_scoped PATH PROFILE — only that profile's keys reach the child
ws_launch_scoped() {
  local p="$1" prof="$2" proj="$3" nkeys nm uuid
  ws_have_claude || { ui_err "the 'claude' CLI is not on PATH"; ui_pause; return 1; }
  nkeys="$(profile_keys "$prof" | sec_nlines)"
  ui_warn "scoped launch: $nkeys credential(s) from profile '$prof' will exist in that process"
  ui_note "everything else in the store stays out. Values never reach your shell."
  ui_confirm "Launch Claude Code with the '$prof' profile injected?" || { ui_info "cancelled"; return 1; }
  nm="$(ws_ask_session_name)" || { ui_info "cancelled — no session started"; ui_pause; return 1; }
  uuid="$(uuidgen | tr 'A-Z' 'a-z')"

  ws_record_session "$nm" "$uuid" "$proj" "$p" "scoped:$prof"
  sec_log_start "launch"; sec_log "claude scoped '$nm' ($uuid, profile $prof, $nkeys keys) in $p"

  ui_ok "session '$nm'"
  ui_info "id         $uuid"
  ui_info "transcript $(ws_transcript_path "$p" "$uuid")"
  printf '\n'
  ( cd "$p" && "$SEC_SELF" run --profile "$prof" -- claude --session-id "$uuid" --name "$nm" )
  ui_info "session '$nm' ended — back in the workspace"
  ui_pause
}

ws_open_editor() {
  local p="$1"
  if command -v zed >/dev/null 2>&1; then
    sec_log_start "launch"; sec_log "zed $p"
    zed "$p" >/dev/null 2>&1 &
    ui_ok "opened $p in Zed"
  else
    ui_err "zed is not on PATH"
  fi
  ui_pause
}

# --- the screen ---------------------------------------------------------------
ws_screen() {
  ui_interactive || { ui_needs_tty workspace; return 1; }
  local -a W_PATH W_NAME W_BRANCH W_DIRTY W_AGE W_STACK W_CREDS W_UNREAD W_LINE
  local n=0 p name

  local seen="" cname cpath cnote
  # curated first, so a pinned project keeps its intended name and ordering
  while IFS='|' read -r cname cpath cnote; do
    [ -n "$cname" ] || continue
    cpath="${cpath/#\~/$HOME}"
    if [ -z "$cpath" ] || [ ! -d "$cpath" ]; then
      W_PATH[$n]="${cpath:-—}"; W_NAME[$n]="$cname"
      W_BRANCH[$n]="not on this host"; W_DIRTY[$n]=0
      W_AGE[$n]="—"; W_STACK[$n]="${cnote:-curated}"
      W_CREDS[$n]="$(ws_project_creds "$cname" | sec_nlines)"
      W_UNREAD[$n]="$(ws_project_unread "$cname")"
      n=$(( n + 1 )); continue
    fi
    W_PATH[$n]="$cpath"; W_NAME[$n]="$cname"
    W_BRANCH[$n]="$(ws_branch "$cpath")"; W_DIRTY[$n]="$(ws_dirty "$cpath")"
    W_AGE[$n]="$(ws_last_commit "$cpath")"; W_STACK[$n]="$(ws_stack "$cpath")"
    W_CREDS[$n]="$(ws_project_creds "$cname" | sec_nlines)"
    W_UNREAD[$n]="$(ws_project_unread "$cname")"
    seen="$seen|$cpath|"
    n=$(( n + 1 ))
  done <<EOF
$(ws_curated)
EOF

  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -d "$p" ] || continue
    case "$seen" in *"|$p|"*) continue ;; esac
    name="$(basename "$p")"
    W_PATH[$n]="$p"; W_NAME[$n]="$name"
    W_BRANCH[$n]="$(ws_branch "$p")"
    W_DIRTY[$n]="$(ws_dirty "$p")"
    W_AGE[$n]="$(ws_last_commit "$p")"
    W_STACK[$n]="$(ws_stack "$p")"
    W_CREDS[$n]="$(ws_project_creds "$name" | sec_nlines)"
    W_UNREAD[$n]="$(ws_project_unread "$name")"
    n=$(( n + 1 ))
  done <<EOF
$(ws_discover)
EOF

  if [ "$n" -eq 0 ]; then
    tui_page "WORKSPACE" "no git repositories found under the configured roots"
    printf '\n'
    ws_roots | sed "s|^|   searched: |"
    printf '\n   %sAdd roots to %s:%s\n\n' "$T_DIM" "${SEC_PROJECTS#$SEC_ROOT/}" "$T_RS"
    printf '     %sroots:%s\n' "$T_ACCENT" "$T_RS"
    printf '     %s  - ~/work%s\n' "$T_ACCENT" "$T_RS"
    printf '     %s  - ~/dev/projects%s\n\n' "$T_ACCENT" "$T_RS"
    ui_pause
    return 0
  fi

  local sel=0 key prev i curline host sub claudever
  host="$(hostname -s 2>/dev/null || echo host)"
  if ws_have_claude; then claudever="Claude Code $(ui_tool_version claude claude --version | awk '{print $1}')"
  else claudever="Claude Code not on PATH"; fi
  sub="$n project(s) · $claudever · agents launch without secret material by default"

  draw_proj() {
    local m="$1" on="$2" mark hue lead right
    printf '\033[%d;1H' "${W_LINE[$m]}"
    if [ "${W_DIRTY[$m]}" -gt 0 ]; then mark='⣔⣉⣢'; hue="$N_AMBER"
    else                                mark='⣏⣉⣹'; hue="$N_GREEN"; fi
    if [ "${W_DIRTY[$m]}" -gt 0 ]; then right="${W_BRANCH[$m]} +${W_DIRTY[$m]} · ${W_AGE[$m]}"
    else                                right="${W_BRANCH[$m]} · ${W_AGE[$m]}"; fi
    lead=$(( TUI_COLS - 9 - ${#W_NAME[$m]} - ${#right} - 6 ))
    [ "$lead" -lt 1 ] && lead=1

    local shortpath="${W_PATH[$m]}"
    case "$shortpath" in "$HOME"/*) shortpath="~${shortpath#$HOME}" ;; esac
    local sub2="$shortpath · ${W_STACK[$m]} · ${W_CREDS[$m]} credential(s)"
    [ "${W_UNREAD[$m]}" -gt 0 ] && sub2="$sub2 · ${W_UNREAD[$m]} unread from agents"
    sub2="$(tui_fit "$sub2" $(( TUI_COLS - 11 )))"

    if [ "$on" = "1" ]; then
      printf '%s  %s▌%s %s%s%s  %s%s%s ' "$T_SELBG" "$T_ACCENT" "$T_SELBG" \
        "$hue" "$mark" "$T_SELBG" "$T_B$T_TEXT" "${W_NAME[$m]}" "$T_SELBG"
      printf '%s' "$T_LEAD"; tui_repeat '·' "$lead"
      printf '%s %s%s%s  ' "$T_SELBG" "$T_MUTE" "$right" "$T_RS"
      printf '\n'
      printf '%s         %s%s%s' "$T_SELBG" "$T_DIM" "$sub2" "$T_SELBG"
      tui_padn "$TUI_COLS" $(( 9 + ${#sub2} )); printf '%s\n' "$T_RS"
    else
      printf '    %s%s%s  %s%s%s ' "$hue" "$mark" "$T_RS" "$T_MUTE" "${W_NAME[$m]}" "$T_RS"
      printf '%s' "$T_LEAD"; tui_repeat '·' "$lead"
      printf ' %s%s%s  \n' "$T_DIM" "$right" "$T_RS"
      printf '         %s%s%s' "$T_LEAD" "$sub2" "$T_RS"
      tui_padn "$TUI_COLS" $(( 9 + ${#sub2} )); printf '\n'
    fi
  }

  draw_ws() {
    tui_home
    tui_header "$host" "$sub"
    curline=4
    local gap=1
    [ "$(( TUI_ROWS - 6 - n * 2 ))" -ge "$(( n * 2 ))" ] && gap=2
    i=0
    while [ "$i" -lt "$n" ]; do
      W_LINE[$i]="$(( curline + 1 ))"
      draw_proj "$i" "$([ "$i" = "$sel" ] && echo 1 || echo 0)"
      curline=$(( curline + 2 ))
      if [ "$i" -lt $(( n - 1 )) ]; then
        local g=0; while [ "$g" -lt "$gap" ]; do tui_blank; curline=$(( curline + 1 )); g=$(( g + 1 )); done
      fi
      i=$(( i + 1 ))
    done
    local pad=$(( TUI_ROWS - curline - 2 )); [ "$pad" -lt 0 ] && pad=0
    i=0; while [ "$i" -lt "$pad" ]; do tui_blank; i=$(( i + 1 )); done
    tui_footer "↑↓ move" "↵ launch" "s scoped" "e editor" "c creds" "n sessions" "esc back"
    tui_clear_below
  }

  ui_prof pre_paint
  tui_begin
  trap 'tui_end; cleanup' EXIT INT TERM
  tui_dims; draw_ws

  while :; do
    key="$(tui_readkey)" || break
    prev="$sel"
    case "$key" in
      up)   sel=$(( sel - 1 )); [ "$sel" -lt 0 ] && sel=$(( n - 1 )) ;;
      down) sel=$(( sel + 1 )); [ "$sel" -ge "$n" ] && sel=0 ;;
      enter|right)
        tui_end
        tui_page "LAUNCH · ${W_NAME[$sel]}" "clean launch — the agent gets no secret material"
        ws_launch_clean "${W_PATH[$sel]}" "${W_NAME[$sel]}"
        tui_begin; tui_dims; draw_ws; continue ;;
      char:s)
        tui_end
        local prof; prof="${W_NAME[$sel]}"
        if profile_names | ui_match_line "$prof"; then
          tui_page "SCOPED LAUNCH · $prof" "only this project's profile reaches the agent"
          ws_launch_scoped "${W_PATH[$sel]}" "$prof" "${W_NAME[$sel]}"
        else
          tui_page "NO PROFILE · ${W_NAME[$sel]}" "a scoped launch needs a profile of the same name"
          ui_warn "no profile named '${W_NAME[$sel]}'"
          ui_note "create one, then this project can launch with exactly those keys:"
          printf '\n     %ssecrets profile add %s%s\n\n' "$T_ACCENT" "${W_NAME[$sel]}" "$T_RS"
          ui_pause
        fi
        tui_begin; tui_dims; draw_ws; continue ;;
      char:e)
        tui_end; ws_open_editor "${W_PATH[$sel]}"; tui_begin; tui_dims; draw_ws; continue ;;
      char:n)
        tui_end; ws_sessions_screen; tui_begin; tui_dims; draw_ws; continue ;;
      char:c)
        tui_end
        tui_page "CREDENTIALS · ${W_NAME[$sel]}" "what the manifest says this project uses"
        local c; c="$(ws_project_creds "${W_NAME[$sel]}")"
        if [ -n "$c" ]; then
          printf '%s\n' "$c" | sed "s|^|   · |"
          printf '\n   %s%s credential(s). Values are never shown here — use c on a key to copy.%s\n' \
            "$T_DIM" "$(printf '%s' "$c" | sec_nlines)" "$T_RS"
        else
          ui_info "none recorded"
          ui_note "set used_by: ${W_NAME[$sel]} in $(basename "$SEC_MANIFEST") to map credentials here"
        fi
        ui_pause
        tui_begin; tui_dims; draw_ws; continue ;;
      quit|esc) break ;;
      *) continue ;;
    esac
    draw_proj "$prev" 0; draw_proj "$sel" 1
  done
  tui_end
  trap 'cleanup' EXIT INT TERM
  return 0
}

# --- sessions screen ----------------------------------------------------------
# The index that makes the UUIDs irrelevant: your names, what each run was for,
# and whether its transcript still exists. Resume by name, never by UUID.
ws_sessions_screen() {
  ui_interactive || { ui_needs_tty sessions "secretsd sessions --json   the session inventory"; return 1; }
  local -a S_ID S_NAME S_PROJ S_PATH S_MODE S_WHEN S_TRANS S_LIVE S_LINE
  local n=0 u
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    S_ID[$n]="$u"
    S_NAME[$n]="$(ws_session_field "$u" name)"
    S_PROJ[$n]="$(ws_session_field "$u" project)"
    S_PATH[$n]="$(ws_session_field "$u" path)"
    S_MODE[$n]="$(ws_session_field "$u" mode)"
    S_WHEN[$n]="$(prov_age "$(ws_session_field "$u" started)")"
    S_TRANS[$n]="$(ws_session_field "$u" transcript)"
    if [ -f "${S_TRANS[$n]}" ]; then S_LIVE[$n]=1; else S_LIVE[$n]=0; fi
    n=$(( n + 1 ))
  done <<SESSIDS
$(ws_session_ids)
SESSIDS

  if [ "$n" -eq 0 ]; then
    tui_page "SESSIONS" "named Claude Code sessions launched from here"
    printf '\n   %sNone yet.%s\n\n' "$T_MUTE" "$T_RS"
    printf '   %sEvery launch from the workspace demands a name up front. The launcher mints\n' "$T_DIM"
    printf '   the session UUID itself, passes it with --session-id, sets the display name\n'
    printf '   with --name, and records the mapping here — so the UUID in the log never has\n'
    printf '   to be something you read or remember.%s\n' "$T_RS"
    ui_pause
    return 0
  fi

  local sel=0 key prev i curline host
  host="$(hostname -s 2>/dev/null || echo host)"

  draw_sess() {
    local m="$1" on="$2" dot dotcol lead right sub2
    printf '\033[%d;1H' "${S_LINE[$m]}"
    if [ "${S_LIVE[$m]}" = "1" ]; then dot='●'; dotcol="$N_GREEN"; else dot='○'; dotcol="$T_DIM"; fi
    right="${S_PROJ[$m]} · ${S_WHEN[$m]}"
    lead=$(( TUI_COLS - 8 - ${#S_NAME[$m]} - ${#right} - 4 ))
    [ "$lead" -lt 1 ] && lead=1
    sub2="$(tui_fit "${S_MODE[$m]} · ${S_ID[$m]}" $(( TUI_COLS - 10 )))"
    [ "${S_LIVE[$m]}" = "0" ] && sub2="$(tui_fit "$sub2 · transcript missing" $(( TUI_COLS - 10 )))"
    if [ "$on" = "1" ]; then
      printf '%s  %s▌%s %s%s %s%s%s ' "$T_SELBG" "$T_ACCENT" "$T_SELBG" "$dotcol" "$dot" \
        "$T_B$T_TEXT" "${S_NAME[$m]}" "$T_SELBG"
      printf '%s' "$T_LEAD"; tui_repeat '·' "$lead"
      printf '%s %s%s%s  \n' "$T_SELBG" "$T_MUTE" "$right" "$T_RS"
      printf '%s        %s%s%s' "$T_SELBG" "$T_DIM" "$sub2" "$T_SELBG"
      tui_padn "$TUI_COLS" $(( 8 + ${#sub2} )); printf '%s\n' "$T_RS"
    else
      printf '    %s%s %s%s%s ' "$dotcol" "$dot" "$T_MUTE" "${S_NAME[$m]}" "$T_RS"
      printf '%s' "$T_LEAD"; tui_repeat '·' "$lead"
      printf ' %s%s%s  \n' "$T_DIM" "$right" "$T_RS"
      printf '        %s%s%s' "$T_LEAD" "$sub2" "$T_RS"
      tui_padn "$TUI_COLS" $(( 8 + ${#sub2} )); printf '\n'
    fi
  }

  draw_sessions() {
    tui_home
    tui_header "$host" "$n named session(s) · your names, not the log UUIDs"
    curline=4
    i=0
    while [ "$i" -lt "$n" ]; do
      S_LINE[$i]="$(( curline + 1 ))"
      draw_sess "$i" "$([ "$i" = "$sel" ] && echo 1 || echo 0)"
      curline=$(( curline + 2 ))
      if [ "$i" -lt $(( n - 1 )) ]; then tui_blank; curline=$(( curline + 1 )); fi
      i=$(( i + 1 ))
    done
    local pad=$(( TUI_ROWS - curline - 2 )); [ "$pad" -lt 0 ] && pad=0
    i=0; while [ "$i" -lt "$pad" ]; do tui_blank; i=$(( i + 1 )); done
    tui_footer "↑↓ move" "↵ resume" "t transcript" "i adopt" "b broker/merge" "esc back"
    tui_clear_below
  }

  tui_begin
  trap 'tui_end; cleanup' EXIT INT TERM
  tui_dims; draw_sessions

  while :; do
    key="$(tui_readkey)" || break
    prev="$sel"
    case "$key" in
      up)   sel=$(( sel - 1 )); [ "$sel" -lt 0 ] && sel=$(( n - 1 )) ;;
      down) sel=$(( sel + 1 )); [ "$sel" -ge "$n" ] && sel=0 ;;
      enter|right)
        tui_end
        tui_page "RESUME · ${S_NAME[$sel]}" "${S_PROJ[$sel]} · ${S_PATH[$sel]}"
        if [ ! -d "${S_PATH[$sel]}" ]; then
          ui_err "project directory no longer exists: ${S_PATH[$sel]}"; ui_pause
        elif [ "${S_LIVE[$sel]}" = "0" ]; then
          ui_err "no transcript on disk for this session"
          ui_note "expected: ${S_TRANS[$sel]}"; ui_pause
        else
          ui_ok "resuming '${S_NAME[$sel]}'"
          sec_log_start "launch"; sec_log "resume '${S_NAME[$sel]}' (${S_ID[$sel]})"
          printf '\n'
          ( cd "${S_PATH[$sel]}" && claude --resume "${S_ID[$sel]}" )
          ui_info "session ended"; ui_pause
        fi
        tui_begin; tui_dims; draw_sessions; continue ;;
      char:i)
        tui_end; ws_adopt_screen; tui_begin; tui_dims; draw_sessions; continue ;;
      char:b)
        tui_end; broker_screen; tui_begin; tui_dims; draw_sessions; continue ;;
      char:t)
        tui_end
        tui_page "TRANSCRIPT · ${S_NAME[$sel]}" "${S_TRANS[$sel]}"
        if [ -f "${S_TRANS[$sel]}" ]; then
          printf '   %s%s lines · %s%s\n\n' "$T_MUTE" \
            "$(wc -l < "${S_TRANS[$sel]}" | tr -d ' ')" \
            "$(du -h "${S_TRANS[$sel]}" 2>/dev/null | awk '{print $1}')" "$T_RS"
          ui_note "open it with: less '${S_TRANS[$sel]}'"
        else
          ui_err "not on disk"
        fi
        ui_pause
        tui_begin; tui_dims; draw_sessions; continue ;;
      quit|esc) break ;;
      *) continue ;;
    esac
    draw_sess "$prev" 0; draw_sess "$sel" 1
  done
  tui_end
  trap 'cleanup' EXIT INT TERM
  return 0
}

# =============================================================================
# HOME — the hub. Every destination is one keypress from here.
# =============================================================================
home_screen() {
  if ! ui_interactive; then sec_help; return 0; fi
  ui_prof home_entry

  local -a H_ID H_MARK H_HUE H_LABEL H_VALUE H_DOT H_DLAB H_DESC H_LINE H_TOP H_BOT
  local n=0

  _row() {  # id mark hue label value dot dlab desc
    H_ID[$n]="$1"; H_MARK[$n]="$2"; H_HUE[$n]="$3"; H_LABEL[$n]="$4"
    H_VALUE[$n]="$5"; H_DOT[$n]="$6"; H_DLAB[$n]="$7"; H_DESC[$n]="$8"
    # Resolve the two-row pictogram ONCE. draw_home_row used to call
    # tui_icon_top and tui_icon_bot inside command substitutions on every row of
    # every repaint — 30 subshells per paint, for glyphs that never change.
    H_TOP[$n]="$(tui_icon_top "$1")"; H_BOT[$n]="$(tui_icon_bot "$1")"
    n=$(( n + 1 ))
  }

  # --- gather, once ---------------------------------------------------------
  local nvault ncred ndoc nproj nunread nsess pkmsys pkmvault claudev pending
  nvault="$(vault_paths | sec_nlines)"
  ui_prof vault_paths
  ncred="$(sec_count 2>/dev/null)"; ncred="${ncred:-0}"
  ui_prof sec_count
  sec_manifest_keys > "$TMPD/hmk" 2>/dev/null; sec_names > "$TMPD/hsk" 2>/dev/null
  ndoc="$(comm -12 "$TMPD/hsk" "$TMPD/hmk" 2>/dev/null | sec_nlines)"
  nproj="$(ws_discover 2>/dev/null | sort -u | sec_nlines)"
  ui_prof ws_discover
  nunread="$(prov_unseen_count)"
  ui_prof prov_unseen_count
  nsess="$(ws_session_ids | sec_nlines)"
  ui_prof ws_session_ids
  ui_prof pre_pkm
  pkmsys="$(pkm_get system)"; [ -n "$pkmsys" ] || pkmsys="not paired"
  pkmvault="$(pkm_get vault)"
  case "$pkmvault" in "$HOME"/*) pkmvault="~${pkmvault#$HOME}" ;; esac
  ui_prof pkm
  if ws_have_claude; then claudev="Claude Code $(ui_tool_version claude claude --version | awk '{print $1}')"
  else claudev="claude CLI not on PATH"; fi
  pending=0
  [ -f "$SEC_ROTATE" ] && pending="$(grep '^- \[ \]' "$SEC_ROTATE" 2>/dev/null | sec_nlines)"

  _row vaults    '⣿⣿⣿' "$N_CYAN"    "VAULTS"    "$nvault database(s)" \
       "$([ "${nvault:-0}" -gt 0 ] && echo ok || echo none)" "$ncred credentials" \
       "encrypted databases, recipients, and backup policy"
  _row workspace '⠽⢂⣒' "$N_GREEN"   "WORKSPACE" "$nproj project(s)" \
       "$(ws_have_claude && echo ok || echo err)" "$claudev" \
       "launch a named Claude Code session — clean, or scoped to one profile"
  _row inbox     '⣠⣿⣄' "$N_MAGENTA" "INBOX"     "$nunread unread" \
       "$([ "${nunread:-0}" -gt 0 ] && echo warn || echo ok)" "agent-authored credentials" \
       "what an agent created for you, for which project, and why"
  _row sessions  '⣠⠞⠳⣄' "$N_BLUE"    "SESSIONS"  "$nsess named" \
       "$([ "${nsess:-0}" -gt 0 ] && echo ok || echo none)" "your names, not log UUIDs" \
       "resume by the name you gave it, never by a UUID"
  _row pkm       '⢴⣿⡦' "$N_VIOLET"  "KNOWLEDGE" "$pkmsys" \
       "$([ "$pkmsys" = "not paired" ] && echo none || echo ok)" "${pkmvault:-no vault detected}" \
       "the note system this credential layer is paired with"
  local nfind ncrit pscan
  ui_prof claude_version
  pscan="$(posture_scan_cached 2>/dev/null)"
  nfind="$(printf '%s\n' "$pscan" | grep -c '|' || true)"
  ncrit="$(printf '%s\n' "$pscan" | grep -c '^crit|' || true)"
  ui_prof posture_cached
  local ykstate ykdesc
  # No ykman call here: `ykman list` costs about a second of Python start-up, and
  # a menu must not pay that on every paint. The module probes when you open it.
  if yk_have; then ykstate=none; ykdesc="ykman $(ui_tool_version ykman ykman --version | awk '{print $NF}')"
  else ykstate=err; ykdesc="ykman not installed"; fi
  _row yubikey   '⣰⣉⣉⣆' "$N_AMBER"   "YUBIKEY"   "$ykdesc" "$ykstate" \
       "$(yk_have && echo 'hardware-backed' || echo 'brew install ykman')" \
       "codes, PIV slots, and moving TOTP seeds off disk onto the key"
  ui_prof yubikey
  local kithave guarded gtotal
  kithave="$(ls "$HOME"/Documents/secretsd-recovery-*.age 2>/dev/null | sec_nlines)"
  gtotal=0; guarded=0
  local -a _repos=()
  while IFS= read -r _p; do
    [ -d "$_p/.git" ] || continue
    gtotal=$(( gtotal + 1 )); _repos+=("$_p")
  done <<HOMEG
$(ws_discover 2>/dev/null | sort -u)
HOMEG
  if [ "${#_repos[@]}" -gt 0 ]; then
    guarded="$(guard_installed_set "${_repos[@]}" | sec_nlines)"
  fi
  _row recovery  '⡏⣩⣍⢹' "$N_RED"      "RECOVERY"  "$([ "${kithave:-0}" -gt 0 ] && echo "$kithave kit(s)" || echo "no kit")" \
       "$([ "${kithave:-0}" -gt 0 ] && echo ok || echo err)" \
       "$([ "${kithave:-0}" -gt 0 ] && echo "verified on build" || echo "one key, one file, no backup")" \
       "lose the age key and every credential is gone — build and prove a kit"
  _row guard     '⡏⠭⠭⢹' "$N_GREEN"    "COMMIT GUARD" "$guarded of $gtotal repos" \
       "$([ "${guarded:-0}" -ge "${gtotal:-1}" ] && echo ok || echo warn)" \
       "$([ "${guarded:-0}" -gt 0 ] && echo "hook installed" || echo "nothing is blocking a leak")" \
       "refuses the commit that contains a credential, instead of cleaning up after"
  ui_prof guard_repos
  local monstate mondesc
  if mon_scheduled 2>/dev/null; then monstate=ok; mondesc="running on a schedule"
  else monstate=warn; mondesc="not scheduled"; fi
  _row monitor   '⣠⠞⠳⣄' "$N_CYAN"     "MONITOR"   "$mondesc" "$monstate" \
       "$([ -f "$MON_LOG" ] && echo "$(grep -c NUDGED "$MON_LOG" 2>/dev/null | head -1) nudges sent" || echo "never run")" \
       "walks sessions and restarts the ones that merely stalled"
  _row posture   '⣿⣿⡀' "$T_ERR"      "POSTURE"   "$nfind finding(s)" \
       "$([ "${ncrit:-0}" -gt 0 ] && echo err || { [ "${nfind:-0}" -gt 0 ] && echo warn || echo ok; })" \
       "$([ "${ncrit:-0}" -gt 0 ] && echo "$ncrit critical" || echo "nothing critical")" \
       "common power-user exposures — reported every launch, fixed only by you"
  # The alert row reads the CACHED state file, never a live scan: opening the
  # dashboard must not pay for reading every certificate on disk.
  local aexp aurg asoon aunk achecked adot aval
  aexp=0; aurg=0; asoon=0; aunk=0; achecked=""
  if [ -f "$ALERT_STATE" ]; then
    local _as; _as="$(cat "$ALERT_STATE" 2>/dev/null)"
    achecked="$(mon_field "$_as" checked)"
    aexp="$(mon_field "$_as" expired)";  aurg="$(mon_field "$_as" urgent)"
    asoon="$(mon_field "$_as" soon)";    aunk="$(mon_field "$_as" unknown)"
  fi
  aexp="${aexp:-0}"; aurg="${aurg:-0}"; asoon="${asoon:-0}"; aunk="${aunk:-0}"
  if   [ "$aexp" -gt 0 ]; then adot=err;  aval="$aexp expired"
  elif [ "$aurg" -gt 0 ]; then adot=warn; aval="$aurg urgent"
  elif [ "$asoon" -gt 0 ]; then adot=warn; aval="$asoon due soon"
  elif [ -n "$achecked" ]; then adot=ok;   aval="nothing due"
  else adot=none; aval="never scanned"; fi
  ui_prof row_alerts_pre
  _row alerts    '⡎⠭⢱⠀' "$N_AMBER"   "EXPIRY"    "$aval" "$adot" \
       "$(alert_scheduled 2>/dev/null && echo "daily at $(alert_schedule_at)" || echo "not scheduled")" \
       "certs and recorded dates, checked on a schedule — $aunk have no date at all"
  ui_prof row_keychain_pre
  _row keychain  '⣰⣉⣉⣆' "$N_BLUE"    "KEYCHAIN"  "$(kc_available 2>/dev/null && echo "macOS login keychain" || echo "not available here")" \
       "$(kc_available 2>/dev/null && echo none || echo err)" "import, never delete" \
       "pull the credentials already sitting in your login keychain into the vault"
  ui_prof row_doctor_pre
  _row doctor    '⠺⣭⠗' "$N_ORANGE"  "DOCTOR"    "$ndoc of $ncred documented" \
       "$([ "${pending:-0}" -gt 0 ] && echo warn || echo ok)" \
       "$([ "${pending:-0}" -gt 0 ] && echo "$pending pending rotation" || echo "nothing pending")" \
       "decryption, recipients, coverage, expiry, plaintext hygiene"
  ui_prof rows_built
  unset -f _row

  # --- CATEGORIES --------------------------------------------------------------
  # Thirteen equal rows is a list, not an interface: everything shouts at the
  # same volume and nothing tells you where to start. The top level is four
  # groups that each answer one question — what do I have, is it safe, what am I
  # working on, where does it get written down — and each opens in place.
  #
  # A category carries the WORST state of its children, so a collapsed group can
  # never hide a problem. That is the whole condition for folding anything away.
  local -a C_ID C_LABEL C_MARK C_HUE C_KIDS C_DESC C_OPEN C_VALUE C_DOT C_DLAB
  local cn=0
  _cat() {
    C_ID[$cn]="$1"; C_MARK[$cn]="$2"; C_HUE[$cn]="$3"; C_LABEL[$cn]="$4"
    C_KIDS[$cn]="$5"; C_DESC[$cn]="$6"; C_OPEN[$cn]=0
    cn=$(( cn + 1 ))
  }
  _cat credentials '⣿⣿⣿' "$N_CYAN"   "CREDENTIALS" "vaults keychain yubikey" \
       "the encrypted stores, and the two places credentials arrive from"
  _cat security    '⣿⣿⡀' "$T_ERR"    "SECURITY"    "posture alerts recovery guard doctor" \
       "what is exposed, what is expiring, and what happens if you lose the key"
  _cat work        '⠙⣦⣴⠋' "$N_GREEN"  "WORK"        "workspace sessions inbox monitor" \
       "projects, the Claude sessions on them, and what agents created for you"
  _cat knowledge   '⣴⣹⣏⣦' "$N_VIOLET" "KNOWLEDGE"   "pkm" \
       "the note system this credential layer is paired with"
  unset -f _cat

  # module index by id
  _mod_idx() {
    local want="$1" i=0
    while [ "$i" -lt "$n" ]; do
      [ "${H_ID[$i]}" = "$want" ] && { printf '%s' "$i"; return 0; }
      i=$(( i + 1 ))
    done
    return 1
  }

  # roll each category up from its children, worst state wins
  local _c=0 _k _ki _worst _bad _warnn _kids
  while [ "$_c" -lt "$cn" ]; do
    _worst=none; _bad=0; _warnn=0; _kids=0
    for _k in ${C_KIDS[$_c]}; do
      _ki="$(_mod_idx "$_k")" || continue
      _kids=$(( _kids + 1 ))
      case "${H_DOT[$_ki]}" in
        err)  _bad=$(( _bad + 1 ));   _worst=err ;;
        warn) _warnn=$(( _warnn + 1 )); [ "$_worst" = err ] || _worst=warn ;;
        ok)   [ "$_worst" = none ] && _worst=ok ;;
      esac
    done
    C_DOT[$_c]="$_worst"
    if   [ "$_bad" -gt 0 ];   then C_DLAB[$_c]="$_bad need attention"
    elif [ "$_warnn" -gt 0 ]; then C_DLAB[$_c]="$_warnn worth a look"
    else                           C_DLAB[$_c]="nothing outstanding"; fi
    C_VALUE[$_c]="$_kids section(s)"
    _c=$(( _c + 1 ))
  done

  # headline numbers, so a folded group still says something concrete
  C_VALUE[0]="$ncred credentials · $nvault store(s)"
  C_VALUE[1]="$nfind finding(s) · $aexp expired"
  C_VALUE[2]="$nproj project(s) · $nsess session(s)"
  C_VALUE[3]="$pkmsys"

  # --- ALWAYS OPEN COLLAPSED ---------------------------------------------------
  # No remembered state, deliberately. An interface that opens in whatever shape
  # you happened to leave it is a different interface every time: you cannot
  # learn where things are, and a screen you left three groups deep greets you
  # with a wall. Every launch starts from the same four rows.
  #
  # The state file this used to write is removed on sight, so an upgrade does
  # not leave a stale one behind that nothing reads.
  rm -f "$SEC_ROOT/state/menu-open" 2>/dev/null

  # --- the visible list: categories, plus the children of the open ones --------
  local -a V_KIND V_REF
  local vn=0
  build_visible() {
    vn=0
    local c=0 k ki
    while [ "$c" -lt "$cn" ]; do
      V_KIND[$vn]=cat; V_REF[$vn]="$c"; vn=$(( vn + 1 ))
      if [ "${C_OPEN[$c]}" = "1" ]; then
        for k in ${C_KIDS[$c]}; do
          ki="$(_mod_idx "$k")" || continue
          V_KIND[$vn]=mod; V_REF[$vn]="$ki"; vn=$(( vn + 1 ))
        done
      fi
      c=$(( c + 1 ))
    done
  }
  build_visible

  local sel=0 key prev i curline host gapn padrows extra block avail mode g _p _r
  local lastcols=0 lastrows=0
  host="$(hostname -s 2>/dev/null || echo host)"

  draw_home_row() {
    # SEPARATE statements on purpose. Every assignment in a single `local` is
    # expanded before ANY of them takes effect, so `local k="$1" kind="${V[$k]}"`
    # reads an unbound k. Already documented, already tested for, and still
    # walked into — because the guard pattern only matched `b="$a"`, not
    # `b="${arr[$a]}"`.
    local k="$1" on="$2" disc lbl kind r
    kind="${V_KIND[$k]}"; r="${V_REF[$k]}"
    printf '\033[%d;1H' "${H_LINE[$k]}"
    if [ "$kind" = cat ]; then
      # ▾ open, ▸ closed — the disclosure state has to be visible without
      # moving the selection onto it
      if [ "${C_OPEN[$r]}" = "1" ]; then disc='▾'; else disc='▸'; fi
      lbl="$disc ${C_LABEL[$r]}"
      tui_modrow "$on" "${C_MARK[$r]}" "${C_HUE[$r]}" "$lbl" \
                 "${C_VALUE[$r]}" "${C_DOT[$r]}" "${C_DLAB[$r]}"
      [ "$mode" != compact ] && tui_moddesc "$on" "$(tui_fit "${C_DESC[$r]}" $(( TUI_COLS - 14 )))" \
                 "" "${C_HUE[$r]}"
    else
      tui_modrow "$on" "${H_TOP[$r]}" "${H_HUE[$r]}" "${H_LABEL[$r]}" \
                 "${H_VALUE[$r]}" "${H_DOT[$r]}" "${H_DLAB[$r]}" 4
      [ "$mode" != compact ] && tui_moddesc "$on" "$(tui_fit "${H_DESC[$r]}" $(( TUI_COLS - 18 )))" \
                 "${H_BOT[$r]}" "${H_HUE[$r]}" 4
    fi
  }

  hlayout() {
    avail=$(( TUI_ROWS - 6 ))
    if [ $(( vn * 2 )) -le "$avail" ]; then mode=normal; block=$(( vn * 2 ))
    else mode=compact; block=$vn; fi
    gapn=0
    if [ "$vn" -gt 1 ]; then
      gapn=$(( (avail - block) / (vn - 1) ))
      [ "$gapn" -lt 0 ] && gapn=0
      [ "$gapn" -gt 3 ] && gapn=3
    fi
    padrows=$(( avail - block - gapn * (vn - 1) )); [ "$padrows" -lt 0 ] && padrows=0
    extra=0
    if [ "$vn" -gt 1 ] && [ "$padrows" -gt 0 ] && [ "$padrows" -lt "$vn" ]; then extra="$padrows"; padrows=0; fi
  }

  draw_home() {
    tui_home
    tui_header "$host" "bridging the secure informational gap between man and machine"
    curline=4
    i=0
    while [ "$i" -lt "$vn" ]; do
      H_LINE[$i]="$(( curline + 1 ))"
      draw_home_row "$i" "$([ "$i" = "$sel" ] && echo 1 || echo 0)"
      curline=$(( curline + 1 ))
      [ "$mode" != compact ] && curline=$(( curline + 1 ))
      if [ "$i" -lt $(( vn - 1 )) ]; then
        g=0; while [ "$g" -lt "$gapn" ]; do tui_blank; curline=$(( curline + 1 )); g=$(( g + 1 )); done
        [ "$i" -lt "$extra" ] && { tui_blank; curline=$(( curline + 1 )); }
      fi
      i=$(( i + 1 ))
    done
    g=0; while [ "$g" -lt "$padrows" ]; do tui_blank; g=$(( g + 1 )); done
    tui_footer "↑↓ move" "↵ open/expand" "← collapse" "E all" "C none" "/ find" "q quit"
    tui_clear_below
  }

  tui_begin
  trap 'tui_end; cleanup' EXIT INT TERM
  ui_prof tui_begin
  tui_dims; hlayout; draw_home
  ui_prof first_draw
  lastcols="$TUI_COLS"; lastrows="$TUI_ROWS"

  while :; do
    key="$(tui_readkey)" || break
    prev="$sel"
    case "$key" in
      up)   sel=$(( sel - 1 )); [ "$sel" -lt 0 ] && sel=$(( vn - 1 )) ;;
      down) sel=$(( sel + 1 )); [ "$sel" -ge "$vn" ] && sel=0 ;;

      left)
        # collapse the group you are in; from a child, go to its category first
        if [ "${V_KIND[$sel]}" = mod ]; then
          _p="$sel"
          while [ "$_p" -gt 0 ] && [ "${V_KIND[$_p]}" != cat ]; do _p=$(( _p - 1 )); done
          sel="$_p"
        fi
        if [ "${V_KIND[$sel]}" = cat ]; then
          C_OPEN[${V_REF[$sel]}]=0;
          build_visible; hlayout; draw_home
          lastcols="$TUI_COLS"; lastrows="$TUI_ROWS"
        fi
        continue ;;

      enter|right)
        if [ "${V_KIND[$sel]}" = cat ]; then
          # a category toggles in place — the whole point of the accordion
          _r="${V_REF[$sel]}"
          if [ "${C_OPEN[$_r]}" = "1" ]; then C_OPEN[$_r]=0; else C_OPEN[$_r]=1; fi
          build_visible; hlayout; draw_home
          lastcols="$TUI_COLS"; lastrows="$TUI_ROWS"
          continue
        fi
        tui_end
        case "${H_ID[${V_REF[$sel]}]}" in
          vaults)    vault_screen ;;
          workspace) ws_screen ;;
          inbox)     inbox_screen ;;
          sessions)  ws_sessions_screen ;;
          pkm)       pkm_screen ;;
          yubikey)   yubikey_screen ;;
          recovery)  recovery_screen ;;
          guard)     guard_screen ;;
          monitor)   monitor_screen ;;
          posture)   posture_screen ;;
          alerts)    alerts_screen ;;
          keychain)  keychain_screen ;;
          doctor)    do_doctor; ui_pause ;;
        esac
        tui_begin; tui_dims; hlayout; draw_home
        lastcols="$TUI_COLS"; lastrows="$TUI_ROWS"; continue ;;

      char:E)
        # expand everything — the old flat list, for when you know what you want
        _c=0; while [ "$_c" -lt "$cn" ]; do C_OPEN[$_c]=1; _c=$(( _c + 1 )); done
         build_visible; hlayout; draw_home
        lastcols="$TUI_COLS"; lastrows="$TUI_ROWS"; continue ;;
      char:C)
        _c=0; while [ "$_c" -lt "$cn" ]; do C_OPEN[$_c]=0; _c=$(( _c + 1 )); done
         build_visible; sel=0; hlayout; draw_home
        lastcols="$TUI_COLS"; lastrows="$TUI_ROWS"; continue ;;
      search) tui_end; palette_screen; tui_begin; tui_dims; hlayout; draw_home
              lastcols="$TUI_COLS"; lastrows="$TUI_ROWS"; continue ;;
      char:g) tui_end; gen_screen; tui_begin; tui_dims; hlayout; draw_home
              lastcols="$TUI_COLS"; lastrows="$TUI_ROWS"; continue ;;
      char:a) tui_end; audit_screen; tui_begin; tui_dims; hlayout; draw_home
              lastcols="$TUI_COLS"; lastrows="$TUI_ROWS"; continue ;;
      char:?) tui_end; help_screen; tui_begin; tui_dims; hlayout; draw_home
              lastcols="$TUI_COLS"; lastrows="$TUI_ROWS"; continue ;;
      quit|esc) break ;;
      *) continue ;;
    esac
    tui_dims
    if [ "$TUI_COLS" != "$lastcols" ] || [ "$TUI_ROWS" != "$lastrows" ]; then
      hlayout; draw_home; lastcols="$TUI_COLS"; lastrows="$TUI_ROWS"
    else
      draw_home_row "$prev" 0; draw_home_row "$sel" 1
    fi
  done
  tui_end
  trap 'cleanup' EXIT INT TERM
  return 0
}

# --- adopting sessions that already exist -------------------------------------
# Claude Code has been writing transcripts long before this program existed, and
# every one of them is filed under a UUID. This finds them and lets you attach a
# human name — the same mapping a launched session gets, applied retroactively.
#
# Claude already writes an `ai-title` record into most transcripts. That becomes
# the suggested name, so adopting is usually "press enter", not "invent a label
# for a session you had three weeks ago".
#
# Only TOP-LEVEL transcripts are offered. The deeper files under subagents/ and
# workflows/ are sidechains of a parent session, not sessions you ever started.

WS_ADOPT_CACHE="$SEC_SECRETS/.sessions-scan"
WS_ADOPT_TTL="${WS_ADOPT_TTL:-900}"

# ws_scan_sessions -> "uuid|cwd|title|when|msgs|subagents"
ws_scan_sessions() {
  local age now mtime
  if [ -f "$WS_ADOPT_CACHE" ]; then
    mtime="$(sec_stat mtime "$WS_ADOPT_CACHE")"
    now="$(date +%s)"; age=$(( now - ${mtime:-0} ))
    [ "$age" -lt "$WS_ADOPT_TTL" ] && { cat "$WS_ADOPT_CACHE"; return 0; }
  fi
  ws_scan_sessions_live > "$WS_ADOPT_CACHE" 2>/dev/null
  chmod 600 "$WS_ADOPT_CACHE" 2>/dev/null
  cat "$WS_ADOPT_CACHE"
}

# One python process for the whole scan. Eighty-three files through a shell loop
# would be eighty-three forks per field; this reads each transcript's head once.
ws_scan_sessions_live() {
  python3 - "$HOME/.claude/projects" <<'SCAN'
import os, sys, json, glob

root = sys.argv[1]
rows = []
for d in sorted(glob.glob(os.path.join(root, "*"))):
    if not os.path.isdir(d):
        continue
    for p in glob.glob(os.path.join(d, "*.jsonl")):
        uuid = os.path.basename(p)[:-6]
        title = cwd = first = ""
        msgs = 0
        try:
            with open(p, "rb") as fh:
                for i, raw in enumerate(fh):
                    if i > 120 and title and cwd:
                        break
                    if b'"type"' not in raw:
                        continue
                    try:
                        r = json.loads(raw)
                    except Exception:
                        continue
                    t = r.get("type")
                    if t == "ai-title" and not title:
                        title = (r.get("aiTitle") or "").strip()
                    elif t == "user":
                        msgs += 1
                        if not cwd:
                            cwd = r.get("cwd") or ""
                        if not first:
                            m = r.get("message") or {}
                            c = m.get("content")
                            if isinstance(c, str):
                                first = c
                            elif isinstance(c, list):
                                first = " ".join(
                                    x.get("text", "") for x in c if isinstance(x, dict)
                                )
                            first = " ".join(first.split())[:90]
        except OSError:
            continue
        if not cwd and not first and not title:
            continue
        sub = 0
        subdir = os.path.join(d, uuid, "subagents")
        if os.path.isdir(subdir):
            sub = sum(1 for _, _, fs in os.walk(subdir) for f in fs if f.endswith(".jsonl"))
        try:
            when = int(os.path.getmtime(p))
        except OSError:
            when = 0
        label = title or first or "(no title)"
        label = label.replace("|", "/")
        rows.append((when, uuid, cwd.replace("|", "/"), label, msgs, sub))

rows.sort(reverse=True)
for when, uuid, cwd, label, msgs, sub in rows:
    print("%s|%s|%s|%s|%s|%s" % (uuid, cwd, label, when, msgs, sub))
SCAN
}

ws_adopt_invalidate() { rm -f "$WS_ADOPT_CACHE" 2>/dev/null; }

ws_when_ago() {   # $1 epoch
  local now d; now="$(date +%s)"; d=$(( now - ${1:-0} ))
  [ "${1:-0}" -eq 0 ] && { printf 'unknown'; return; }
  if   [ "$d" -lt 3600 ];  then printf '%dm ago' $(( d / 60 ))
  elif [ "$d" -lt 86400 ]; then printf '%dh ago' $(( d / 3600 ))
  else printf '%dd ago' $(( d / 86400 )); fi
}

ws_is_adopted() { ws_session_ids | ui_match_line "$1"; }

# --- the screen ---------------------------------------------------------------
ws_adopt_screen() {
  ui_interactive || { ui_needs_tty adopt; return 1; }
  local -a A_ID A_CWD A_TITLE A_WHEN A_MSGS A_SUB A_DONE A_LINE
  local n=0 uuid cwd title when msgs sub

  ui_clear; printf '\n  '; tui_grad_violet 'reading existing Claude sessions…'; printf '\n'

  while IFS='|' read -r uuid cwd title when msgs sub; do
    [ -n "$uuid" ] || continue
    A_ID[$n]="$uuid"; A_CWD[$n]="$cwd"; A_TITLE[$n]="$title"
    A_WHEN[$n]="$when"; A_MSGS[$n]="$msgs"; A_SUB[$n]="$sub"
    if ws_is_adopted "$uuid"; then A_DONE[$n]=1; else A_DONE[$n]=0; fi
    n=$(( n + 1 ))
  done <<ADOPT
$(ws_scan_sessions)
ADOPT

  if [ "$n" -eq 0 ]; then
    tui_page "ADOPT SESSIONS" "no existing Claude transcripts found"
    ui_note "looked under ~/.claude/projects"
    ui_pause; return 0
  fi

  local sel=0 key prev curline host i nnew=0
  host="$(hostname -s 2>/dev/null || echo host)"
  i=0; while [ "$i" -lt "$n" ]; do [ "${A_DONE[$i]}" = "0" ] && nnew=$(( nnew + 1 )); i=$(( i + 1 )); done

  draw_adopt() {
    local k="$1" on="$2" dot dlab hue proj
    if [ "${A_DONE[$k]}" = "1" ]; then dot=ok; dlab="named"; hue="$N_GREEN"
    else dot=none; dlab="unnamed"; hue="$T_DIM"; fi
    proj="$(basename "${A_CWD[$k]:-unknown}")"
    printf '\033[%d;1H' "${A_LINE[$k]}"
    tui_modrow "$on" "$(tui_icon_top sessions)" "$hue" \
      "$(tui_fit "${A_TITLE[$k]}" 44)" "$proj" "$dot" "$dlab"
    tui_moddesc "$on" \
      "$(tui_fit "${A_ID[$k]:0:8}… · $(ws_when_ago "${A_WHEN[$k]}") · ${A_MSGS[$k]} prompts$([ "${A_SUB[$k]}" -gt 0 ] && echo " · ${A_SUB[$k]} subagents")" $(( TUI_COLS - 14 )))" \
      "$(tui_icon_bot sessions)" "$hue"
  }

  draw_adopts() {
    tui_home
    tui_header "$host" "$n existing session(s) · $nnew still unnamed · Claude's own title is the suggestion"
    curline=4
    local shown=0 maxrows
    maxrows=$(( (TUI_ROWS - 6) / 3 ))
    [ "$maxrows" -lt 1 ] && maxrows=1
    local start=0
    [ "$sel" -ge "$maxrows" ] && start=$(( sel - maxrows + 1 ))
    i="$start"
    while [ "$i" -lt "$n" ] && [ "$shown" -lt "$maxrows" ]; do
      A_LINE[$i]="$(( curline + 1 ))"
      draw_adopt "$i" "$([ "$i" = "$sel" ] && echo 1 || echo 0)"
      curline=$(( curline + 2 ))
      [ "$shown" -lt $(( maxrows - 1 )) ] && { tui_blank; curline=$(( curline + 1 )); }
      i=$(( i + 1 )); shown=$(( shown + 1 ))
    done
    local pad=$(( TUI_ROWS - curline - 2 )); [ "$pad" -lt 0 ] && pad=0
    i=0; while [ "$i" -lt "$pad" ]; do tui_blank; i=$(( i + 1 )); done
    tui_footer "↑↓ move" "↵ name it" "A adopt all titled" "r rescan" "esc back"
    tui_clear_below
  }

  tui_begin
  trap 'tui_end; cleanup' EXIT INT TERM
  tui_dims; draw_adopts

  while :; do
    key="$(tui_readkey)" || break
    prev="$sel"
    case "$key" in
      up)   sel=$(( sel - 1 )); [ "$sel" -lt 0 ] && sel=$(( n - 1 )) ;;
      down) sel=$(( sel + 1 )); [ "$sel" -ge "$n" ] && sel=0 ;;

      enter|right)
        tui_end
        tui_page "NAME THIS SESSION" "$(basename "${A_CWD[$sel]:-unknown}")"
        tui_kv "Claude's title" "$(tui_fit "${A_TITLE[$sel]}" $(( TUI_COLS - 24 )))"
        tui_kv "project"        "${A_CWD[$sel]:-unknown}"
        tui_kv "last activity"  "$(ws_when_ago "${A_WHEN[$sel]}")"
        tui_kv "prompts"        "${A_MSGS[$sel]}"
        [ "${A_SUB[$sel]}" -gt 0 ] && tui_kv "subagent transcripts" "${A_SUB[$sel]}"
        tui_kv "session id"     "${A_ID[$sel]}"
        tui_kv "already named"  "$([ "${A_DONE[$sel]}" = "1" ] && echo yes || echo no)"
        printf '\n'
        local nm
        nm="$(ui_ask 'Name (enter accepts the suggestion)' "${A_TITLE[$sel]}")" || { tui_begin; tui_dims; draw_adopts; continue; }
        [ -n "$nm" ] || nm="${A_TITLE[$sel]}"
        nm="$(printf '%s' "$nm" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/"/'"'"'/g')"
        if [ -z "$nm" ] || [ "$nm" = "(no title)" ]; then
          ui_warn "a name is required — nothing recorded"
        else
          if ws_is_adopted "${A_ID[$sel]}"; then
            ui_warn "this session already has a name in SESSIONS.yaml"
            ui_note "edit $(basename "$SEC_SESSIONS") by hand to change it"
          else
            ws_record_session "$nm" "${A_ID[$sel]}" \
              "$(basename "${A_CWD[$sel]:-unknown}")" "${A_CWD[$sel]}" adopted
            if ws_is_adopted "${A_ID[$sel]}"; then
              A_DONE[$sel]=1; nnew=$(( nnew - 1 ))
              ui_ok "re-read: '$nm' is now mapped to ${A_ID[$sel]:0:8}…"
              sec_log_start sessions; sec_log "adopted ${A_ID[$sel]} as '$nm'"
            else
              ui_err "could not write the mapping"
            fi
          fi
        fi
        ui_pause
        tui_begin; tui_dims; draw_adopts; continue ;;

      char:A)
        tui_end
        tui_page "ADOPT ALL TITLED" "every unnamed session that Claude already titled"
        local cand=0 j=0
        while [ "$j" -lt "$n" ]; do
          if [ "${A_DONE[$j]}" = "0" ] && [ -n "${A_TITLE[$j]}" ] && [ "${A_TITLE[$j]}" != "(no title)" ]; then
            cand=$(( cand + 1 ))
          fi
          j=$(( j + 1 ))
        done
        if [ "$cand" -eq 0 ]; then
          ui_info "nothing to adopt — every titled session already has a name"
        else
          ui_note "$cand session(s) will take Claude's own title as their name."
          ui_note "Anything untitled is skipped; those need a name from you."
          printf '\n'
          if ui_confirm "Adopt all $cand?"; then
            local done_n=0
            j=0
            while [ "$j" -lt "$n" ]; do
              if [ "${A_DONE[$j]}" = "0" ] && [ -n "${A_TITLE[$j]}" ] && [ "${A_TITLE[$j]}" != "(no title)" ]; then
                ws_record_session "${A_TITLE[$j]}" "${A_ID[$j]}" \
                  "$(basename "${A_CWD[$j]:-unknown}")" "${A_CWD[$j]}" adopted
                if ws_is_adopted "${A_ID[$j]}"; then
                  A_DONE[$j]=1; done_n=$(( done_n + 1 )); nnew=$(( nnew - 1 ))
                fi
              fi
              j=$(( j + 1 ))
            done
            ui_ok "re-read SESSIONS.yaml: $done_n of $cand adopted"
            sec_log_start sessions; sec_log "bulk adopted $done_n sessions"
          else ui_info "nothing adopted"; fi
        fi
        ui_pause
        tui_begin; tui_dims; draw_adopts; continue ;;

      char:r)
        tui_end
        tui_page "RESCAN" "re-reading every transcript head"
        ws_adopt_invalidate
        ui_ok "cache cleared — reopen Adopt to rescan"
        ui_pause
        tui_begin; tui_dims; draw_adopts; continue ;;

      quit|esc) break ;;
      *) continue ;;
    esac
    tui_dims; draw_adopts
  done
  tui_end
  trap 'cleanup' EXIT INT TERM
  return 0
}
