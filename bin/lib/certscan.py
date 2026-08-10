#!/usr/bin/env python3
"""Read every certificate's identity and expiry in ONE process.

WHY THIS EXISTS. The certificate screen used to shell out to `openssl` once per
FIELD per certificate — subject, then enddate, then enddate again from inside
certs_days_left — plus `date` twice to convert it and `grep` to count the
bundle. About six processes per certificate. Measured on one real machine: 58
certificates, 2.855 seconds, every time the screen was opened.

The dates live in the certificate itself, in DER, and DER is walkable. This
parses them directly: one python process for the whole scan, no forks at all.

HONESTY ABOUT THE PARSE. This is a deliberately minimal walker — enough of
X.509 to reach `validity` and the subject's CN, not a validation library. It
does not check signatures, chains, or anything else, because the screen does not
either; it reports what a certificate SAYS about itself. Anything it cannot
parse is reported with reason "unparsed" and the caller falls back to openssl
for that one file, so a strange certificate degrades to the old slow path
instead of vanishing from the report. Vanishing is the dangerous failure here:
a certificate that silently drops off an expiry report is exactly the one that
takes something down.

usage: certscan.py FILE...
output: one TSV line per certificate file
    path <TAB> cn <TAB> notAfter_epoch <TAB> count <TAB> status
    status is `ok` or `unparsed`; on `unparsed` the cn and epoch are empty.
"""

import base64
import calendar
import re
import sys

PEM = re.compile(rb"-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----", re.S)


def der_read(buf, i):
    """Read one TLV at offset i -> (tag, content_start, content_len, next_offset)."""
    tag = buf[i]
    i += 1
    n = buf[i]
    i += 1
    if n & 0x80:
        k = n & 0x7F
        if k == 0 or k > 4:
            raise ValueError("unsupported length")
        n = int.from_bytes(buf[i:i + k], "big")
        i += k
    return tag, i, n, i + n


def der_children(buf, start, end):
    i = start
    while i < end:
        tag, cs, cl, nxt = der_read(buf, i)
        yield tag, cs, cl
        i = nxt


def parse_time(buf, tag, cs, cl):
    """UTCTime (0x17) or GeneralizedTime (0x18) -> epoch seconds."""
    raw = buf[cs:cs + cl].decode("ascii", "replace").rstrip("Z")
    if tag == 0x17:                      # YYMMDDHHMMSS
        yy = int(raw[0:2])
        year = 2000 + yy if yy < 50 else 1900 + yy
        rest = raw[2:]
    elif tag == 0x18:                    # YYYYMMDDHHMMSS
        year = int(raw[0:4])
        rest = raw[4:]
    else:
        raise ValueError("not a time")
    mo, dy, hh = int(rest[0:2]), int(rest[2:4]), int(rest[4:6])
    mi = int(rest[6:8]) if len(rest) >= 8 else 0
    ss = int(rest[8:10]) if len(rest) >= 10 else 0
    return calendar.timegm((year, mo, dy, hh, mi, ss, 0, 0, 0))


CN_OID = bytes([0x55, 0x04, 0x03])       # 2.5.4.3


def subject_cn(buf, start, end):
    """Walk an RDNSequence for the LAST commonName, which is the leaf's own."""
    found = None
    for _, sset_s, sset_l in der_children(buf, start, end):
        for _, atv_s, atv_l in der_children(buf, sset_s, sset_s + sset_l):
            kids = list(der_children(buf, atv_s, atv_s + atv_l))
            if len(kids) < 2:
                continue
            (_, oid_s, oid_l), (_, val_s, val_l) = kids[0], kids[1]
            if buf[oid_s:oid_s + oid_l] == CN_OID:
                found = buf[val_s:val_s + val_l].decode("utf-8", "replace")
    return found


def cert_fields(der):
    """-> (cn, notAfter_epoch)"""
    _, cs, cl, _ = der_read(der, 0)                       # Certificate
    kids = list(der_children(der, cs, cs + cl))
    _, tbs_s, tbs_l = kids[0]                             # tbsCertificate

    fields = list(der_children(der, tbs_s, tbs_s + tbs_l))
    # version is [0] EXPLICIT and optional; everything shifts by one when present
    idx = 1 if fields and fields[0][0] == 0xA0 else 0
    # serialNumber, signature, issuer, validity, subject
    _, val_s, val_l = fields[idx + 3]
    _, sub_s, sub_l = fields[idx + 4]

    times = list(der_children(der, val_s, val_s + val_l))
    if len(times) < 2:
        raise ValueError("validity has no notAfter")
    tag, cs2, cl2 = times[1]
    not_after = parse_time(der, tag, cs2, cl2)

    return subject_cn(der, sub_s, sub_s + sub_l), not_after


def main():
    for path in sys.argv[1:]:
        try:
            with open(path, "rb") as fh:
                blob = fh.read()
        except OSError:
            continue

        blocks = PEM.findall(blob)
        if blocks:
            count = len(blocks)
            try:
                der = base64.b64decode(re.sub(rb"\s+", b"", blocks[0]))
            except Exception:
                print("%s\t\t\t%d\tunparsed" % (path, count))
                continue
        else:
            # a bare DER file (.cer is often DER, not PEM)
            count = 1
            der = blob

        try:
            cn, exp = cert_fields(der)
        except Exception:
            print("%s\t\t\t%d\tunparsed" % (path, count))
            continue

        print("%s\t%s\t%d\t%d\tok" % (path, cn or "", exp, count))


if __name__ == "__main__":
    main()
