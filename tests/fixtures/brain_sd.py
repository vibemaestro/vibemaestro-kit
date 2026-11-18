"""Windows security descriptors built as bytes, for the brain's descriptor reader (brain_store.sd_problem) on any system.

Run: python3 brain_sd.py <brain scripts dir> — prints one answer per line: each named descriptor, then the counts of the
truncated and fuzzed ones. The layouts are the documented self-relative ones: SECURITY_DESCRIPTOR_RELATIVE (20 bytes), ACL
(8-byte header), ACE_HEADER then the mask and the SID, SID (revision, count, 6-byte authority, 32-bit sub-authorities).
"""
import random
import struct
import sys

sys.path.insert(0, sys.argv[1])
import brain_store as s  # noqa: E402

ME, ADM, SYS, EVERY, USERS = "S-1-5-21-1-2-3-1001", "S-1-5-32-544", "S-1-5-18", "S-1-1-0", "S-1-5-32-545"
FA, GA, SYNC = 0x001F01FF, 0x10000000, 0x00100000
OICI, OICI_IO = 0x03, 0x0B


def sid(t):
    p = t.split("-")
    subs = [int(x) for x in p[3:]]
    return bytes([1, len(subs)]) + int(p[2]).to_bytes(6, "big") + struct.pack("<%dI" % len(subs), *subs)


def ace(sid_t, mask=FA, kind=0, flags=OICI):
    body = struct.pack("<I", mask) + sid(sid_t)
    return struct.pack("<BBH", kind, flags, 4 + len(body)) + body


def acl(*aces, rev=2):
    body = b"".join(aces)
    return struct.pack("<BBHHH", rev, 0, 8 + len(body), len(aces), 0) + body


def sd(owner, dacl, ctrl=0x8004):
    """Self-relative, owner then DACL; dacl None: no DACL present."""
    o = sid(owner)
    return struct.pack("<BBHIIII", 1, 0, ctrl if dacl is not None else 0x8000, 20, 0, 0, 20 + len(o) if dacl is not None else 0) + o + (dacl or b"")


PROFILE = sd(ME, acl(ace(SYS), ace(ADM), ace(ME)))   # what a folder under the user's profile carries
CASES = [
    ("profile", PROFILE, (ME, ME)),
    ("another owner", sd(SYS, acl(ace(SYS), ace(ME))), (ME, ME)),
    ("everyone may change", sd(ME, acl(ace(ME), ace(EVERY, 0x001301BF))), (ME, ME)),
    ("users may read", sd(ME, acl(ace(ME), ace(USERS, 0x001200A9))), (ME, ME)),
    ("no dacl", sd(ME, None), (ME, ME)),
    ("inherit-only everyone", sd(ME, acl(ace(ME), ace(EVERY, GA, flags=OICI_IO))), (ME, ME)),
    ("creator owner", sd(ME, acl(ace(ME), ace("S-1-3-0", GA, flags=OICI_IO))), (ME, ME)),
    ("deny everyone", sd(ME, acl(ace(ME), ace(EVERY, FA, kind=1))), (ME, ME)),
    ("everyone synchronize", sd(ME, acl(ace(ME), ace(EVERY, SYNC))), (ME, ME)),
    ("callback allow", sd(ME, acl(ace(ME), ace(EVERY, FA, kind=9))), (ME, ME)),
    ("python 3.13 mkdir 0o700", sd(ME, acl(ace(SYS), ace(ADM), ace("S-1-3-4")), ctrl=0x9004), (ME, ME)),
    ("elevated, owner administrators", sd(ADM, acl(ace(SYS), ace(ADM), ace(ME))), (ME, ADM)),
    ("not elevated, owner administrators", sd(ADM, acl(ace(SYS), ace(ADM), ace(ME))), (ME, ME)),
    ("acl revision 4", sd(ME, acl(ace(ME), rev=4)), (ME, ME)),
    ("empty dacl", sd(ME, acl()), (ME, ME)),
]


def patched(b, at, fmt, v):
    b = bytearray(b)
    struct.pack_into(fmt, b, at, v)
    return bytes(b)


O_ACL = 20 + len(sid(ME))                           # the DACL's offset in PROFILE
CASES += [
    ("sd revision 2", patched(PROFILE, 0, "<B", 2), (ME, ME)),
    ("not self-relative", patched(PROFILE, 2, "<H", 0x0004), (ME, ME)),
    ("owner offset past the end", patched(PROFILE, 4, "<I", len(PROFILE)), (ME, ME)),
    ("owner with 16 sub-authorities", patched(PROFILE, 21, "<B", 16), (ME, ME)),
    ("dacl offset past the end", patched(PROFILE, 16, "<I", len(PROFILE) - 4), (ME, ME)),
    ("acl size past the end", patched(PROFILE, O_ACL + 2, "<H", len(PROFILE)), (ME, ME)),
    ("one ace more than there is", patched(PROFILE, O_ACL + 4, "<H", 4), (ME, ME)),
    ("ace size past the acl", patched(PROFILE, O_ACL + 8 + 2, "<H", 0xFFFF), (ME, ME)),
    ("ace size below an allow ace", patched(PROFILE, O_ACL + 8 + 2, "<H", 8), (ME, ME)),
    ("ace sid past its ace", patched(PROFILE, O_ACL + 8 + 9, "<B", 5), (ME, ME)),
]
for name, b, mine in CASES:
    print("%s: %s" % (name, s.sd_problem(b, mine)))
print("prefixes answered None: %d of %d" % (sum(s.sd_problem(PROFILE[:n], (ME, ME)) is None for n in range(len(PROFILE))),
                                             len(PROFILE)))
rnd, raised = random.Random(911), 0
for _ in range(3000):
    b = bytearray(PROFILE)
    for _ in range(rnd.randint(1, 4)):
        b[rnd.randrange(len(b))] = rnd.randrange(256)
    junk = bytes(rnd.randrange(256) for _ in range(rnd.randint(0, 120)))
    for x in (bytes(b), junk, bytes(b[:rnd.randint(0, len(b))])):
        try:
            s.sd_problem(x, (ME, ME))
        except Exception:
            raised += 1
print("fuzzed descriptors that raised: %d" % raised)
print("owner only, another owner: %s" % s.sd_problem(sd(SYS, None), (ME, ME), owner_only=True))
print("owner only, no dacl: %s" % s.sd_problem(sd(ME, None), (ME, ME), owner_only=True))
