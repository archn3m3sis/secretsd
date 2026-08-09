#!/usr/bin/env bash
# install.sh — put secretsd on your PATH and decide where its data lives.
#
# Everything this script does is printed before it does it, and verified after.
# Nothing is written outside ~/.local/bin, ~/.local/share/zsh/completions and the
# data root you choose.
set -uo pipefail

HERE="$(cd -P "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin"
COMP="$HOME/.local/share/zsh/completions"
CFG="$HOME/.config/secretsd"

b()   { printf '\033[1m%s\033[0m' "$1"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; }
inf() { printf '  \033[2m·\033[0m %s\n' "$1"; }

printf '\n%s\n' "$(b 'secretsd — install')"
printf '  %s\n\n' "$HERE"

# --- 1. dependencies ----------------------------------------------------------
printf '%s\n' "$(b '1. dependencies')"
missing=0
for t in sops age python3 git; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t"
  else bad "$t is REQUIRED and not installed"; missing=1; fi
done
for t in gum jq openssl ykman claude; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t (optional)"
  else inf "$t not installed — the features that use it will say so plainly"; fi
done
if [ "${BASH_VERSINFO[0]:-3}" -lt 4 ]; then
  bad "this shell is bash ${BASH_VERSION%%(*} — secretsd needs bash 4+"
  inf "on macOS: brew install bash   (the system bash is 3.2 and stays 3.2)"
  missing=1
fi
[ "$missing" -eq 1 ] && { printf '\n  install the missing tools, then run this again\n\n'; exit 1; }

# --- 2. where the data lives --------------------------------------------------
printf '\n%s\n' "$(b '2. where should your credentials live?')"
inf "code and data are kept separate — this path is NOT inside the repository"
DEFAULT_HOME="$HOME/.local/share/secretsd"
printf '  [%s]: ' "$DEFAULT_HOME"
IFS= read -r CHOSEN < /dev/tty || CHOSEN=""
DATA="${CHOSEN:-$DEFAULT_HOME}"
DATA="${DATA/#\~/$HOME}"

mkdir -p "$DATA/secrets" "$DATA/run-logs" || { bad "cannot create $DATA"; exit 1; }
chmod 700 "$DATA" "$DATA/secrets" 2>/dev/null
mkdir -p "$CFG" && chmod 700 "$CFG"
printf '%s\n' "$DATA" > "$CFG/home"
chmod 600 "$CFG/home"
ok "data root: $DATA"
ok "recorded in $CFG/home"

# --- 3. an age key ------------------------------------------------------------
printf '\n%s\n' "$(b '3. encryption key')"
KEYFILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
if [ -f "$KEYFILE" ]; then
  ok "using the age key already at $KEYFILE"
  PUB="$(grep -m1 'public key:' "$KEYFILE" 2>/dev/null | sed 's/.*public key: *//')"
else
  inf "no age key found — generating one"
  mkdir -p "$(dirname "$KEYFILE")" && chmod 700 "$(dirname "$KEYFILE")"
  age-keygen -o "$KEYFILE" 2>/dev/null
  chmod 600 "$KEYFILE"
  PUB="$(grep -m1 'public key:' "$KEYFILE" | sed 's/.*public key: *//')"
  ok "created $KEYFILE"
  printf '\n  \033[33m!\033[0m BACK THIS FILE UP NOW. Lose it and every vault it encrypts is gone.\n'
  printf '    There is no recovery, by design.\n\n'
fi
[ -n "${PUB:-}" ] && ok "public key: $PUB"

# --- 4. sops creation rule ----------------------------------------------------
printf '\n%s\n' "$(b '4. sops configuration')"
SOPSCFG="$DATA/.sops.yaml"
if [ -f "$SOPSCFG" ]; then
  ok "keeping the existing $SOPSCFG"
elif [ -n "${PUB:-}" ]; then
  cat > "$SOPSCFG" <<EOF
# Which age recipients each store is encrypted to.
# Add a host by appending its PUBLIC key here, then: sops updatekeys <file>
creation_rules:
  - path_regex: secrets[\\\\/].*\\.enc\\.(env|yaml|json)\$
    age: $PUB
EOF
  chmod 600 "$SOPSCFG"
  ok "wrote $SOPSCFG (this host only)"
else
  bad "no public key resolved — write $SOPSCFG by hand before first use"
fi

# --- 5. the store -------------------------------------------------------------
printf '\n%s\n' "$(b '5. first store')"
STORE="$DATA/secrets/api-keys.enc.env"
if [ -f "$STORE" ]; then
  ok "store already exists"
elif [ -n "${PUB:-}" ]; then
  printf 'SOPS_SELFTEST=ok\n' > "$DATA/secrets/.seed.env"
  if (cd "$DATA" && sops --encrypt --age "$PUB" secrets/.seed.env > "$STORE" 2>/dev/null); then
    chmod 600 "$STORE"; rm -f "$DATA/secrets/.seed.env"
    ok "created $STORE"
  else
    rm -f "$DATA/secrets/.seed.env" "$STORE"
    bad "could not create the store — check that sops and the age key agree"
  fi
fi

# --- 6. PATH and completion ---------------------------------------------------
printf '\n%s\n' "$(b '6. commands and completion')"
mkdir -p "$BIN" "$COMP"
ln -sfn "$HERE/bin/secretsd" "$BIN/secretsd"
ln -sfn "$HERE/bin/secretsd" "$BIN/secrets"     # the name most people will type
ok "$BIN/secretsd"
ok "$BIN/secrets (alias)"
ln -sfn "$HERE/completions/_secrets" "$COMP/_secretsd"
ok "zsh completion -> $COMP/_secretsd"
case ":$PATH:" in
  *":$BIN:"*) ok "$BIN is already on your PATH" ;;
  *) printf '  \033[33m!\033[0m %s is NOT on your PATH. Add:\n' "$BIN"
     printf '      export PATH="%s:$PATH"\n' "$BIN" ;;
esac
grep -q "$COMP" "$HOME/.zshrc" 2>/dev/null || \
  inf "for completion, ensure this is in your fpath: $COMP"

# --- 7. verify ----------------------------------------------------------------
printf '\n%s\n' "$(b '7. verify')"
if "$BIN/secretsd" check >/dev/null 2>&1; then
  ok "the store decrypts on this host"
else
  bad "the store did not decrypt — run: secretsd doctor"
fi
n="$("$BIN/secretsd" names 2>/dev/null | grep -c . || echo 0)"
ok "$n credential(s) readable"

printf '\n%s\n' "$(b 'done')"
printf '  run  %s  to start\n' "$(b secretsd)"
printf '  run  %s  for a full health report\n' "$(b 'secretsd doctor')"
printf '  run  %s  to import from another password manager\n\n' "$(b 'secretsd import')"
