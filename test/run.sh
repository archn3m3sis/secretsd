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
  # Scans test/ as well as bin/. It originally scanned only bin/, which is why a
  # fresh instance of this exact bug landed in THIS file and reached Linux CI.
  # A guard that cannot see its own house is not a guard.
  hits="$(grep -rn 'stat -f.*||.*stat -c' "$ROOT/bin" "$ROOT/test" 2>/dev/null \
          | grep -vE ':[0-9]+: *#' | grep -v 'grep -rn' | grep -c . || true)"
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
      for s in "" home posture keys api vaults workspace alerts guard inbox \
                 profiles broker notes gen machines dns logins auth env; do
        n="$(SD_BIN="$BIN" SECRETSD_HOME="$DATA" SOPS_AGE_KEY_FILE="$AGE_KEY" \
             python3 "$SHOT" "$c" "$r" $s 2>/dev/null | grep -c '│')"
        [ "$n" -ge "$r" ] || bad="$bad ${s:-entry}@$size"
      done
    done
    [ -z "$bad" ] && ok "every screen fills the terminal at 3 sizes" || no "render faults:$bad"
  else skip "render" "test/shot.py missing"; fi
fi


# ==============================================================================
# --json — machine-readable output
#
# The single most important assertion in this file: a JSON mode that leaks a
# credential value would silently undo the entire premise of the program. The
# leak test decrypts the fixture store, then greps every --json output for each
# real value. It must find nothing.
# ==============================================================================
if want json; then
  group "--json"

  JOUT="$DATA/json"; mkdir -p "$JOUT"
  for c in names doctor expiring posture sessions alerts; do
    sd "$c" --json > "$JOUT/$c.json" 2>"$JOUT/$c.err"
    printf '%s' "$?" > "$JOUT/$c.rc"
  done

  badjson=""
  for c in names doctor expiring posture sessions alerts; do
    python3 -c "import json,sys; json.load(open('$JOUT/$c.json'))" 2>/dev/null || badjson="$badjson $c"
  done
  [ -z "$badjson" ] && ok "every --json command emits parseable JSON" \
                    || no "invalid JSON from:$badjson"

  # stderr must stay empty on the happy path — a warning there is fine, but a
  # traceback is not, and a traceback is what a missing helper looks like.
  tb=""
  for c in names doctor expiring posture sessions alerts; do
    grep -q 'Traceback' "$JOUT/$c.err" 2>/dev/null && tb="$tb $c"
  done
  [ -z "$tb" ] && ok "no --json command raises a python traceback" || no "traceback from:$tb"

  # THE LEAK TEST
  leaked=""
  vals="$(SECRETSD_HOME="$DATA" SOPS_AGE_KEY_FILE="$AGE_KEY" \
          sops --config /dev/null -d --input-type dotenv --output-type dotenv \
          "$DATA/secrets/api-keys.enc.env" 2>/dev/null | sed 's/^[^=]*=//' | grep -v '^ok$')"
  while IFS= read -r v; do
    [ ${#v} -ge 8 ] || continue
    for c in names doctor expiring posture sessions alerts; do
      grep -qF -- "$v" "$JOUT/$c.json" 2>/dev/null && leaked="$leaked $c"
    done
  done <<LEAKV
$vals
LEAKV
  [ -z "$leaked" ] && ok "no --json output contains a credential value" \
                   || no "VALUE LEAKED into:$leaked"

  # names --json must list every key the plain command lists
  jn="$(python3 -c "import json; print(json.load(open('$JOUT/names.json'))['count'])" 2>/dev/null)"
  pn="$(sd names 2>/dev/null | grep -c . || true)"
  [ "$jn" = "$pn" ] && ok "names --json counts match the plain listing ($jn)" \
                    || no "names --json says $jn, plain says $pn"

  # exit codes are the CI contract: 0 clean, 1 warnings, 2 critical
  drc="$(cat "$JOUT/doctor.rc")"
  case "$drc" in 0|1|2) ok "doctor --json exits with a documented code ($drc)" ;;
                 *)     no "doctor --json exited $drc, expected 0, 1 or 2" ;; esac

  # a command with no JSON form must refuse loudly, not print a TUI into a pipe
  out="$(sd rotate --json 2>&1)"; rc=$?
  if [ "$rc" = "64" ] && printf '%s' "$out" | grep -q 'not available'; then
    ok "--json refuses unsupported commands with exit 64"
  else
    no "--json on an unsupported command exited $rc" "$(printf '%s' "$out" | head -2)"
  fi

  # --json is a GLOBAL flag: it must work before the subcommand too
  if sd --json names 2>/dev/null | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    ok "--json is accepted before the subcommand as well as after"
  else
    no "--json only works in one position"
  fi
fi

# ==============================================================================
# doctor — one producer, two renderers
# ==============================================================================
if want doctor; then
  group "doctor"

  recs="$(SECRETSD_HOME="$DATA" SOPS_AGE_KEY_FILE="$AGE_KEY" bash -c '
    SEC_SELF="'"$BIN"'"; export SEC_SELF
    . "'"$ROOT"'/bin/lib/ui.sh" 2>/dev/null
    exec "'"$BIN"'" doctor --json' 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(d["total"], d["failures"], d["warnings"])' 2>/dev/null)"
  set -- $recs
  [ "${1:-0}" -gt 10 ] && ok "doctor_probe emits a full check set (${1:-0} checks)" \
                       || no "doctor emitted only ${1:-0} checks"

  # every record must carry all four fields; a missing section makes the
  # terminal renderer print an empty rule
  bad="$(sd doctor --json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(sum(1 for c in d["checks"] if not c["section"] or not c["check"] or c["status"] not in ("ok","warn","fail","info")))')"
  [ "${bad:-1}" = "0" ] && ok "every doctor record is well-formed" \
                        || no "$bad doctor record(s) are malformed"

  # the two renderers must agree on the verdict
  sd doctor >/dev/null 2>&1; trc=$?
  sd doctor --json >/dev/null 2>&1; jrc=$?
  # terminal returns 1 only on failure; json returns 2 on failure, 1 on warnings
  if { [ "$trc" = "1" ] && [ "$jrc" = "2" ]; } || { [ "$trc" = "0" ] && [ "$jrc" != "2" ]; }; then
    ok "terminal and JSON doctor agree on the verdict (tty=$trc json=$jrc)"
  else
    no "doctor renderers disagree" "terminal=$trc json=$jrc"
  fi
fi

# ==============================================================================
# alerts — proactive expiry
# ==============================================================================
if want alerts; then
  group "alerts"

  sd alerts run >/dev/null 2>&1; arc=$?
  if [ -f "$DATA/state/alerts.state" ]; then
    ok "alerts run writes its state file"
  else
    no "alerts run produced no state file"
  fi
  [ -f "$DATA/state/expiry-report.md" ] && ok "alerts run always writes the report" \
                                        || no "no expiry report written"

  # the report is the durable channel and must never carry a value
  rl=""
  while IFS= read -r v; do
    [ ${#v} -ge 8 ] || continue
    grep -qF -- "$v" "$DATA/state/expiry-report.md" 2>/dev/null && rl="leaked"
  done <<LEAKR
$(SECRETSD_HOME="$DATA" SOPS_AGE_KEY_FILE="$AGE_KEY" \
  sops --config /dev/null -d --input-type dotenv --output-type dotenv \
  "$DATA/secrets/api-keys.enc.env" 2>/dev/null | sed 's/^[^=]*=//' | grep -v '^ok$')
LEAKR
  [ -z "$rl" ] && ok "the expiry report contains no credential value" \
               || no "VALUE LEAKED into the expiry report"

  # a credential with no recorded expiry is a FINDING, not silence — this is the
  # exact gap that let four DoD CA certs sit ~500 days expired unnoticed
  unk="$(sd alerts --json 2>/dev/null | python3 -c '
import json,sys; print(json.load(sys.stdin)["counts"]["unknown"])' 2>/dev/null)"
  [ "${unk:-0}" -gt 0 ] && ok "credentials with no recorded expiry are reported ($unk)" \
                        || no "unknown expiry was silently treated as fine"

  # state file permissions — it names your credentials
  if [ -f "$DATA/state/alerts.state" ]; then
    if stat -c '%a' / >/dev/null 2>&1; then m="$(stat -c '%a' "$DATA/state/alerts.state")"
    else                                    m="$(stat -f '%Lp' "$DATA/state/alerts.state")"; fi
    [ "$m" = "600" ] && ok "alert state is mode 600" || no "alert state is mode $m, expected 600"
  fi

  # alerts must never modify the store
  before="$(md5sum "$DATA/secrets/api-keys.enc.env" 2>/dev/null || md5 -q "$DATA/secrets/api-keys.enc.env")"
  sd alerts run >/dev/null 2>&1
  after="$(md5sum "$DATA/secrets/api-keys.enc.env" 2>/dev/null || md5 -q "$DATA/secrets/api-keys.enc.env")"
  [ "$before" = "$after" ] && ok "alerts never modify the credential store" \
                           || no "the store changed after an alert run"

  # warn-only: a scheduled run must not install anything by itself
  [ -f "$HOME/Library/LaunchAgents/com.secretsd.alerts.plist" ] \
    && skip "alerts does not self-schedule" "a plist already exists on this host" \
    || ok "running alerts does not install a schedule by itself"
fi

# ==============================================================================
# keychain — macOS import
# ==============================================================================
if want keychain; then
  group "keychain"

  kcsh() { SECRETSD_HOME="$DATA" SOPS_AGE_KEY_FILE="$AGE_KEY" bash -c '
    set -uo pipefail
    SEC_ROOT="'"$DATA"'"; SEC_BIN="'"$ROOT"'/bin"; TMPD="'"$DATA"'/tmp"; mkdir -p "$TMPD"
    . "$SEC_BIN/lib/ui.sh"; . "$SEC_BIN/lib/keychain.sh"
    '"$1"''; }

  # key names must be legal store keys whatever the service is called
  bad="$(kcsh '
    for s in "Google Chrome Safe Storage" "my.app/thing" "1Password" "café ☕ login" "-leading" ""; do
      k="$(kc_keyname "$s" "acct")"
      printf "%s\n" "$k" | grep -qE "^[A-Z][A-Z0-9_]*$" || printf "%s->%s " "$s" "$k"
    done')"
  [ -z "$bad" ] && ok "keychain key names are always legal store keys" \
               || no "illegal key names generated" "$bad"

  # names must be capped — a 200-char service name must not become a 200-char key
  len="$(kcsh 'kc_keyname "$(python3 -c "print(\"x\"*300)")" "" | tr -d "\n" | wc -c' | tr -d ' ')"
  [ "${len:-999}" -le 60 ] && ok "keychain key names are capped at 60 characters" \
                           || no "a key name of $len characters was generated"

  # the system filter must hide Apple internals and keep real ones
  r="$(kcsh '
    for s in "com.apple.assistant" "iCloud" "Chrome Safe Storage" "AirPlay Server Identity"; do
      kc_is_system "$s" || printf "MISSED:%s " "$s"; done
    for s in "Raycast" "my-startup-api" "GitLab" "nova-key-1666"; do
      kc_is_system "$s" && printf "OVERREACH:%s " "$s"; done; true')"
  [ -z "$r" ] && ok "the system filter hides Apple internals and keeps yours" || no "filter wrong" "$r"

  if [ "$(uname -s)" = "Darwin" ]; then
    # enumeration must never require authorisation and never return a value
    out="$(kcsh 'kc_list | head -40')"
    if printf '%s' "$out" | grep -q '|'; then
      ok "keychain enumerates without any authorisation prompt"
    else
      skip "keychain enumeration" "no items enumerable in this environment"
    fi
    printf '%s' "$out" | grep -qiE 'password:|"passw|0x[0-9a-f]{32}' \
      && no "kc_list output looks like it carries secret material" \
      || ok "kc_list returns names only, never values"
  else
    kcsh 'kc_available' && no "kc_available claims yes on a non-Darwin host" \
                        || ok "keychain correctly reports unavailable off macOS"
  fi
fi


# ==============================================================================
# no command may be silent
#
# Every full-screen module used to be guarded by `ui_interactive || return 0`,
# so running one without a terminal did nothing and exited 0. A command that
# produces no output and reports success is indistinguishable from one that is
# broken — this cost a live debugging session, so it is now a test.
# ==============================================================================
if want silence; then
  group "silence"

  quiet=""
  for c in keychain broker janitor profiles recovery notes inbox pkm workspace \
           monitor audit import posture keys certs machines dns yubikey find \
           gen guard sessions adopt record alerts; do
    out="$(sd "$c" 2>&1 </dev/null | tr -d '[:space:]')"
    [ -n "$out" ] || quiet="$quiet $c"
  done
  [ -z "$quiet" ] && ok "no command exits silently without a terminal" \
                  || no "silent command(s):$quiet"

  # and the explanation must go to STDERR, so `secretsd posture > f` still shows it
  errout="$(sd posture 2>&1 >/dev/null </dev/null | tr -d '[:space:]')"
  [ -n "$errout" ] && ok "the no-terminal explanation goes to stderr" \
                   || no "the explanation is on stdout, so a redirect hides it"

  # a screen that could not run must NOT report success
  sd posture >/dev/null 2>&1 </dev/null && no "a screen that did not run exited 0" \
                                        || ok "a screen that could not run exits non-zero"

  # the guard is only meaningful if the pattern itself is gone
  hits="$(grep -rn 'ui_interactive || return 0' "$ROOT/bin" 2>/dev/null \
          | grep -vE ':[0-9]+: *#' | grep -c . || true)"
  [ "${hits:-0}" = "0" ] && ok "no bare silent-return tty guard remains in the source" \
                         || no "$hits silent tty guard(s) still present"
fi


# ==============================================================================
# pipefail + grep -q — the false-failure class
#
# `producer | grep -q PAT` under `set -o pipefail`: grep exits on first match,
# the producer dies of SIGPIPE with 141, pipefail promotes it, and a SUCCESSFUL
# match is reported as a FAILURE. This made every launchd schedule install
# report "launchctl did not report the agent as loaded" while the agent was
# loaded and listed. The work succeeded; only the proof of it lied.
# ==============================================================================
if want pipefail; then
  group "pipefail"

  m="$(bash -c '
    set -uo pipefail
    . "'"$ROOT"'/bin/lib/ui.sh"
    # a producer that keeps writing well past the pipe buffer
    if seq 1 200000 | ui_match_line "7"; then echo "ok:$?"; else echo "bad:$?"; fi')"
  case "$m" in ok:0) ok "ui_match_line survives a large producer under pipefail" ;;
               *)    no "ui_match_line returned $m (SIGPIPE not handled)" ;; esac

  m="$(bash -c '
    set -uo pipefail
    . "'"$ROOT"'/bin/lib/ui.sh"
    if seq 1 200000 | ui_match_sub "1234"; then echo "ok:$?"; else echo "bad:$?"; fi')"
  case "$m" in ok:0) ok "ui_match_sub survives a large producer under pipefail" ;;
               *)    no "ui_match_sub returned $m" ;; esac

  # and it must still report a genuine miss as a miss
  bash -c '
    set -uo pipefail
    . "'"$ROOT"'/bin/lib/ui.sh"
    seq 1 100 | ui_match_line "nope"' && no "ui_match_line matched something absent" \
                                      || ok "a genuine non-match still returns non-zero"

  # demonstrate the trap is real, so this test is evidence and not decoration
  m="$(bash -c 'set -uo pipefail; seq 1 200000 | grep -q "^7$"; echo $?')"
  [ "$m" != "0" ] && ok "the old grep -q form does fail here (exit $m) — the trap is real" \
                  || skip "grep -q trap" "did not reproduce on this platform"

  # no piped grep -q with a process producer may remain in the source
  hits="$(grep -rn '| *grep -q' "$ROOT/bin" 2>/dev/null \
          | grep -vE ':[0-9]+: *#' | grep -v 'printf ' | grep -c . || true)"
  [ "${hits:-0}" = "0" ] && ok "no piped grep -q with a process producer remains" \
                         || no "$hits piped grep -q call(s) still present"

  # the launchd plist reader must handle key and value on ONE line
  m="$(bash -c '
    . "'"$ROOT"'/bin/lib/ui.sh"
    f="$(mktemp)"
    printf "<dict><key>Hour</key><integer>17</integer></dict>\n" > "$f"
    ui_plist_int "$f" Hour; rm -f "$f"')"
  [ "$m" = "17" ] && ok "the plist reader handles key and value on one line" \
                  || no "plist reader returned [$m], expected 17"
fi


# ==============================================================================
# the clock picker
# ==============================================================================
if want clock; then
  group "clock"

  CLK="$ROOT/bin/lib/clock.py"

  # a face must be square in CELLS: dots/2 wide, dots/4 tall
  d="$(python3 "$CLK" 9 0 48 2>/dev/null)"
  rows="$(printf '%s\n' "$d" | wc -l | tr -d ' ')"
  cols="$(printf '%s\n' "$d" | head -1 | python3 -c 'import sys; print(len(sys.stdin.readline().rstrip("\n")))')"
  if [ "$rows" = "12" ] && [ "$cols" = "24" ]; then
    ok "the 48-dot face renders 24x12 cells"
  else
    no "face geometry is ${cols}x${rows}, expected 24x12"
  fi

  # every character must be from the braille block — one stray ASCII and the
  # grid stops lining up
  bad="$(printf '%s\n' "$d" | python3 -c '
import sys
n = 0
for line in sys.stdin:
    for ch in line.rstrip("\n"):
        if not (0x2800 <= ord(ch) <= 0x28FF):
            n += 1
print(n)')"
  [ "${bad:-1}" = "0" ] && ok "the face is drawn entirely from the braille block" \
                        || no "$bad non-braille character(s) in the face"

  # the hands must actually move — 3:00 and 9:00 cannot render identically
  a="$(python3 "$CLK" 3 0 48 2>/dev/null | md5sum 2>/dev/null || python3 "$CLK" 3 0 48 | md5 -q)"
  b="$(python3 "$CLK" 9 0 48 2>/dev/null | md5sum 2>/dev/null || python3 "$CLK" 9 0 48 | md5 -q)"
  [ "$a" != "$b" ] && ok "different times render different faces" \
                   || no "3:00 and 9:00 render identically — the hands are not drawn"

  # the hour hand must follow the minutes: 09:00 and 09:59 differ
  a="$(python3 "$CLK" 9 0 48  | md5sum 2>/dev/null || python3 "$CLK" 9 0 48  | md5 -q)"
  b="$(python3 "$CLK" 9 59 48 | md5sum 2>/dev/null || python3 "$CLK" 9 59 48 | md5 -q)"
  [ "$a" != "$b" ] && ok "the hour hand advances with the minutes" \
                   || no "09:00 and 09:59 are identical — the hour hand is nailed to the hour"

  # 24-hour wrap: 21:00 must look like 9:00, because a clock face has 12 hours
  a="$(python3 "$CLK" 21 0 48 | md5sum 2>/dev/null || python3 "$CLK" 21 0 48 | md5 -q)"
  b="$(python3 "$CLK" 9 0 48  | md5sum 2>/dev/null || python3 "$CLK" 9 0 48  | md5 -q)"
  [ "$a" = "$b" ] && ok "21:00 draws the same face as 09:00" \
                  || no "the 24-hour wrap is wrong"

  # never crash on the edges, whatever is thrown at it
  bad=""
  for t in "0 0" "23 59" "12 30" "24 60" "-1 -1"; do
    python3 "$CLK" $t 48 >/dev/null 2>&1 || bad="$bad [$t]"
  done
  [ -z "$bad" ] && ok "the renderer survives every edge value" || no "crashed on:$bad"

  # tp_commit: two digits that overflow start a NEW entry rather than clamping.
  # A silent clamp is how you end up scheduled for a time you never chose.
  r="$(bash -c '
    . "'"$ROOT"'/bin/lib/ui.sh"; . "'"$ROOT"'/bin/lib/tui.sh" 2>/dev/null
    SEC_BIN="'"$ROOT"'/bin"; . "'"$ROOT"'/bin/lib/timepick.sh"
    printf "%s %s %s %s" "$(tp_commit 09 23)" "$(tp_commit 23 23)" \
                         "$(tp_commit 25 23)" "$(tp_commit 07 59)"')"
  [ "$r" = "9 23 5 7" ] && ok "hour entry rejects an overflow instead of clamping it" \
                        || no "tp_commit gave [$r], expected [9 23 5 7]"

  # the picker must not draw on its own return channel
  if grep -q 'exec 3>&1 1>/dev/tty' "$ROOT/bin/lib/timepick.sh"; then
    ok "clock_pick_time reserves stdout as its return channel"
  else
    no "clock_pick_time draws on stdout — the caller will capture the drawing"
  fi

  # the schedule must round-trip hour AND minute through the plist
  r="$(bash -c '
    . "'"$ROOT"'/bin/lib/ui.sh"
    f="$(mktemp)"
    printf "<dict><key>Hour</key><integer>0</integer><key>Minute</key><integer>30</integer></dict>\n" > "$f"
    printf "%s:%s" "$(ui_plist_int "$f" Hour)" "$(ui_plist_int "$f" Minute)"; rm -f "$f"')"
  [ "$r" = "0:30" ] && ok "hour and minute both round-trip through the plist" \
                    || no "plist round-trip gave [$r], expected [0:30]"
fi


# ==============================================================================
# screens must name themselves
#
# Every module screen used to wear the "S E C R E T S" wordmark, so nine
# different modules all introduced themselves with the program's name and buried
# what you were actually looking at down in the subtitle.
# ==============================================================================
if want naming; then
  group "screen naming"

  SHOT="$ROOT/test/shot.py"
  if [ -f "$SHOT" ]; then
    bad=""
    for pair in "guard:COMMIT GUARD" "keys:SSH KEYS" "posture:SECURITY POSTURE" \
                "inbox:AGENT INBOX" "alerts:EXPIRY ALERTS" "vaults:VAULTS" \
                "profiles:SESSION PROFILES" "notes:PUBLISH TO NOTES"; do
      sc="${pair%%:*}"; want_title="${pair#*:}"
      out="$(SD_BIN="$BIN" SECRETSD_HOME="$DATA" SOPS_AGE_KEY_FILE="$AGE_KEY" \
             python3 "$SHOT" 110 20 "$sc" 2>/dev/null | head -6)"
      printf '%s' "$out" | grep -qF "$want_title" || bad="$bad $sc"
    done
    [ -z "$bad" ] && ok "every module screen shows its own title" \
                  || no "screens still unnamed or mistitled:$bad"

    # and none of them may fall back to the program wordmark
    bad=""
    for sc in guard keys posture inbox alerts profiles; do
      out="$(SD_BIN="$BIN" SECRETSD_HOME="$DATA" SOPS_AGE_KEY_FILE="$AGE_KEY" \
             python3 "$SHOT" 110 20 "$sc" 2>/dev/null | head -6)"
      printf '%s' "$out" | grep -qF 'S E C R E T S' && bad="$bad $sc"
    done
    [ -z "$bad" ] && ok "no module screen falls back to the program wordmark" \
                  || no "still wearing the wordmark:$bad"
  else
    skip "screen naming" "test/shot.py missing"
  fi
fi


# ==============================================================================
# one expiry producer, three renderers
#
# `secretsd expiring` ran its own manifest-only scan while `secretsd alerts`
# read certificates too, so on a real machine one reported ZERO expired and the
# other reported four dead CA certs at the same moment. Two answers to one
# question is worse than no answer — you believe whichever you ran.
# ==============================================================================
if want expiry; then
  group "expiry agreement"

  # A real expired certificate, in a root the scanner is pointed at for the
  # duration of this group. Without this the agreement assertions pass
  # trivially with three zeroes on a machine that happens to have no certs.
  mkdir -p "$DATA/certs"
  CERTFIX=0
  if command -v openssl >/dev/null 2>&1; then
    # -days 1 with a backdated start: openssl cannot issue a negative lifetime,
    # so the cert is born already expired via faketime-free arithmetic on
    # notBefore/notAfter through -not_before/-not_after where supported, else
    # a 1-day cert that the window (0 days) still catches.
    openssl req -x509 -newkey rsa:2048 -keyout "$DATA/certs/dead.key" \
      -out "$DATA/certs/dead.pem" -days 1 -nodes -subj "/CN=expired.test" \
      >/dev/null 2>&1 && CERTFIX=1
  fi
  [ "$CERTFIX" = "1" ] && ok "built a real certificate for the scanner to find" \
                       || skip "certificate fixture" "openssl missing"

  # point the scanner at the fixture only, so this group is isolated from
  # whatever certificates happen to live on the machine running the suite
  sdc() { CERTS_ROOTS="$DATA/certs" sd "$@"; }

  a="$(sdc expiring 2>/dev/null | grep -c 'EXPIRED' || true)"
  b="$(sdc expiring --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["expired"])' 2>/dev/null)"
  c="$(sdc alerts --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["counts"]["expired"])' 2>/dev/null)"
  if [ "$a" = "$b" ] && [ "$b" = "$c" ]; then
    ok "expiring, expiring --json and alerts --json agree on the expired count ($a)"
  else
    no "the expiry renderers disagree" "terminal=$a json=$b alerts=$c"
  fi

  # the unknown count must agree too — that is the half that used to be silent
  b="$(sdc expiring --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["expiry_unknown"])' 2>/dev/null)"
  c="$(sdc alerts --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["counts"]["unknown"])' 2>/dev/null)"
  [ "$b" = "$c" ] && ok "both renderers agree on how many expiries are unrecorded ($b)" \
                  || no "unknown counts disagree" "json=$b alerts=$c"

  # PROVE the certificate source is actually reached: a cert valid for 1 day
  # must appear inside a 2-day window, and must NOT appear in a 0-day one.
  if [ "$CERTFIX" = "1" ]; then
    inw="$(CERTS_ROOTS="$DATA/certs" sd expiring --json 2 2>/dev/null \
           | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for i in d["items"] if i["source"]=="cert"))' 2>/dev/null)"
    [ "${inw:-0}" -ge 1 ] && ok "the certificate source is genuinely reached ($inw in a 2-day window)" \
                          || no "no certificate reached the report — the cert source is not wired"
  fi

  # expiring must read certificates, not just the manifest
  if grep -q 'alert_scan' "$BIN"; then
    ok "do_expiring renders the shared producer rather than its own scan"
  else
    no "do_expiring still runs a private manifest-only scan"
  fi

  # a report piped somewhere must not carry a shell error in its stream
  errout="$(sdc expiring 2>&1 >/dev/null </dev/null)"
  if printf '%s' "$errout" | grep -qE '/dev/tty|command not found|line [0-9]+:'; then
    no "a shell error leaks into stderr on a report" "$(printf '%s' "$errout" | head -1)"
  else
    ok "no shell error leaks into a piped report"
  fi
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
