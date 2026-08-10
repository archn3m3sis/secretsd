#!/usr/bin/env bash
# lib/json.sh — machine-readable output.
#
# Everything this program knows about the SHAPE of your credentials — names,
# ages, expiry, posture findings, session inventory — is emitted as JSON so it
# can feed a script, a dashboard, a CI gate, or an agent.
#
# THE ONE RULE: no `--json` output ever contains a credential VALUE. Not
# truncated, not hashed, not "just the first four characters". The whole point
# of this program is that values reach exactly one child process and nowhere
# else, and a JSON mode that leaks them would quietly undo that. Names, dates,
# counts, and verdicts only. jq_leak in the test suite enforces this.
#
# Sourced, never executed.

# json_str VALUE -> a correctly escaped JSON string, including the quotes.
# Hand-rolling this with sed is how you end up emitting invalid JSON the first
# time a key contains a backslash, so python does it.
json_str() {
  printf '%s' "${1-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

# json_emit — read "key<TAB>value" pairs on stdin, print one JSON object.
# Values are emitted as strings unless they look like a bare integer or a
# boolean, which keeps `.count` usable as a number in jq without quoting.
json_emit() {
  python3 -c '
import json, sys
o = {}
for line in sys.stdin:
    line = line.rstrip("\n")
    if "\t" not in line:
        continue
    k, v = line.split("\t", 1)
    if v.isdigit():                 o[k] = int(v)
    elif v in ("true", "false"):    o[k] = (v == "true")
    elif v == "null":               o[k] = None
    else:
        try:    o[k] = json.loads(v) if v[:1] in "[{" else v
        except Exception: o[k] = v
print(json.dumps(o, indent=2))
'
}

# json_array — read one item per line on stdin, print a JSON array of strings.
json_array() {
  python3 -c '
import json, sys
print(json.dumps([l.rstrip("\n") for l in sys.stdin if l.strip()], indent=2))
'
}

json_meta() {
  printf 'tool\tsecretsd\n'
  printf 'version\t%s\n' "${SEC_VERSION:-dev}"
  printf 'generated\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'host\t%s\n' "$(hostname -s 2>/dev/null || printf 'unknown')"
}

# ---------------------------------------------------------------------------
# per-command JSON producers
#
# Each one reuses the SAME producer the terminal report uses — doctor_probe,
# posture_scan, the manifest — so the two renderers can never disagree about
# what was found. None of them touch a credential value.
# ---------------------------------------------------------------------------

# names — the inventory. Names only; that is the whole point.
json_names() {
  local names; names="$(sec_names)"
  {
    json_meta
    printf 'count\t%s\n' "$(printf '%s\n' "$names" | sec_nlines)"
    printf 'names\t%s\n' "$(printf '%s\n' "$names" | json_array | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)))')"
  } | json_emit
}

# doctor — every check with its verdict. Exit code mirrors severity so this is
# usable as a CI gate: 0 clean, 1 warnings only, 2 any failure.
json_doctor() {
  doctor_probe 2>/dev/null > "$TMPD/doctor.json.rec" || true
  python3 - "$TMPD/doctor.json.rec" "${SEC_VERSION:-dev}" <<'PY_DOC'
import json, sys, socket, datetime
rows, fail, warn = [], 0, 0
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line or "\t" not in line:
            continue
        p = (line.split("\t") + ["", "", "", ""])[:4]
        st, sec, chk, det = p
        rows.append({"status": st, "section": sec, "check": chk, "detail": det})
        if st == "fail": fail += 1
        elif st == "warn": warn += 1
print(json.dumps({
    "tool": "secretsd", "version": sys.argv[2],
    "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host": socket.gethostname().split(".")[0],
    "checks": rows,
    "total": len(rows), "failures": fail, "warnings": warn,
    "healthy": fail == 0,
}, indent=2))
sys.exit(2 if fail else (1 if warn else 0))
PY_DOC
}

# expiring — anything with a known expiry, soonest first, plus the ones whose
# expiry nobody ever recorded. Those are not "fine"; they are unknown, and the
# JSON says so rather than omitting them.
json_expiring() {
  local days="${1:-30}"
  alert_scan "$days" "$days" 2>/dev/null > "$TMPD/exp.json.rec" || true
  python3 - "$TMPD/exp.json.rec" "$days" "${SEC_VERSION:-dev}" <<'PY_EXP'
import json, sys, socket, datetime
window = int(sys.argv[2])
items, expired, soon, unknown = [], 0, 0, 0
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line or "|" not in line:
            continue
        p = (line.split("|") + ["", "", "", "", ""])[:5]
        sev, src, name, detail, left = p
        try:    left_i = int(left)
        except ValueError: left_i = None
        status = "expired" if sev == "expired" else ("soon" if sev in ("urgent", "soon") else "unknown")
        if status == "expired": expired += 1
        elif status == "soon":  soon += 1
        else:                   unknown += 1
        items.append({"name": name, "status": status, "source": src,
                      "detail": detail, "days_left": left_i})
rank = {"expired": 0, "soon": 1, "unknown": 2}
items.sort(key=lambda r: (rank.get(r["status"], 9),
                          r["days_left"] if r["days_left"] is not None else 10**9))
print(json.dumps({
    "tool": "secretsd", "version": sys.argv[3],
    "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host": socket.gethostname().split(".")[0],
    "window_days": window,
    "items": items,
    "total": len(items), "expired": expired, "expiring_soon": soon,
    "expiry_unknown": unknown,
}, indent=2))
sys.exit(2 if expired else (1 if soon else 0))
PY_EXP
}

# posture — the security findings. posture_scan already emits records; this only
# reshapes them. Field order is: severity|id|action|title|detail|path
json_posture() {
  posture_scan 2>/dev/null > "$TMPD/posture.json.rec" || true
  python3 - "$TMPD/posture.json.rec" "${SEC_VERSION:-dev}" <<'PY_POS'
import json, sys, socket, datetime
rows, crit, med, low = [], 0, 0, 0
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line or "|" not in line:
            continue
        p = (line.split("|") + ["", "", "", "", "", ""])[:6]
        sev, fid, action, title, detail, path = p
        rows.append({"severity": sev, "id": fid, "remediation": action,
                     "finding": title, "detail": detail, "path": path or None})
        if sev == "crit": crit += 1
        elif sev == "med": med += 1
        elif sev == "low": low += 1
order = {"crit": 0, "med": 1, "low": 2}
rows.sort(key=lambda r: order.get(r["severity"], 9))
print(json.dumps({
    "tool": "secretsd", "version": sys.argv[2],
    "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host": socket.gethostname().split(".")[0],
    "findings": rows,
    "total": len(rows), "critical": crit, "medium": med, "low": low,
}, indent=2))
sys.exit(2 if crit else (1 if (med or low) else 0))
PY_POS
}

# sessions — the adopted Claude Code sessions and their human names.
json_sessions() {
  : > "$TMPD/sess.json.rec"
  local u
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$u" \
      "$(ws_session_field "$u" name)" \
      "$(ws_session_field "$u" project)" \
      "$(ws_session_field "$u" path)" \
      "$(ws_session_field "$u" mode)" \
      "$(ws_session_field "$u" started)" >> "$TMPD/sess.json.rec"
  done <<SESS
$(ws_session_ids)
SESS
  python3 - "$TMPD/sess.json.rec" "${SEC_VERSION:-dev}" <<'PY_SESS'
import json, sys, socket, datetime
rows = []
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line or "\t" not in line:
            continue
        p = (line.split("\t") + [""] * 6)[:6]
        uuid, name, project, path, mode, started = p
        rows.append({"uuid": uuid, "name": name or None, "project": project or None,
                     "path": path or None, "mode": mode or None, "started": started or None})
print(json.dumps({
    "tool": "secretsd", "version": sys.argv[2],
    "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host": socket.gethostname().split(".")[0],
    "sessions": rows,
    "count": len(rows),
    "named": sum(1 for r in rows if r["name"]),
}, indent=2))
PY_SESS
}

# alerts — the scheduled expiry scan, machine-readable. Same exit contract:
# 2 when something has expired, 1 when something is inside a warning window.
json_alerts() {
  alert_scan 2>/dev/null > "$TMPD/alerts.json.rec" || true
  python3 - "$TMPD/alerts.json.rec" "${SEC_VERSION:-dev}" "$ALERT_SOON" "$ALERT_URGENT" <<'PY_AL'
import json, sys, socket, datetime
rows = {"expired": [], "urgent": [], "soon": [], "unknown": []}
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line or "|" not in line:
            continue
        p = (line.split("|") + ["", "", "", "", ""])[:5]
        sev, src, name, detail, left = p
        if sev not in rows:
            continue
        try:    left_i = int(left)
        except ValueError: left_i = None
        rows[sev].append({"name": name, "source": src, "detail": detail, "days_left": left_i})
for k in rows:
    rows[k].sort(key=lambda r: (r["days_left"] is None, r["days_left"]))
print(json.dumps({
    "tool": "secretsd", "version": sys.argv[2],
    "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host": socket.gethostname().split(".")[0],
    "thresholds": {"soon_days": int(sys.argv[3]), "urgent_days": int(sys.argv[4])},
    "expired": rows["expired"], "urgent": rows["urgent"],
    "soon": rows["soon"], "expiry_unknown": rows["unknown"],
    "counts": {k: len(v) for k, v in rows.items()},
}, indent=2))
sys.exit(2 if rows["expired"] else (1 if (rows["urgent"] or rows["soon"]) else 0))
PY_AL
}

# json_dispatch CMD [ARGS…] -> 0 when handled, 1 when the command has no JSON
# form, so the caller can say so instead of silently printing a TUI.
json_dispatch() {
  case "${1:-}" in
    names|ls|list) json_names ;;
    doctor)        json_doctor ;;
    expiring)      shift; json_expiring "${1:-30}" ;;
    posture)       json_posture ;;
    sessions)      json_sessions ;;
    alerts)        json_alerts ;;
    *)             return 1 ;;
  esac
}
