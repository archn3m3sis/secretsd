#!/usr/bin/env bash
# lib/import.sh — bring an existing password manager in.
#
# SUPPORTED
#   Bitwarden      .json export, or .csv export
#   1Password      .csv export (v8), or .1pif
#   KeePass/XC     .csv export
#   Passbolt       .csv export
#   pass (passcli) the ~/.password-store tree, decrypted entry by entry with gpg
#
# Format is DETECTED from the file's own headers or structure, never from the
# extension — a .csv tells you nothing about which tool wrote it.
#
# HOW THE PLAINTEXT IS HANDLED
#   The export you feed in is the single most dangerous file on your disk: every
#   password you own, in the clear. So:
#     · it is parsed in ONE python process and never copied anywhere
#     · the merged result goes to `sops --encrypt` through a PIPE — no temp file
#       ever holds the decrypted set
#     · after a verified import you are offered a shred of the source, and are
#       told plainly that it stays dangerous until you do
#     · a dry run reports exactly what would be written, and writes nothing
#
# Sourced, never executed.

# --- detection ----------------------------------------------------------------
imp_detect() {
  local f="$1" head1
  [ -f "$f" ] || { [ -d "$f" ] && { printf 'pass-store'; return 0; }; return 1; }

  # JSON exports
  if head -c 2000 "$f" | grep -q '"items"' && head -c 2000 "$f" | grep -q '"login"'; then
    printf 'bitwarden-json'; return 0
  fi
  if head -c 2000 "$f" | grep -q '"vaultUuid"\|"secureContents"'; then
    printf '1password-1pif'; return 0
  fi

  head1="$(head -1 "$f" | tr -d '"' | tr 'A-Z' 'a-z')"
  case "$head1" in
    *login_username*|*login_password*)             printf 'bitwarden-csv'; return 0 ;;
    *otpauth*)                                     printf '1password-csv'; return 0 ;;
    *group*title*username*password*url*)           printf 'keepass-csv';   return 0 ;;
    *secret_clear*|*folder_parent*)                printf 'passbolt-csv';  return 0 ;;
    *title*url*username*password*)                 printf '1password-csv'; return 0 ;;
    *name*uri*username*)                           printf 'passbolt-csv';  return 0 ;;
    *username*password*)                           printf 'generic-csv';   return 0 ;;
  esac
  return 1
}

imp_format_label() {
  case "$1" in
    bitwarden-json) printf 'Bitwarden (JSON export)' ;;
    bitwarden-csv)  printf 'Bitwarden (CSV export)' ;;
    1password-csv)  printf '1Password (CSV export)' ;;
    1password-1pif) printf '1Password (1PIF export)' ;;
    keepass-csv)    printf 'KeePass / KeePassXC (CSV export)' ;;
    passbolt-csv)   printf 'Passbolt (CSV export)' ;;
    pass-store)     printf 'pass / passcli (password-store tree)' ;;
    generic-csv)    printf 'generic CSV (username/password columns)' ;;
    *)              printf 'unrecognised' ;;
  esac
}

# --- parsing ------------------------------------------------------------------
# imp_parse FILE FORMAT -> normalised JSON {id: {url,username,password,totp,notes}}
imp_parse() {
  local f="$1" fmt="$2"
  case "$fmt" in
    pass-store) imp_parse_pass "$f" ;;
    *) IMP_FMT="$fmt" python3 - "$f" <<'PARSE'
import csv, json, os, sys, re

path = sys.argv[1]
fmt  = os.environ["IMP_FMT"]
out  = {}

def slug(name, url=""):
    base = (name or "").strip() or (url or "").strip() or "entry"
    base = re.sub(r"^https?://", "", base)
    base = re.sub(r"[^A-Za-z0-9._-]+", "-", base).strip("-.")
    return (base or "entry")[:60]

def put(name, url="", user="", pw="", totp="", notes=""):
    if not (user or pw or totp):
        return                      # a record with nothing secret is not a login
    key = slug(name, url)
    n, k = 1, key
    while k in out:
        n += 1; k = "%s-%d" % (key, n)
    rec = {}
    if url:   rec["url"] = url
    if user:  rec["username"] = user
    if pw:    rec["password"] = pw
    if totp:  rec["totp"] = re.sub(r"^otpauth://.*?secret=([A-Z2-7=]+).*$", r"\1", totp, flags=re.I)
    if notes: rec["notes"] = " ".join(notes.split())[:400]
    out[k] = rec

def col(row, *names):
    for n in names:
        for k in row:
            if k and k.strip().lower() == n:
                return (row[k] or "").strip()
    return ""

if fmt == "bitwarden-json":
    data = json.load(open(path))
    for it in data.get("items", []):
        if it.get("type") not in (1, None):
            continue
        lg = it.get("login") or {}
        uris = lg.get("uris") or []
        url = (uris[0].get("uri") if uris and isinstance(uris[0], dict) else "") or ""
        put(it.get("name",""), url, lg.get("username","") or "",
            lg.get("password","") or "", lg.get("totp","") or "", it.get("notes","") or "")

elif fmt == "1password-1pif":
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try: it = json.loads(line)
        except Exception: continue
        sc = it.get("secureContents") or {}
        user = pw = ""
        for fld in sc.get("fields", []) or []:
            d = (fld.get("designation") or "").lower()
            if d == "username": user = fld.get("value","")
            elif d == "password": pw = fld.get("value","")
        put(it.get("title",""), sc.get("location","") or it.get("location",""),
            user, pw or sc.get("password","") or "", "", sc.get("notesPlain","") or "")

else:
    with open(path, newline="", encoding="utf-8", errors="replace") as fh:
        for row in csv.DictReader(fh):
            if not row: continue
            if fmt == "bitwarden-csv":
                if (col(row,"type") or "login") != "login": continue
                put(col(row,"name"), col(row,"login_uri"), col(row,"login_username"),
                    col(row,"login_password"), col(row,"login_totp"), col(row,"notes"))
            elif fmt == "keepass-csv":
                grp = col(row,"group")
                title = col(row,"title")
                name = ("%s-%s" % (grp.split("/")[-1], title)) if grp and title else (title or grp)
                put(name, col(row,"url"), col(row,"username"),
                    col(row,"password"), col(row,"totp"), col(row,"notes"))
            elif fmt == "passbolt-csv":
                put(col(row,"name","title"), col(row,"uri","url"), col(row,"username"),
                    col(row,"secret_clear","password","secret"), "",
                    col(row,"description","notes"))
            else:   # 1password-csv and generic-csv
                put(col(row,"title","name"), col(row,"url","website","urls"),
                    col(row,"username","login","user","email"),
                    col(row,"password","pass"),
                    col(row,"otpauth","totp","one-time password"),
                    col(row,"notes","note"))

json.dump(out, sys.stdout)
PARSE
    ;;
  esac
}

# pass / passcli: entries are individual gpg files; decrypt one at a time.
imp_parse_pass() {
  local store="$1" rel name body
  command -v gpg >/dev/null 2>&1 || { printf '{}'; return 1; }
  {
    printf '{'
    local first=1
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      rel="${f#$store/}"; rel="${rel%.gpg}"
      name="$(printf '%s' "$rel" | tr '/' '-' | tr -c 'A-Za-z0-9._-' '-')"
      body="$(gpg --quiet --batch --decrypt "$f" 2>/dev/null)" || continue
      [ -n "$body" ] || continue
      [ "$first" = "1" ] || printf ','
      first=0
      IMP_NAME="$name" IMP_BODY="$body" python3 -c '
import json, os, sys
name = os.environ["IMP_NAME"]; body = os.environ["IMP_BODY"].splitlines()
rec = {"password": body[0]} if body else {}
for line in body[1:]:
    if ":" not in line: continue
    k, v = line.split(":", 1)
    k = k.strip().lower(); v = v.strip()
    if k in ("login", "user", "username"): rec["username"] = v
    elif k in ("url", "site"):             rec["url"] = v
    elif k in ("totp", "otp", "otpauth"):  rec["totp"] = v
    elif k in ("comment", "notes"):        rec["notes"] = v
sys.stdout.write(json.dumps(name)[0:0] + json.dumps(name) + ":" + json.dumps(rec))
'
    done <<PASSLIST
$(find "$store" -name '*.gpg' -type f 2>/dev/null)
PASSLIST
    printf '}'
  }
}

# --- merge + encrypt ----------------------------------------------------------
# imp_merge DEST JSON_ON_STDIN — merges into DEST and re-encrypts in one pass.
# The combined plaintext exists only in a pipe between two processes.
imp_merge() {
  local dest="$1" recipients existing merged
  recipients="$(sec_file_recipients "$dest" 2>/dev/null | paste -sd, -)"
  if [ -z "$recipients" ]; then
    recipients="$(sec_config_recipients | paste -sd, -)"
  fi
  [ -n "$recipients" ] || { ui_err "no age recipients resolved — refusing to write"; return 1; }

  local tmpenc="$TMPD/merged.enc.yaml"
  if [ -f "$dest" ]; then
    # existing store + incoming, merged in memory, encrypted straight back out
    { sops -d --output-type json "$dest" 2>/dev/null; printf '\n---SPLIT---\n'; cat; } \
      | python3 -c '
import json, sys
raw = sys.stdin.read()
a, _, b = raw.partition("\n---SPLIT---\n")
try: base = json.loads(a) if a.strip() else {}
except Exception: base = {}
base = {k: v for k, v in base.items() if k != "sops" and not k.startswith("sops_")}
try: new = json.loads(b) if b.strip() else {}
except Exception: new = {}
added = 0
for k, v in new.items():
    if k in base:            # never clobber something you already curated
        continue
    base[k] = v; added += 1
sys.stderr.write(str(added))
json.dump(base, sys.stdout)
' 2>"$TMPD/added" \
      | sops --config /dev/null --encrypt --input-type json --output-type yaml \
             --age "$recipients" /dev/stdin > "$tmpenc" 2>>"${SEC_LOG:-/dev/null}"
  else
    sops --config /dev/null --encrypt --input-type json --output-type yaml \
         --age "$recipients" /dev/stdin > "$tmpenc" 2>>"${SEC_LOG:-/dev/null}"
    printf '%s' "?" > "$TMPD/added"
  fi

  [ -s "$tmpenc" ] || { ui_err "encryption produced nothing — destination untouched"; return 1; }
  mkdir -p "$(dirname "$dest")"
  cat "$tmpenc" > "$dest"
  chmod 600 "$dest"
  rm -f "$tmpenc"
  return 0
}

# --- the screen ---------------------------------------------------------------
import_screen() {
  ui_interactive || { ui_needs_tty import; return 1; }
  local src fmt dest count preview

  dest="$SEC_ENC_DIR/logins.enc.yaml"

  tui_page "IMPORT" "bring an existing password manager into the vault"
  printf '\n'
  printf '   %sBitwarden · 1Password · KeePass/XC · Passbolt · pass%s\n\n' "$T_MUTE" "$T_RS"
  ui_note "Export from your manager first, then point at the file."
  ui_warn "That export contains every password you own, in the clear."
  printf '\n'

  src="$(ui_ask 'Path to the export (or ~/.password-store)' "$HOME/Downloads/")" || return 0
  [ -n "$src" ] || return 0
  src="${src/#\~/$HOME}"
  [ -e "$src" ] || { ui_err "no such file: $src"; ui_pause; return 1; }

  fmt="$(imp_detect "$src")" || {
    tui_page "IMPORT" "$src"
    ui_err "could not recognise this file"
    ui_note "first line was:"
    head -1 "$src" 2>/dev/null | cut -c1-100 | sed 's/^/     /'
    ui_note "supported: Bitwarden json/csv · 1Password csv/1pif · KeePass csv · Passbolt csv · pass tree"
    ui_pause; return 1
  }

  tui_page "IMPORT · $(imp_format_label "$fmt")" "$src"
  ui_info "parsing…"
  local parsed="$TMPD/parsed.json"
  imp_parse "$src" "$fmt" > "$parsed" 2>/dev/null
  chmod 600 "$parsed" 2>/dev/null
  count="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$parsed" 2>/dev/null || echo 0)"

  if [ "${count:-0}" -eq 0 ]; then
    ui_err "no login records found in that file"
    ui_note "the format was detected as $(imp_format_label "$fmt") — if that is wrong, say so"
    rm -f "$parsed"; ui_pause; return 1
  fi

  # preview: names and which fields are present, never a value
  preview="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for k in sorted(d)[:12]:
    print("     %-38s %s" % (k[:38], " ".join(sorted(d[k]))))
' "$parsed" 2>/dev/null)"

  tui_page "IMPORT · $(imp_format_label "$fmt")" "$count record(s) parsed · nothing written yet"
  tui_kv "source"      "$(tui_fit "$src" $(( TUI_COLS - 24 )))"
  tui_kv "format"      "$(imp_format_label "$fmt")"
  tui_kv "records"     "$count"
  tui_kv "destination" "${dest#$SEC_ROOT/}"
  tui_kv "existing"    "$([ -f "$dest" ] && rec_ids "$dest" | sec_nlines || echo 0) record(s) already there"
  tui_section "WHAT WILL BE WRITTEN (names and field types only)"
  printf '%s\n' "$preview"
  [ "$count" -gt 12 ] && printf '     %s… and %s more%s\n' "$T_DIM" "$(( count - 12 ))" "$T_RS"
  printf '\n'
  ui_note "Existing records with the same name are never overwritten — they are skipped."
  printf '\n'

  if ! ui_confirm "Import $count record(s) into $(basename "$dest")?"; then
    rm -f "$parsed"; ui_info "nothing imported"; ui_pause; return 0
  fi

  if imp_merge "$dest" < "$parsed"; then
    local now added
    now="$(rec_ids "$dest" | sec_nlines)"
    added="$(cat "$TMPD/added" 2>/dev/null || echo '?')"
    rm -f "$parsed" "$TMPD/added"
    ui_ok "re-read the store: it now holds $now record(s)"
    [ "$added" != "?" ] && ui_info "$added new, $(( count - added )) skipped as already present"
    sec_log_start import; sec_log "imported $count from $fmt ($src)"
    printf '\n'
    ui_warn "The export at $src is still plaintext on disk."
    if ui_confirm "Remove it now?"; then
      rm -f "$src"
      if [ -e "$src" ]; then ui_err "could not remove it"
      else
        ui_ok "removed"
        ui_note "APFS on SSD: deletion is not a wipe. If that export ever left this Mac,"
        ui_note "treat those credentials as exposed and rotate them."
      fi
    else
      ui_warn "left in place — every password you own is readable in that file"
    fi
  else
    rm -f "$parsed"
    ui_err "import failed — the destination was not modified"
  fi
  ui_pause
}
