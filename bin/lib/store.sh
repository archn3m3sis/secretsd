#!/usr/bin/env bash
# lib/store.sh — storage layer for the `secrets` platform.
#
# TWO TIERS, ONE INTERFACE:
#   encrypted tier — SOPS+age files holding real secret material
#   directory tier — plaintext YAML holding NO secret values, only the map of
#                    what exists, where it lives, and how you authenticate
#
# INJECT, NEVER RETRIEVE still holds: nothing here prints a secret VALUE to
# stdout. The one deliberate exception is `secrets copy`, which routes a value to
# the system clipboard and auto-clears it, never through a terminal or a log.
#
# bash 3.2-clean. Sourced, never executed.

# --- paths --------------------------------------------------------------------
: "${SEC_ROOT:?store.sh needs SEC_ROOT}"
SEC_SECRETS="$SEC_ROOT/secrets"
SEC_ENC_DIR="$SEC_SECRETS/domains"        # encrypted per-module stores
SEC_DIR_DIR="$SEC_SECRETS/directory"      # plaintext per-module directories
SEC_STORE="$SEC_SECRETS/api-keys.enc.env" # the API module store (historical name, kept)
SEC_MANIFEST="$SEC_SECRETS/CREDENTIALS.yaml"
SEC_ROTATE="$SEC_SECRETS/ROTATE-THESE.md"
: "${SOPS_AGE_KEY_FILE:=$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE

# --- logging ------------------------------------------------------------------
# Lazy by design. Read-only commands write NO log file at all — the old
# behaviour created a file per invocation and grew run-logs/ to 78,000 files.
SEC_LOG=""
sec_log_start() {
  [ -n "$SEC_LOG" ] && return 0
  mkdir -p "$SEC_ROOT/run-logs" 2>/dev/null
  SEC_LOG="$SEC_ROOT/run-logs/secret_$(date +%Y%m%d-%H%M%S)-$$.log"
  printf '%s  === %s ===\n' "$(date -u +%FT%TZ)" "${1:-session}" >> "$SEC_LOG" 2>/dev/null
}
sec_log() { [ -n "$SEC_LOG" ] && printf '%s  %s\n' "$(date -u +%FT%TZ)" "$*" >> "$SEC_LOG" 2>/dev/null; return 0; }
sec_die() { ui_err "${*:-error}"; sec_log "ERROR $*"; exit 1; }

# sec_log_prune [KEEP] — cap run-logs/ at KEEP most recent files (default 400).
# Echoes the number ACTUALLY removed, measured by recounting — not by arithmetic.
# Deliberately not `ls -t dir/*.log`: at 78,000 files the glob exceeds ARG_MAX,
# ls fails, and the pipeline deletes nothing while every exit code looks fine.
sec_log_prune() {
  local keep="${1:-400}" dir="$SEC_ROOT/run-logs" before after
  [ -d "$dir" ] || { printf '0'; return 0; }
  before="$(sec_log_count)"
  [ "${before:-0}" -le "$keep" ] && { printf '0'; return 0; }

  python3 - "$dir" "$keep" <<'PY' >/dev/null 2>&1
import os, sys
d, keep = sys.argv[1], int(sys.argv[2])
files = []
try:
    with os.scandir(d) as it:
        for e in it:
            try:
                if e.is_file() and e.name.endswith('.log'):
                    files.append((e.stat().st_mtime, e.path))
            except OSError:
                pass
except OSError:
    sys.exit(1)
files.sort(reverse=True)          # newest first
for _, p in files[keep:]:
    try:
        os.remove(p)
    except OSError:
        pass
PY

  after="$(sec_log_count)"
  printf '%s' "$(( before - after ))"
}

sec_log_count() {
  find "$SEC_ROOT/run-logs" -maxdepth 1 -type f -name '*.log' 2>/dev/null | wc -l | tr -d ' '
}

# --- module registry ----------------------------------------------------------
# id|icon|label|tier|relative-store-path|state
# tier:  enc = SOPS encrypted | dir = plaintext directory
# state: built | planned
sec_modules() {
  cat <<'MODS'
api|🔑|API Management|enc|secrets/api-keys.enc.env|built
pii|🪪|PII Management|enc|secrets/domains/pii.enc.yaml|built
keys|🗝️|Key Management|enc|secrets/domains/keys.enc.yaml|built
auth|🗺️|Auth Mapping|dir|secrets/directory/authmap.yaml|built
machines|🖥️|Machine Management|dir|secrets/directory/machines.yaml|built
certs|📜|Certificate Mgmt|enc|secrets/domains/certs.enc.yaml|built
env|📦|Environment Mgmt|dir|secrets/directory/environments.yaml|built
dns|🌐|Domain Management|dir|secrets/directory/dnsmap.yaml|built
logins|🔐|Login Management|enc|secrets/domains/logins.enc.yaml|built
MODS
}

sec_module_field() { # $1 id  $2 field-number
  sec_modules | awk -F'|' -v id="$1" -v f="$2" '$1==id {print $f}'
}
sec_module_exists() { sec_modules | cut -d'|' -f1 | ui_match_line "$1"; }
sec_module_state()  { sec_module_field "$1" 6; }
sec_module_label()  { sec_module_field "$1" 3; }
sec_module_icon()   { sec_module_field "$1" 2; }
sec_module_store()  { printf '%s/%s' "$SEC_ROOT" "$(sec_module_field "$1" 5)"; }

# --- encrypted-store helpers --------------------------------------------------
# Key-name enumeration goes through JSON, not dotenv. The dotenv path greps for
# ^NAME= and would invent phantom keys the first time a value contains a newline
# (a PEM certificate or an SSH private key). JSON gives the real key set.
sec_names() { # $1 = store path (default: API store)
  local f="${1:-$SEC_STORE}"
  [ -f "$f" ] || return 0
  sops -d --output-type json "$f" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
for k in sorted(d):
    if k == "sops" or k.startswith("sops_"):
        continue
    print(k)
' 2>/dev/null
}

# Fallback for hosts with no python3: dotenv enumeration, explicitly flagged as
# degraded rather than silently substituted.
sec_names_have_python() { command -v python3 >/dev/null 2>&1; }

sec_count()   { sec_names "${1:-$SEC_STORE}" | grep -c . ; }
sec_has()     { sec_names "${2:-$SEC_STORE}" | ui_match_line "$1"; }
sec_valid_name() { printf '%s' "$1" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$'; }

# sec_multiline_names — STORE key names whose value contains a newline.
# Enumerated through the sanctioned inject path so no value reaches this shell.
# It must intersect with the real key list: `sops exec-env` layers the store on
# top of the caller's existing environment, so scanning all of os.environ would
# report the user's own shell variables (FZF_DEFAULT_OPTS and friends) as store
# keys — a false positive that would send you hunting a problem you don't have.
sec_multiline_names() {
  local f="${1:-$SEC_STORE}" py="${TMPD:-${TMPDIR:-/tmp}}/sec-ml.py"
  cat > "$py" <<'PY'
import os
for k in os.environ.get("SEC_KEYLIST", "").split():
    v = os.environ.get(k)
    if v is not None and "\n" in v:
        print(k)
PY
  # Honour a caller-supplied SEC_KEYLIST. doctor already enumerated the store
  # for its own checks; making this decrypt a second time to ask the same
  # question is 20ms for an answer already in hand.
  local list="${SEC_KEYLIST:-}"
  [ -n "$list" ] || list="$(sec_names "$f" | tr '\n' ' ')"
  SEC_KEYLIST="$list" sops exec-env "$f" "python3 $py" 2>/dev/null
  rm -f "$py"
}

sec_put() { # $1 name  $2 value  [$3 store]
  local f="${3:-$SEC_STORE}" jv
  jv="$(printf '%s' "$2" | python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))' 2>/dev/null)" || return 1
  [ -n "$jv" ] || return 1
  sops set "$f" "[\"$1\"]" "$jv" 2>>"${SEC_LOG:-/dev/null}"
}

sec_unset() { # $1 name  [$2 store]
  sops unset "${2:-$SEC_STORE}" "[\"$1\"]" 2>>"${SEC_LOG:-/dev/null}"
}

# --- recipients (read from the encrypted file, no decryption needed) ----------
sec_file_recipients() { # $1 store -> age public keys currently on the file
  grep -oE 'age1[0-9a-z]{50,}' "${1:-$SEC_STORE}" 2>/dev/null | sort -u
}
sec_config_recipients() { # recipients declared in .sops.yaml
  grep -oE 'age1[0-9a-z]{50,}' "$SEC_ROOT/.sops.yaml" 2>/dev/null | sort -u
}

# --- manifest -----------------------------------------------------------------
sec_manifest_keys() {
  [ -f "$SEC_MANIFEST" ] || return 0
  grep -oE '^[A-Za-z_][A-Za-z0-9_]*:' "$SEC_MANIFEST" 2>/dev/null | sed 's/:$//' | sort
}

# sec_manifest_field KEY FIELD -> the value, or empty
sec_manifest_field() {
  [ -f "$SEC_MANIFEST" ] || return 0
  awk -v key="$1" -v want="$2" '
    /^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/ { k=$1; sub(/:$/,"",k); next }
    k == key && $1 == want":" { $1=""; sub(/^[[:space:]]+/,""); sub(/[[:space:]]*#.*$/,""); sub(/[[:space:]]+$/,""); print; exit }
  ' "$SEC_MANIFEST"
}

sec_epoch_of() { date -j -f "%Y-%m-%d" "$1" +%s 2>/dev/null || date -d "$1" +%s 2>/dev/null; }

# --- preconditions ------------------------------------------------------------
sec_require_sops() {
  command -v sops >/dev/null 2>&1 || sec_die "sops is not installed on this host"
  if [ ! -f "$SEC_STORE" ]; then
    ui_err "no credential store at $SEC_STORE"
    ui_note "this looks like a first run. Set it up with:"
    printf '\n     %s./install.sh%s        from the secretsd checkout\n\n' "${T_ACCENT:-}" "${T_RS:-}"
    ui_note "or point at an existing data root:  export SECRETSD_HOME=/path/to/root"
    exit 1
  fi
  [ -f "$SOPS_AGE_KEY_FILE" ] || sec_die \
    "no age key at $SOPS_AGE_KEY_FILE — this host cannot decrypt (by design on the VPS and neo)"
  sec_names_have_python || sec_die \
    "python3 not found — key enumeration would silently degrade to a dotenv scan that
     invents phantom keys on multi-line values. Install python3 rather than run degraded."
}

# sec_nlines — count lines on stdin, always echoing a single integer.
# `grep -c` exits 1 on zero matches, so the idiom `$(... | grep -c . || echo 0)`
# emits "0\n0" and every downstream [ ] test dies with "integer expected".
sec_nlines() { awk 'END{print NR+0}'; }

# sec_module_desc ID — one-line description shown under a module row
sec_module_desc() {
  case "$1" in
    api)      printf 'tokens, API keys, and service credentials' ;;
    pii)      printf 'identity, health, and personal records — this host only' ;;
    keys)     printf 'SSH keys, fingerprints, and host-to-key mapping' ;;
    auth)     printf 'how you authenticate to what — the method directory' ;;
    machines) printf 'host inventory, roles, and live reachability' ;;
    certs)    printf 'certificates, chains, and expiry parsed from the cert' ;;
    env)      printf 'projects, backups, serving channels, and access' ;;
    dns)      printf 'zones, records, and Cloudflare control' ;;
    logins)   printf 'accounts, passwords, TOTP seeds, recovery codes' ;;
    *)        printf '' ;;
  esac
}

# sec_module_caps ID — what the module will hold and do, one capability per line.
# Shown on the module screen so the design is visible in the product rather than
# living only in a planning document.
sec_module_caps() {
  case "$1" in
    pii) cat <<'C'
person records: identity, contact, health, birth, government numbers
single-recipient encryption — this Mac only, never the 5-host fleet list
redaction-aware display: fields stay masked until explicitly revealed
export blocked by default; copy routes through the auto-clearing clipboard
C
;;
    keys) cat <<'C'
SSH private keys and passphrases, ECDSA nistp384 to your convention
fingerprint per key, and which hosts currently accept it
orphan detection: a key no host accepts, and a config entry with no key
generate a new key and stage the public half for deployment
C
;;
    auth) cat <<'C'
target -> method directory: CAC, SSH key, SSO, password + TOTP, API token
plaintext by design so the access map is readable without decrypting
cross-references credentials by NAME only, never by value
gap report: a target with no recorded method, a method with no credential
C
;;
    machines) cat <<'C'
reader over the existing asset register — one source of truth, no drift
live reachability, and whether your key is accepted on each host
certificate and credential expiry rolled up per host
flags any disagreement between the register and what it measures
C
;;
    certs) cat <<'C'
certificates, chains, and private keys as structured records
expiry parsed FROM the certificate, never a hand-typed date that goes stale
revocation-list awareness, including offline and air-gapped CRL refresh
renewal queue ordered by what actually expires first
C
;;
    env) cat <<'C'
project -> where it lives, how it is backed up, how it is served
access map: who and what can reach each environment
migration and restore runbooks generated from the recorded topology
ties the other eight modules together per project
C
;;
    dns) cat <<'C'
zones and records, with which Cloudflare token governs each
full read plus guarded write: confirmation and a before/after diff as proof
drift report: live DNS against the recorded map
tokens injected per call — never exported into your shell
C
;;
    logins) cat <<'C'
accounts: username, password, TOTP seed, recovery codes
per-account URL and the authentication method it pairs with
TOTP generated locally on demand, never stored decrypted
breach-shaped hygiene: reused passwords, ageing credentials
C
;;
    *) printf '' ;;
  esac
}
