#!/usr/bin/env bash
# lib/recovery.sh — the recovery kit, and proving it works.
#
# THE PROBLEM NOBODY PLANS FOR
#   Every vault here is encrypted to an age key that exists in exactly one file.
#   Lose `~/.config/sops/age/keys.txt` and every credential you own becomes
#   permanently unreadable. Not "call support" unreadable — mathematically gone.
#   Disk failure, a bad restore, an OS reinstall, a `rm` in the wrong directory.
#
#   Most people know this and still have no backup, because making one means
#   deciding where to put the most dangerous file they own.
#
# WHAT A KIT IS
#   One passphrase-encrypted archive containing the age identity, every
#   encrypted store, and the plaintext metadata needed to make sense of them.
#   It is encrypted with age's passphrase mode — NOT with the key it contains,
#   which would be a circular lock — so it can be opened with something you
#   remember on a machine that has nothing.
#
# THE PART THAT MATTERS
#   A backup you have not restored is a rumour. Building a kit is followed
#   immediately by a REAL restore into a throwaway directory, decrypting a real
#   value out of the restored store with the restored key. If that fails, the kit
#   is deleted rather than kept, because a kit that does not restore is worse
#   than no kit — it stops you looking for a real one.
#
# Sourced, never executed.

REC_DEFAULT_DIR="${REC_DEFAULT_DIR:-$HOME/Documents}"

rec_kit_manifest() {
  printf 'secretsd recovery kit\n'
  printf 'created:  %s\n' "$(date -u +%FT%TZ)"
  printf 'host:     %s\n' "$(hostname -s 2>/dev/null)"
  printf 'user:     %s\n' "$(id -un)"
  printf 'data root %s\n' "$SEC_ROOT"
  printf '\ncontents:\n'
  printf '  keys.txt              the age identity — THIS is what everything depends on\n'
  printf '  secrets/              every encrypted store, exactly as it is on disk\n'
  printf '  .sops.yaml            which recipients each store is encrypted to\n'
  printf '  metadata/             manifest, provenance, sessions, conventions (no values)\n'
  printf '\nto restore on a machine with sops and age installed:\n'
  printf '  age -d -o kit.tar kit.age      # you will be asked for the passphrase\n'
  printf '  tar xf kit.tar\n'
  printf '  mkdir -p ~/.config/sops/age && cp keys.txt ~/.config/sops/age/keys.txt\n'
  printf '  chmod 600 ~/.config/sops/age/keys.txt\n'
  printf '  export SECRETSD_HOME=$PWD\n'
  printf '  secretsd check\n'
}

# rec_build DEST — build a kit, then restore it to prove it. Echoes the path.
rec_build() {
  local dest="$1" stage="$TMPD/kit" kit tarball
  local keyfile="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

  [ -f "$keyfile" ] || { ui_err "no age identity at $keyfile — nothing to protect"; return 1; }

  rm -rf "$stage"; mkdir -p "$stage/secrets" "$stage/metadata"; chmod -R 700 "$stage"

  ui_info "collecting the identity"
  cp "$keyfile" "$stage/keys.txt" && chmod 600 "$stage/keys.txt"

  ui_info "collecting encrypted stores"
  local f n=0
  for f in "$SEC_SECRETS"/*.enc.* "$SEC_ENC_DIR"/*.enc.*; do
    [ -f "$f" ] || continue
    mkdir -p "$stage/secrets/$(dirname "${f#$SEC_SECRETS/}")" 2>/dev/null
    cp "$f" "$stage/secrets/${f#$SEC_SECRETS/}" 2>/dev/null && n=$(( n + 1 ))
  done
  ui_ok "$n encrypted store(s)"

  [ -f "$SEC_ROOT/.sops.yaml" ] && cp "$SEC_ROOT/.sops.yaml" "$stage/.sops.yaml"

  ui_info "collecting metadata (no secret values)"
  for f in CREDENTIALS.yaml PROVENANCE.yaml SESSIONS.yaml CONVENTIONS.yaml \
           PROJECTS.yaml VAULTS.yaml PKM.yaml ROTATE-THESE.md; do
    [ -f "$SEC_SECRETS/$f" ] && cp "$SEC_SECRETS/$f" "$stage/metadata/$f"
  done
  [ -d "$SEC_DIR_DIR" ] && cp -R "$SEC_DIR_DIR" "$stage/metadata/directory" 2>/dev/null
  rec_kit_manifest > "$stage/README.txt"

  tarball="$TMPD/kit.tar"
  ( cd "$stage" && tar cf "$tarball" . ) || { ui_err "could not archive"; return 1; }

  printf '\n'
  ui_note "The kit is encrypted with a PASSPHRASE, not with the key inside it."
  ui_note "Choose something you can reproduce from memory in a bad week."
  ui_warn "There is no recovery for this passphrase either. Write it down somewhere physical."
  printf '\n'

  kit="$dest/secretsd-recovery-$(date +%Y%m%d-%H%M%S).age"
  mkdir -p "$dest" 2>/dev/null
  if ! age --passphrase -o "$kit" "$tarball" </dev/tty; then
    rm -f "$kit" "$tarball"; rm -rf "$stage"
    ui_err "encryption failed or was cancelled — no kit was written"
    return 1
  fi
  chmod 600 "$kit"
  rm -f "$tarball"; rm -rf "$stage"
  printf '%s' "$kit"
}

# rec_verify KIT — a REAL restore into a throwaway root. Returns 0 only if a
# value actually decrypts using the restored identity.
rec_verify() {
  local kit="$1" work="$TMPD/verify" out
  rm -rf "$work"; mkdir -p "$work"; chmod 700 "$work"

  ui_info "decrypting the kit (you will be asked for the passphrase again)"
  if ! age -d -o "$work/kit.tar" "$kit" </dev/tty; then
    ui_err "the kit did not decrypt with that passphrase"
    return 1
  fi
  ( cd "$work" && tar xf kit.tar ) || { ui_err "the archive is corrupt"; return 1; }
  rm -f "$work/kit.tar"

  [ -f "$work/keys.txt" ] || { ui_err "no identity in the kit"; return 1; }
  ui_ok "archive opens, identity present"

  local store
  store="$(ls "$work"/secrets/*.enc.env "$work"/secrets/*.enc.yaml 2>/dev/null | head -1)"
  [ -n "$store" ] || { ui_err "no encrypted store in the kit"; return 1; }

  # the actual test: restored key, restored store, real decryption
  out="$(SOPS_AGE_KEY_FILE="$work/keys.txt" sops exec-env "$store" \
        'printf %s "${SOPS_SELFTEST:-decrypted}"' 2>/dev/null)"
  if [ -n "$out" ]; then
    ui_ok "PROVEN: a value decrypted from the restored store using the restored key"
    rm -rf "$work"
    return 0
  fi
  ui_err "the restored key could NOT decrypt the restored store"
  rm -rf "$work"
  return 1
}

recovery_screen() {
  ui_interactive || return 0
  local keyfile="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

  tui_page "RECOVERY KIT" "the one failure nobody plans for"
  printf '\n'
  tui_kv "identity"     "$keyfile" "$([ -f "$keyfile" ] && printf '%s' "$T_OK" || printf '%s' "$T_ERR")"
  tui_kv "stores"       "$(ls "$SEC_SECRETS"/*.enc.* "$SEC_ENC_DIR"/*.enc.* 2>/dev/null | sec_nlines) encrypted file(s)"
  tui_kv "credentials"  "$(sec_count 2>/dev/null || echo '?')"
  printf '\n'
  printf '   %sEverything above is encrypted to ONE key, in ONE file. If that file is\n' "$T_MUTE"
  printf '   lost, every credential becomes permanently unreadable. There is no\n'
  printf '   recovery path, by design — that is what makes the encryption worth having.%s\n' "$T_RS"
  printf '\n'

  local act
  act="$(tui_menu "RECOVERY" "a backup you have not restored is a rumour" \
    "Build a kit, then prove it restores|encrypt to a passphrase, then actually restore it" \
    "Verify an existing kit|restore a kit you already have, without changing anything" \
    "Where should it live|guidance, not an action" \
    "Cancel|do nothing")" || return 0

  case "$act" in
    "Build a kit"*)
      tui_page "BUILD A RECOVERY KIT" "$SEC_ROOT"
      local dest
      dest="$(ui_ask 'Write the kit to' "$REC_DEFAULT_DIR")" || return 0
      dest="${dest/#\~/$HOME}"
      [ -n "$dest" ] || dest="$REC_DEFAULT_DIR"
      printf '\n'
      local kit
      kit="$(rec_build "$dest")"
      if [ -z "$kit" ] || [ ! -f "$kit" ]; then ui_pause; return 1; fi
      ui_ok "kit written: $kit ($(du -h "$kit" 2>/dev/null | awk '{print $1}'))"
      printf '\n'
      tui_section "NOW PROVING IT"
      printf '   %sA kit that has never been restored is not a backup. Restoring it now,\n' "$T_DIM"
      printf '   into a throwaway directory, using only what is inside the kit.%s\n\n' "$T_RS"
      if rec_verify "$kit"; then
        printf '\n'
        ui_ok "this kit is real — it was built and restored end to end"
        sec_log_start recovery; sec_log "kit built and verified: $kit"
        printf '\n'
        tui_section "WHERE TO PUT IT"
        printf '   %s· somewhere physically separate from this machine%s\n' "$T_MUTE" "$T_RS"
        printf '   %s· a second copy in a different place — one copy is not a backup%s\n' "$T_MUTE" "$T_RS"
        printf '   %s· NOT beside the machine it protects, and not only in cloud sync%s\n' "$T_MUTE" "$T_RS"
        printf '   %s· the passphrase written down somewhere physical and separate again%s\n' "$T_MUTE" "$T_RS"
      else
        printf '\n'
        ui_err "the kit did NOT restore — deleting it"
        ui_note "A kit that cannot be restored is worse than none: it stops you"
        ui_note "looking for a real one. Nothing has been kept."
        rm -f "$kit"
        sec_log_start recovery; sec_log "kit FAILED verification and was deleted"
      fi
      ui_pause ;;

    "Verify an existing kit"*)
      tui_page "VERIFY A KIT" "restores into a throwaway directory — changes nothing"
      local k
      k="$(ui_ask 'Path to the .age kit' "$REC_DEFAULT_DIR/")" || return 0
      k="${k/#\~/$HOME}"
      [ -f "$k" ] || { ui_err "no such file"; ui_pause; return 1; }
      printf '\n'
      if rec_verify "$k"; then ui_ok "that kit restores correctly"
      else ui_err "that kit did NOT restore — treat yourself as having no backup"; fi
      ui_pause ;;

    "Where should it live"*)
      tui_page "WHERE A KIT SHOULD LIVE" "the honest version"
      printf '\n'
      tui_section "GOOD"
      printf '   %s· an encrypted USB key in a drawer at a different address%s\n' "$T_MUTE" "$T_RS"
      printf '   %s· a safe deposit box, if your threat model justifies the trip%s\n' "$T_MUTE" "$T_RS"
      printf '   %s· a second machine you control, on different storage%s\n' "$T_MUTE" "$T_RS"
      printf '   %s· cloud storage IS acceptable — the kit is passphrase-encrypted and%s\n' "$T_MUTE" "$T_RS"
      printf '   %s  the provider holds ciphertext. Just never the passphrase with it.%s\n' "$T_MUTE" "$T_RS"
      tui_section "BAD"
      printf '   %s· the same disk as the data it protects%s\n' "$T_MUTE" "$T_RS"
      printf '   %s· a password manager whose own recovery depends on this key%s\n' "$T_MUTE" "$T_RS"
      printf '   %s· one copy, anywhere%s\n' "$T_MUTE" "$T_RS"
      printf '   %s· with the passphrase in the same place, which makes it a plain archive%s\n' "$T_MUTE" "$T_RS"
      ui_pause ;;
  esac
  return 0
}
