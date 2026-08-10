#!/usr/bin/env bash
# test/run.sh — the test suite.
#
# Dependency-free on purpose: a credential tool that needs a test framework
# installed before you can verify it will not get verified. This runs anywhere
# bash 4 runs.
#
# WHAT IT ACTUALLY TESTS
#   Not "does the function exist". Every assertion here is about behaviour that
#   has broken at least once, in ways that shipped:
#     · stdout purity — warnings on stdout silently corrupt a caller's data
#     · return channels — a function that draws AND returns must not use stdout
#     · grep -c "0\n0" — the fallback that breaks every integer test downstream
#     · local a=$1 b=$a — arguments expand before assignments take effect
#     · publish-time redaction — a note must never carry a vault value
#     · the commit guard must refuse a real secret and accept clean code
#     · every screen must render at several terminal sizes
#     · the program must survive a hostile data root without a syntax fault
#
# Every test builds its own throwaway data root. Nothing touches your real vault.
#
# usage: test/run.sh [pattern]
set -uo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/secretsd"
PASS=0; FAIL=0; SKIP=0
FILTER="${1:-}"
FAILED_NAMES=()

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; B=$'\033[1m'; X=$'\033[0m'

ok()   { PASS=$((PASS+1)); printf '  %s✓%s %s\n' "$G" "$X" "$1"; return 0; }
# NOTE: every one of these returns 0. A reporter that ends on a conditional
# poisons `test && no "x" || ok "y"` — the && branch runs, returns non-zero, and
# the || branch runs too, printing both a pass and a failure for one assertion.
no()   { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  %s✗%s %s\n' "$R" "$X" "$1"
         if [ -n "${2:-}" ]; then printf '      %s%s%s\n' "$D" "$2" "$X"; fi
         return 0; }
skip() { SKIP=$((SKIP+1)); printf '  %s−%s %s %s(%s)%s\n' "$Y" "$X" "$1" "$D" "${2:-}" "$X"; return 0; }
group(){ printf '\n%s%s%s\n' "$B" "$1" "$X"; }
want()  { case "$1" in *"$FILTER"*) return 0 ;; *) return 1 ;; esac; }

# --- a throwaway vault, built from scratch ------------------------------------
AGE_KEY=""; DATA=""
setup_fixture() {
  DATA="$(mktemp -d)"; chmod 700 "$DATA"
  mkdir -p "$DATA/secrets" "$DATA/run-logs"
  AGE_KEY="$DATA/keys.txt"
  age-keygen -o "$AGE_KEY" 2>/dev/null
  chmod 600 "$AGE_KEY"
  local pub; pub="$(grep -m1 'public key:' "$AGE_KEY" | sed 's/.*public key: *//')"
  cat > "$DATA/.sops.yaml" <<EOF
creation_rules:
  - path_regex: secrets[\\/].*\.enc\.(env|yaml|json)\$
    age: $pub
EOF
  printf 'SOPS_SELFTEST=ok\nDEMO_TOKEN=abcdefghijklmnopqrstuvwxyz012345\nDEMO_HOST=10.99.88.77\n' > "$DATA/plain.env"
  sops --config /dev/null --encrypt --age "$pub" --input-type dotenv --output-type dotenv \
       "$DATA/plain.env" > "$DATA/secrets/api-keys.enc.env" 2>/dev/null
  rm -f "$DATA/plain.env"
  chmod 600 "$DATA/secrets/api-keys.enc.env"
}
teardown_fixture() { [ -n "$DATA" ] && rm -rf "$DATA"; }
sd() { SECRETSD_HOME="$DATA" SOPS_AGE_KEY_FILE="$AGE_KEY" "$BIN" "$@"; }

command -v sops    >/dev/null 2>&1 || { echo "sops required"; exit 1; }
command -v age     >/dev/null 2>&1 || { echo "age required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required"; exit 1; }

printf '%ssecretsd test suite%s  %s%s%s\n' "$B" "$X" "$D" "$ROOT" "$X"
setup_fixture
trap teardown_fixture EXIT

# ==============================================================================
group "syntax and static analysis"
# ==============================================================================
if want "parse"; then
  bad=""
  for f in "$BIN" "$ROOT"/bin/lib/*.sh "$ROOT"/install.sh "$ROOT"/test/run.sh; do
    bash -n "$f" 2>/dev/null || bad="$bad $(basename "$f")"
  done
  [ -z "$bad" ] && ok "every shell file parses" || no "shell files fail to parse" "$bad"
fi
if want "shellcheck"; then
  if command -v shellcheck >/dev/null 2>&1; then
    n="$(shellcheck -s bash -S error -f gcc "$BIN" "$ROOT"/bin/lib/*.sh "$ROOT"/install.sh 2>/dev/null | wc -l | tr -d ' ')"
    [ "$n" = "0" ] && ok "shellcheck reports no errors" || no "shellcheck errors: $n"
  else skip "shellcheck" "not installed"; fi
fi
if want "python"; then
  if python3 -c "import ast;ast.parse(open('$ROOT/bin/lib/agepty.py').read())" 2>/dev/null; then
    ok "agepty.py parses"
  else no "agepty.py does not parse"; fi
fi

# ==============================================================================
group "the store"
# ==============================================================================
if want "names"; then
  out="$(sd names 2>/dev/null)"
  [ "$(printf '%s\n' "$out" | grep -c .)" = "3" ] && ok "names lists every key" \
    || no "names returned $(printf '%s\n' "$out" | grep -c .) keys, expected 3"
fi
if want "stdout-purity"; then
  # a warning on stdout silently corrupts whatever consumes it
  chmod 644 "$DATA/secrets/api-keys.enc.env"
  out="$(sd names 2>/dev/null)"
  chmod 600 "$DATA/secrets/api-keys.enc.env"
  if printf '%s' "$out" | grep -qvE '^[A-Z0-9_]*$'; then
    no "stdout polluted while a warning was active" "$(printf '%s' "$out" | head -1)"
  else ok "stdout carries only key names, even while warning"; fi
fi
if want "stderr-warns"; then
  chmod 644 "$DATA/secrets/api-keys.enc.env"
  errs="$(sd names 2>&1 >/dev/null)"
  chmod 600 "$DATA/secrets/api-keys.enc.env"
  printf '%s' "$errs" | grep -q 'more open' && ok "the permission warning goes to stderr" \
    || no "permission warning never appeared on stderr"
fi
if want "check"; then
  sd check >/dev/null 2>&1 && ok "check decrypts the store" || no "check could not decrypt"
fi
if want "inject"; then
  v="$(sd run --only DEMO_TOKEN -- sh -c 'printf %s "$DEMO_TOKEN"' 2>/dev/null)"
  [ "$v" = "abcdefghijklmnopqrstuvwxyz012345" ] && ok "run --only injects the value" \
    || no "run --only did not inject" "got: ${v:0:12}…"
fi
if want "scoping"; then
  v="$(sd run --only DEMO_TOKEN -- sh -c 'printf %s "${DEMO_HOST:-unset}"' 2>/dev/null)"
  [ "$v" = "unset" ] && ok "run --only excludes every other key" \
    || no "run --only leaked an unrelated key"
fi
if want "no-value-stdout"; then
  # no subcommand may ever print a value
  out="$(sd names 2>&1; sd check 2>&1; sd doctor 2>&1)"
  printf '%s' "$out" | grep -q 'abcdefghijklmnopqrstuvwxyz012345' \
    && no "a secret VALUE reached stdout" || ok "no command printed a secret value"
fi

# ==============================================================================
group "the bug classes that shipped"
# ==============================================================================
if want "grep-c"; then
  # grep -c prints 0 AND exits 1; `|| echo 0` then yields "0\n0"
  hits="$(grep -rnE 'grep -c[^|]*\|\| *(echo|printf) .0.' "$ROOT/bin" 2>/dev/null | grep -vE ':[0-9]+: *#' | grep -c . || true)"
  [ "${hits:-0}" = "0" ] && ok "no 'grep -c … || echo 0' remains" || no "$hits instance(s) of the 0\\n0 idiom"
fi
if want "local-expand"; then
  # local a="$1" b="$a" — all arguments expand before any assignment takes effect
  hits="$(grep -rnE 'local [a-z_]+="\$[0-9]" [a-z_]+="\$[a-z_]+' "$ROOT/bin" 2>/dev/null | grep -vE ':[0-9]+: *#' | grep -c . || true)"
  if [ "${hits:-0}" = "0" ]; then ok "no 'local a=\$1 b=\$a' self-reference"
  else no "'local a=\$1 b=\$a' self-reference present" "$hits instance(s)"; fi
fi
if want "gum-bare"; then
  # a bare gum call leaves terminal query replies in the input buffer
  hits="$(grep -nE '^[^#]*[^_a-z]gum ' "$ROOT/bin/lib/ui.sh" 2>/dev/null | grep -v 'command -v gum' | grep -vc 'gum "\$@"' || true)"
  [ "${hits:-0}" = "0" ] && ok "every gum call is wrapped so the tty is drained" || no "$hits bare gum call(s)"
fi
if want "return-channel"; then
  # rec_build both draws and returns a path; it must not draw on stdout
  grep -q 'exec 3>&1 1>/dev/tty' "$ROOT/bin/lib/recovery.sh" \
    && ok "rec_build reserves stdout as its return channel" \
    || no "rec_build draws on stdout — the caller will capture the drawing"
fi
if want "stat-portable"; then
  # `stat -f` on GNU means "show the filesystem" and exits 0, so a
  # `stat -f … || stat -c …` fallback never reaches the GNU branch. Linux CI
  # caught this as "the permission warning never appeared"; macOS could not.
  hits="$(grep -rn 'stat -f.*||.*stat -c' "$ROOT/bin" 2>/dev/null | grep -vE ':[0-9]+: *#' | grep -c . || true)"
  if [ "${hits:-0}" = "0" ]; then ok "no BSD-then-GNU stat fallback (it never falls back)"
  else no "BSD-then-GNU stat fallback present" "$hits instance(s)"; fi
fi
if want "stat-works"; then
  m="$(bash -c '
    SEC_ROOT="'"$DATA"'"; TMPD=$(mktemp -d); SEC_BIN="'"$ROOT"'/bin"
    export SEC_ROOT TMPD SEC_BIN
    for l in ui store security; do . "$SEC_BIN/lib/$l.sh" 2>/dev/null; done
    sec_mode "'"$DATA"'/secrets/api-keys.enc.env"; rm -rf $TMPD' 2>/dev/null)"
  case "$m" in
    600) ok "sec_mode returns a real octal mode on this platform" ;;
    *)   no "sec_mode returned '$m', expected 600" ;;
  esac
fi
if want "tput-stderr"; then
  # `tput cols 2>/dev/null` silently returns the terminfo default
  if grep -rn 'tput cols 2>/dev/null' "$ROOT/bin" 2>/dev/null | grep -qvE ':[0-9]+: *#' ; then
    no "tput size query redirects stderr and will return 80"
  else
    ok "terminal size is not read through a stderr-redirected tput"
  fi
fi

# ==============================================================================
group "hostile input"
# ==============================================================================
if want "hostile-root"; then
  H="$(mktemp -d)"; mkdir -p "$H/secrets"
  printf 'not yaml {{{\n' > "$H/secrets/CREDENTIALS.yaml"
  printf 'x' > "$H/secrets/api-keys.enc.env"
  faults=0
  for c in names check doctor posture home; do
    o="$(SECRETSD_HOME="$H" SOPS_AGE_KEY_FILE="$AGE_KEY" "$BIN" $c </dev/null 2>&1)"
    printf '%s' "$o" | grep -qiE 'unbound variable|syntax error|integer expression|bad substitution' && faults=$((faults+1))
  done
  rm -rf "$H"
  [ "$faults" = "0" ] && ok "survives a corrupt data root without a shell fault" \
    || no "$faults command(s) faulted on a corrupt data root"
fi
if want "missing-store"; then
  H="$(mktemp -d)"
  o="$(SECRETSD_HOME="$H" "$BIN" names </dev/null 2>&1)"
  rm -rf "$H"
  printf '%s' "$o" | grep -q 'first run' && ok "a missing store gives first-run guidance" \
    || no "a missing store gives an unhelpful error"
fi
if want "root-refusal"; then
  grep -q 'refusing to run as root' "$ROOT/bin/lib/security.sh" \
    && ok "refuses to run as root" || no "no root refusal"
fi

# ==============================================================================
group "publish-time redaction"
# ==============================================================================
if want "redact"; then
  doc="$(mktemp)"
  printf '# note\n\nhost 10.99.88.77 uses abcdefghijklmnopqrstuvwxyz012345\n' > "$doc"
  out="$(SECRETSD_HOME="$DATA" SOPS_AGE_KEY_FILE="$AGE_KEY" bash -c '
    SEC_ROOT="'"$DATA"'"; TMPD=$(mktemp -d); SEC_BIN="'"$ROOT"'/bin"; SEC_SELF="'"$BIN"'"
    export SEC_ROOT TMPD SEC_BIN SEC_SELF SECRETSD_HOME SOPS_AGE_KEY_FILE
    for l in ui store tui security pkm notes; do . "$SEC_BIN/lib/$l.sh" 2>/dev/null; done
    notes_redact "'"$doc"'"
    rm -rf $TMPD' 2>/dev/null)"
  body="$(cat "$doc")"; rm -f "$doc"
  if printf '%s' "$body" | grep -q 'abcdefghijklmnopqrstuvwxyz012345'; then
    no "redaction left a secret value in the document"
  elif printf '%s' "$body" | grep -q '10.99.88.77'; then
    no "redaction left a stored host value in the document"
  elif printf '%s' "$out" | grep -q 'DEMO_TOKEN'; then
    ok "redaction removes vault values and reports the key names"
  else
    no "redaction did not report which keys it removed" "reported: $out"
  fi
fi

# ==============================================================================
group "the commit guard"
# ==============================================================================
if want "guard"; then
  G_REPO="$(mktemp -d)"
  ( cd "$G_REPO" && git init -q && git config user.email t@t && git config user.name t
    printf 'hello\n' > a.txt && git add a.txt && git commit -qm init ) 2>/dev/null
  SECRETSD_HOME="$DATA" SOPS_AGE_KEY_FILE="$AGE_KEY" "$BIN" guard "$G_REPO" >/dev/null 2>&1
  if [ -f "$G_REPO/.git/hooks/pre-commit" ]; then
    ok "guard installs a pre-commit hook"
    ( cd "$G_REPO" && printf 'AWS=AKIAIOSFODNN7EXAMPLE\n' > leak.py && git add leak.py ) 2>/dev/null
    if ( cd "$G_REPO" && git commit -qm leak ) >/dev/null 2>&1; then
      no "the guard let a real-looking AWS key through"
    else ok "the guard refuses a commit containing a credential"; fi
    ( cd "$G_REPO" && git reset -q HEAD leak.py && rm -f leak.py
      printf 'x = 1\n' > ok.py && git add ok.py ) 2>/dev/null
    if ( cd "$G_REPO" && git commit -qm clean ) >/dev/null 2>&1; then
      ok "the guard accepts a clean commit"
    else no "the guard blocked a clean commit (false positive)"; fi
  else no "guard did not install a hook"; fi
  rm -rf "$G_REPO"
fi

# ==============================================================================
group "generation"
# ==============================================================================
if want "gen"; then
  out="$(bash -c '
    SEC_ROOT="'"$DATA"'"; TMPD=$(mktemp -d); SEC_BIN="'"$ROOT"'/bin"
    export SEC_ROOT TMPD SEC_BIN
    for l in ui store tui gen; do . "$SEC_BIN/lib/$l.sh" 2>/dev/null; done
    p="$(gen_password 24 1)"
    printf "%s|%s|%s|%s|%s\n" "${#p}" \
      "$(printf %s "$p" | grep -c "[a-z]")" "$(printf %s "$p" | grep -c "[A-Z]")" \
      "$(printf %s "$p" | grep -c "[0-9]")" "$(printf %s "$p" | grep -c "[^A-Za-z0-9]")"
    rm -rf $TMPD' 2>/dev/null)"
  IFS='|' read -r len lo up di sy <<< "$out"
  [ "$len" = "24" ] && ok "generated password has the requested length" || no "length was $len, wanted 24"
  [ "$lo$up$di$sy" = "1111" ] && ok "generated password contains every character class" \
    || no "character classes missing" "lower=$lo upper=$up digit=$di symbol=$sy"
fi
if want "totp"; then
  code="$(bash -c '
    SEC_ROOT="'"$DATA"'"; TMPD=$(mktemp -d); SEC_BIN="'"$ROOT"'/bin"
    export SEC_ROOT TMPD SEC_BIN
    for l in ui store tui gen; do . "$SEC_BIN/lib/$l.sh" 2>/dev/null; done
    gen_totp GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ; rm -rf $TMPD' 2>/dev/null)"
  ref="$(python3 -c '
import base64,hmac,hashlib,struct,time
k=base64.b32decode("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
h=hmac.new(k,struct.pack(">Q",int(time.time())//30),hashlib.sha1).digest()
o=h[19]&15
print(str((struct.unpack(">I",h[o:o+4])[0]&0x7fffffff)%1000000).zfill(6))')"
  [ "$code" = "$ref" ] && ok "TOTP matches an independent RFC 6238 implementation" \
    || no "TOTP mismatch" "ours=$code reference=$ref"
fi

# ==============================================================================
group "importers"
# ==============================================================================
if want "import"; then
  IMP="$(mktemp -d)"
  printf 'folder,favorite,type,name,notes,fields,login_uri,login_username,login_password,login_totp\n,,login,GitHub,,,https://github.com,kyle,pw123456,JBSWY3DPEHPK3PXP\n' > "$IMP/bw.csv"
  printf 'Title,Url,Username,Password,OTPAuth,Notes\nCF,https://x.com,a@b.c,hunter2,,n\n' > "$IMP/1p.csv"
  printf '"Group","Title","Username","Password","URL","Notes","TOTP"\n"R","Gitea","g","t","https://g","",""\n' > "$IMP/kp.csv"
  printf 'name,uri,username,secret_clear,description,folder_parent\nPve,https://p,root,pw,c,/i\n' > "$IMP/pb.csv"
  printf '{"items":[{"type":1,"name":"AWS","login":{"username":"root","password":"s3cret","uris":[{"uri":"https://aws"}]}}]}\n' > "$IMP/bw.json"
  detected=0; parsed=0
  for f in "$IMP"/*; do
    r="$(bash -c '
      SEC_ROOT="'"$DATA"'"; TMPD=$(mktemp -d); SEC_BIN="'"$ROOT"'/bin"
      export SEC_ROOT TMPD SEC_BIN
      for l in ui store tui record import; do . "$SEC_BIN/lib/$l.sh" 2>/dev/null; done
      fmt="$(imp_detect "'"$f"'")" || fmt=""
      [ -n "$fmt" ] && printf "%s|%s" "$fmt" "$(imp_parse "'"$f"'" "$fmt" | python3 -c "import json,sys;print(len(json.load(sys.stdin)))" 2>/dev/null)"
      rm -rf $TMPD' 2>/dev/null)"
    [ -n "${r%%|*}" ] && detected=$((detected+1))
    [ "${r##*|}" = "1" ] && parsed=$((parsed+1))
  done
  rm -rf "$IMP"
  [ "$detected" = "5" ] && ok "detects all five export formats" || no "detected $detected/5 formats"
  [ "$parsed"   = "5" ] && ok "parses one record from each format" || no "parsed $parsed/5"
fi

# ==============================================================================
group "rendering"
# ==============================================================================
if want "render"; then
  SHOT="$ROOT/test/shot.py"
  if [ -f "$SHOT" ]; then
    bad=""; sizes="70x18 100x24 200x30"
    for size in $sizes; do
      c="${size%x*}"; r="${size#*x}"
      for s in "" home posture keys api vaults workspace; do
        n="$(SD_BIN="$BIN" SECRETSD_HOME="$DATA" SOPS_AGE_KEY_FILE="$AGE_KEY" \
             python3 "$SHOT" "$c" "$r" $s 2>/dev/null | grep -c '│')"
        [ "$n" -ge "$r" ] || bad="$bad ${s:-entry}@$size"
      done
    done
    [ -z "$bad" ] && ok "every screen fills the terminal at 3 sizes" || no "render faults:$bad"
  else skip "render" "test/shot.py missing"; fi
fi

# ==============================================================================
printf '\n%s%s passed%s' "$G" "$PASS" "$X"
[ "$FAIL" -gt 0 ] && printf '  %s%s failed%s' "$R" "$FAIL" "$X"
[ "$SKIP" -gt 0 ] && printf '  %s%s skipped%s' "$Y" "$SKIP" "$X"
printf '\n'
if [ "$FAIL" -gt 0 ]; then
  printf '\n%sfailures:%s\n' "$R" "$X"
  for f in "${FAILED_NAMES[@]}"; do printf '  · %s\n' "$f"; done
  exit 1
fi
exit 0
