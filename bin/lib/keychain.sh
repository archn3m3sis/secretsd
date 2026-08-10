#!/usr/bin/env bash
# lib/keychain.sh — import from the macOS Keychain.
#
# The largest pile of credentials on a Mac is already sitting in the login
# keychain, and most people have never looked at what is in it. This enumerates
# it, lets you choose, and moves the ones you pick into the vault.
#
# HOW THE PROMPTS WORK, HONESTLY
#   Enumeration is free: `security dump-keychain` lists service and account
#   names without any authorisation, because names are not secret.
#
#   Reading a VALUE is not free. macOS will show an "allow access" dialog for
#   each item, because secretsd is not the application that stored it. That is
#   the keychain working correctly, and it is why this imports a selection
#   rather than everything: fifty dialogs is not a workflow.
#
#   Clicking "Always Allow" grants secretsd standing access to that one item.
#   "Allow" grants it once. Prefer Allow unless you intend to re-import.
#
# NOTHING IS DELETED. The keychain copy stays where it is. Removing it is a
# separate decision, and one this program will not make for you.
#
# Sourced, never executed.

# kc_is_system SERVICE -> 0 when the item belongs to macOS rather than to you.
# Measured on one real Mac: 53 of 165 items are Apple internals — assistant
# tokens, scoped bookmarks, iCloud plumbing, per-app "Safe Storage" keys.
# Importing those achieves nothing and buries the ones that matter, so they are
# hidden unless KC_SHOW_SYSTEM=1 asks for them.
kc_is_system() {
  case "$1" in
    com.apple.*|Apple\ *|iCloud*|AirPlay*|MetadataKeychain|ProtectedCloudStorage|\
    *Safe\ Storage|SafariCredentialsPro*|Chrome\ Safe*|*.xpc.*|CloudKit*|\
    Local\ Items*|iOSFactoryTest*|Continuity*|*BluetoothGlobal*|com.microsoft.*)
      return 0 ;;
  esac
  return 1
}

kc_available() { [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; }

# kc_list -> "class|service|account"
# Parses the dump into the two fields that identify an item. No value is read.
kc_list() {
  security dump-keychain 2>/dev/null | python3 -c '
import re, sys

cls = svc = acct = None
out = []
for line in sys.stdin:
    line = line.rstrip("\n")
    m = re.match(r'"'"'^\s*class: "(\w+)"'"'"', line)
    if m:
        if cls and (svc or acct):
            out.append((cls, svc or "", acct or ""))
        cls, svc, acct = m.group(1), None, None
        continue
    # 0x00000007 / "svce" carries the service, "acct" the account
    m = re.match(r'"'"'^\s*"(svce|acct|srvr)"<blob>=(.*)$'"'"', line)
    if m:
        key, val = m.group(1), m.group(2).strip()
        if val in ("<NULL>", ""):
            continue
        q = re.match(r'"'"'^"(.*)"$'"'"', val)
        val = q.group(1) if q else val
        if key in ("svce", "srvr"): svc = val
        elif key == "acct":         acct = val
if cls and (svc or acct):
    out.append((cls, svc or "", acct or ""))

seen = set()
for c, s, a in out:
    if not s and not a:
        continue
    k = (c, s, a)
    if k in seen:
        continue
    seen.add(k)
    print("%s|%s|%s" % (c, s.replace("|", "/"), a.replace("|", "/")))
' 2>/dev/null
}

# kc_read CLASS SERVICE ACCOUNT -> the value on stdout. This is what prompts.
kc_read() {
  case "$1" in
    inet) security find-internet-password -w -s "$2" ${3:+-a "$3"} 2>/dev/null ;;
    *)    security find-generic-password  -w -s "$2" ${3:+-a "$3"} 2>/dev/null ;;
  esac
}

# kc_keyname SERVICE ACCOUNT -> a store-legal key name
kc_keyname() {
  local n="$1"
  [ -n "$2" ] && n="${n}_$2"
  printf '%s' "$n" \
    | tr '[:lower:]' '[:upper:]' \
    | sed 's/[^A-Z0-9]\{1,\}/_/g; s/^_*//; s/_*$//; s/^\([0-9]\)/K\1/' \
    | cut -c1-60
}

keychain_screen() {
  ui_interactive || return 0

  if ! kc_available; then
    tui_page "KEYCHAIN IMPORT" "macOS only"
    ui_err "the Keychain is a macOS facility and `security` is not present"
    ui_pause; return 0
  fi

  ui_clear; printf '\n  '; tui_grad_violet 'reading the keychain index…'; printf '\n'

  local -a K_CLASS K_SVC K_ACCT K_LINE
  local n=0 c s a hidden=0
  while IFS='|' read -r c s a; do
    [ -n "$c" ] || continue
    if [ "${KC_SHOW_SYSTEM:-0}" != "1" ] && kc_is_system "$s"; then
      hidden=$(( hidden + 1 )); continue
    fi
    K_CLASS[$n]="$c"; K_SVC[$n]="$s"; K_ACCT[$n]="$a"
    n=$(( n + 1 ))
  done <<KCL
$(kc_list)
KCL

  if [ "$n" -eq 0 ]; then
    tui_page "KEYCHAIN IMPORT" "nothing enumerable"
    ui_info "no generic or internet password items were listed"
    ui_pause; return 0
  fi

  tui_page "KEYCHAIN IMPORT" "$n item(s) worth looking at in your login keychain"
  printf '\n'
  tui_kv "generic passwords"  "$(printf '%s\n' "${K_CLASS[@]}" | grep -c genp || true)"
  tui_kv "internet passwords" "$(printf '%s\n' "${K_CLASS[@]}" | grep -c inet || true)"
  tui_kv "already in the vault" "$(sec_count) credential(s)"
  [ "$hidden" -gt 0 ] && tui_kv "macOS internals hidden" "$hidden  (KC_SHOW_SYSTEM=1 to include)" "$T_DIM"
  printf '\n'
  ui_note "Names are listed without any authorisation — names are not secret."
  ui_warn "Reading a VALUE makes macOS ask permission, once per item."
  ui_note "That is the keychain working. Pick a handful, not all $n."
  printf '\n'

  local picked
  picked="$(
    local i=0
    while [ "$i" -lt "$n" ]; do
      printf '%-46s %-26s %s\n' \
        "$(printf '%s' "${K_SVC[$i]}" | cut -c1-46)" \
        "$(printf '%s' "${K_ACCT[$i]}" | cut -c1-26)" \
        "${K_CLASS[$i]}"
      i=$(( i + 1 ))
    done | ui_filter_multi 'tab to mark · enter to import the marked items'
  )" || return 0
  [ -n "$picked" ] || { ui_info "nothing selected"; ui_pause; return 0; }

  local count; count="$(printf '%s\n' "$picked" | sec_nlines)"
  tui_page "IMPORT $count ITEM(S)" "macOS will ask permission for each one"
  printf '\n'
  printf '%s\n' "$picked" | head -12 | sed 's/^/     /'
  [ "$count" -gt 12 ] && printf '     … and %s more\n' "$(( count - 12 ))"
  printf '\n'
  ui_note "For each: click Allow (once) or Always Allow (standing access)."
  ui_warn "The keychain copy is NOT removed. Nothing is deleted."
  printf '\n'
  ui_confirm "Import $count item(s) into the vault?" || { ui_info "nothing imported"; ui_pause; return 0; }
  printf '\n'

  local line svc acct cls key val imported=0 denied=0 skipped=0 i
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # recover the original fields by matching the rendered row back to the index
    i=0; svc=""; acct=""; cls=""
    while [ "$i" -lt "$n" ]; do
      if [ "$(printf '%-46s %-26s %s' "$(printf '%s' "${K_SVC[$i]}" | cut -c1-46)" \
                "$(printf '%s' "${K_ACCT[$i]}" | cut -c1-26)" "${K_CLASS[$i]}")" = "$line" ]; then
        svc="${K_SVC[$i]}"; acct="${K_ACCT[$i]}"; cls="${K_CLASS[$i]}"; break
      fi
      i=$(( i + 1 ))
    done
    [ -n "$svc$acct" ] || continue

    key="$(kc_keyname "$svc" "$acct")"
    printf '   %-52s ' "$(printf '%s' "$key" | cut -c1-52)"

    if sec_has "$key"; then
      skipped=$(( skipped + 1 )); printf '%salready in the vault%s\n' "$T_DIM" "$T_RS"; continue
    fi

    val="$(kc_read "$cls" "$svc" "$acct")"
    if [ -z "$val" ]; then
      denied=$(( denied + 1 )); printf '%sdenied or empty%s\n' "$T_WARN" "$T_RS"; continue
    fi
    if sec_put "$key" "$val"; then
      imported=$(( imported + 1 )); printf '%simported%s\n' "$T_OK" "$T_RS"
    else
      printf '%swrite failed%s\n' "$T_ERR" "$T_RS"
    fi
    val=""
  done <<PICKED
$picked
PICKED

  printf '\n'
  tui_kv "imported"            "$imported" "$T_OK"
  tui_kv "already present"     "$skipped"  "$T_DIM"
  tui_kv "denied or empty"     "$denied"   "$([ "$denied" -gt 0 ] && printf '%s' "$T_WARN" || printf '%s' "$T_DIM")"
  tui_kv "store now holds"     "$(sec_count) credential(s)"
  if [ "$imported" -gt 0 ]; then
    sec_log_start keychain; sec_log "imported $imported item(s) from the macOS keychain"
    printf '\n'
    ui_note "record what each one is for, so it can be rotated later:"
    printf '     %ssecretsd manifest%s\n' "$T_ACCENT" "$T_RS"
    ui_warn "The keychain still holds its own copy of each. Two copies now exist."
  fi
  ui_pause
}
