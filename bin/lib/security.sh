#!/usr/bin/env bash
# lib/security.sh — enforcement, not advice.
#
# THIS LAYER NEVER MODIFIES YOUR FILES. It measures, it reports, and it keeps
# reporting every launch until you resolve the finding — but the decision is
# always yours. Nothing is chmod-ed, moved, or deleted on your behalf.
#
# The one thing it does impose is on ITSELF: umask, core dumps, and its own
# scratch directory. Hardening its own process is not a decision about your
# machine.
#
#   1 umask 077          nothing this process creates is group/world readable
#   2 no root            refuses to run as root: root-owned files in your vault
#                        and a root-readable agent socket are both unrecoverable
#   3 key permissions    REPORTS an age key that is not 0600 and owned by you
#   4 store permissions  REPORTS any encrypted store that is not 0600
#   5 scratch            its own temp dir is forced to 0700 (this process only)
#   6 plaintext          REPORTS plaintext credential files in secrets/ loudly,
#                        every launch, until you deal with them
#   7 clipboard          any value copied is cleared on exit as well as on TTL
#   8 idle lock          the interface quits itself after inactivity
#   9 core dumps         disabled, so a crash cannot spill decrypted memory
#
# Sourced, never executed.

# --- 1. process hardening, applied at source time -----------------------------
umask 077
ulimit -c 0 2>/dev/null || true          # 9: no core dumps carrying plaintext

SEC_IDLE_TIMEOUT="${SEC_IDLE_TIMEOUT:-600}"   # 8: seconds of inactivity before lock

# --- helpers ------------------------------------------------------------------
# --- stat, portably -----------------------------------------------------------
# `stat -f '%Lp' file 2>/dev/null || stat -c '%a' file` looks like a sensible
# BSD-then-GNU fallback and is not: on GNU coreutils `-f` means "show the
# FILESYSTEM containing this file", which succeeds and exits 0. The fallback
# never runs, the caller gets filesystem output where it expected a mode, and
# every permission check silently passes. CI on Linux caught this; macOS could
# not have.
# Detect by asking for the GNU form directly. Probing the BSD form is
# ambiguous — `stat -f /` succeeds on macOS as well, since it reads "/" as the
# format string, so a "does -f work" test picks the wrong branch on macOS.
if stat -c '%a' / >/dev/null 2>&1; then
  SEC_STAT=gnu            # GNU coreutils
else
  SEC_STAT=bsd            # BSD / macOS
fi
sec_stat() {   # $1 = mode|owner|mtime|size   $2 = path
  case "$SEC_STAT:$1" in
    bsd:mode)  stat -f '%Lp' "$2" 2>/dev/null ;;
    gnu:mode)  stat -c '%a'  "$2" 2>/dev/null ;;
    bsd:owner) stat -f '%Su' "$2" 2>/dev/null ;;
    gnu:owner) stat -c '%U'  "$2" 2>/dev/null ;;
    bsd:mtime) stat -f '%m'  "$2" 2>/dev/null ;;
    gnu:mtime) stat -c '%Y'  "$2" 2>/dev/null ;;
    bsd:size)  stat -f '%z'  "$2" 2>/dev/null ;;
    gnu:size)  stat -c '%s'  "$2" 2>/dev/null ;;
  esac
}

sec_mode()  { sec_stat mode  "$1"; }
sec_owner() { sec_stat owner "$1"; }

# sec_mode_bad PATH MAXMODE -> 0 (true) when the file is more permissive
sec_mode_bad() {
  local m; m="$(sec_mode "$1")"
  [ -n "$m" ] || return 1
  [ "$(( 8#$m & 8#077 ))" -ne 0 ] && return 0
  return 1
}

# --- 2. refuse to run as root -------------------------------------------------
sec_enforce_not_root() {
  if [ "$(id -u)" = "0" ]; then
    ui_err "refusing to run as root"
    ui_note "Running this as root creates root-owned files inside your vault and"
    ui_note "leaves a root-readable agent socket. Both are worse than the problem"
    ui_note "you were trying to solve. Run it as your own user."
    exit 1
  fi
}

# --- 3/4. permission enforcement ----------------------------------------------
# Reports offending paths. REPAIR=1 is available for an explicit, user-initiated
# fix from the posture screen — it is never passed on a normal launch.
# sec_stat_batch PATH... -> "path<TAB>mode<TAB>owner" for every path, in ONE
# stat call. Asking stat once per file per field is what made the launch gate
# cost 61ms of pure fork overhead on every single invocation of the program.
sec_stat_batch() {
  [ "$#" -gt 0 ] || return 0
  # A LITERAL tab, not "\t": BSD stat does not interpret escape sequences in its
  # format string, so it emitted the two characters backslash-t and every row
  # failed to split — the audit found nothing and reported everything fine.
  # GNU stat does interpret them, which is exactly how a bug like this survives
  # on one platform and hides on the other.
  local TAB; TAB="$(printf '\t')"
  case "$SEC_STAT" in
    gnu) stat -c "%n${TAB}%a${TAB}%U${TAB}%Y${TAB}%s"    "$@" 2>/dev/null ;;
    *)   stat -f "%N${TAB}%Lp${TAB}%Su${TAB}%m${TAB}%z"   "$@" 2>/dev/null ;;
  esac
}

sec_audit_permissions() {   # $1 = repair? (0/1)  -> prints findings, returns 1 if any
  local repair="${1:-0}" bad=0 f me kd
  me="$(id -un)"

  # Collect every path FIRST, then ask stat once. The previous version called
  # sec_mode/sec_owner per file — two forks each, ~15 files — and it runs on
  # every launch of the program, including the dashboard.
  local -a paths=() kinds=()
  if [ -f "$SOPS_AGE_KEY_FILE" ]; then
    paths+=("$SOPS_AGE_KEY_FILE"); kinds+=(key)
    kd="$(dirname "$SOPS_AGE_KEY_FILE")"
    paths+=("$kd"); kinds+=(keydir)
  fi
  for f in "$SEC_SECRETS"/*.enc.* "$SEC_ENC_DIR"/*.enc.*; do
    [ -f "$f" ] || continue
    paths+=("$f"); kinds+=(store)
  done
  for f in "$SEC_SECRETS"/*.yaml "$SEC_SECRETS"/*.md; do
    [ -f "$f" ] || continue
    paths+=("$f"); kinds+=(meta)
  done
  [ "${#paths[@]}" -gt 0 ] || return 0

  # one stat call for all of them
  local -A MODE=() OWNER=()
  local sp sm so smt sz
  while IFS="$(printf '\t')" read -r sp sm so smt sz; do
    [ -n "$sp" ] || continue
    MODE["$sp"]="$sm"; OWNER["$sp"]="$so"
  done <<STATB
$(sec_stat_batch "${paths[@]}")
STATB

  local i=0 n="${#paths[@]}" path kind mode owner
  while [ "$i" -lt "$n" ]; do
    path="${paths[$i]}"; kind="${kinds[$i]}"
    mode="${MODE[$path]:-}"; owner="${OWNER[$path]:-}"
    i=$(( i + 1 ))
    [ -n "$mode" ] || continue

    if [ "$kind" = key ] && [ -n "$owner" ] && [ "$owner" != "$me" ]; then
      printf 'OWNER %s %s\n' "$path" "$owner"; bad=1
    fi

    # group or other bits set at all is too open for any of these
    case "$mode" in
      *[1-7][0-7]|*[0-7][1-7])
        printf 'MODE %s %s\n' "$path" "$mode"
        if [ "$repair" = "1" ]; then
          case "$kind" in keydir) chmod 700 "$path" ;; *) chmod 600 "$path" ;; esac
        fi
        bad=1 ;;
    esac
  done

  return $(( bad == 0 ? 0 : 1 ))
}

# --- 5. scratch space ---------------------------------------------------------
sec_enforce_scratch() {
  [ -n "${TMPD:-}" ] || return 0
  chmod 700 "$TMPD" 2>/dev/null
  if sec_mode_bad "$TMPD"; then
    ui_err "scratch directory $TMPD is group/world accessible and could not be fixed"
    exit 1
  fi
}

# --- 7. clipboard scrubbing on exit -------------------------------------------
# Whatever `secrets copy` put on the clipboard is cleared when the program ends,
# not only when its timer fires — quitting must not leave a value behind.
SEC_CLIP_HASH=""
sec_clip_scrub() {
  [ -n "$SEC_CLIP_HASH" ] || return 0
  local get put cur
  case "$(uname -s)" in
    Darwin) get=pbpaste; put=pbcopy ;;
    *) if command -v wl-paste >/dev/null 2>&1; then get=wl-paste; put=wl-copy
       elif command -v xclip >/dev/null 2>&1; then get="xclip -selection clipboard -o"; put="xclip -selection clipboard"
       else return 0; fi ;;
  esac
  cur="$($get 2>/dev/null | shasum -a 256 | cut -d' ' -f1)"
  [ "$cur" = "$SEC_CLIP_HASH" ] && printf '' | $put 2>/dev/null
  SEC_CLIP_HASH=""
}

# --- 8. idle lock -------------------------------------------------------------
# tui_readkey blocks forever by default. This wraps it with a timeout so an
# unattended terminal does not sit on an open vault indefinitely.
sec_readkey_timed() {
  local k
  if [ "${BASH_VERSINFO[0]:-3}" -ge 4 ] && [ "${SEC_IDLE_TIMEOUT:-0}" -gt 0 ]; then
    if ! IFS= read -rsn1 -t "$SEC_IDLE_TIMEOUT" k </dev/tty 2>/dev/null; then
      printf 'idle'; return 0
    fi
  else
    IFS= read -rsn1 k </dev/tty 2>/dev/null || return 1
  fi
  tui_decode_key "$k"
}

# --- the gate -----------------------------------------------------------------
# Runs once per launch. It BLOCKS nothing and CHANGES nothing — it states what is
# wrong, every single time, until you choose to act. Persistent nagging is the
# enforcement; the authority stays with you.
sec_enforce_all() {
  sec_enforce_not_root          # the only refusal: root would create files we cannot undo
  sec_enforce_scratch           # our own scratch dir, not yours

  local findings plaintext
  findings="$(sec_audit_permissions 0)"
  plaintext="$(sec_find_plaintext)"

  [ -z "$findings" ] && [ -z "$plaintext" ] && return 0

  # EVERYTHING below goes to stderr. `secretsd names` and friends are piped into
  # scripts, and a warning on stdout silently corrupts the caller's data.
  {
    printf '\n'
    if [ -n "$plaintext" ]; then
      ui_err "PLAINTEXT CREDENTIALS PRESENT"
      printf '%s\n' "$plaintext" | sed 's/^/      /'
      ui_note "A plaintext export sitting beside an encrypted store is how credentials"
      ui_note "leak. Nothing has been moved or deleted — the decision is yours."
    fi
    if [ -n "$findings" ]; then
      ui_warn "permissions are more open than they should be:"
      printf '%s\n' "$findings" | while IFS=' ' read -r kind path mode; do
        case "$kind" in
          MODE)  printf '      %s is mode %s\n' "$path" "$mode" ;;
          OWNER) printf '      %s is owned by %s, not you\n' "$path" "$mode" ;;
        esac
      done
    fi
    ui_note "Nothing was changed. Review and fix from POSTURE on the home screen."
    printf '\n'
  } >&2
  return 0
}

# sec_find_plaintext -> plaintext credential files under secrets/, one per line
# TWO greps per candidate file was 32 forks on a normal store, paid on every
# single command because the launch gate calls this. awk reads them all in one
# pass and applies both rules per file.
sec_find_plaintext() {
  local f
  local -a cand=()
  for f in "$SEC_SECRETS"/* "$SEC_SECRETS"/.[!.]* "$SEC_ENC_DIR"/*; do
    [ -f "$f" ] || continue
    [ -s "$f" ] || continue
    case "$f" in
      *.enc.env|*.enc.yaml|*.enc.json|*.md|*.yaml|*.bak-*|*.selftest-only.bak) continue ;;
    esac
    cand+=("$f")
  done
  [ "${#cand[@]}" -gt 0 ] || return 0
  awk '
    FNR == 1 { sops[FILENAME] = 0; assign[FILENAME] = 0; seen[FILENAME] = 1 }
    /sops_/                          { sops[FILENAME] = 1 }
    /^[A-Za-z_][A-Za-z0-9_]*=/       { assign[FILENAME] = 1 }
    END {
      for (f in seen) if (!sops[f] && assign[f]) print f
    }
  ' "${cand[@]}" 2>/dev/null | sort
}
