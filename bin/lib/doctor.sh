#!/usr/bin/env bash
# lib/doctor.sh — the health checks, as data.
#
# There is exactly ONE implementation of every check, `doctor_probe`, which
# emits records and renders nothing. The terminal report and the `--json` output
# are both renderers over those records. The alternative — a pretty version and
# a machine version, each with its own copy of the logic — guarantees that one
# day they disagree, and you will believe whichever one you happened to run.
#
# RECORD FORMAT, one per line, tab-separated:
#   status <TAB> section <TAB> check <TAB> detail
# status is one of: ok | warn | fail | info
# `info` is a fact worth printing that is not a verdict (counts, sizes).
#
# Sourced, never executed.

doc_rec() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}"; }

doctor_probe() {
  local f

  # 1 · Toolchain ------------------------------------------------------------
  if command -v sops >/dev/null 2>&1; then
    doc_rec ok Toolchain "sops present" "$(sops --version 2>/dev/null | head -1 | awk '{print $2}')"
  else
    doc_rec fail Toolchain "sops missing" "nothing can be decrypted without it"
  fi
  if command -v age >/dev/null 2>&1; then
    doc_rec ok Toolchain "age present" "$(age --version 2>/dev/null)"
  else
    doc_rec warn Toolchain "age binary missing" "sops has it built in, but key generation needs the binary"
  fi
  if command -v gum >/dev/null 2>&1; then
    doc_rec ok Toolchain "gum present" "$(gum --version 2>/dev/null | awk '{print $3}') — full visual layer"
  else
    doc_rec warn Toolchain "gum missing" "degraded to plain prompts"
  fi
  if sec_names_have_python; then
    doc_rec ok Toolchain "python3 present" "safe key enumeration is available"
  else
    doc_rec fail Toolchain "python3 missing" "enumeration would degrade to line parsing"
  fi

  # 2 · Decryption -----------------------------------------------------------
  if [ -f "$SOPS_AGE_KEY_FILE" ]; then
    doc_rec ok Decryption "age key present" "$SOPS_AGE_KEY_FILE"
  else
    doc_rec fail Decryption "no age key" "expected at $SOPS_AGE_KEY_FILE"
  fi
  if api_check >/dev/null 2>&1; then
    doc_rec ok Decryption "store decrypts" "the SOPS_SELFTEST canary reads 'ok'"
  else
    doc_rec fail Decryption "store did NOT decrypt on this host" "the key present cannot open this store"
  fi

  # 3 · Recipients -----------------------------------------------------------
  sec_config_recipients > "$TMPD/cfgrec" 2>/dev/null || : > "$TMPD/cfgrec"
  sec_file_recipients "$SEC_STORE" > "$TMPD/filerec" 2>/dev/null || : > "$TMPD/filerec"
  local nc nf
  nc="$(sec_nlines < "$TMPD/cfgrec")"; nf="$(sec_nlines < "$TMPD/filerec")"
  doc_rec info Recipients "declared in .sops.yaml" "$nc age recipient(s)"
  doc_rec info Recipients "carried on the store"   "$nf age recipient(s)"
  if [ "$nc" = "$nf" ] && [ -z "$(comm -3 "$TMPD/cfgrec" "$TMPD/filerec" 2>/dev/null)" ]; then
    doc_rec ok Recipients "store recipients match .sops.yaml" ""
  else
    local only_cfg only_file
    only_cfg="$(comm -23 "$TMPD/cfgrec" "$TMPD/filerec" 2>/dev/null | tr '\n' ' ')"
    only_file="$(comm -13 "$TMPD/cfgrec" "$TMPD/filerec" 2>/dev/null | tr '\n' ' ')"
    doc_rec fail Recipients "DRIFT between .sops.yaml and the store" \
      "declared-not-on-file: ${only_cfg:-none}; on-file-not-declared: ${only_file:-none}; fix with: sops updatekeys $SEC_STORE"
  fi

  # 4 · Store integrity ------------------------------------------------------
  local n ml
  n="$(sec_count)"
  doc_rec ok "Store integrity" "$n credentials enumerate cleanly" ""
  ml="$(sec_multiline_names 2>/dev/null | sec_nlines)"
  if [ "${ml:-0}" -gt 0 ]; then
    doc_rec warn "Store integrity" "$ml value(s) contain newlines" \
      "enumeration is JSON-based so reading is safe, but dotenv EDITING of those keys mangles them — use the certs or keys module"
  else
    doc_rec ok "Store integrity" "no multi-line values" "dotenv format is safe here"
  fi

  # 5 · Documentation coverage ----------------------------------------------
  sec_manifest_keys > "$TMPD/mk" 2>/dev/null || : > "$TMPD/mk"
  sec_names > "$TMPD/sk" 2>/dev/null || : > "$TMPD/sk"
  local undoc doc pct
  undoc="$(comm -23 "$TMPD/sk" "$TMPD/mk" 2>/dev/null | sec_nlines)"
  doc=$(( n - undoc )); pct=0; [ "$n" -gt 0 ] && pct=$(( doc * 100 / n ))
  doc_rec info Documentation "coverage" "$doc of $n ($pct%)"
  if [ "$undoc" -gt 0 ]; then
    doc_rec warn Documentation "$undoc credential(s) have no manifest entry" \
      "an undocumented credential cannot be rotated, because nobody knows what breaks"
  else
    doc_rec ok Documentation "every credential is documented" ""
  fi

  # 6 · Expiry ---------------------------------------------------------------
  # do_expiring calls sec_die when there is no manifest, which would exit the
  # whole program mid-report. A health check must survive an unhealthy store.
  if [ ! -f "$SEC_MANIFEST" ]; then
    doc_rec warn Expiry "no credential manifest yet" "run: secretsd manifest"
  elif ( do_expiring 14 >/dev/null 2>&1 ); then
    doc_rec ok Expiry "nothing due within 14 days" "full expiry coverage"
  else
    doc_rec warn Expiry "expiry report is not clear" "run: secretsd expiring"
  fi

  # 7 · Plaintext hygiene ----------------------------------------------------
  local stray=0
  for f in "$SEC_SECRETS"/* "$SEC_SECRETS"/.[!.]*; do
    [ -f "$f" ] || continue
    case "$f" in *.enc.env|*.enc.yaml|*.enc.json|*.md|*.yaml|*.bak-*|*.selftest-only.bak) continue ;; esac
    if [ -s "$f" ] && ! grep -q 'sops_' "$f" 2>/dev/null && grep -qE '^[A-Za-z_][A-Za-z0-9_]*=' "$f" 2>/dev/null; then
      doc_rec fail Hygiene "PLAINTEXT credential file" "$f"
      stray=$((stray+1))
    fi
  done
  [ "$stray" -eq 0 ] && doc_rec ok Hygiene "no plaintext credential files in secrets/" ""

  # A sync tool that copies your data root somewhere else is the single most
  # common way an encrypted store ends up somewhere it should not be.
  if [ -d "$SEC_ROOT/.git" ] || git -C "$SEC_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    if git -C "$SEC_ROOT" check-ignore -q secrets 2>/dev/null; then
      doc_rec ok Hygiene "data root is under git, and secrets/ is ignored" ""
    else
      doc_rec fail Hygiene "data root is under git and secrets/ is NOT ignored" \
        "add 'secrets/' to .gitignore before you ever commit"
    fi
  else
    doc_rec ok Hygiene "the data root is not a git repository" ""
  fi
  case "$SEC_ROOT" in
    "$HOME"/Dropbox/*|"$HOME"/Library/CloudStorage/*|"$HOME"/"Google Drive"/*|*/iCloud*/*)
      doc_rec warn Hygiene "data root sits inside a cloud-synced folder" \
        "encrypted blobs stay encrypted, but the sync provider gets a copy of everything" ;;
  esac

  if [ -f "$SEC_ROTATE" ]; then
    local pending; pending="$(grep -c '^- \[ \]' "$SEC_ROTATE" 2>/dev/null || true)"
    pending="${pending:-0}"
    if [ "$pending" -gt 0 ]; then
      doc_rec warn Hygiene "$pending credential(s) pending rotation after exposure" "see $SEC_ROTATE"
    else
      doc_rec ok Hygiene "exposure rotation worklist is fully cleared" ""
    fi
  fi

  # 8 · Housekeeping ---------------------------------------------------------
  local nlogs sz
  nlogs="$(find "$SEC_ROOT/run-logs" -maxdepth 1 -type f -name '*.log' 2>/dev/null | wc -l | tr -d ' ')"
  sz="$(du -sh "$SEC_ROOT/run-logs" 2>/dev/null | awk '{print $1}')"
  doc_rec info Housekeeping "run-logs" "${nlogs:-0} files, ${sz:-0}"
  if [ "${nlogs:-0}" -gt 1000 ]; then
    doc_rec warn Housekeeping "run-logs is large" "prune with: secretsd logs prune"
  else
    doc_rec ok Housekeeping "run-log volume is sane" ""
  fi
}

# --- renderer: the terminal report -------------------------------------------
# Returns 1 on any failure, 2 on warnings only, 0 clean — the same contract the
# JSON renderer uses, so a script and a human get the same verdict.
do_doctor() {
  local fails=0 warns=0 section="" st sec chk det

  ui_clear
  ui_panel "🩺  secrets doctor" "$(hostname -s) · $(date -u +%FT%TZ)"

  doctor_probe > "$TMPD/doctor.rec"

  while IFS=$'\t' read -r st sec chk det; do
    [ -n "$st" ] || continue
    if [ "$sec" != "$section" ]; then section="$sec"; ui_rule "$section"; fi
    case "$st" in
      ok)   ui_ok   "$chk${det:+ — $det}" ;;
      warn) ui_warn "$chk"; [ -n "$det" ] && ui_note "$det"; warns=$((warns+1)) ;;
      fail) ui_err  "$chk"; [ -n "$det" ] && ui_note "$det"; fails=$((fails+1)) ;;
      info) printf '  %s: %s\n' "$chk" "$det" ;;
    esac
  done < "$TMPD/doctor.rec"

  ui_rule "Verdict"
  if [ "$fails" -gt 0 ]; then
    ui_err "$fails failure(s), $warns warning(s) — this store is NOT healthy"
    return 1
  elif [ "$warns" -gt 0 ]; then
    ui_warn "0 failures, $warns warning(s) — working, with gaps worth closing"
    return 0
  else
    ui_ok "everything checked out"
    return 0
  fi
}
