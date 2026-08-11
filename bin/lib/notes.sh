#!/usr/bin/env bash
# lib/notes.sh — writing back into your knowledge base.
#
# This is the half the whole design argues for and, until now, did not exist.
# secretsd knew which note system you kept, and wrote reports into its own
# directory where nobody would ever read them again.
#
# A knowledge base earns its keep when the thing that knows the facts writes them
# down. So: profile reports, the credential inventory, the access map, the
# session index and the posture report all publish into your vault as ordinary
# notes — with frontmatter, tags and backlinks, so they behave like notes you
# wrote rather than files something dumped.
#
# WHAT IS NEVER PUBLISHED
#   No secret value, ever. Not masked, not truncated, not "just the first four
#   characters". The notes carry NAMES, purposes, relationships and dates. That
#   is precisely what makes them safe to sync, share and search — and it is why
#   the directory tier exists at all.
#
# BACKENDS
#   obsidian     markdown files in the vault (fully wired)
#   plaintext    a directory of markdown — Notepad, or any editor
#   apple-notes  via osascript, into a named folder
#   joplin       via the local clipper REST API on 127.0.0.1:41184
#   cherrytree   writes a CherryTree XML document (.ctd) that CherryTree opens
#                and imports directly. It does NOT write into a .ctb, which is a
#                live SQLite database: writing into a document the application
#                has open is how you corrupt somebody's whole notebook.
#   notion       via the official REST API. Hosted, so it needs egress and a
#                token — and it is the ONE backend that sends anything off this
#                machine, which is stated plainly on the screen before you pair.
#
# Sourced, never executed.

NOTES_SUBDIR="${NOTES_SUBDIR:-secretsd}"

notes_system() { pkm_get system; }
notes_vault()  { pkm_get vault; }

notes_backend_ready() {
  case "$(notes_system)" in
    obsidian)    [ -n "$(notes_vault)" ] && [ -d "$(notes_vault)" ] ;;
    plaintext)   [ -n "$(notes_vault)" ] ;;
    apple-notes) command -v osascript >/dev/null 2>&1 ;;
    joplin)      curl -sS --max-time 2 "http://127.0.0.1:41184/ping" 2>/dev/null | ui_match_sub JoplinClipperServer ;;
    cherrytree)  [ -n "$(notes_vault)" ] ;;
    notion)      [ -n "$(pkm_get notion_parent)" ] && sec_has "$(notes_notion_keyname)" ;;
    *)           return 1 ;;
  esac
}

notes_target_desc() {
  case "$(notes_system)" in
    obsidian)    printf '%s/%s' "$(notes_vault)" "$NOTES_SUBDIR" ;;
    plaintext)   printf '%s/%s' "$(notes_vault)" "$NOTES_SUBDIR" ;;
    apple-notes) printf 'Apple Notes → folder "%s"' "$NOTES_SUBDIR" ;;
    joplin)      printf 'Joplin → notebook "%s"' "$NOTES_SUBDIR" ;;
    cherrytree)  printf '%s/%s.ctd  (open or import in CherryTree)' "$(notes_vault)" "$NOTES_SUBDIR" ;;
    notion)      printf 'Notion → page %s  (leaves this machine)' "$(pkm_get notion_parent)" ;;
    *)           printf 'nothing paired' ;;
  esac
}

notes_slug() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//'; }


# --- publish-time redaction ---------------------------------------------------
# A note is only safe to sync if it contains no value from your vault. Intent is
# not enough: the access map publishes HostName and User straight out of
# ~/.ssh/config, and if you also keep that IP or that username as a credential
# then a document that never touched the vault still ends up carrying a value
# you chose to encrypt. That is exactly what happened the first time this ran.
#
# So every document is checked against the ACTUAL store values immediately before
# publishing. Any match is replaced with the key NAME. The comparison happens
# inside one injected child; only key names ever come back out.
notes_redact() {   # $1 document path -> rewrites in place, prints keys redacted
  local doc="$1" script="$TMPD/redact.py"
  cat > "$script" <<'PY'
import os, sys
path = os.environ["REDACT_DOC"]
body = open(path).read()
hits = []
for k, v in os.environ.items():
    if not k.isupper() or not v or len(v) < 8:
        continue
    if k in ("PATH","HOME","SHELL","PWD","LANG","TERM","TMPDIR","REDACT_DOC",
             "SEC_ROOT","SEC_BIN","TMPD","SEC_SELF","OLDPWD","SHLVL","_"):
        continue
    if v in body:
        body = body.replace(v, "«redacted — value of %s»" % k)
        hits.append(k)
open(path, "w").write(body)
for h in sorted(set(hits)):
    sys.stdout.write(h + "\n")
PY
  REDACT_DOC="$doc" "$SEC_SELF" run -- python3 "$script" 2>/dev/null
  rm -f "$script"
}

# notes_write TITLE TAGS BODYFILE -> prints where it landed
notes_write() {
  local title="$1" tags="$2" body="$3" sys dir out slug redacted
  sys="$(notes_system)"

  # never publish a document that carries a value from the vault
  redacted="$(notes_redact "$body")"
  if [ -n "$redacted" ]; then
    ui_warn "redacted $(printf '%s' "$redacted" | sec_nlines) vault value(s) before publishing:"
    printf '%s\n' "$redacted" | sed 's/^/       /' >&2
  fi
  slug="$(notes_slug "$title")"

  case "$sys" in
    obsidian|plaintext)
      dir="$(notes_vault)/$NOTES_SUBDIR"
      mkdir -p "$dir" || { ui_err "cannot write to $dir"; return 1; }
      out="$dir/$slug.md"
      {
        # Obsidian reads YAML frontmatter; a plain editor just sees a header.
        printf -- '---\n'
        printf 'title: %s\n' "$title"
        printf 'created: %s\n' "$(date -u +%FT%TZ)"
        printf 'host: %s\n' "$(hostname -s 2>/dev/null)"
        printf 'source: secretsd\n'
        printf 'tags: [%s]\n' "$tags"
        printf -- '---\n\n'
        cat "$body"
        printf '\n\n---\n'
        printf '*Written by `secretsd` on %s. Contains names and relationships only — no secret values.*\n' \
          "$(hostname -s 2>/dev/null)"
      } > "$out"
      chmod 600 "$out"
      printf '%s' "$out" ;;

    apple-notes)
      # osascript needs the body as HTML; convert the essentials and escape quotes
      local html
      html="$(python3 - "$body" "$title" <<'PY'
import html, sys, re
title = sys.argv[2]
text  = open(sys.argv[1]).read()
out = ["<h1>%s</h1>" % html.escape(title)]
for line in text.split("\n"):
    e = html.escape(line)
    if   line.startswith("### "): out.append("<h3>%s</h3>" % e[4:])
    elif line.startswith("## "):  out.append("<h2>%s</h2>" % e[3:])
    elif line.startswith("# "):   out.append("<h1>%s</h1>" % e[2:])
    elif line.startswith("- "):   out.append("<li>%s</li>" % e[2:])
    elif not line.strip():        out.append("<br>")
    else:                         out.append("<div>%s</div>" % e)
body = "".join(out)
# AppleScript string literal: escape backslashes then quotes
print(body.replace("\\", "\\\\").replace('"', '\\"'))
PY
)"
      osascript >/dev/null 2>&1 <<OSA
tell application "Notes"
  if not (exists folder "$NOTES_SUBDIR") then make new folder with properties {name:"$NOTES_SUBDIR"}
  make new note at folder "$NOTES_SUBDIR" with properties {body:"$html"}
end tell
OSA
      [ $? -eq 0 ] || { ui_err "Apple Notes refused the note"; return 1; }
      printf 'Apple Notes → %s → %s' "$NOTES_SUBDIR" "$title" ;;

    joplin)
      local token payload
      token="$(pkm_get joplin_token)"
      [ -n "$token" ] || { ui_err "no Joplin API token recorded"; return 1; }
      payload="$(python3 -c '
import json,sys
print(json.dumps({"title": sys.argv[1], "body": open(sys.argv[2]).read()}))' "$title" "$body")"
      curl -sS --max-time 5 -X POST \
        "http://127.0.0.1:41184/notes?token=$token" \
        -H 'Content-Type: application/json' --data "$payload" >/dev/null 2>&1 \
        || { ui_err "Joplin API refused the note"; return 1; }
      printf 'Joplin → %s' "$title" ;;

    cherrytree)
      # A .ctd is CherryTree's XML document format. Writing one is safe at any
      # time; writing into a .ctb — a live SQLite database the application may
      # have open — is not, and no amount of care makes it safe, so this does
      # not offer to.
      #
      # Each publish REPLACES the node of the same name rather than appending,
      # so re-publishing the inventory does not leave you with nine copies of it
      # to tell apart.
      dir="$(notes_vault)"
      mkdir -p "$dir" || { ui_err "cannot write to $dir"; return 1; }
      out="$dir/$NOTES_SUBDIR.ctd"
      python3 - "$out" "$title" "$body" "$(hostname -s 2>/dev/null)" <<'PY_CT' || {
import html, os, re, sys, xml.etree.ElementTree as ET

path, title, bodyfile, host = sys.argv[1:5]
text = open(bodyfile, encoding="utf-8", errors="replace").read()

if os.path.exists(path):
    try:
        tree = ET.parse(path); root = tree.getroot()
    except Exception:
        root = ET.Element("cherrytree")
else:
    root = ET.Element("cherrytree")

# replace any node with this title — publishing twice must not duplicate
for existing in list(root.findall("node")):
    if existing.get("name") == title:
        root.remove(existing)

used = {int(n.get("unique_id", 0)) for n in root.iter("node") if (n.get("unique_id") or "").isdigit()}
uid = 1
while uid in used:
    uid += 1

node = ET.SubElement(root, "node", {
    "name": title,
    "unique_id": str(uid),
    "prog_lang": "custom-colors",
    "tags": "secretsd",
    "readonly": "0",
    "nosearch_me": "0",
    "nosearch_ch": "0",
    "custom_icon_id": "0",
    "is_bold": "0",
    "foreground": "",
    "ts_creation": "0",
    "ts_lastsave": "0",
})
rt = ET.SubElement(node, "rich_text")
rt.text = text + "\n\nWritten by secretsd on %s. Names and relationships only — no secret values.\n" % host

ET.ElementTree(root).write(path, encoding="UTF-8", xml_declaration=True)
PY_CT
        ui_err "could not write the CherryTree document"; return 1; }
      chmod 600 "$out"
      printf '%s' "$out" ;;

    notion)
      # The ONLY backend that sends anything off this machine. The token is
      # injected into one curl and never printed, never exported, never written
      # to the run log — the same contract as every other value in this program.
      local parent keyname
      parent="$(pkm_get notion_parent)"
      keyname="$(notes_notion_keyname)"
      [ -n "$parent" ] || { ui_err "no Notion parent page recorded — run: secretsd pkm"; return 1; }
      sec_has "$keyname" || { ui_err "no $keyname in the vault"; return 1; }

      python3 - "$body" "$title" "$parent" > "$TMPD/notion.json" <<'PY_NO'
import json, sys
title, parent = sys.argv[2], sys.argv[3]
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()

def rt(s):
    return [{"type": "text", "text": {"content": s[:1900]}}]

blocks = []
for line in text.split("\n"):
    if not line.strip():
        continue
    if line.startswith("### "):
        blocks.append({"object": "block", "type": "heading_3",
                       "heading_3": {"rich_text": rt(line[4:])}})
    elif line.startswith("## "):
        blocks.append({"object": "block", "type": "heading_2",
                       "heading_2": {"rich_text": rt(line[3:])}})
    elif line.startswith("- ") or line.startswith("* "):
        blocks.append({"object": "block", "type": "bulleted_list_item",
                       "bulleted_list_item": {"rich_text": rt(line[2:])}})
    else:
        blocks.append({"object": "block", "type": "paragraph",
                       "paragraph": {"rich_text": rt(line)}})
    if len(blocks) >= 95:            # Notion caps children per request at 100
        break

print(json.dumps({
    "parent": {"page_id": parent},
    "properties": {"title": {"title": rt(title)}},
    "children": blocks,
}))
PY_NO

      local rc
      SEC_NOTION_PAYLOAD="$TMPD/notion.json" \
      "$SEC_SELF" run --only "$keyname" -- sh -c '
        code=$(curl -sS --max-time 15 -o "$SEC_NOTION_PAYLOAD.out" -w "%{http_code}" \
          -X POST https://api.notion.com/v1/pages \
          -H "Authorization: Bearer ${'"$keyname"'}" \
          -H "Notion-Version: 2022-06-28" \
          -H "Content-Type: application/json" \
          --data @"$SEC_NOTION_PAYLOAD")
        [ "$code" = "200" ] || { echo "$code" > "$SEC_NOTION_PAYLOAD.code"; exit 1; }
      ' >/dev/null 2>&1
      rc=$?
      if [ "$rc" -ne 0 ]; then
        ui_err "Notion refused the page$( [ -f "$TMPD/notion.json.code" ] && printf ' (HTTP %s)' "$(cat "$TMPD/notion.json.code")" )"
        [ -f "$TMPD/notion.json.out" ] && \
          ui_note "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("message","")[:160])' "$TMPD/notion.json.out" 2>/dev/null)"
        return 1
      fi
      printf 'Notion → %s' "$title" ;;

    *) ui_err "no note backend is paired — run: secretsd pkm"; return 1 ;;
  esac
}

# The Notion integration token, by name. Kept in the vault like everything else,
# so it is injected into one curl and never appears in a process listing.
notes_notion_keyname() { printf '%s' "${SECRETSD_NOTION_KEY:-NOTION_TOKEN}"; }

# --- the documents it can publish ---------------------------------------------

notes_doc_inventory() {   # credential inventory: names, purpose, dates. No values.
  local out="$TMPD/doc.md" n
  {
    printf '## Credential inventory\n\n'
    printf 'Every credential this host holds, by name. **No values appear here.**\n\n'
    printf '| Name | Provider | Used by | Expires | Rotated |\n|---|---|---|---|---|\n'
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      printf '| `%s` | %s | %s | %s | %s |\n' "$n" \
        "$(sec_manifest_field "$n" provider    | sed 's/^TODO$/—/;s/^$/—/')" \
        "$(sec_manifest_field "$n" used_by     | sed 's/^TODO$/—/;s/^$/—/')" \
        "$(sec_manifest_field "$n" expires     | sed 's/^TODO$/—/;s/^$/—/')" \
        "$(sec_manifest_field "$n" rotated     | sed 's/^$/never/')"
    done <<INV
$(sec_names)
INV
    printf '\n%s credentials. Undocumented entries show — and are worth filling in;\n' "$(sec_count)"
    printf 'you cannot rotate or revoke what you cannot state the purpose of.\n'
  } > "$out"
  printf '%s' "$out"
}

notes_doc_access() {   # the access map: hosts, keys, methods. Still no values.
  local out="$TMPD/doc.md" p
  {
    printf '## Access map\n\n'
    printf 'How this host reaches what it reaches. Read this without decrypting anything.\n\n'
    printf '### SSH keys\n\n| Key | Type | Passphrase | Used by |\n|---|---|---|---|\n'
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      printf '| `%s` | %s %s | %s | %s |\n' "$(basename "$p")" "$(keys_type "$p")" "$(keys_bits "$p")" \
        "$(keys_has_passphrase "$p" && echo 'protected' || echo '**none**')" \
        "$(keys_hosts_using "$p" | sed 's/^$/—/')"
    done <<AK
$(keys_private_paths)
AK
    printf '\n### Configured hosts\n\n| Alias | Hostname | User | Port | Key |\n|---|---|---|---|---|\n'
    mach_hosts | while IFS='|' read -r a hn u pt idf; do
      [ -n "$a" ] || continue
      printf '| `%s` | %s | %s | %s | %s |\n' "$a" "${hn:-$a}" "${u:-—}" "${pt:-22}" "$([ -n "$idf" ] && basename "$idf" || echo '—')"
    done
  } > "$out"
  printf '%s' "$out"
}

notes_doc_posture() {
  local out="$TMPD/doc.md"
  {
    printf '## Security posture\n\n'
    printf 'Findings as of %s on `%s`.\n\n' "$(date -u +%FT%TZ)" "$(hostname -s)"
    printf '| Severity | Finding | Detail |\n|---|---|---|\n'
    posture_scan_cached 2>/dev/null | sort -t'|' -k1,1 | while IFS='|' read -r sev id kind title detail target; do
      [ -n "$id" ] || continue
      printf '| %s | %s | %s |\n' "$sev" "$title" "$(printf '%s' "$detail" | sed 's/|/\\|/g')"
    done
    printf '\nRun `secretsd posture` to act on any of these. Nothing is changed without you.\n'
  } > "$out"
  printf '%s' "$out"
}

notes_doc_sessions() {
  local out="$TMPD/doc.md" u
  {
    printf '## Named sessions\n\n'
    printf 'Human names for Claude Code sessions, so a note can cite the conversation\n'
    printf 'where a decision was actually made rather than a UUID nobody can resolve.\n\n'
    printf '| Name | Project | Started | Mode |\n|---|---|---|---|\n'
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      printf '| %s | %s | %s | %s |\n' \
        "$(ws_session_field "$u" name)" "$(ws_session_field "$u" project)" \
        "$(ws_session_field "$u" started)" "$(ws_session_field "$u" mode)"
    done <<SS
$(ws_session_ids)
SS
  } > "$out"
  printf '%s' "$out"
}

# --- the screen ---------------------------------------------------------------
notes_screen() {
  ui_interactive || { ui_needs_tty notes; return 1; }

  local sys; sys="$(notes_system)"
  if [ -z "$sys" ] || [ "$sys" = "none" ]; then
    tui_page "PUBLISH TO NOTES" "no knowledge system paired"
    ui_note "pair one first — it takes one keypress:"
    printf '\n     %ssecretsd pkm%s\n\n' "$T_ACCENT" "$T_RS"
    ui_pause; return 0
  fi

  if ! notes_backend_ready; then
    tui_page "PUBLISH TO NOTES" "$sys is paired but not reachable"
    case "$sys" in
      obsidian|plaintext) ui_err "vault path not found: $(notes_vault)" ;;
      apple-notes)        ui_err "osascript unavailable — is this macOS?" ;;
      joplin)             ui_err "Joplin clipper API not answering on 127.0.0.1:41184"
                          ui_note "enable it: Joplin → Tools → Options → Web Clipper" ;;
      cherrytree)         ui_err "no folder set for the CherryTree document"
                          ui_note "run: secretsd pkm — and choose where the .ctd should live" ;;
      notion)             ui_err "Notion is not fully set up"
                          ui_note "needs a parent page id and $(notes_notion_keyname) in the vault"
                          ui_note "run: secretsd pkm" ;;
      *)                  ui_err "no note system is paired"
                          ui_note "all six are wired: Obsidian, plain markdown, Apple Notes,"
                          ui_note "Joplin, CherryTree and Notion — run: secretsd pkm" ;;
    esac
    ui_pause; return 0
  fi

  local act doc title tags where
  while :; do
    TUI_MENU_ICON=notes
    TUI_MENU_PANEL="$(
      {
        printf 'note system\t%s\t%s\n' "$sys" "$T_TEXT"
        printf 'destination\t%s\t%s\n' "$(notes_target_desc)" "$T_TEXT"
        printf 'contains\tnames, purposes, relationships\t%s\n' "$T_OK"
        printf 'never contains\ta credential value, redacted at publish time\t%s\n' "$T_OK"
      } | tui_kvgroup
    )"

    act="$(tui_menu "PUBLISH TO NOTES" "no secret values leave the vault — that is what makes this safe to sync" \
      "Credential inventory|every credential by name, with purpose and expiry" \
      "Access map|SSH keys, which hosts use them, and every configured host" \
      "Security posture|current findings, so the vault records what needed fixing" \
      "Session index|human names for Claude sessions, citable from any note" \
      "Latest profile report|the most recent Cross-Utility / Convention / Debt report" \
      "Publish all of them|one pass, four or five notes" \
      "Back|change nothing")" || break

    case "$act" in
      "Credential inventory") doc="$(notes_doc_inventory)"; title="Credential inventory — $(hostname -s)"; tags="secretsd, credentials, inventory" ;;
      "Access map")           doc="$(notes_doc_access)";    title="Access map — $(hostname -s)";           tags="secretsd, access, ssh" ;;
      "Security posture")     doc="$(notes_doc_posture)";   title="Security posture — $(hostname -s)";     tags="secretsd, security, posture" ;;
      "Session index")        doc="$(notes_doc_sessions)";  title="Session index — $(hostname -s)";        tags="secretsd, sessions, claude" ;;
      "Latest profile report")
        local latest
        latest="$(ls -1t "$PROF_REPORTS"/*.md 2>/dev/null | head -1)"
        if [ -z "$latest" ]; then
          tui_page "NO REPORT YET" "run a profile first"
          ui_note "secretsd profiles → Cross-Utility Scout, Convention Warden, …"
          ui_pause; continue
        fi
        doc="$latest"; title="$(basename "${latest%.md}") — $(hostname -s)"; tags="secretsd, report, sessions" ;;
      "Publish all of them")
        tui_page "PUBLISHING" "$(notes_target_desc)"
        printf '\n'
        local ok=0
        for pair in "inventory:Credential inventory:credentials" \
                    "access:Access map:access" \
                    "posture:Security posture:security" \
                    "sessions:Session index:sessions"; do
          local fn="${pair%%:*}"; local rest="${pair#*:}"
          local t="${rest%%:*}"; local tg="${rest#*:}"
          printf '   %-26s ' "$t"
          doc="$(notes_doc_$fn)"
          if where="$(notes_write "$t — $(hostname -s)" "secretsd, $tg" "$doc")"; then
            ok=$(( ok + 1 )); printf '%s%s%s\n' "$T_OK" "published" "$T_RS"
          else printf '%sfailed%s\n' "$T_ERR" "$T_RS"; fi
        done
        printf '\n'
        ui_ok "$ok of 4 published to $(notes_target_desc)"
        sec_log_start notes; sec_log "published $ok notes to $sys"
        ui_pause; continue ;;
      *) break ;;
    esac

    tui_page "PUBLISH · $title" "$(notes_target_desc)"
    printf '\n'
    ui_info "preview (first 14 lines):"
    head -14 "$doc" | sed 's/^/     /'
    printf '\n'
    ui_note "No secret values appear in this note — only names and relationships."
    printf '\n'
    if ui_confirm "Publish it?"; then
      if where="$(notes_write "$title" "$tags" "$doc")"; then
        ui_ok "written to $where"
        sec_log_start notes; sec_log "published '$title' to $sys"
      fi
    else ui_info "not published"; fi
    ui_pause
  done
  return 0
}
