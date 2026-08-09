#!/usr/bin/env bash
# lib/gen.sh — credential generation and TOTP.
#
# GENERATION NEVER PRINTS THE VALUE. A generated secret goes straight into the
# vault under a name you choose, and optionally to the auto-clearing clipboard.
# It is not echoed, not logged, and not left in scrollback — which is the entire
# reason to generate it here instead of in a shell one-liner.
#
# Entropy comes from /dev/urandom via openssl. Character-class generation uses
# rejection sampling, not modulo, so every character is uniformly distributed —
# `$RANDOM % 62` is biased and a password generator has no business being biased.
#
# TOTP is computed locally from the stored seed. The seed is read into the child
# process only, and only the 6-digit code is ever displayed.
#
# Sourced, never executed.

GEN_LOWER='abcdefghijkmnopqrstuvwxyz'      # no l
GEN_UPPER='ABCDEFGHJKLMNPQRSTUVWXYZ'       # no I, O
GEN_DIGIT='23456789'                       # no 0, 1
GEN_SYM='!@#$%^&*()-_=+[]{};:,.?'

# gen_random_string LENGTH CHARSET -> uniform random string
gen_random_string() {
  local len="$1" set="$2" n="${#2}" out="" byte max
  max=$(( 256 - (256 % n) ))               # rejection bound kills modulo bias
  while [ "${#out}" -lt "$len" ]; do
    byte="$(openssl rand 1 2>/dev/null | od -An -tu1 | tr -d ' \n')"
    [ -n "$byte" ] || return 1
    [ "$byte" -ge "$max" ] && continue
    out="$out${set:$(( byte % n )):1}"
  done
  printf '%s' "$out"
}

# gen_password LENGTH [with-symbols] — at least one of each requested class
gen_password() {
  local len="${1:-32}" syms="${2:-1}" set pw tries=0
  set="$GEN_LOWER$GEN_UPPER$GEN_DIGIT"
  [ "$syms" = "1" ] && set="$set$GEN_SYM"
  while [ "$tries" -lt 40 ]; do
    pw="$(gen_random_string "$len" "$set")" || return 1
    if printf '%s' "$pw" | grep -q '[a-z]' && printf '%s' "$pw" | grep -q '[A-Z]' \
       && printf '%s' "$pw" | grep -q '[0-9]'; then
      if [ "$syms" != "1" ] || printf '%s' "$pw" | grep -q '[^A-Za-z0-9]'; then
        printf '%s' "$pw"; return 0
      fi
    fi
    tries=$(( tries + 1 ))
  done
  printf '%s' "$pw"
}

# gen_passphrase WORDS — diceware-style from the system word list
gen_passphrase() {
  local words="${1:-6}" list="/usr/share/dict/words" out="" i=0 total w idx
  if [ ! -f "$list" ]; then
    # no word list: fall back to readable syllables rather than silently degrading
    while [ "$i" -lt "$words" ]; do
      out="$out$([ -n "$out" ] && printf '-')$(gen_random_string 5 "$GEN_LOWER")"
      i=$(( i + 1 ))
    done
    printf '%s' "$out"; return 0
  fi
  total="$(grep -c '^[a-z]\{4,8\}$' "$list")"
  while [ "$i" -lt "$words" ]; do
    idx=$(( ($(openssl rand 4 | od -An -tu4 | tr -d ' \n') % total) + 1 ))
    w="$(grep '^[a-z]\{4,8\}$' "$list" | sed -n "${idx}p")"
    [ -n "$w" ] || continue
    out="$out$([ -n "$out" ] && printf '-')$w"
    i=$(( i + 1 ))
  done
  printf '%s' "$out"
}

gen_hex()    { openssl rand -hex "${1:-32}"; }
gen_base64() { openssl rand -base64 "${1:-32}" | tr -d '\n'; }

# gen_entropy_bits LENGTH CHARSET_SIZE -> approximate bits
gen_entropy_bits() {
  python3 -c "import math,sys; print(int(int(sys.argv[1])*math.log2(int(sys.argv[2]))))" "$1" "$2" 2>/dev/null || echo '?'
}

# --- the screen ---------------------------------------------------------------
gen_screen() {
  ui_interactive || return 0
  local kind len value name bits setsize

  tui_page "GENERATE" "the value goes straight into the vault — it is never printed"

  kind="$(tui_menu "GENERATE A CREDENTIAL" "nothing is echoed to your terminal" \
    "Password (letters, digits, symbols)|32 chars · uniform, unbiased · ~200 bits" \
    "Password (alphanumeric only)|for systems that reject symbols" \
    "Passphrase (words)|easier to type on a console or phone" \
    "Hex token|for API keys and webhook secrets" \
    "Base64 token|for headers and config files" \
    "Cancel|change nothing")" || return 0

  case "$kind" in
    "Password (letters"*)  len="$(ui_ask 'Length' '32')"; len="${len:-32}"
                           value="$(gen_password "$len" 1)"; setsize=$(( 25+24+8+23 )) ;;
    "Password (alpha"*)    len="$(ui_ask 'Length' '32')"; len="${len:-32}"
                           value="$(gen_password "$len" 0)"; setsize=$(( 25+24+8 )) ;;
    "Passphrase"*)         len="$(ui_ask 'Words' '6')"; len="${len:-6}"
                           value="$(gen_passphrase "$len")"; setsize=7776 ;;
    "Hex token"*)          len="$(ui_ask 'Bytes' '32')"; len="${len:-32}"
                           value="$(gen_hex "$len")"; setsize=16; len=$(( len * 2 )) ;;
    "Base64 token"*)       len="$(ui_ask 'Bytes' '32')"; len="${len:-32}"
                           value="$(gen_base64 "$len")"; setsize=64; len=$(( (len * 4 + 2) / 3 )) ;;
    *) return 0 ;;
  esac

  [ -n "$value" ] || { ui_err "generation failed"; ui_pause; return 1; }
  bits="$(gen_entropy_bits "$len" "$setsize")"

  printf '\n'
  tui_kv "length"  "$len"
  tui_kv "entropy" "~$bits bits" "$([ "${bits:-0}" -ge 100 ] 2>/dev/null && printf '%s' "$T_OK" || printf '%s' "$T_WARN")"
  tui_kv "value"   "•••••••••••••••• (not shown)" "$T_DIM"
  printf '\n    %sstrength%s  ' "$T_MUTE" "$T_RS"
  tui_meter "$([ "${bits:-0}" -gt 256 ] 2>/dev/null && echo 256 || echo "${bits:-0}")" 256 30
  printf '\n\n'

  name="$(ui_ask 'Store it as' 'e.g. STRIPE_LIVE_KEY')" || { unset value; ui_info "discarded"; ui_pause; return 0; }
  if [ -z "$name" ] || ! sec_valid_name "$name"; then
    unset value; ui_err "invalid name — value discarded, nothing written"; ui_pause; return 1
  fi
  if sec_has "$name"; then
    ui_confirm "'$name' exists — overwrite it?" || { unset value; ui_info "discarded"; ui_pause; return 0; }
  fi

  if sec_put "$name" "$value"; then
    ui_ok "'$name' generated and stored, encrypted"
    sec_log_start gen; sec_log "generated $name ($len chars, ~$bits bits)"
    if ui_confirm "Copy it to the clipboard as well (clears in 45s)?"; then
      printf '%s' "$value" | pbcopy 2>/dev/null || printf '%s' "$value" | xclip -selection clipboard 2>/dev/null
      SEC_CLIP_HASH="$(printf '%s' "$value" | shasum -a 256 | cut -d' ' -f1)"
      ui_ok "on the clipboard — cleared on exit or in 45s"
      ( sleep 45; cur="$(pbpaste 2>/dev/null | shasum -a 256 | cut -d' ' -f1)"
        [ "$cur" = "$SEC_CLIP_HASH" ] && printf '' | pbcopy ) >/dev/null 2>&1 &
    fi
    unset value
    ui_note "record why it exists so future-you can rotate it:"
    printf '     %ssecrets manifest%s\n' "$T_ACCENT" "$T_RS"
  else
    unset value; ui_err "could not write to the vault — nothing stored"
  fi
  ui_pause
}

# --- TOTP ---------------------------------------------------------------------
# gen_totp SEED [DIGITS] -> current code. RFC 6238, SHA-1, 30s step.
gen_totp() {
  local seed="$1" digits="${2:-6}"
  printf '%s' "$seed" | python3 -c '
import sys, base64, hmac, hashlib, struct, time
seed = sys.stdin.read().strip().replace(" ", "").upper()
pad = "=" * ((8 - len(seed) % 8) % 8)
try:
    key = base64.b32decode(seed + pad)
except Exception:
    sys.exit(1)
ctr = struct.pack(">Q", int(time.time()) // 30)
h = hmac.new(key, ctr, hashlib.sha1).digest()
o = h[19] & 15
code = (struct.unpack(">I", h[o:o+4])[0] & 0x7fffffff) % (10 ** '"$digits"')
print(str(code).zfill('"$digits"'))
' 2>/dev/null
}

gen_totp_remaining() { printf '%s' $(( 30 - ($(date +%s) % 30) )); }

# totp_cmd NAME — scriptable: prints the CODE only (never the seed).
# Reads the seed from the logins vault, or from a store key of that name.
totp_cmd() {
  local name="${1:-}" seed="" code=""   # set -u: declaring is not initialising
  [ -n "$name" ] || sec_die "usage: secrets totp NAME"
  if [ -f "$SEC_ENC_DIR/logins.enc.yaml" ]; then
    seed="$(rece_get "$SEC_ENC_DIR/logins.enc.yaml" "$name" totp)"
  fi
  if [ -z "$seed" ] && sec_has "$name"; then
    seed="$("$SEC_BIN/secret" run --only "$name" -- sh -c "printf '%s' \"\$$name\"")"
  fi
  [ -n "$seed" ] || sec_die "no TOTP seed found for '$name'"
  code="$(gen_totp "$seed")"; unset seed
  [ -n "$code" ] || sec_die "seed is not valid base32"
  printf '%s\n' "$code"
}
