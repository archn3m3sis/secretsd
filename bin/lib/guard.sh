#!/usr/bin/env bash
# lib/guard.sh — stop the commit before it happens.
#
# The most common credential leak is not sophisticated. It is a `.env` that gets
# committed, noticed an hour later, and "fixed" by deleting the file in the next
# commit — while the value sits in the history, in every clone, and in every
# fork, forever. The rotation that should follow almost never happens, because
# the file being gone *feels* like the problem being gone.
#
# This installs a pre-commit hook that refuses the commit in the first place.
#
# WHAT IT CHECKS, ON STAGED CONTENT ONLY
#   · files that should never be committed at all (.env, *.pem, id_rsa, keys.txt)
#   · high-entropy strings shaped like real credentials (provider prefixes first,
#     then generic long random values assigned to secret-looking names)
#   · private key headers in any file
#
# WHAT IT DELIBERATELY DOES NOT DO
#   It does not scan history, and it does not phone anywhere. It is a local hook
#   that runs in milliseconds, because a slow hook gets disabled and a hook that
#   is disabled protects nothing.
#
# Sourced, never executed.

guard_hook_body() {
  cat <<'HOOK'
#!/usr/bin/env bash
# Installed by secretsd. Blocks commits containing credential material.
# Bypass for one commit with:  git commit --no-verify
# If you find yourself bypassing it often, the check is wrong — fix the check.
set -uo pipefail

RED=$'\033[31m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RS=$'\033[0m'; B=$'\033[1m'
fail=0

staged() { git diff --cached --name-only --diff-filter=ACM; }

# --- allowing what is legitimately credential-shaped --------------------------
# Test fixtures, documentation and this hook itself must be able to contain a
# fake AWS key. Without a way to say so, the honest response to a false positive
# is --no-verify, and a hook that trains you to bypass it is worse than none.
#
#   .secretsd-guard-ignore   one path glob per line, # for comments
#   secretsd:allow           an inline marker on the offending line
IGNORE_FILE=".secretsd-guard-ignore"
path_allowed() {
  [ -f "$IGNORE_FILE" ] || return 1
  local pat
  while IFS= read -r pat; do
    case "$pat" in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2254
    case "$1" in $pat) return 0 ;; esac
  done < "$IGNORE_FILE"
  return 1
}

# --- 1. files that are never safe to commit -----------------------------------
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$(basename "$f")" in
    .env|.env.*|*.env)          why="an environment file" ;;
    id_rsa|id_dsa|id_ecdsa|id_ed25519) why="an SSH private key" ;;
    keys.txt)                   why="an age identity" ;;
    *.pem|*.p12|*.pfx|*.jks)    why="key or certificate material" ;;
    *.kdbx|*.opvault)           why="a password database" ;;
    credentials|.netrc|.pgpass) why="a credentials file" ;;
    *) continue ;;
  esac
  if path_allowed "$f"; then
    printf '%s·%s %s %s(allowed by %s)%s\n' "$DIM" "$RS" "$f" "$DIM" "$IGNORE_FILE" "$RS"
    continue
  fi
  printf '%s✗%s %s%s%s is %s\n' "$RED" "$RS" "$B" "$f" "$RS" "$why"
  fail=1
done <<< "$(staged)"

# --- 2. credential-shaped strings in the staged diff --------------------------
# Provider-prefixed tokens first: these are unambiguous and worth naming exactly.
# Build the diff from only the files that are not allowlisted, and drop any
# line that carries the inline marker.
diff_content=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  path_allowed "$f" && continue
  diff_content="$diff_content
$(git diff --cached -U0 -- "$f" 2>/dev/null | grep -v 'secretsd:allow')"
done <<< "$(staged)"

check() {   # pattern  description
  local hits
  hits="$(printf '%s' "$diff_content" | grep -nE "^\+.*$1" | head -3)"
  if [ -n "$hits" ]; then
    printf '%s✗%s %s\n' "$RED" "$RS" "$2"
    printf '%s' "$hits" | sed -E 's/^/    /; s/(.{100}).*/\1…/'
    fail=1
  fi
}

check '(sk-[A-Za-z0-9_-]{20,})'                'an OpenAI-style secret key'
check '(xoxb-|xoxp-|xapp-)[A-Za-z0-9-]{10,}'   'a Slack token'
check '(ghp_|gho_|ghu_|ghs_|ghr_)[A-Za-z0-9]{20,}' 'a GitHub token'
check 'glpat-[A-Za-z0-9_-]{16,}'               'a GitLab token'
check 'AKIA[0-9A-Z]{16}'                       'an AWS access key id'
check 'AIza[0-9A-Za-z_-]{30,}'                 'a Google API key'
check '(xai-|sk-ant-)[A-Za-z0-9_-]{20,}'       'an xAI or Anthropic key'
check '-----BEGIN [A-Z ]*PRIVATE KEY-----'     'a private key block'
check 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.' 'a JWT'

# Generic: a secret-looking NAME assigned a long random-looking VALUE.
# Deliberately narrow — a broad entropy check fires on hashes, minified JS and
# base64 test fixtures, and a hook that cries wolf gets removed.
check '(SECRET|PASSWORD|PASSWD|TOKEN|API_?KEY|PRIVATE_?KEY|CREDENTIAL)[A-Z_]*[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9+/_-]{24,}' \
      'a secret-looking name assigned a long value'

if [ "$fail" -eq 1 ]; then
  printf '\n%s%sCommit refused.%s\n' "$B" "$RED" "$RS"
  printf '%sPut the value in your vault and reference it by name instead:%s\n' "$DIM" "$RS"
  printf '    secretsd add MY_TOKEN\n'
  printf '    secretsd run --only MY_TOKEN -- your-command\n\n'
  printf '%sIf this is a false positive, commit with --no-verify and tell secretsd:%s\n' "$DIM" "$RS"
  printf '    git commit --no-verify\n\n'
  exit 1
fi
exit 0
HOOK
}

guard_installed() { [ -f "$1/.git/hooks/pre-commit" ] && grep -q 'Installed by secretsd' "$1/.git/hooks/pre-commit" 2>/dev/null; }

guard_install() {   # $1 repo path
  local repo="$1" hook="$1/.git/hooks/pre-commit"
  [ -d "$repo/.git" ] || { ui_err "not a git repository: $repo"; return 1; }
  if [ -f "$hook" ] && ! guard_installed "$repo"; then
    ui_warn "a pre-commit hook already exists and was not written by secretsd"
    ui_note "keeping a copy at pre-commit.before-secretsd"
    cp -p "$hook" "$repo/.git/hooks/pre-commit.before-secretsd"
  fi
  guard_hook_body > "$hook" && chmod +x "$hook" || { ui_err "could not write the hook"; return 1; }
  guard_installed "$repo" || { ui_err "the hook did not install"; return 1; }
  return 0
}

guard_remove() {
  local repo="$1" hook="$1/.git/hooks/pre-commit"
  guard_installed "$repo" || { ui_warn "no secretsd hook here"; return 1; }
  rm -f "$hook"
  if [ -f "$repo/.git/hooks/pre-commit.before-secretsd" ]; then
    mv "$repo/.git/hooks/pre-commit.before-secretsd" "$hook"
    ui_ok "removed, and restored the hook that was there before"
  else
    ui_ok "removed"
  fi
  return 0
}

# guard_selftest REPO — prove the hook blocks a real secret before trusting it
guard_selftest() {
  # NOT `local repo="$1" tmp="$repo/..."` — local is a command, and all of its
  # arguments are expanded before any of the assignments take effect, so $repo
  # is still empty when $tmp is built. Split the declaration.
  local repo="$1"
  local tmp="$repo/.secretsd-guard-selftest"
  ui_info "planting a fake credential and attempting a commit…"
  printf 'AWS_SECRET_ACCESS_KEY = "AKIAIOSFODNN7EXAMPLE"\nAPI_KEY="sk-abcdefghijklmnopqrstuvwxyz0123456789"\n' > "$tmp"
  ( cd "$repo" && git add "$(basename "$tmp")" 2>/dev/null )
  local out rc
  out="$( cd "$repo" && git commit -m "secretsd guard selftest — should be refused" 2>&1 )"; rc=$?
  ( cd "$repo" && git reset -q HEAD "$(basename "$tmp")" 2>/dev/null )
  rm -f "$tmp"
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'Commit refused'; then
    ui_ok "PROVEN: the hook refused a commit containing a fake AWS key"
    return 0
  fi
  ui_err "the hook did NOT block a planted credential — do not rely on it"
  printf '%s\n' "$out" | head -5 | sed 's/^/    /'
  return 1
}

guard_screen() {
  ui_interactive || { ui_needs_tty guard "secretsd guard install <repo>" "secretsd guard selftest"; return 1; }
  local -a G_PATH G_NAME G_ON G_LINE
  local n=0 p

  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -d "$p/.git" ] || continue
    G_PATH[$n]="$p"; G_NAME[$n]="$(basename "$p")"
    if guard_installed "$p"; then G_ON[$n]=1; else G_ON[$n]=0; fi
    n=$(( n + 1 ))
  done <<GR
$(ws_discover 2>/dev/null | sort -u)
GR

  if [ "$n" -eq 0 ]; then
    tui_page "COMMIT GUARD" "no git repositories found under your project roots"
    ui_note "add roots to PROJECTS.yaml, or run: secretsd guard /path/to/repo"
    ui_pause; return 0
  fi

  local sel=0 key prev curline host i on=0
  host="$(hostname -s 2>/dev/null || echo host)"
  i=0; while [ "$i" -lt "$n" ]; do [ "${G_ON[$i]}" = "1" ] && on=$(( on + 1 )); i=$(( i + 1 )); done

  draw_g() {
    local k="$1" s="$2" dot dlab hue
    if [ "${G_ON[$k]}" = "1" ]; then dot=ok; dlab="guarded"; hue="$N_GREEN"
    else dot=warn; dlab="unguarded"; hue="$T_DIM"; fi
    printf '\033[%d;1H' "${G_LINE[$k]}"
    tui_modrow "$s" "$(tui_icon_top posture)" "$hue" "$(tui_fit "${G_NAME[$k]}" 40)" "" "$dot" "$dlab"
    tui_moddesc "$s" "$(tui_fit "${G_PATH[$k]/#$HOME/~}" $(( TUI_COLS - 14 )))" "$(tui_icon_bot posture)" "$hue"
  }
  draw_gs() {
    tui_home
    tui_header "$host" "$on of $n repository(ies) guarded · blocks the commit, not the cleanup"
    curline=4
    i=0
    while [ "$i" -lt "$n" ]; do
      G_LINE[$i]="$(( curline + 1 ))"
      draw_g "$i" "$([ "$i" = "$sel" ] && echo 1 || echo 0)"
      curline=$(( curline + 2 ))
      [ "$i" -lt $(( n - 1 )) ] && { tui_blank; curline=$(( curline + 1 )); }
      i=$(( i + 1 ))
    done
    local pad=$(( TUI_ROWS - curline - 2 )); [ "$pad" -lt 0 ] && pad=0
    i=0; while [ "$i" -lt "$pad" ]; do tui_blank; i=$(( i + 1 )); done
    tui_footer "↑↓ move" "↵ install+prove" "r remove" "A guard all" "esc back"
    tui_clear_below
  }

  tui_begin
  trap 'tui_end; cleanup' EXIT INT TERM
  tui_dims; draw_gs

  while :; do
    key="$(tui_readkey)" || break
    prev="$sel"
    case "$key" in
      up)   sel=$(( sel - 1 )); [ "$sel" -lt 0 ] && sel=$(( n - 1 )) ;;
      down) sel=$(( sel + 1 )); [ "$sel" -ge "$n" ] && sel=0 ;;
      enter|right)
        tui_end
        tui_page "GUARD · ${G_NAME[$sel]}" "${G_PATH[$sel]}"
        if guard_install "${G_PATH[$sel]}"; then
          ui_ok "pre-commit hook installed"
          printf '\n'
          tui_section "PROVING IT"
          if guard_selftest "${G_PATH[$sel]}"; then
            G_ON[$sel]=1; on=$(( on + 1 ))
            sec_log_start guard; sec_log "guard installed + verified in ${G_PATH[$sel]}"
          fi
        fi
        ui_pause; tui_begin; tui_dims; draw_gs; continue ;;
      char:r)
        tui_end
        tui_page "REMOVE GUARD · ${G_NAME[$sel]}" "${G_PATH[$sel]}"
        ui_confirm "Remove the commit guard from this repository?" \
          && { guard_remove "${G_PATH[$sel]}" && { G_ON[$sel]=0; on=$(( on - 1 )); }; } || ui_info "kept"
        ui_pause; tui_begin; tui_dims; draw_gs; continue ;;
      char:A)
        tui_end
        tui_page "GUARD EVERY REPOSITORY" "$n repositories under your project roots"
        ui_confirm "Install the hook in all $n?" || { ui_info "nothing changed"; ui_pause; tui_begin; tui_dims; draw_gs; continue; }
        printf '\n'
        i=0; local done_n=0
        while [ "$i" -lt "$n" ]; do
          printf '   %-34s ' "$(tui_fit "${G_NAME[$i]}" 34)"
          if guard_install "${G_PATH[$i]}"; then
            G_ON[$i]=1; done_n=$(( done_n + 1 )); printf '%sinstalled%s\n' "$T_OK" "$T_RS"
          else printf '%sfailed%s\n' "$T_ERR" "$T_RS"; fi
          i=$(( i + 1 ))
        done
        on="$done_n"
        printf '\n'; ui_ok "$done_n of $n guarded"
        ui_note "verify any one of them with enter — installation is not proof"
        ui_pause; tui_begin; tui_dims; draw_gs; continue ;;
      quit|esc) break ;;
      *) continue ;;
    esac
    draw_g "$prev" 0; draw_g "$sel" 1
  done
  tui_end
  trap 'cleanup' EXIT INT TERM
  return 0
}
