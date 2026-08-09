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
ui_interactive() { [ -t 1 ] && [ -c /dev/tty ] 2>/dev/null; }

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
ui_ok()   { if ui_has_gum; then gum style --foreground $UI_OK   "✓ $*"; else printf '%s✓%s %s\n' "$UI_FG_OK" "$UI_RS" "$*"; fi; }
ui_info() { if ui_has_gum; then gum style --foreground $UI_DIM  "• $*"; else printf '%s•%s %s\n' "$UI_D" "$UI_RS" "$*"; fi; }
ui_note() { if ui_has_gum; then gum style --foreground $UI_INFO "› $*"; else printf '%s›%s %s\n' "$UI_FG_I" "$UI_RS" "$*"; fi; }
ui_warn() { if ui_has_gum; then gum style --foreground $UI_WARN "! $*"; else printf '%s!%s %s\n' "$UI_FG_WARN" "$UI_RS" "$*" >&2; fi; }
ui_err()  { if ui_has_gum; then gum style --foreground $UI_ERR  "✗ $*"; else printf '%s✗%s %s\n' "$UI_FG_ERR" "$UI_RS" "$*" >&2; fi; }

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
  w="$(tput cols 2>/dev/null || echo 80)"; [ "$w" -gt 100 ] && w=100
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
  if ui_has_gum; then
    if [ -n "$subtitle" ]; then
      gum style --border rounded --border-foreground $UI_ACCENT --padding "0 2" \
        --margin "1 0 0 0" --foreground $UI_ACCENT --bold "$title" "$subtitle"
    else
      gum style --border rounded --border-foreground $UI_ACCENT --padding "0 2" \
        --margin "1 0 0 0" --foreground $UI_ACCENT --bold "$title"
    fi
  else
    printf '\n%s%s%s\n' "$UI_B$UI_FG_V" "$title" "$UI_RS"
    [ -n "$subtitle" ] && printf '%s%s%s\n' "$UI_D" "$subtitle" "$UI_RS"
  fi
}

# --- input widgets ------------------------------------------------------------
ui_ask() { # $1 prompt  $2 placeholder -> echoes input; nonzero on cancel
  if ui_has_gum; then
    gum input --prompt "$1 › " --prompt.foreground $UI_ACCENT --placeholder "${2:-}"
  else
    local v; printf '%s%s:%s ' "$UI_B" "$1" "$UI_RS" >&2; ui_read v || return 1; printf '%s' "$v"
  fi
}

ui_ask_secret() { # $1 prompt -> echoes hidden input; nonzero on cancel
  if ui_has_gum; then
    gum input --password --prompt "$1 › " --prompt.foreground $UI_ACCENT
  elif ui_interactive; then
    local v; printf '%s%s (hidden):%s ' "$UI_B" "$1" "$UI_RS" >&2
    ui_read_secret v || return 1; printf '\n' >&2; printf '%s' "$v"
  else
    local v; IFS= read -r v || return 1; printf '%s' "$v"   # piped input (scripts, tests)
  fi
}

ui_confirm() { # $1 question -> 0 = yes
  if ui_has_gum; then
    gum confirm --selected.background $UI_ACCENT "$1"
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
    printf '%s\n' "$opts" | gum choose --header "$header" --header.foreground $UI_DIM \
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
    gum filter --placeholder "type to narrow…" --header "$header" \
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
    gum filter --no-limit --placeholder "type to narrow, tab to mark…" --header "$header" \
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
  if ui_has_gum; then gum spin --spinner dot --title "$title" --spinner.foreground $UI_ACCENT -- "$@"
  else printf '%s%s…%s\n' "$UI_D" "$title" "$UI_RS" >&2; "$@"; fi
}

ui_pause() {
  if ui_has_gum; then gum input --placeholder "press enter to continue" >/dev/null 2>&1 || true
  else local _x; printf '%s(enter to continue)%s ' "$UI_D" "$UI_RS"; IFS= read -r _x || true; fi
}

ui_clear() { ui_interactive && printf '\033[2J\033[H'; }
