#!/usr/bin/env bash
# lib/ui.sh — shared visual layer for the `secrets` platform.
#
# One theme, one set of widgets, so every module looks like the same program.
# Uses `gum` when present AND attached to a real terminal; degrades to plain
# prompts otherwise so scripts and pipes keep working. bash 3.2-clean.
#
# Sourced, never executed.

# --- palette (gum 256-colour codes) ------------------------------------------
UI_ACCENT=141   # violet   — primary / cursor / brand
UI_OK=42        # green    — healthy
UI_WARN=214     # amber    — attention
UI_ERR=203      # red      — failure / highest sensitivity
UI_DIM=244      # grey     — chrome
UI_INFO=75      # blue     — informational
UI_PII=204      # pink     — personally identifiable information, marked distinctly

# tput fallbacks for the no-gum path
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  UI_B="$(tput bold)"; UI_D="$(tput dim)"; UI_RS="$(tput sgr0)"
  UI_FG_OK="$(tput setaf 2)"; UI_FG_WARN="$(tput setaf 3)"
  UI_FG_ERR="$(tput setaf 1)"; UI_FG_V="$(tput setaf 5)"; UI_FG_I="$(tput setaf 4)"
else
  UI_B=""; UI_D=""; UI_RS=""; UI_FG_OK=""; UI_FG_WARN=""; UI_FG_ERR=""; UI_FG_V=""; UI_FG_I=""
fi

# Interactivity is decided by the CONTROLLING TERMINAL, never by stdin.
# Widgets are routinely fed their options through a pipe (`... | ui_choose`), so
# testing `[ -t 0 ]` would disable gum exactly when it is being used properly —
# and then the plain fallback would read the piped OPTION LIST as the user's
# answer and bail out. gum interacts over /dev/tty, so that is what we test.
ui_has_gum() { ui_interactive && command -v gum >/dev/null 2>&1; }

# _gum — every gum invocation, funnelled through one place.
#
# gum asks the terminal questions (background colour, cursor position). A real
# terminal answers by writing into the tty input buffer, and those answers are
# still sitting there when the next read happens. Draining after each call is
# the difference between "type your passphrase" and "type your passphrase and
# also here are 40 characters you did not type".
_gum() {
  gum "$@"
  local __rc=$?
  ui_drain_tty
  return $__rc
}

ui_interactive() { [ -t 1 ] && [ -c /dev/tty ] 2>/dev/null; }

# --- profiling ----------------------------------------------------------------
# SECRETSD_PROFILE=1 prints a timing line per instrumented step to stderr.
# Startup cost is the kind of thing you MEASURE — every previous guess about
# where this program spent its first second was wrong, including two of mine.
SEC_PROF_T0="${EPOCHREALTIME:-0}"
ui_prof() {
  [ "${SECRETSD_PROFILE:-0}" = "1" ] || return 0
  local now="${EPOCHREALTIME:-0}"
  awk -v a="$SEC_PROF_LAST" -v b="$now" -v z="$SEC_PROF_T0" -v n="$1" \
    'BEGIN{ printf "  %-28s %7.1f ms   (t+%.0f ms)\n", n, (b-a)*1000, (b-z)*1000 }' >&2
  SEC_PROF_LAST="$now"
}
SEC_PROF_LAST="$SEC_PROF_T0"

# ui_launchd_jobs -> `launchctl list` output, read at most ONCE per process.
#
# The dashboard asks whether the monitor is scheduled and whether the alerts
# agent is scheduled, and each question forked launchctl and read the entire job
# table. Two questions, two full scans, ~35ms, on every launch. The answer
# cannot change while the program is drawing one screen.
#
# Anything that CHANGES a schedule calls ui_launchd_invalidate, so the very next
# read is fresh — a stale "scheduled: yes" straight after removing it would be a
# lie, and this program does not get to lie about whether something is running.
SEC_LAUNCHD_JOBS=""
SEC_LAUNCHD_READ=0
ui_launchd_jobs() {
  if [ "$SEC_LAUNCHD_READ" = "0" ]; then
    SEC_LAUNCHD_JOBS="$(launchctl list 2>/dev/null)"
    SEC_LAUNCHD_READ=1
  fi
  printf '%s\n' "$SEC_LAUNCHD_JOBS"
}
ui_launchd_invalidate() { SEC_LAUNCHD_READ=0; SEC_LAUNCHD_JOBS=""; }

# --- external tool versions ---------------------------------------------------
# ui_tool_version NAME COMMAND... -> the version string, cached.
#
# `ykman --version` costs 195 MILLISECONDS — it is a Python program, and paying
# its interpreter start-up just to print a string was a fifth of this program's
# entire launch time. `claude --version` is another 45ms. Neither answer changes
# until the binary itself changes, so the cache is keyed on the binary's own
# mtime and size: replace or upgrade the tool and it is re-read, otherwise it is
# a single grep of a small file.
#
# The dashboard shows this to tell you a tool is PRESENT and roughly which
# build. It is not a compatibility gate, and nothing decides anything from it.
ui_tool_version() {
  local name="$1"; shift
  local bin stamp cache line
  bin="$(command -v "$name" 2>/dev/null)" || return 1
  [ -n "$bin" ] || return 1
  stamp="$(sec_stat mtime "$bin" 2>/dev/null)-$(sec_stat size "$bin" 2>/dev/null)"
  cache="${SEC_ROOT:-$HOME}/state/tool-versions"

  if [ -f "$cache" ]; then
    line="$(awk -F'\t' -v n="$name" -v s="$stamp" '$1==n && $2==s {print $3; exit}' "$cache")"
    [ -n "$line" ] && { printf '%s' "$line"; return 0; }
  fi

  local v; v="$("$@" 2>/dev/null | head -1)"
  [ -n "$v" ] || return 1
  mkdir -p "$(dirname "$cache")" 2>/dev/null
  # drop any previous row for this tool, then append the fresh one
  if [ -f "$cache" ]; then
    awk -F'\t' -v n="$name" '$1!=n' "$cache" > "$cache.tmp" 2>/dev/null && mv -f "$cache.tmp" "$cache"
  fi
  printf '%s\t%s\t%s\n' "$name" "$stamp" "$v" >> "$cache"
  chmod 600 "$cache" 2>/dev/null
  printf '%s' "$v"
}

# --- pipeline-safe matching ---------------------------------------------------
#
# `producer | grep -q PATTERN` is a trap in any script that sets `pipefail`:
# grep exits the moment it matches, the producer is killed by SIGPIPE and exits
# 141, and pipefail promotes that 141 to the pipeline's status — so a SUCCESSFUL
# match is reported as a FAILURE.
#
# This is not theoretical. `launchctl list | grep -q com.secretsd.alerts` made
# every single schedule install report "launchctl did not report the agent as
# loaded" while the agent was, in fact, loaded and listed. The install worked;
# only the proof of it lied, which is the worst possible way for a check to fail.
#
# awk reads stdin to EOF, so the producer always finishes and its status is 0.
ui_match_line() { awk -v w="$1" '$0 == w        { f = 1 } END { exit !f }'; }  # exact line
ui_match_sub()  { awk -v w="$1" 'index($0, w)   { f = 1 } END { exit !f }'; }  # substring
ui_match_re()   { awk -v w="$1" '$0 ~ w         { f = 1 } END { exit !f }'; }  # regex
# print matching lines (reads to EOF, so the producer is never SIGPIPEd)
ui_grep_show() { awk -v w="$1" 'index($0, w)'; }

# ui_plist_int PLIST KEY — read an <integer> value out of a launchd plist.
# The plists here write <key>K</key><integer>N</integer> on ONE line, so the
# obvious "match the key, then read the next line" returns empty every time and
# the screen cheerfully reports "daily at :00".
ui_plist_int() {
  [ -f "$1" ] || return 1
  local v
  v="$(sed -n "s|.*<key>$2</key>[[:space:]]*<integer>\([0-9][0-9]*\)</integer>.*|\1|p" "$1" 2>/dev/null | head -1)"
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# ui_needs_tty NAME [ALTERNATIVE...] — say why nothing happened, then fail.
#
# Every full-screen module used to be guarded by `ui_interactive || return 0`,
# which meant that running one without a terminal — a pipe, a redirect, cron,
# CI, or an editor's "run this command" box — did the work of nothing and
# reported success. A command that produces no output and exits 0 is
# indistinguishable from a command that is broken, and it wasted a real
# debugging session before this existed.
#
# Goes to stderr, so a caller redirecting stdout still sees it, and returns 1,
# because the screen did not run.
ui_needs_tty() {
  local what="$1"; shift
  {
    printf '\n  secretsd %s is a full-screen module and needs an interactive terminal.\n' "$what"
    printf '  This is not one (a pipe, a redirect, cron, CI, or an editor run box).\n\n'
    if [ $# -gt 0 ]; then
      printf '  What you can run here instead:\n'
      local a; for a in "$@"; do printf '     %s\n' "$a"; done
      printf '\n'
    fi
    printf '  For the module itself, run this in your terminal:\n'
    printf '     secretsd %s\n\n' "$what"
  } >&2
  return 1
}

# Read a line from the human, not from whatever is piped into stdin.
ui_read() { # $1 = variable name to set
  if [ -t 0 ]; then IFS= read -r "$1"
  else IFS= read -r "$1" < /dev/tty; fi
}
ui_read_secret() {
  if [ -t 0 ]; then IFS= read -rs "$1"
  else IFS= read -rs "$1" < /dev/tty; fi
}

# --- status lines -------------------------------------------------------------
# These are one-line status prints. They used to shell out to `gum style`, which
# is a whole process that QUERIES the terminal — OSC 11 for the background colour
# and CPR for the cursor position. A real terminal answers those queries by
# writing the reply into the tty INPUT buffer. The replies then either print as
# literal garbage (^[]11;rgb:...) or, worse, get consumed by the next read as if
# you had typed them — which is how a short passphrase drew 130 bullets.
#
# Colour needs no subprocess. These are plain printf now.
ui_ok()   { printf '%s✓%s %s\n' "$UI_FG_OK"   "$UI_RS" "$*"; }
ui_info() { printf '%s•%s %s\n' "$UI_D"       "$UI_RS" "$*"; }
ui_note() { printf '%s›%s %s\n' "$UI_FG_I"    "$UI_RS" "$*"; }
ui_warn() { printf '%s!%s %s\n' "$UI_FG_WARN" "$UI_RS" "$*" >&2; }
ui_err()  { printf '%s✗%s %s\n' "$UI_FG_ERR"  "$UI_RS" "$*" >&2; }

# ui_dot STATE -> a coloured health dot + label, for dashboards
ui_dot() {
  case "$1" in
    ok|healthy) printf '\033[38;5;%sm●\033[0m %s' "$UI_OK"   "${2:-healthy}" ;;
    warn)       printf '\033[38;5;%sm●\033[0m %s' "$UI_WARN" "${2:-attention}" ;;
    err)        printf '\033[38;5;%sm●\033[0m %s' "$UI_ERR"  "${2:-failed}" ;;
    pii)        printf '\033[38;5;%sm●\033[0m %s' "$UI_PII"  "${2:-local only}" ;;
    *)          printf '\033[38;5;%sm○\033[0m %s' "$UI_DIM"  "${2:-not built}" ;;
  esac
}

# --- headings -----------------------------------------------------------------
# ui_rule TITLE — a section rule that fills the terminal width
ui_rule() {
  local w t pad
  # NOT `tput cols 2>/dev/null` — ncurses asks the terminal over STDERR, so
  # redirecting it makes tput fall back to terminfo's static 80 and report
  # success. Ask the tty directly.
  # The 2>/dev/null on stty silences STTY, not bash's own "cannot open
  # /dev/tty" when there is no controlling terminal — that message went to the
  # user's stderr and corrupted the top of a piped report. Grouping puts the
  # failed redirect inside the silenced scope.
  local sz; sz="$( { stty size </dev/tty; } 2>/dev/null )"
  if [ -n "$sz" ]; then w="${sz##* }"; else w="$(tput cols)"; fi
  case "$w" in ''|*[!0-9]*) w=80 ;; esac
  [ "$w" -gt 100 ] && w=100
  t=" $1 "
  pad=$(( w - ${#t} - 3 ))
  [ "$pad" -lt 0 ] && pad=0
  printf '\n\033[38;5;%sm──%s' "$UI_ACCENT" "$t"
  printf '%*s' "$pad" '' | tr ' ' '─'
  printf '\033[0m\n'
}

# ui_panel TITLE SUBTITLE — the bordered brand box used at the top of a view
ui_panel() {
  local title="$1" subtitle="${2:-}"
  printf '\n%s%s%s\n' "$UI_B$UI_FG_V" "$title" "$UI_RS"
  [ -n "$subtitle" ] && printf '%s%s%s\n' "$UI_D" "$subtitle" "$UI_RS"
  return 0
}

# --- input widgets ------------------------------------------------------------
ui_ask() { # $1 prompt  $2 placeholder -> echoes input; nonzero on cancel
  if ui_has_gum; then
    _gum input --prompt "$1 › " --prompt.foreground $UI_ACCENT --placeholder "${2:-}"
  else
    local v; printf '%s%s:%s ' "$UI_B" "$1" "$UI_RS" >&2; ui_read v || return 1; printf '%s' "$v"
  fi
}

ui_ask_secret() { # $1 prompt -> echoes hidden input; nonzero on cancel
  # gum's password mode shows nothing at all, which is the confusing behaviour
  # we are trying to remove — so we always use our own masked reader when there
  # is a terminal, and fall back to a plain read only for piped input.
  if ui_interactive; then
    local v=""
    printf '  %s%s%s ' "$UI_B" "$1" "$UI_RS" > /dev/tty
    ui_read_masked v || return 1
    printf '%s' "$v"
    v=""
  else
    local v; IFS= read -r v || return 1; printf '%s' "$v"   # piped input (scripts, tests)
  fi
}

ui_confirm() { # $1 question -> 0 = yes
  if ui_has_gum; then
    _gum confirm --selected.background $UI_ACCENT "$1"
  else
    local a; printf '%s%s [y/N]:%s ' "$UI_B" "$1" "$UI_RS" >&2; ui_read a || return 1
    case "$a" in [Yy]*) return 0 ;; *) return 1 ;; esac
  fi
}

# ui_choose HEADER [opt ...] — options come from the arguments, or from stdin
# when none are given. Both call sites are used, so both must work.
ui_choose() {
  local header="$1"; shift
  local opts
  if [ $# -gt 0 ]; then opts="$(printf '%s\n' "$@")"; else opts="$(cat)"; fi
  [ -n "$opts" ] || return 1

  if ui_has_gum; then
    printf '%s\n' "$opts" | _gum choose --header "$header" --header.foreground $UI_DIM \
      --cursor "❯ " --cursor.foreground $UI_ACCENT \
      --selected.foreground $UI_ACCENT
  else
    printf '%s%s%s\n' "$UI_D" "$header" "$UI_RS" >&2
    printf '%s\n' "$opts" | awk -v b="$UI_B" -v rs="$UI_RS" '{printf "  %s%d)%s %s\n", b, NR, rs, $0}' >&2
    local n total; total="$(printf '%s\n' "$opts" | awk 'END{print NR+0}')"
    printf '%sselect ›%s ' "$UI_FG_V" "$UI_RS" >&2; ui_read n || return 1
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    [ "$n" -ge 1 ] && [ "$n" -le "$total" ] || return 1
    printf '%s\n' "$opts" | sed -n "${n}p"
  fi
}

# ui_filter HEADER  — fuzzy-filter stdin, echo the chosen line.
# THIS is the answer to "a hundred keys and I have to remember the name".
ui_filter() {
  local header="${1:-filter}"
  if ui_has_gum; then
    _gum filter --placeholder "type to narrow…" --header "$header" \
      --header.foreground $UI_DIM --indicator "❯" --indicator.foreground $UI_ACCENT \
      --match.foreground $UI_ACCENT --height 18
  else
    # no gum: show the list, take an exact name
    cat >&2
    local v; printf '%sname ›%s ' "$UI_FG_V" "$UI_RS" >&2; IFS= read -r v || return 1; printf '%s' "$v"
  fi
}

# ui_filter_multi HEADER — same, but returns several lines
ui_filter_multi() {
  local header="${1:-filter}"
  if ui_has_gum; then
    _gum filter --no-limit --placeholder "type to narrow, tab to mark…" --header "$header" \
      --header.foreground $UI_DIM --indicator "❯" --indicator.foreground $UI_ACCENT \
      --match.foreground $UI_ACCENT --height 18
  else
    cat >&2
    local v; printf '%snames (space-separated) ›%s ' "$UI_FG_V" "$UI_RS" >&2
    IFS= read -r v || return 1; printf '%s' "$v" | tr ' ' '\n'
  fi
}

ui_spin() { # $1 title, rest command
  local title="$1"; shift
  if ui_has_gum; then _gum spin --spinner dot --title "$title" --spinner.foreground $UI_ACCENT -- "$@"
  else printf '%s%s…%s\n' "$UI_D" "$title" "$UI_RS" >&2; "$@"; fi
}

ui_pause() {
  if ui_has_gum; then _gum input --placeholder "press enter to continue" >/dev/null 2>&1 || true
  else local _x; printf '%s(enter to continue)%s ' "$UI_D" "$UI_RS"; IFS= read -r _x || true; fi
}

ui_clear() { ui_interactive && printf '\033[2J\033[H'; }

# --- masked secret input ------------------------------------------------------
# Reading a secret with no echo at all is the Unix default and it is a bad one:
# you cannot tell whether a keystroke registered, whether caps lock is on, or how
# much you have typed. Every user hesitates, retypes, and gets it wrong.
#
# This echoes one • per character, handles backspace, and never puts the value in
# a variable that survives the call. It is still not shown in the clear.
# ui_drain_tty — discard bytes the terminal pushed back at us (query replies)
# before we start treating input as keystrokes.
ui_drain_tty() {
  local _junk
  while IFS= read -r -s -n 64 -t 0.05 _junk </dev/tty 2>/dev/null; do
    [ -n "$_junk" ] || break
  done
  return 0
}

ui_read_masked() {   # $1 = variable name to set
  local __var="$1" __s="" __c
  ui_drain_tty
  # stty -echo so the terminal does not print, then we draw the mask ourselves
  local __old; __old="$(stty -g </dev/tty 2>/dev/null)"
  stty -echo </dev/tty 2>/dev/null
  while IFS= read -r -s -n 1 __c </dev/tty 2>/dev/null; do
    case "$__c" in
      '') break ;;                                   # enter
      $'\177'|$'\b')                                 # backspace / delete
        if [ -n "$__s" ]; then
          __s="${__s%?}"
          printf '\b \b' > /dev/tty
        fi ;;
      $'\003') stty "$__old" </dev/tty 2>/dev/null; printf '\n' >/dev/tty; return 1 ;;   # ctrl-c
      *) __s="$__s$__c"; printf '%s' '•' > /dev/tty ;;
    esac
  done
  stty "$__old" </dev/tty 2>/dev/null
  printf '\n' > /dev/tty
  printf -v "$__var" '%s' "$__s"
  __s=""
  return 0
}

# ui_ask_masked PROMPT VARNAME — prompt, read masked, show the length typed
ui_ask_masked() {
  local prompt="$1" var="$2"
  printf '  %s%s%s ' "$T_B" "$prompt" "$T_RS" > /dev/tty
  ui_read_masked "$var" || return 1
  return 0
}
