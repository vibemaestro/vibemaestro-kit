#!/bin/bash
# =============================================================================
# Gate: sensitive values in PR text (plugins/vibemaestro-sdlc/gates/pr_sensitive.py), the families of the hub's scanner tests
# =============================================================================
# Run: bash tests/test-gates-sensitive.sh
#
# The scanner FAILS CLOSED: an exemption depends only on the shape of the value, never on the words around it. So the positive cases
# include the sentences that were once exempt by context (`curl -v <ip>`, `tag: <ip>`, `suppose it leaked: <id>`, `version <ip-shaped>`),
# and the negative cases are the SHAPES that are exempt (multicast, a cluster-internal DSN, `git@<git host>`, a variable name with
# no digit, a name glued to a version, `<...>`, `${VAR}`, `***`). A real false positive is exempted by the sha256 of that value in
# the allowlist, never by loosening a rule.
#
# A positive case asserts the KIND of pattern, not only rc 1: a text often matches several patterns (`postgres://u:pw@host` matches
# the e-mail one too), so counting rc would let one pattern vanish while another catches for it.
#
# Positive fixtures are built by joining strings at run time: a whole fake token in this file would be caught by the secret scanners
# that read it.
#
#   [P] every pattern red on its kind      [N] every exempt shape green        [L] masked output only, on every channel
#   [C] the PR shape: body, comments, commits, scan scopes, warnings, --git-log, --corpus
#   [A] the allowlist: hashes only, read from the base ref in CI, never a raw value, the sha256 only outside Actions
#   [G] --pr through a fake gh: every source, pagination, truncation, base-ref reads, gh failing
# Real git and a fake gh, no network, no sleep.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/flow.sh
. "$HERE/fixtures/flow.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"
# shellcheck source=fixtures/gates.sh
. "$HERE/fixtures/gates.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1   # the families import the real plugin modules: no __pycache__ in the checkout that parallel suites copy
[ -f "$PLUGIN/gates/pr_sensitive.py" ] && ok "the gate exists" || { bad "the gate is missing"; summary; exit 1; }

W="$TMP/gen"; mkdir -p "$W"
python3 - "$W" <<'PY'
import hashlib, os, sys
W = sys.argv[1]
j = "".join
R = "aB3xK9pQ2mZ7vL4nW8rT6yU1"          # all three character classes, looks random
H = lambda tag: hashlib.md5(tag.encode()).hexdigest()   # a real-looking hex id: random, no repeat, no run
G = lambda tag: "-".join([H(tag)[:8], H(tag)[8:12], H(tag)[12:16], H(tag)[16:20], H(tag)[20:32]])
IP = lambda *x: ".".join(x)
POS = {  # case: (kind that must be named, text)
    "github-token":   ("github-token", "my token " + j(["gh", "p_"]) + R + R[:12]),
    "github-pat":     ("github-token", j(["github", "_pat_"]) + R + R),
    "api-key-sk":     ("api-key-sk", "key " + j(["sk", "-ant-"]) + R),
    "slack-token":    ("slack-token", j(["xo", "xb-"]) + "1234567890-" + R),
    "aws-access-key": ("aws-access-key", j(["AK", "IA"]) + "Q7W3E9R2T5Y8U1I4"),
    "vault-token":    ("vault-token", "VAULT_TOKEN is " + j(["hv", "s."]) + R),
    "jwt":            ("jwt", j(["ey", "J"]) + "hbGciOiJIUzI1.eyJzdWIiOiIxMjM0.SflKxwRJSM"),
    "private-key":    ("private-key", j(["-----BEGIN ", "OPENSSH PRIVATE KEY-----"])),
    "age-secret-key": ("age-secret-key", j(["AGE-SECRET", "-KEY-1"]) + "QWERTYUIOP1234567890ASDF"),
    "bearer-token":   ("bearer-token", "Authorization: Bearer " + R),
    # one case per keyword of secret-assignment: dropping a keyword from the regex turns its case red
    "kv-password":    ("secret-assignment", "DB_PASSWORD=" + R),
    "kv-passwd":      ("secret-assignment", "passwd: " + R),
    "kv-secret":      ("secret-assignment", "secret=" + R),
    "kv-token":       ("secret-assignment", "token = " + R),
    "kv-api_key":     ("secret-assignment", '"api_key": "' + R + '"'),
    "kv-apikey":      ("secret-assignment", "apikey=" + R),
    "kv-client_secret": ("secret-assignment", "client_secret: " + R),
    "kv-access_key":  ("secret-assignment", "access-key=" + R),
    "url-credential": ("url-credential", "postgres://app:" + "Zq8" + "Lm2Kp9@db:5432/x"),
    "long-base64":    ("long-base64", "data: " + R + R + "=="),
    "account-id":     ("account-id", '"account_id": "' + H("acct") + '"'),
    "account-id-guid": ("account-id", "tenant " + G("tenant")),
    "zone-id":        ("account-id", "zone ID of acme: " + H("zone")),
    "subscription-id": ("account-id", "subscription " + G("sub")),
    "dash-url":       ("cloud-account-url", "https://dash.cloudflare.com/" + H("dash") + "/workers"),
    "accounts-api":   ("cloud-account-url", "GET /client/v4/accounts/" + H("api") + "/tokens"),
    "email":          ("email", "log in with " + j(["jane.doe", "@", "gmail.com"])),
    "phone-national": ("phone", "call 0" + "912345678"),
    "phone-intl":     ("phone", "call +84" + "912345678"),
    # a number glued to letters, an underscore or a non-ASCII letter is still a number; only a digit or a dot next to it is not
    "phone-glued-prefix": ("phone", "tel0" + "912345678"),
    "phone-glued-underscore": ("phone", "phone_0" + "912345678"),
    "phone-glued-suffix": ("phone", "0" + "912345678abc"),
    "phone-glued-letter": ("phone", "a0" + "912345678"),
    "phone-glued-nonascii": ("phone", "sdt:0" + "912345678\u0111"),
    "phone-glued-plus": ("phone", "x+84" + "912345678"),
    # the digits that end a commit id, written in prose, are still a number
    "phone-sha-digits-prose": ("phone", "call 0" + "862421027"),
    # …and a 40-hex word glued to a word character is not a whole id: the boundary of the exemption holds
    "phone-sha-glued-underscore": ("phone", "x_f95235a7dbbbff47719bed8eb8c3be" + "0862421027"),
    "public-ipv4":    ("public-ipv4", "edge node at " + IP("103", "97", "12", "44")),
    "public-ipv4-cidr": ("public-ipv4", "allowlist " + IP("45", "117", "80", "0") + "/24"),
    "workstation-ip": ("public-ipv4", "ufw allow from " + IP("1", "54", "200", "7") + " to any port 80"),
    # the word "version" on ANOTHER line does not exempt an IP: context counts only when glued
    "ip-after-version-line": ("public-ipv4", "version 2\nnode " + IP("103", "97", "12", "44")),
    # "example" in the sentence before the keyword does not exempt a real id after the keyword
    "id-example-before-kw": ("account-id", "example below. zone " + H("z2")),
    # sentences that used to slip through by context; all red now
    "r2-curl-v":      ("public-ipv4", "curl -v " + IP("45", "77", "12", "34")),
    "r2-basic-host":  ("public-ipv4", "basic host: " + IP("45", "77", "12", "34")),
    "r2-tag":         ("public-ipv4", "tag: " + IP("45", "77", "12", "34")),
    "r2-suppose":     ("account-id", "account ID, suppose it leaked: " + H("r2")),
    "r2-dash-eg":     ("cloud-account-url", "e.g. https://dash.cloudflare.com/" + H("r2d")),
    "r2-screaming-digits": ("secret-assignment", "password=" + "PROD_K8S_" + "2026_XQ"),
    "r2-git-at-other": ("email", "g" + "it@evil-host.test"),
    # fail closed: words around or inside the value do not exempt it
    "fc-version-space": ("public-ipv4", "version 1.25.3.1"),
    "fc-ip-1-2-3":    ("public-ipv4", "e.g. 1.2.3.0/24"),
    "fc-id-eg-ctx":   ("account-id", "tenant for example " + G("eg")),
    "fc-id-example":  ("account-id", "zone (example) " + H("ex")),
    "fc-id-substr":   ("account-id", "zone " + H("s")[:10] + "0123456" + H("s")[17:]),
    "fc-fake-cred-url": ("url-credential", "https://user:" + j(["gh", "p_"]) + "SECRET123@host"),
    "fc-kebab-digits": ("secret-assignment", "secret=" + j(["db-", "pass-", "2026"])),
    "fc-email-internal": ("email", "admin@host.internal"),
    "fc-email-local": ("email", "ops@b.local"),
    # password characters, a `/` in a URL password, passphrases, tokens that merely contain a placeholder mark
    "kv-at-bang":     ("secret-assignment", "password: P" + "@ssw0rd!2026xyz"),
    "kv-hash":        ("secret-assignment", "password: Hunter" + "#2026Abcd"),
    "kv-dollar-inside": ("secret-assignment", "secret=Abc" + "$def2026XyZq"),
    "url-slash":      ("url-credential", "postgres://app:" + "Zq8/Lm2Kp9x@db/x"),
    "url-short":      ("url-credential", "postgres://app:" + "Zq8Lm2Kp9@db/x"),
    "url-stars-inside": ("url-credential", "https://app:" + "Zq8Lm2Kp9x***Wd4Rt7@git.example.org/x"),
    "url-angle-inside": ("url-credential", "https://app:" + "Zq8Lm2<Kp9x7Wd4@git.example.org/x"),
    "diceware-password": ("secret-assignment", "password=" + "correct-horse-battery-staple"),
    "diceware-passwd-3": ("secret-assignment", "passwd: " + "horse-battery-staple"),
    "diceware-secret-4": ("secret-assignment", "secret=" + "correct-horse-battery-staple"),
    "bearer-xxx":     ("bearer-token", "Authorization: Bearer " + R[:8] + "xxx" + R[8:]),
    "bearer-dollar":  ("bearer-token", "Authorization: Bearer " + R[:8] + "$DEF" + R[8:]),
    "sk-xxx":         ("api-key-sk", "key " + j(["sk", "-ant-"]) + R[:8] + "xxx" + R[8:]),
    "ph-xxx-left-10": ("secret-assignment", "password: " + j(["abc", "xxx", "1234567"])),
    # a run of 3 or 4 of a character other than x or * is part of the value, not a mask
    "url-repeat-digits": ("url-credential", "postgres://app:" + "hunter222@db/x"),
    "kv-repeat-letters": ("secret-assignment", "secret=" + "aaaa1234bcdE"),
    "kv-run-digits-5": ("secret-assignment", "password=" + "Pass00000word"),
    "kv-dollar-start": ("secret-assignment", "password=" + "$uperS3cretPass2026"),   # a name with all three classes is a password
    "kv-var-random-tail": ("secret-assignment", "token: $PROD_DB_PASS." + "xK2mQ7pL"),  # random text after a variable is not a suffix
    "url-var-random-tail": ("url-credential", "mongodb://root:$PROD_DB_PASS-" + "xK2mQ7pL@mongo"),
    # round 2: a dotted user part, and a `/` password with two of the three classes
    "url-dotted-user": ("url-credential", "postgres://john.doe:" + "Xk9mQ2/pLw7ZrAb@db:5432/app"),
    "url-slash-two-classes": ("url-credential", "postgres://svc:" + "Abcdefgh/ijklmnop@localhost/app"),
    # a run of one letter beside other text is part of the value, in every context that asks for a placeholder
    "run-pw":         ("secret-assignment", "password: " + "zzzzz" + R[:9]),
    "run-pw-upper":   ("secret-assignment", "password: " + "ZZZZZ" + R[:9]),
    "run-tail":       ("secret-assignment", "token: " + R[:9] + "qqqqq"),
    "run-two-runs":   ("secret-assignment", "password: " + "aaaaa" + R[:9] + "bbbbb"),
    "run-passphrase": ("secret-assignment", "password: " + "hellooooo-world"),
    "run-url":        ("url-credential", "https://app:" + "zzzzz" + R[:9] + "@db/x"),
    "run-bearer":     ("bearer-token", "Authorization: Bearer " + "zzzzzz." + R[:9]),
    "run-sk":         ("api-key-sk", "key " + j(["sk", "-"]) + "z" * 17 + R[:7]),
    "run-of-3-segments": ("secret-assignment", "password: " + "aaa-bbb-ccc-ddd"),   # a run counts from 5 letters
    # one run of one letter alone is red, as at the hub: a weak password, not a mask
    "run-single-url":  ("url-credential", "https://app:" + "pppppppp" + "@db/x"),
    "run-single-pw":   ("secret-assignment", "password: " + "yyyyyyyyyyyy"),
    "run-single-bearer": ("bearer-token", "Authorization: Bearer " + "a" * 20),
    # runs of one letter with no placeholder part are red too, as at the hub (it exempts only a value with `xxx`, `***`, `<`, `${`)
    "run-runs-no-part-bearer": ("bearer-token", "Authorization: Bearer " + "aaaaaaaaaa.bbbbbbbbbb"),
    "run-runs-no-part-pw": ("secret-assignment", "password: " + "aaaaa__ccccc"),
    # next to a part, a run counts only when nothing else is left
    "run-x-then-random": ("bearer-token", "Authorization: Bearer " + "xxxxx.yyyyy." + R[:10]),
    "run-of-3-next-to-part": ("secret-assignment", "password: " + "xxxaaa" + R[:9]),   # filler counts from 5 letters
    # review round 1: a mark after a character 1.0.0 did not read (`@ ! $ #`, `$` after bearer) does not exempt the text before it
    "kv-mark-after-hash": ("secret-assignment", "password: " + "zzzzz" + R[:9] + "#xxx"),
    "kv-mark-after-at": ("secret-assignment", "token: " + R[:9] + "qqqqq" + "@xxx"),
    "kv-mark-after-dollar": ("secret-assignment", "api_key=" + "aaaaabbbbb" + R[:9] + "$xxx"),
    "kv-mark-after-hash-norun": ("secret-assignment", "password: " + "Ab3-xK9-pQ2-" + "#xxx"),
    "bearer-mark-after-dollar": ("bearer-token", "Authorization: Bearer " + "zzzzzzz" + R[:9] + "$xxx"),
    # `${...}` is a placeholder only around a name; a lower-cased `İ` is two characters; removing a part joins no letters
    "url-brace-digit": ("url-credential", "https://user:" + "${9Zx2Kq7Lm4Pw8Rt}" + "@db/app"),
    "url-brace-empty": ("url-credential", "https://app:" + "${}" + R[:9] + "@db/x"),
    "url-unicode-lower": ("url-credential", "https://app:" + "\u0130" + "Ab3xK9pQ@db/x"),
    "run-joined-by-part": ("bearer-token", "Authorization: Bearer " + "kkkkxxxkkkk" + "B3xK9pQ7"),
    # review round 2: a value that swallows a second assignment glued behind a stop character does not hide it
    "kv-swallowed-second": ("secret-assignment", "token=xxxxxx#token=" + R[:14]),
    "kv-swallowed-second-pw": ("secret-assignment", "password=xxxxxx!!!!!!password: " + R[:14]),
    # a review case: a token key with a short value holding `@`, then a second secret key on the same line
    "kv-swallowed-at": ("secret-assignment", "token=ab@xxxxx@api_key=" + R[:14]),
    # review round 3: the other keyword pattern swallows the keyword of the real assignment (no stop character in the chain)
    "kv-chain-overlap": ("secret-assignment", "password=xxxxxx.secret=xxxxxxxxxxxx.token=" + R[:14]),
    "kv-chain-overlap-quoted": ("secret-assignment", "password: xxxxxx.access_key=xxxxxxxxxxxxmy_token=\"" + R[:14]),
    # a personal home-directory path, one case per shape, separator and boundary. Made-up names only.
    "home-macos":     ("home-path", "cd @U@alice/projects/x"),
    "home-linux":     ("home-path", "see @H@alice/work/x for the log"),
    "home-linux-bare": ("home-path", "@H@alice"),
    "home-windows":   ("home-path", "C:\\Users\\alice\\Desktop\\x.txt"),
    "home-windows-slash": ("home-path", "opened C:@U@alice/Desktop/x.txt"),
    "home-windows-mixed": ("home-path", "C:\\Users/alice\\x"),
    "home-windows-json": ("home-path", '{"p": "c:\\\\Users\\\\alice\\\\x"}'),
    "home-wsl":       ("home-path", "/mnt/c@U@alice/x"),
    "home-file-url":  ("home-path", "file://@U@alice/x.html"),
    "home-file-url-win": ("home-path", "file:///C:@U@alice/x.html"),
    "home-pct-posix": ("home-path", "link %2Fhome%2Falice%2Fx"),
    "home-pct-win":   ("home-path", "link C%3A%5CUsers%5Calice%5Cx"),
    "home-fenced":    ("home-path", "```\n$ ls @H@alice\n```"),
    "home-quoted":    ("home-path", 'path="@U@alice/x"'),
    "home-backtick":  ("home-path", "`@U@alice/x`"),
    "home-paren":     ("home-path", "see (@H@alice/x)"),
    "home-md-link":   ("home-path", "[log](@U@alice/x)"),
    "home-json":      ("home-path", '{"cwd":"@H@alice"}'),
    "home-assign":    ("home-path", "cwd=@H@alice/x"),
    "home-path-list": ("home-path", "PATH=/usr/bin:@H@alice/bin"),
    "home-colon":     ("home-path", "cwd:@H@alice/x"),
    "home-dotted-name": ("home-path", "x=@H@alice.smith/y"),
    "home-sentence-end": ("home-path", "it lives in @H@alice."),
    "home-nonascii":  ("home-path", "`@U@Nguy\u1ec5n/x`"),
    "home-name-foo":  ("home-path", "@H@foo/x"),
    "home-name-test": ("home-path", "@U@test/y"),
    "home-redirect":  ("home-path", "echo hi >@H@alice/log and 2>@H@alice/err"),
    "home-html-tag":  ("home-path", "<code>@H@alice</code>"),
    "home-html-br":   ("home-path", "<pre>@H@alice<br></pre>"),
    "home-diff-removed": ("home-path", "-@H@alice/x"),
    "home-diff-added": ("home-path", "+@H@alice/x"),
    "home-prompt-dollar": ("home-path", "bob@box:@H@alice$ ls"),
    "home-prompt-percent": ("home-path", "@U@alice% ls"),
    "home-glob":      ("home-path", "ls @H@alice*"),
    "home-brace":     ("home-path", "du -sh @H@alice{,.bak}"),
    "home-gitbash":   ("home-path", "/c@U@alice/x"),
    "home-cygdrive":  ("home-path", "/cygdrive/c@U@alice/x"),
    "home-one-letter-colon": ("home-path", "PATH=a:@H@alice and -v /a:@H@alice"),
    "home-pct-utf8":  ("home-path", "link %2Fhome%2FNguy%E1%BB%85n%2Fx"),
    "home-pct-twice": ("home-path", "link %252Fhome%252Falice"),
    "home-two-homes-two-values": ("home-path", "@H@alice/x and @U@bob/y"),
}
for w in ("Redacted", "changeme", "example-", "dummy_", "fake", "Secret"):   # a word inside the value does not exempt it
    POS["fc-word-" + w.strip("-_").lower()] = ("secret-assignment", "token=" + w + "Value2026")
NEG = {
    "git-sha":       "SHA: " + "9a8b7c6d5e4f" + "3a2b1c0d9e8f7a6b5c4d3e2f1a0b",
    "sha256":        "sha256:" + "b312576b420c19ee0b7e9a8e37430dbc" * 2,
    "path-long":     '  File "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9"',
    "path-opt":      "ok   /opt/data/workspace/repos/acme/service/tests/../scripts/auto-sync",
    "url-path":      "https://github.com/orgs/acme/packages/container/package/tool",
    "fake-token-x":  "user:" + j(["gh", "p_"]) + "xxxxxxxxx",
    "fake-token-x36": j(["gh", "p_"]) + "x" * 36,
    "rfc1918":       "10.43.0.10 172.16.5.4 192.168.1.20",
    "shared-range":  "curl http://100.101.102.103/ -H 'Host: a.example.com'",
    "doc-ip":        "192.0.2.10 198.51.100.7 203.0.113.5",
    "multicast":     "mDNS 224.0.0.251, SSDP 239.255.255.250",
    "not-an-ip":     "999.1.1.1 and 300.1.2.3",
    "cdn-range":     "A case like `104.16.0.0/013`, the range 172.64.0.0/13",
    "server-version": "Server: gateway/3.10.0.18-enterprise-edition\nVia: 1.1 gateway/3.10.0.18-enterprise-edition",
    "version-glued": "v1.25.3.1 and helm/2.4.10.1",
    "any-ip":        "listen 0.0.0.0:80, DNS 1.1.1.1 and 8.8.8.8",
    "oid":           "OID 1.3.6.1.4.1.311",
    "k8s-secret-name": "GitRepository provider=github secret=flux-system-app Ready=True",
    "env-ref":       "password: ${DB_PASSWORD_FROM_VAULT}",
    "env-name":      "api_key: OPENAI_API_KEY_FROM_VAULT",
    # one case per branch of _placeholder: dropping a branch turns its case red
    "ph-xxxx":       "token=abcxxxxxxxxxxxxx",
    "ph-stars":      "https://app:ab***cdef@git.example.org/x",
    "ph-xxx-left-9": "password: " + j(["abc", "xxx", "123456"]),       # 9 letters and digits outside the run: a placeholder
    "ph-angle":      "postgres://app:<password>@db:5432/x",
    "ph-dollar":     "redis://app:${REDIS_PASS}@redis:6379",
    "ph-var-whole":  "password: $DB_PASSWORD_FROM_VAULT",
    "ph-bearer-var": "Authorization: Bearer $GITHUB_TOKEN_FROM_SECRETS",
    "ph-sk-x":       "key " + j(["sk", "-ant-"]) + "x" * 30,
    "ph-redacted-url": "https://app:abcd****wxyz@git.example.org/x",
    "url-port-path": "pulled http://localhost:8080/v2/Acme/tool@sha256",
    "ph-dollar-mid": "redis://app:pw-${REDIS_PASS}@redis:6379",
    "url-port-path-host": "pulled https://registry.example.com:8443/v2/acme/tool@sha256",
    "url-scp-path":  "pip install git+ssh://github.com:Acme2/Tool.git@v1.2.3 and ssh://gitlab.example.org:group/sub/repo.git@main",
    "url-path-word": "see https://host:port/path/to/pkg@1.2.3",
    "ph-var-chain":  "password=$DB_PASSWORD$SUFFIX and token=$TOKEN_PREFIX$TOKEN_BODY",
    "ph-var-suffix": "export GH_TOKEN=$GITHUB_TOKEN. and Authorization: Bearer $ACCESS_TOKEN.trim",
    "ph-jwt-xyz":    "Authorization: Bearer xxxxx.yyyyy.zzzzz",
    # runs next to a mark, and the obvious placeholders in each context. Some lines are green before the placeholder
    # rule is asked (shorter than the pattern's minimum, or a `<` the value class stops at: `password=changeme`, `key sk-<...>`);
    # the lines that reach it are the URL and bearer ones and `password: xxxxxxxxxxxx` (break placeholder-never)
    "ph-runs-seps":  "Authorization: Bearer xxxxx-yyyyy_zzzzz and token=XXXXX.YYYYY.ZZZZZ",
    "ph-runs-one":   "Authorization: Bearer xxxxxxxxxx.yyyyyyyyyy and password: XXXXX-QQQQQQQQQQ",
    "ph-xxxxx":      "password: xxxxx, password: xxxxxxxxxxxx, https://app:xxxxxx@db/x, Authorization: Bearer xxxxxxxxxxxxxxxxxxxx",
    "ph-changeme":   "DB_PASSWORD=changeme\npassword=changeme\nAuthorization: Bearer changeme",
    "ph-your-token": 'Authorization: Bearer <your-token>\npassword=<your-token>\nhttps://app:<your-token>@db/x\ntoken: "<your-token>"\nkey sk-<your-token>',
    "kv-name-3":     "token=cert-manager-tls and secret=flux-system-app",
    "kv-plain-word": "password: required, token = sent-by-email",
    "trailer":       "fix: x\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>",
    "web-flow":      "Committer: GitHub <noreply@github.com>",
    "git-remote":    "g" + "it@github.com:acme/service.git",
    "git-remote-gl": "g" + "it@gitlab.com:x/y",
    "git-remote-bb": "g" + "it@bitbucket.org:x/y",
    "bot-email":     "ciapp@users.noreply.github.com",
    "example-email": "write to user@example.com or ops@mail.example.org",
    "dsn-internal":  "postgres@db.svc.cluster.local, redis@cache.infra.svc.cluster.local",
    "request-id":    'request_id: "83a4' + "0f1e2d3c" * 3 + 'aabbccdd"',
    "camel-ident":   "alertOnNoDataNotifyByGroupResolvableDisabledField",
    "id-repeat":     "zone " + "0f1e2d3c" * 4,
    "id-sequential": "account_id: " + "0123456789abcdef" * 2,
    "id-few-chars":  "zone " + "ab1c2" "ba21c" "c1ab2" "2cba1" "1c2ab" "a2b1c" "ba",
    "version-plus":  "diff +1234567 and +123",
    "short-zero":    "build 0123456789 done",
    "phone-in-longer-number": "id 00" + "912345678" + "9",
    "phone-in-dotted":       "v0" + "912345678.1",
    # a whole commit id (40 hex) or sha256 (64 hex) whose digits hold a phone shape is an id, not a number
    "phone-in-sha":          "head f95235a7dbbbff47719bed8eb8c3be" + "0862421027",
    "phone-in-sha256":       "sha256=" + "ab" * 27 + "0862421027",
    # the forms that must stay green or normal PRs go red. Placeholders, no root, products and images, URLs, routes, relative paths
    "home-ph-angle":  "@U@<name>/x and @H@<user>/x",
    "home-ph-var":    "@H@$USER/x @H@${USER}/x @U@$LOGNAME/x",
    "home-ph-percent": "C:\\Users\\%USERNAME%\\x and %USERPROFILE%\\x",
    "home-ph-brackets": "@H@[name]/x @H@{user}/x @U@*/x @U@\u2026/x",
    "home-ph-template": "@H@user-<id>/x and @H@u$N/x",
    "home-tilde":     "~/projects/x and ~@H@x",
    "home-env":       "$HOME/projects/x and ${HOME}/x and $HOME@U@x",
    "home-runner":    "@H@runner/work/repo/repo and @U@runner/work/x and C:\\Users\\runneradmin\\x",
    "home-agent":     "@H@agent/vibemaestro-plugins",
    "home-ci-accounts": "@H@vsts/work @H@circleci/project @H@linuxbrew/.linuxbrew/bin",
    "home-system-profiles": "@U@Shared/x @U@Guest C:\\Users\\Public\\x C:\\Users\\Default\\x",
    "home-slot-words": "@H@user/x @U@username/x @H@name/x @H@yourname/x @U@YourUser/x",
    "home-url-path":  "https://host.example.org@H@settings and https://host.example.org/a@U@alice",
    "home-url-path-2": "http://localhost:8080@H@dashboard and https://host.example.org:8443@U@alice/x",
    "home-route-lower": "GET /users/alice and /users/123@H@x",
    "home-relative":  "src@U@model.ts and .@H@alice and ..@H@alice and lib@H@alice",
    "home-no-name":   "the @H@ directory and @U@ folder, @U@ and @H@",
    "home-concat-roots": "$(pwd)@H@alice and ${HOME}@H@alice and %HOME%@H@alice and $HOME@H@alice and [root]@H@alice and ${HOME}/c@U@alice and $(pwd)/mnt/c@U@alice and //c@U@alice",
    "home-image-accounts": "WORKDIR @H@node/app @H@vscode @H@codespace @H@ubuntu @H@ec2-user @H@jovyan @H@jenkins @H@git @H@postgres @H@www-data @H@nobody @H@app @H@appuser @H@travis @H@gitpod @H@vagrant @H@pi @H@admin @H@dev",
    "home-slot-spellings": "@U@YOU @U@me @H@your_name @H@your-name @H@your-username @H@yourUser",
    "home-ph-template-marks": "@H@u$N @H@u%N @H@user-{id} @H@user_<n>",
    "home-glued-word": "app@H@alice and srv@U@alice and x1@H@alice",
    "home-runner-sentence-end": "the CI home is @H@runner.",
}
for d, cases in (("pos", POS), ("neg", NEG)):
    os.makedirs(os.path.join(W, d))
    for k, v in cases.items():
        if d == "pos":
            open(os.path.join(W, d, k + ".kind"), "w").write(v[0])
            v = v[1]
        # a home path is spelled with a token so this file (and the repo-wide scan for machine paths) holds none: @U@ is the macOS root, @H@ the Linux one
        v = v.replace("@U@", "/Us" + "ers/").replace("@H@", "/ho" + "me/")
        open(os.path.join(W, d, k + ".txt"), "w").write(v)
PY

PS() { printf '%s' "$1/gates/pr_sensitive.py"; }
IPX() { printf '%s.%s.%s.%s' "$@"; }   # a public address from parts, so no literal sits in this file
shaof() { printf '%s' "$1" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }

fam_positive() {
  local p=$1 f k want
  for f in "$W"/pos/*.txt; do
    k=$(basename "$f" .txt); want=$(cat "$W/pos/$k.kind")
    RC=0; OUT=$(cenv python3 "$(PS "$p")" --text < "$f" 2>&1) || RC=$?
    if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qF "stdin text: $want "; then ok "[P] $k -> $want"
    else bad "[P] $k: rc $RC, wanted kind '$want' -> $(printf '%s' "$OUT" | grep '^RED' | cut -d: -f2 | tr '\n' ',')"; fi
  done
}
fam_negative() {
  local p=$1 f k
  for f in "$W"/neg/*.txt; do
    k=$(basename "$f" .txt)
    RC=0; OUT=$(cenv python3 "$(PS "$p")" --text < "$f" 2>&1) || RC=$?
    [ "$RC" -eq 0 ] && ok "[N] $k is green" || bad "[N] $k was caught by mistake -> $OUT"
  done
}

# No value of 6 characters or more may leak in any channel: stdout, stderr, the ::error:: annotation (only under GITHUB_ACTIONS), in
# --text and --payload (body, comment, commit). Positive control for the measurement itself: the mask MUST be in the output; if it
# is not, the wrong stream was read.
fam_log() {
  local p=$1
  P="$p" python3 - "$W/pos" "$W" "$(PS "$p")" <<'PY' && ok "[L] every positive case on {--text local, --payload GITHUB_ACTIONS} and every sixth on the other two channels: only the mask is printed" || bad "[L] a log leaks a value or is not measured (details above)"
import importlib.util, json, os, subprocess, sys
pos, W, script = sys.argv[1:4]
sys.path.insert(0, os.path.dirname(script))
spec = importlib.util.spec_from_file_location("s", script)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
bad = 0
for idx, f in enumerate(sorted(x for x in os.listdir(pos) if x.endswith(".txt"))):
    t = open(os.path.join(pos, f)).read()
    pj = os.path.join(W, "leak.json")
    json.dump({"number": 1, "body": t, "comments": [{"where": "comment 1", "body": t}], "commits": [{"sha": "ab" * 20, "message": t}]}, open(pj, "w"))
    for gha in (False, True):
        env = {k: v for k, v in os.environ.items() if k != "GITHUB_ACTIONS"}
        if gha:
            env["GITHUB_ACTIONS"] = "true"
        for args, inp in ((["--text"], t), (["--payload", pj], None)):
            # every case on the two diagonal channels; the other two channels on every sixth case (they share the code path)
            if (args[0] == "--text") == gha and idx % 6:
                continue
            p = subprocess.run([sys.executable, script] + args, input=inp, capture_output=True, text=True, env=env)
            out = p.stdout + p.stderr
            where = "%s %s%s" % (f, args[0], " GITHUB_ACTIONS" if gha else "")
            hits = m.scan_text(t)
            if not hits:
                print("  no hit to examine:", where); bad += 1
            for kind, v in hits:
                if len(v) >= 6 and v in out:
                    print("  leak:", where, kind); bad += 1
                if m.mask(v) not in out:
                    print("  mask missing (wrong stream?):", where, kind); bad += 1
            if gha and "::error title=pr-sensitive::" not in p.stdout:
                print("  ::error:: annotation missing:", where); bad += 1
sys.exit(1 if bad else 0)
PY
}

fam_payload() {
  local p=$1 ip ip2
  ip=$(IPX 103 97 12 44); ip2=$(IPX 45 117 80 9)
  P="$TMP/pl"; mkdir -p "$P"
  python3 - "$P" "$ip" "$ip2" <<'PY'
import json, sys
W, ip, ip2 = sys.argv[1:4]
dump = lambda n, o: json.dump(o, open("%s/%s.json" % (W, n), "w"))
dump("b5000", {"number": 6, "body": "x" * 5000, "comments": [], "commits": []})        # 5000 is silent, 5001 warns
dump("b5001", {"number": 7, "body": "x" * 5001, "comments": [], "commits": []})
dump("commit", {"number": 8, "body": "ok", "comments": [{"where": "comment 1", "body": "ok"}], "commits": [{"sha": "ab" * 20, "message": "fix: node\n\ndetails: " + ip}]})
dump("comment", {"number": 9, "body": "ok", "commits": [], "comments": [{"where": "review-comment 5", "body": "ip " + ip}]})
dump("trunc", {"number": 10, "body": "ok", "comments": [], "commits": [], "commits_truncated": True})
dump("two", {"number": 11, "body": ip + " and " + ip2, "comments": [], "commits": []})    # dedupe by (kind, value), not by kind
dump("corpus", [{"number": 1, "body": "ok", "comments": []}, {"number": 2, "body": "ok", "comments": [{"body": "node " + ip}]}])
dump("all", {"number": 12, "body": "body " + ip, "comments": [{"where": "comment 1", "body": "c " + ip}], "commits": [{"sha": "cd" * 20, "message": "m " + ip}]})
PY
  run_gate python3 "$(PS "$p")" --payload "$P/b5000.json"; want 0 "[C] a body of 5000 characters: no warning"
  has_q WARNING && bad "[C] 5000 characters warned" || ok "[C] …and nothing warned"
  RC=0; OUT=$(cenv GITHUB_ACTIONS=true python3 "$(PS "$p")" --payload "$P/b5001.json" 2>&1) || RC=$?
  want 0 "[C] a body of 5001 characters: a warning, still rc 0" "WARNING PR #7 body is 5001"
  printf '%s\n' "$OUT" | grep -q '^::warning title=pr-sensitive::PR #7 body is' && ok "[C] …and a ::warning:: annotation" || bad "[C] no ::warning:: annotation: $OUT"
  run_gate python3 "$(PS "$p")" --payload "$P/commit.json"; want 1 "[C] an IP in the BODY of a commit message: red, short sha and mask" "PR #8 commit abababab: public-ipv4 103."
  run_gate python3 "$(PS "$p")" --payload "$P/comment.json"; want 1 "[C] a review comment with an IP: red" "PR #9 review-comment 5: public-ipv4"
  RC=0; OUT=$(cenv GITHUB_ACTIONS=true python3 "$(PS "$p")" --payload "$P/trunc.json" 2>&1) || RC=$?
  want 0 "[C] more than 250 commits: a warning about the unscanned part" "at most 250 commits"
  printf '%s\n' "$OUT" | grep -q '^::warning title=pr-sensitive::PR #10' && ok "[C] …with an annotation" || bad "[C] no truncation annotation: $OUT"
  run_gate python3 "$(PS "$p")" --payload "$P/two.json"; want 1 "[C] two values of one kind are two hits" "1 sources, 2 sensitive values"
  run_gate python3 "$(PS "$p")" --corpus "$P/corpus.json"; want 1 "[C] --corpus with a red PR: rc 1" "corpus: 3 sources, 1 red PRs"
  put_cfg "$P/rb" '{"sensitive": {"scan": ["pr_body"]}}'
  run_gate python3 "$(PS "$p")" --cwd "$P/rb" --payload "$P/all.json"; want 1 "[C] sensitive.scan = pr_body: only the body is scanned" "1 sources, 1 sensitive values"
  put_cfg "$P/rc" '{"sensitive": {"scan": ["pr_comments"]}}'
  run_gate python3 "$(PS "$p")" --cwd "$P/rc" --payload "$P/all.json"; want 1 "[C] sensitive.scan = pr_comments: only the comment" "comment 1"
  put_cfg "$P/rm" '{"sensitive": {"scan": ["commit_messages"]}}'
  run_gate python3 "$(PS "$p")" --cwd "$P/rm" --payload "$P/all.json"; want 1 "[C] sensitive.scan = commit_messages: only the commit" "commit cdcdcdcd"
  put_cfg "$P/ra" '{}'
  run_gate python3 "$(PS "$p")" --cwd "$P/ra" --payload "$P/all.json"; want 1 "[C] the default scans all three sources" "3 sources, 3 sensitive values"
  put_cfg "$P/rn" '{"sensitive": {"scan": []}}'
  run_gate python3 "$(PS "$p")" --cwd "$P/rn" --payload "$P/all.json"; want 0 "[C] an empty scan list scans nothing" "0 sources"
  local G; G=$(mk_repo plg)
  G -C "$G" commit -q --allow-empty -m "chore: clean"; G -C "$G" commit -q --allow-empty -m "fix: clean subject" -m "node $ip"
  local red; red=$(git -C "$G" rev-parse --short=8 HEAD); G -C "$G" commit -q --allow-empty -m "docs: clean too"
  run_gate python3 "$(PS "$p")" --cwd "$G" --git-log HEAD; want 1 "[C] --git-log: exactly one red commit (the IP is in the body)" "git-log: 4 commits, 1 red: $red"
  put_cfg "$G" '{"sensitive": {"scan": ["pr_body"]}}'
  run_gate python3 "$(PS "$p")" --cwd "$G" --git-log HEAD; want 0 "[C] --git-log with commit_messages out of the scan list: nothing scanned" "nothing scanned"
}

fam_allow() {
  local p=$1 A B R
  A=$(IPX 45 77 12 34); B=$(IPX 45 77 12 35)
  printf '# note\n%s  # test case\nnot-a-hash\n%s\n' "$(shaof "$A")" "$A" > "$TMP/allow.txt"
  RC=0; OUT=$(printf 'node %s\n' "$A" | cenv python3 "$(PS "$p")" --text --allow "$TMP/allow.txt" 2>&1) || RC=$?
  want 0 "[A] --allow: a value whose sha256 is in the file: green"
  has_q "WARNING allowlist: 2 line(s)" && ok "[A] …two lines are not a hash (one word, one raw value): ignored and counted" || bad "[A] the ignored lines were not reported: $OUT"
  has_q "$A" && bad "[A] a raw value in the allowlist was echoed back" || ok "[A] …and the raw value in the file is never printed back"
  RC=0; OUT=$(printf 'node %s\n' "$B" | cenv python3 "$(PS "$p")" --text --allow "$TMP/allow.txt" 2>&1) || RC=$?
  want 1 "[A] --allow: the address next to it is still red"
  RC=0; OUT=$(printf 'node %s\n' "$A" | cenv python3 "$(PS "$p")" --text --allow "$TMP/no-such" 2>&1) || RC=$?
  want 64 "[A] an unreadable --allow file is rc 64"
  # the base carries an allowlist that exempts A; the head adds B to the working tree. Read at the base: A green, B red.
  R=$(mk_repo alw); commit_cfg "$R" '{"sensitive": {"allowlist": "ops/allow.txt"}}' "base: config"
  mkdir -p "$R/ops"; shaof "$A" > "$R/ops/allow.txt"; shaof "$B" > "$R/ops/self.txt"   # self.txt exists at the base but its config does not name it
  G -C "$R" add ops; G -C "$R" commit -qm "base: allowlist"; G -C "$R" branch base
  G -C "$R" checkout -qb pr; shaof "$B" >> "$R/ops/allow.txt"; G -C "$R" commit -qam "head exempts itself"
  RC=0; OUT=$(printf 'node %s\n' "$A" | cenv python3 "$(PS "$p")" --cwd "$R" --text --config-ref base 2>&1) || RC=$?
  want 0 "[A] --config-ref base: a value exempt at the BASE is green (the path comes from the base's config)"
  RC=0; OUT=$(printf 'node %s\n' "$B" | cenv python3 "$(PS "$p")" --cwd "$R" --text --config-ref base 2>&1) || RC=$?
  want 1 "[A] --config-ref base: a value exempt only in the HEAD is still red (a PR cannot exempt what it leaks)"
  RC=0; OUT=$(printf 'node %s\n' "$B" | cenv python3 "$(PS "$p")" --cwd "$R" --text 2>&1) || RC=$?
  want 0 "[A] a local run with no ref reads the working tree (the author's own list), as the config does"
  RC=0; OUT=$(printf 'node %s\n' "$A" | cenv python3 "$(PS "$p")" --cwd "$R" --text --config-ref no-such-ref 2>&1) || RC=$?
  want 2 "[A] a ref that does not read is rc 2, never green"
  # the config of the head moves the allowlist to a file that exempts B; the base's config must still decide
  commit_cfg "$R" '{"sensitive": {"allowlist": "ops/self.txt"}}' "head: moves the list"
  RC=0; OUT=$(printf 'node %s\n' "$B" | cenv python3 "$(PS "$p")" --cwd "$R" --text --config-ref base 2>&1) || RC=$?
  want 1 "[A] a PR that points sensitive.allowlist at its own file is judged by the base's config: red"
  RC=0; OUT=$(printf 'node %s\n' "$B" | cenv python3 "$(PS "$p")" --cwd "$R" --text 2>&1) || RC=$?
  want 0 "[A] …control: without the ref the head's own config is used: green"
  RC=0; OUT=$(printf 'node %s\n' "$B" | env -u GITHUB_ACTIONS PATH="$PATH" python3 "$(PS "$p")" --text 2>&1) || RC=$?
  has_q "sha256=$(shaof "$B")" && ok "[A] local: the red line carries the sha256, so a person can add it" || bad "[A] the sha256 is missing locally: $OUT"
  RC=0; OUT=$(printf 'node %s\n' "$B" | GITHUB_ACTIONS=true python3 "$(PS "$p")" --text 2>&1) || RC=$?
  has_q "sha256=" && bad "[A] under GITHUB_ACTIONS the log prints a sha256" || ok "[A] under GITHUB_ACTIONS: no sha256 (it can be reversed from a public log)"
  put_cfg "$R" '{"sensitive": {"allowlist": 3}}'
  RC=0; OUT=$(printf 'x\n' | cenv python3 "$(PS "$p")" --cwd "$R" --text 2>&1) || RC=$?
  want 65 "[A] an invalid config is rc 65" sensitive.allowlist
  # the default allowlist name
  R=$(mk_repo aldef); shaof "$A" > "$R/.pr-sensitive-allow"
  RC=0; OUT=$(printf 'node %s\n' "$A" | cenv python3 "$(PS "$p")" --cwd "$R" --text 2>&1) || RC=$?
  want 0 "[A] the default allowlist file is .pr-sensitive-allow"
}

# --pr through the fake gh. Dirty values sit on page 2 of every list: a call without --paginate loses them.
fam_pr() {
  local p=$1 d ip1 ip2 ip3 mail phone sha base
  d=$(mktemp -d "$TMP/g.XXXXXX"); install_gate_gh "$d/bin" >/dev/null
  ip1=$(IPX 103 97 12 44); ip2=$(IPX 45 117 80 9); ip3=$(IPX 1 54 200 7)
  mail=$(printf 'jane.doe%sgmail.com' @); phone="0$(printf 912345678)"
  sha="c0ffee$(printf 'ab%.0s' $(seq 1 17))"; base="ba5e$(printf 'cd%.0s' $(seq 1 18))"
  mkfx() {  # mkfx <file> <dirty|clean|allow|trunc>
    python3 - "$1" "$2" "$ip1" "$ip2" "$ip3" "$mail" "$phone" "$sha" "$base" "$(shaof "$(IPX 62 210 1 8)")" "$(IPX 62 210 1 8)" <<'PY'
import json, sys
out, mode, ip1, ip2, ip3, mail, phone, sha, base, okhash, ipok = sys.argv[1:12]
dirty = {"body": "node " + ip1, "comment": "contact " + mail, "review-comment": "edge " + ip2, "review": "call " + phone, "commit": "fix: ufw allow from " + ip3}
t = dirty if mode == "dirty" else {k: "ok" for k in dirty}
if mode == "allow":
    t = dict(t, body="node %s and %s" % (ipok, ip1))
ok = lambda i: {"id": i, "body": "ok"}
commits = [{"sha": "0" * 40, "commit": {"message": "chore: ok"}}, {"sha": sha, "commit": {"message": t["commit"]}}]
if mode == "trunc":
    commits = [{"sha": "%040x" % i, "commit": {"message": "chore: ok"}} for i in range(250)]
json.dump({
    "pulls/7": {"number": 7, "body": t["body"], "base": {"sha": base}},
    "contents/.vibemaestro/sdlc.json?ref=" + base: '{"sensitive": {"allowlist": "ops/allow.txt"}}',
    "contents/ops/allow.txt?ref=" + base: "# base\n%s  # test case\n" % okhash,
    "issues/7/comments": [ok(21), {"id": 11, "body": t["comment"]}],
    "pulls/7/comments": [ok(22), {"id": 12, "body": t["review-comment"]}],
    "pulls/7/reviews": [ok(23), {"id": 13, "body": t["review"]}],
    "pulls/7/commits": commits,
    "__require_paginate__": True}, open(out, "w"))
PY
  }
  local repo; repo=$(mk_repo prg)   # a work tree whose own allowlist and config say the opposite of the base
  mkdir -p "$repo/ops"; shaof "$ip1" > "$repo/ops/allow.txt"; put_cfg "$repo" '{"sensitive": {"scan": []}}'
  prun() {  # prun <mode> [gha] -> OUT RC
    mkfx "$d/fx-$1.json" "$1"; : > "$d/gh.log"
    RC=0; OUT=$(cenv PATH="$d/bin:$PATH" FAKE_GH_LOG="$d/gh.log" FAKE_GH_FX="$d/fx-$1.json" ${2:+GITHUB_ACTIONS=true} python3 "$(PS "$p")" --cwd "$repo" --pr 7 --repo acme/service 2>&1) || RC=$?
  }
  local gha
  for gha in "" 1; do
    prun dirty $gha; want 1 "[G] --pr, dirty fixture${gha:+ (GITHUB_ACTIONS)}: red"
    local w; for w in "body" "comment 11" "review-comment 12" "review 13" "commit ${sha:0:8}"; do
      has_q "RED  PR #7 $w:" && ok "[G] a RED line for the source '$w'${gha:+ (GITHUB_ACTIONS)}" || bad "[G] no RED line for '$w': $OUT"; done
    for w in "$ip1" "$ip2" "$ip3" "$mail" "$phone"; do has_q "$w" && bad "[G] the log leaks a whole value" || ok "[G] the log holds only the mask of ${w:0:4}...${gha:+ (GITHUB_ACTIONS)}"; done
    local ep; for ep in pulls/7 issues/7/comments pulls/7/comments pulls/7/reviews pulls/7/commits; do
      grep -qF "repos/acme/service/$ep" "$d/gh.log" && ok "[G] the API was called for $ep" || bad "[G] no call for $ep"; done
  done
  prun clean; want 0 "[G] --pr, clean fixture: green"
  prun allow; want 1 "[G] --pr: one value exempt at the base, one that only the work tree exempts: still red"
  has_q "$ip1" && bad "[G] the allowlist case leaks a value" || ok "[G] …and the log holds no whole value"
  has_q "RED  PR #7 body: public-ipv4 $(printf '%s' "$(IPX 62 210 1 8)" | cut -c1-4)" && bad "[G] the value exempt at the base was reported" || ok "[G] the value exempt at the base (read through the API, base config path) is not reported"
  prun trunc; want 0 "[G] --pr with 250 commits: a warning, not red" "at most 250 commits"
  : > "$d/gh.log"; mkfx "$d/fx-x.json" clean
  python3 - "$d/fx-x.json" <<'PY'
import json, sys
fx = json.load(open(sys.argv[1])); fx["__fail__"] = True; json.dump(fx, open(sys.argv[1], "w"))
PY
  RC=0; OUT=$(cenv PATH="$d/bin:$PATH" FAKE_GH_LOG="$d/gh.log" FAKE_GH_FX="$d/fx-x.json" python3 "$(PS "$p")" --cwd "$repo" --pr 7 --repo acme/service 2>&1) || RC=$?
  want 2 "[G] gh failing: could not conclude, rc 2 (a scan that never ran is not green)"
  # --config-ref by hand: a ref neither git nor the API knows is rc 2 (it read as "no file", so the defaults and no
  # allowlist); a ref only the API knows is read through the API like the base sha
  mkfx "$d/fx-r.json" allow
  python3 - "$d/fx-r.json" "$base" <<'PY2'
import json, sys
fx = json.load(open(sys.argv[1])); b = sys.argv[2]
for k in [k for k in fx if k.endswith("?ref=" + b)]:
    fx[k.replace("?ref=" + b, "?ref=release-7")] = fx[k]
fx["commits/release-7"] = {"sha": b}
json.dump(fx, open(sys.argv[1], "w"))
PY2
  RC=0; OUT=$(cenv PATH="$d/bin:$PATH" FAKE_GH_LOG="$d/gh.log" FAKE_GH_FX="$d/fx-r.json" python3 "$(PS "$p")" --cwd "$repo" --pr 7 --repo acme/service --config-ref no-such-ref 2>&1) || RC=$?
  want 2 "[G] --config-ref that neither git nor the API knows: rc 2, never the defaults" "no-such-ref"
  RC=0; OUT=$(cenv PATH="$d/bin:$PATH" FAKE_GH_LOG="$d/gh.log" FAKE_GH_FX="$d/fx-r.json" python3 "$(PS "$p")" --cwd "$repo" --pr 7 --repo acme/service --config-ref release-7 2>&1) || RC=$?
  want 1 "[G] …control: --config-ref the API knows: read there, one value exempt, the other red"
  has_q "RED  PR #7 body: public-ipv4 $(printf '%s' "$(IPX 62 210 1 8)" | cut -c1-4)" && bad "[G] the allowlist at the API ref was not read" || ok "[G] …the value exempt at that ref is not reported"
  # the base sha is not in the local clone and the contents call is a 404: no allowlist, defaults (stricter, never looser)
  mkfx "$d/fx-n.json" allow
  python3 - "$d/fx-n.json" "$base" <<'PY'
import json, sys
fx = json.load(open(sys.argv[1])); del fx["contents/ops/allow.txt?ref=" + sys.argv[2]]; json.dump(fx, open(sys.argv[1], "w"))
PY
  RC=0; OUT=$(cenv PATH="$d/bin:$PATH" FAKE_GH_LOG="$d/gh.log" FAKE_GH_FX="$d/fx-n.json" python3 "$(PS "$p")" --cwd "$repo" --pr 7 --repo acme/service 2>&1) || RC=$?
  want 1 "[G] an allowlist that cannot be read at the base: scanned with none, red"
  # a locale that is not UTF-8: the PR text is decoded as UTF-8 anyway, and a failure never prints the text
  local tk; tk="$(printf 'gh%s_' p)aB3xK9pQ2mZ7vL4nW8rT6yU1aB3xK9pQ2mZ7"
  python3 - "$d/fx-u.json" "$tk" "$base" <<'PY'
import json, sys
out, tk, base = sys.argv[1:4]
json.dump({"pulls/7": {"number": 7, "body": "caf\u00e9 \u1ed3 token " + tk, "base": {"sha": base}}, "issues/7/comments": [], "pulls/7/comments": [],
           "pulls/7/reviews": [], "pulls/7/commits": []}, open(out, "w"))
PY
  RC=0; OUT=$(cenv PATH="$d/bin:$PATH" FAKE_GH_LOG="$d/gh.log" FAKE_GH_FX="$d/fx-u.json" LC_ALL=C PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 python3 "$(PS "$p")" --cwd "$repo" --pr 7 --repo acme/service 2>&1) || RC=$?
  want 1 "[G] a locale that is not UTF-8: the PR text is still read as UTF-8 and the token is found" "github-token"
  has_q "$tk" && bad "[G] the log leaks the whole token under a non-UTF-8 locale" || ok "[G] …and the log holds no whole token"
  # base commit present locally: read through git, not the API
  local r2; r2=$(mk_repo prgit); commit_cfg "$r2" '{"sensitive": {"allowlist": "ops/allow.txt"}}' "cfg"; mkdir -p "$r2/ops"; shaof "$(IPX 62 210 1 8)" > "$r2/ops/allow.txt"; G -C "$r2" add ops; G -C "$r2" commit -qm allow
  local real; real=$(git -C "$r2" rev-parse HEAD)
  mkfx "$d/fx-g.json" allow
  python3 - "$d/fx-g.json" "$base" "$real" <<'PY'
import json, sys
fx = json.load(open(sys.argv[1])); b, real = sys.argv[2:4]
fx["pulls/7"]["base"]["sha"] = real
for k in [k for k in fx if k.startswith("contents/")]:
    del fx[k]
json.dump(fx, open(sys.argv[1], "w"))
PY
  : > "$d/gh.log"
  RC=0; OUT=$(cenv PATH="$d/bin:$PATH" FAKE_GH_LOG="$d/gh.log" FAKE_GH_FX="$d/fx-g.json" python3 "$(PS "$p")" --cwd "$r2" --pr 7 --repo acme/service 2>&1) || RC=$?
  want 1 "[G] base commit present locally: config and allowlist read through git (the exempt value is not reported, the other is)"
  grep -q 'contents/' "$d/gh.log" && bad "[G] git had the base, but the API contents endpoint was called" || ok "[G] …and the contents endpoint was not needed"
  has_q "RED  PR #7 body: public-ipv4 103." && ok "[G] …the head-only value is reported" || bad "[G] the head-only value was not reported: $OUT"
}

# the number of values, not only the kind. One planted home path is ONE value (a second reading of the same path, as a drive-letter path with forward slashes
# also matching the POSIX shape, would make it two); every allowed form is none; the e-mail, IP and token cases of before still give one.
fam_home() {
  local p=$1 f k n want HP; HP="/ho""me/"
  for f in "$W"/pos/home-*.txt "$W/pos/email.txt" "$W/pos/public-ipv4.txt" "$W/pos/github-token.txt"; do
    k=$(basename "$f" .txt); want=1; [ "$k" = home-two-homes-two-values ] && want=2
    OUT=$(cenv python3 "$(PS "$p")" --text < "$f" 2>&1) || true
    n=$(printf '%s\n' "$OUT" | sed -n 's/^pr-sensitive: 1 sources, \([0-9]*\) sensitive values.*/\1/p')
    [ "$n" = "$want" ] && ok "[H] $k gives $want value(s)" || bad "[H] $k gives '$n' value(s), wanted $want"
  done
  for f in "$W"/neg/home-*.txt; do
    k=$(basename "$f" .txt)
    OUT=$(cenv python3 "$(PS "$p")" --text < "$f" 2>&1) || true
    n=$(printf '%s\n' "$OUT" | sed -n 's/^pr-sensitive: 1 sources, \([0-9]*\) sensitive values.*/\1/p')
    [ "$n" = 0 ] && ok "[H] $k gives 0 values" || bad "[H] $k gives '$n' values, wanted 0 -> $(printf '%s' "$OUT" | grep -c '^RED') red"
  done
  # a byte that is not UTF-8 in the text (stdin) is a name like any other: the gate answers 1, it does not stop with 2
  RC=0; OUT=$(printf '%sal\377ice/x' "$HP" | cenv python3 "$(PS "$p")" --text 2>&1) || RC=$?
  [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qF "home-path" && ok "[H] invalid UTF-8 in a home path: rc 1 and the path is reported" || bad "[H] invalid UTF-8 in a home path: rc $RC -> ${OUT:0:120}"
  # the allowlist works on the prefix: one line hides every path under that home, and only that home
  local al="$TMP/home-allow.txt"; shaof "${HP}alice" > "$al"
  OUT=$(printf '%s\n' "${HP}alice/a and ${HP}alice/b and ${HP}bob/c" | cenv python3 "$(PS "$p")" --text --allow "$al" 2>&1) || true
  printf '%s\n' "$OUT" | grep -qF "1 sources, 1 sensitive values" && ok "[H] the allowlist hash of a home prefix hides that home, not another one" || bad "[H] the allowlist hash of a home prefix did not hide that home only: $OUT"
}

FAMILIES="fam_positive fam_negative fam_home fam_log fam_payload fam_allow fam_pr"
for f in $FAMILIES; do "$f" "$PLUGIN"; done

python3 - "$PLUGIN/gates/pr_sensitive.py" <<'PY' && ok "[C] the gate parses as Python 3.8 and imports only the standard library" || bad "[C] the gate is not Python 3.8 or imports something else"
import ast, sys
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read(), feature_version=(3, 8))
allowed = {"argparse", "hashlib", "ipaddress", "json", "os", "re", "subprocess", "sys", "gate_common"}
imports = set()
for n in ast.walk(tree):
    if isinstance(n, ast.Import):
        imports |= {a.name.split(".")[0] for a in n.names}
    elif isinstance(n, ast.ImportFrom):
        imports.add((n.module or "").split(".")[0])
sys.exit(1 if imports - allowed else 0)
PY

echo "== planted breaks: each turns its family red =="
PSY=pr_sensitive.py
BRKG phone-pattern-dropped fam_positive '[P] phone-intl' $PSY '("phone", r"(?<![\d.])(?:\+\d{9,14}|0[35789]\d{8})(?![\d.])", 0, None),' ''
BRKG phone-boundary-loosened fam_positive '[P] phone-glued-prefix' $PSY '("phone", r"(?<![\d.])(?:\+\d{9,14}|0[35789]\d{8})(?![\d.])", 0, None),' '("phone", r"(?<![\w.])(?:\+\d{9,14}|0[35789]\d{8})(?![\w.])", 0, None),'
BRKG hex-id-not-exempt fam_negative '[N] phone-in-sha' $PSY '_NOT_IN_HEX_ID = ("phone",)' '_NOT_IN_HEX_ID = ()'
BRKG hex-id-any-length fam_positive '[P] phone-glued-suffix' $PSY '(?:[0-9a-fA-F]{64}|[0-9a-fA-F]{40})' '[0-9a-fA-F]{7,64}'
BRKG email-exempt-everything fam_positive '[P] r2-git-at-other' $PSY '|git@(github\.com|gitlab\.com|bitbucket\.org)"' '|git@[^ ]+"'
BRKG keyword-dropped fam_positive '[P] kv-passwd' $PSY '(?:password|passwd)' '(?:password)'
BRKG exempt-by-context fam_positive '[P] fc-word-fake' $PSY '    return _placeholder(s) or bool(re.fullmatch(r"[a-z]+(-[a-z]+){1,2}", s))' '    return _placeholder(s) or bool(re.search(r"(?i)fake|changeme|secret|dummy", s)) or bool(re.fullmatch(r"[a-z]+(-[a-z]+){1,2}", s))'
BRKG ip-version-by-words fam_positive '[P] fc-version-space' $PSY '(?<![\w.])(?<![A-Za-z]/)(' '(?<![\w.])(?<!version )(?<![A-Za-z]/)('
BRKG private-range-flagged fam_negative '[N] rfc1918' $PSY '    if not ip.is_global or ip.is_multicast or s in _WELL_KNOWN:' '    if s in _WELL_KNOWN:'
BRKG multicast-flagged fam_negative '[N] multicast' $PSY 'if not ip.is_global or ip.is_multicast or s in _WELL_KNOWN:' 'if not ip.is_global or s in _WELL_KNOWN:'
BRKG placeholder-branch-dropped fam_negative '[N] ph-dollar-mid' $PSY '|\$\{[A-Za-z_][^{}\s]*\}|' '|'
BRKG placeholder-angle-dropped fam_negative '[N] ph-angle' $PSY '_PH_PART = re.compile(r"<[^<>\s]*>|' '_PH_PART = re.compile(r"'
BRKG placeholder-x-dropped fam_negative '[N] ph-xxx-left-9' $PSY '|x{3,}|' '|'
BRKG placeholder-stars-dropped fam_negative '[N] ph-stars' $PSY '|\*{3,}")' '")'
BRKG placeholder-runs-dropped fam_negative '[N] ph-jwt-xyz' $PSY '_PH_RUN.sub("", _PH_PART.sub(" ", low))' '_PH_PART.sub(" ", low)'
BRKG placeholder-any-run-of-3 fam_positive '[P] url-repeat-digits' $PSY '|\*{3,}")' '|\*{3,}|(.)\1{2,}")'
BRKG placeholder-digit-run-of-5 fam_positive '[P] kv-run-digits-5' $PSY '|\*{3,}")' '|\*{3,}|(.)\1{4,}")'
BRKG placeholder-short-run fam_positive '[P] run-of-3-next-to-part' $PSY '_PH_RUN = re.compile(r"([a-z])\1{4,}")' '_PH_RUN = re.compile(r"([a-z])\1{2,}")'
# a run of one letter is filler only next to a real placeholder part; each break drops that guard (1.1.0)
NOPART='    if not _PH_PART.search(low):
        return False           # no placeholder part: nothing marks the value as one
'
BRKG placeholder-single-run-url fam_positive '[P] run-single-url' $PSY "$NOPART" ''
BRKG placeholder-single-run-pw fam_positive '[P] run-single-pw' $PSY "$NOPART" ''
BRKG placeholder-single-run-bearer fam_positive '[P] run-single-bearer' $PSY "$NOPART" ''
# the exact 1.1.0 rule: the run is a placeholder part of its own
BRKG placeholder-run-as-part fam_positive '[P] run-pw' $PSY '    if not _PH_PART.search(low):
        return False           # no placeholder part: nothing marks the value as one
    left = _PH_RUN.sub("", _PH_PART.sub(" ", low))   # a space: removing a part must not join two letter groups into a run
    return sum(c.isalnum() for c in left) < _PH_LEFT' '    left = re.sub(r"<[^<>\s]*>|\$\{[^{}\s]*\}|x{3,}|\*{3,}|([a-z])\1{4,}", "", low)
    return len(left) < len(s) and sum(c.isalnum() for c in left) < _PH_LEFT'
# review round 1
BRKG placeholder-never fam_negative '[N] ph-your-token' $PSY '    m = _PH_VARS.match(s)' '    return False
    m = _PH_VARS.match(s)'
BRKG first-piece-dropped fam_positive '[P] kv-mark-after-hash' $PSY '        return ok(s) and (i == len(s) or i < n or ok(s[:i]))' '        return ok(s)'
BRKG first-piece-bearer-dropped fam_positive '[P] bearer-mark-after-dollar' $PSY '_first_piece(_placeholder, "$", 16)),' '_placeholder),'
BRKG brace-any-content fam_positive '[P] url-brace-digit' $PSY '|\$\{[A-Za-z_][^{}\s]*\}|' '|\$\{[^{}\s]*\}|'
BRKG part-length-compared fam_positive '[P] url-unicode-lower' $PSY '    if not _PH_PART.search(low):' '    if len(_PH_PART.sub("", low)) == len(s):'
BRKG scan-resumes-after-value fam_positive '[P] kv-swallowed-second' $PSY '    return m.start(grp) + 1 if hasattr(ok, "stops") else m.end()' '    return m.end()'
BRKG scan-resumes-after-at fam_positive '[P] kv-swallowed-at' $PSY '    return m.start(grp) + 1 if hasattr(ok, "stops") else m.end()' '    return m.end()'
# the round-2 rule: resume after the first piece only; the chain without a stop character stays hidden
BRKG scan-resumes-after-piece fam_positive '[P] kv-chain-overlap' $PSY '    return m.start(grp) + 1 if hasattr(ok, "stops") else m.end()' '    v = m.group(grp)
    i = next((k for k, c in enumerate(v) if c in getattr(ok, "stops", "")), None)
    return m.end() if i is None else m.start(grp) + i + 1'
BRKG part-removed-joins fam_positive '[P] run-joined-by-part' $PSY '_PH_RUN.sub("", _PH_PART.sub(" ", low))' '_PH_RUN.sub("", _PH_PART.sub("", low))'
BRKG placeholder-var-whole-only fam_negative '[N] ph-var-suffix' $PSY '        return bool(_PH_VAR_TAIL.fullmatch(s[m.end():]))' '        return m.end() == len(s)'
BRKG placeholder-var-any-tail fam_positive '[P] kv-var-random-tail' $PSY '        return bool(_PH_VAR_TAIL.fullmatch(s[m.end():]))' '        return sum(c.isalnum() for c in s[m.end():]) < _PH_LEFT'
BRKG placeholder-any-var-name fam_positive '[P] kv-dollar-start' $PSY '    return not (re.search(r"\d", n) and re.search(r"[a-z]", n) and re.search(r"[A-Z]", n))' '    return True'
BRKG url-path-as-password fam_negative '[N] url-path-word' $PSY '{6,})@", 1, _url_pw_ok),' '{6,})@", 1, _placeholder),'
BRKG url-slash-three-classes fam_positive '[P] url-slash-two-classes' $PSY 'for c in (r"\d", r"[a-z]", r"[A-Z]")) < 2):' 'for c in (r"\d", r"[a-z]", r"[A-Z]")) < 3):'
BRKG placeholder-var-dropped fam_negative '[N] ph-var-whole' $PSY '    m = _PH_VARS.match(s)' '    m = None'
# each break restores the old behaviour of one pattern change
BRKG placeholder-by-substring fam_positive '[P] bearer-xxx' $PSY '    m = _PH_VARS.match(s)' '    if re.search(r"(?i)x{3,}|\*{3}|<|\$\{?[A-Za-z_]", s):
        return True
    m = _PH_VARS.match(s)'
BRKG placeholder-left-threshold fam_negative '[N] ph-xxx-left-9' $PSY '_PH_LEFT = 10' '_PH_LEFT = 9'
BRKG placeholder-left-threshold-up fam_positive '[P] ph-xxx-left-10' $PSY '_PH_LEFT = 10' '_PH_LEFT = 11'
BRKG placeholder-nothing-removed fam_positive '[P] url-short' $PSY "$NOPART" ''
BRKG kv-old-value-class fam_positive '[P] kv-at-bang' $PSY '([A-Za-z0-9+/_\-.@!$#]{12,})' '([A-Za-z0-9+/_\-.]{12,})'
BRKG url-no-slash fam_positive '[P] url-slash' $PSY ':(?!\d{1,5}/)([^\s@]{6,})@' ':(?!\d{1,5}/)([^/\s@]{6,})@'
BRKG url-port-dropped fam_negative '[N] url-port-path' $PSY ':(?!\d{1,5}/)([^\s@]{6,})@' ':([^\s@]{6,})@'
BRKG url-dotted-user-as-host fam_positive '[P] url-dotted-user' $PSY ':(?!\d{1,5}/)([^\s@]{6,})@", 1, _url_pw_ok),' ':(?!\d{1,5}/)([^\s@]{6,})@", 1, lambda s: "/" in s or _url_pw_ok(s)),'
BRKG url-scp-git-path fam_negative '[N] url-scp-path' $PSY 'if "/" in s and (s.endswith(".git") or ' 'if "/" in s and ('
BRKG kebab-any-length fam_positive '[P] diceware-secret-4' $PSY 'bool(re.fullmatch(r"[a-z]+(-[a-z]+){1,2}", s))' 'bool(re.fullmatch(r"[a-z]+(-[a-z]+)+", s))'
BRKG password-as-name fam_positive '[P] diceware-passwd-3' $PSY '(?:password|passwd)" + _KV_VALUE, 1, _first_piece(_pw_ok, "@!$#", 12)),' '(?:password|passwd)" + _KV_VALUE, 1, _first_piece(_kv_ok, "@!$#", 12)),'
BRKG bearer-no-dollar fam_positive '[P] bearer-dollar' $PSY '([A-Za-z0-9._\-$]{16,})' '([A-Za-z0-9._\-]{16,})'
BRKG id-repeat-flagged fam_negative '[N] id-repeat' $PSY '    return any(h == (h[:k] * (len(h) // k + 1))[:len(h)] for k in range(1, 17))' '    return False'
BRKG identifier-flagged fam_negative '[N] camel-ident' $PSY '    return not (digits and re.search(r"[a-z]", s) and re.search(r"[A-Z]", s))' '    return False'
BRKG value-printed fam_log '[L] a log leaks' $PSY '    return "%s...[%d]" % (s[:4], len(s))' '    return s'
BRKG hash-in-actions-log fam_allow '[A] under GITHUB_ACTIONS' $PSY '            print("RED  " + line + ("" if gha else "  sha256=" + digest(v)))' '            print("RED  " + line + "  sha256=" + digest(v))'
BRKG body-limit-off-by-one fam_payload '[C] a body of 5001 characters' $PSY 'len(text or "") > max_body' 'len(text or "") > max_body + 1'
BRKG truncation-silent fam_payload '[C] more than 250 commits' $PSY '        if p.get("commits_truncated") and "commit_messages" in scopes:' '        if False:'
BRKG scan-list-ignored fam_payload '[C] sensitive.scan = pr_body' $PSY '    scopes = cfg["sensitive"]["scan"]' '    scopes = ["pr_body", "pr_comments", "commit_messages"]'
BRKG dedupe-by-kind fam_payload '[C] two values of one kind are two hits' $PSY '            seen.add((kind, v))' '            seen.add((kind, ""))
            if kind in {k for k, _ in out}:
                continue'
BRKG allowlist-by-kind fam_allow '[A] --allow: the address next to it is still red' $PSY '            if (ok and ok(v)) or (kind, v) in seen or digest(v) in allow:' '            if (ok and ok(v)) or (kind, v) in seen or (allow and kind == "public-ipv4"):'
BRKG raw-line-honoured fam_allow '[A] a raw value in the allowlist was echoed back' $PSY '        if len(tok) == 1 and re.fullmatch(r"[0-9a-f]{64}", tok[0]):
            out.add(tok[0])' '        if len(tok) == 1 and re.fullmatch(r"[0-9a-f]{64}", tok[0]):
            out.add(tok[0])
        elif len(tok) == 1:
            out.add(digest(tok[0])); print("allowed", tok[0])'
BRKG allowlist-from-worktree fam_allow '[A] --config-ref base: a value exempt only in the HEAD' $PSY '        elif a.config_ref:
            text = gc.read_at(a.cwd, a.config_ref, rel)' '        elif a.config_ref:
            text = gc.read_at(a.cwd, None, rel)'
BRKG config-from-worktree fam_allow '[A] a PR that points sensitive.allowlist' gate_common.py '    return load_config_text(read_at(root, ref, sdlc_config.CONFIG_REL), " (read at %s)" % ref)' '    return load_config(root, None)'
BRKG bad-ref-is-absent fam_allow '[A] a ref that does not read is rc 2' gate_common.py '        raise Infra("ref `%s` does not read" % ref)
    if git(["cat-file"' '        return None
    if git(["cat-file"'
BRKG paginate-dropped fam_pr '[G] --pr, dirty fixture: red' $PSY '    pages = json.loads(_gh(["api", path, "--paginate", "--slurp"]) or "[]")' '    pages = json.loads(_gh(["api", path, "--slurp"]) or "[]")'
BRKG source-dropped fam_pr "[G] no RED line for" $PSY '                + [{"where": "review %s" % c["id"], "body": c.get("body")} for c in rv])' '                )'
BRKG gh-failure-green fam_pr '[G] gh failing' $PSY '        raise gc.Infra("gh %s failed: %s" % (" ".join(args[:2]), p.stderr.decode("utf-8", "replace").strip()[:160]))' '        return "{}"'
BRKG base-from-worktree fam_pr '[G] --pr, dirty fixture' $PSY '        reader = base_reader(a.cwd, a.config_ref or pr_obj["base_sha"], base_path, check_ref=bool(a.config_ref))' '        reader = lambda rel: gc.read_at(gc.sdlc_config.repo_root(a.cwd), None, rel)'
BRKG config-ref-unchecked fam_pr '[G] --config-ref that neither git nor the API knows' $PSY 'check_ref=bool(a.config_ref))' 'check_ref=False)'
BRKG truncation-flag-gone fam_pr '[G] --pr with 250 commits' $PSY '"commits_truncated": len(commits) >= 250,' '"commits_truncated": False,'
d="$TMP/break-gh-locale"; mk_plugin_copy "$d"
mutate "$d/gates/pr_sensitive.py" 'p = subprocess.run(["gh"] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)' 'p = subprocess.run(["gh"] + args, capture_output=True, text=True, timeout=120)' \
  && mutate "$d/gates/pr_sensitive.py" 'return p.stdout.decode("utf-8", "replace")   # UTF-8 on purpose, not the locale: a PR is not ASCII' 'return p.stdout' \
  && mutate "$d/gates/pr_sensitive.py" 'p.stderr.decode("utf-8", "replace").strip()[:160]' 'p.stderr.strip()[:160]' \
  && expect_red gh-decoded-by-locale fam_pr "$d" '[G] a locale that is not UTF-8'
# each break removes or loosens one part of the home-path detector
BRKG home-detector-removed fam_positive '[P] home-macos' $PSY '    for v in _home_values(text or ""):' '    for v in []:'
BRKG home-detector-removed-count fam_home '[H] home-linux' $PSY '    for v in _home_values(text or ""):' '    for v in []:'
BRKG home-boundary-dropped fam_negative '[N] home-url-path' $PSY '_HOME_BOUND = r"(?:(?<![\w.~/$%}\])])|(?<=file://))"' '_HOME_BOUND = r""'
BRKG home-word-boundary-dropped fam_negative '[N] home-glued-word' $PSY '_HOME_BOUND = r"(?:(?<![\w.~/$%}\])])|(?<=file://))"' '_HOME_BOUND = r"(?:(?<![.~/$%}\])])|(?<=file://))"'
BRKG home-tilde-boundary-dropped fam_negative '[N] home-tilde' $PSY '_HOME_BOUND = r"(?:(?<![\w.~/$%}\])])|(?<=file://))"' '_HOME_BOUND = r"(?:(?<![\w./$%}\])])|(?<=file://))"'
BRKG home-paren-closer-dropped fam_negative '[N] home-concat-roots' $PSY '_HOME_BOUND = r"(?:(?<![\w.~/$%}\])])|(?<=file://))"' '_HOME_BOUND = r"(?:(?<![\w.~/$%}\]])|(?<=file://))"'
BRKG home-bracket-closer-dropped fam_negative '[N] home-concat-roots' $PSY '_HOME_BOUND = r"(?:(?<![\w.~/$%}\])])|(?<=file://))"' '_HOME_BOUND = r"(?:(?<![\w.~/$%})])|(?<=file://))"'
BRKG home-brace-closer-dropped fam_negative '[N] home-concat-roots' $PSY '_HOME_BOUND = r"(?:(?<![\w.~/$%}\])])|(?<=file://))"' '_HOME_BOUND = r"(?:(?<![\w.~/$%\])])|(?<=file://))"'
BRKG home-percent-closer-dropped fam_negative '[N] home-concat-roots' $PSY '_HOME_BOUND = r"(?:(?<![\w.~/$%}\])])|(?<=file://))"' '_HOME_BOUND = r"(?:(?<![\w.~/$}\])])|(?<=file://))"'
BRKG home-dot-boundary-dropped fam_negative '[N] home-relative' $PSY '_HOME_BOUND = r"(?:(?<![\w.~/$%}\])])|(?<=file://))"' '_HOME_BOUND = r"(?:(?<![\w~/$%}\])])|(?<=file://))"'
BRKG home-redirect-glued fam_positive '[P] home-redirect' $PSY '_HOME_BOUND = r"(?:(?<![\w.~/$%}\])])|(?<=file://))"' '_HOME_BOUND = r"(?:(?<![\w.~/$%}\])>-])|(?<=file://))"'
BRKG home-file-url-dropped fam_positive '[P] home-file-url' $PSY '|(?<=file://))"' ')"'
BRKG home-drive-guard-dropped fam_home '[H] home-windows-slash' $PSY '(?<!\b[A-Za-z]:)(/Users/)' '(/Users/)'
BRKG home-drive-guard-on-home fam_positive '[P] home-one-letter-colon' $PSY '_HOME_BOUND + r"(/home/)"' '_HOME_BOUND + r"(?<!\b[A-Za-z]:)(/home/)"'
BRKG home-posix-case-folded fam_negative '[N] home-route-lower' $PSY '(?<!\b[A-Za-z]:)(/Users/)" + _HOME_NAME,' '(?<!\b[A-Za-z]:)((?i:/users/))" + _HOME_NAME,'
BRKG home-windows-slash-single fam_positive '[P] home-windows-json' $PSY '(?i:Users)[\\/]+)" + _HOME_NAME' '(?i:Users)[\\/])" + _HOME_NAME'
BRKG home-wsl-dropped fam_positive '[P] home-wsl' $PSY '    _HOME_BOUND + r"(/(?:(?:mnt|cygdrive)/)?[A-Za-z]/Users/)" + _HOME_NAME,' ''
BRKG home-gitbash-boundary-old fam_negative '[N] home-concat-roots' $PSY '    _HOME_BOUND + r"(/(?:(?:mnt|cygdrive)/)?[A-Za-z]/Users/)" + _HOME_NAME,' '    r"(?<![\w.~])(/(?:(?:mnt|cygdrive)/)?[A-Za-z]/Users/)" + _HOME_NAME,'
BRKG home-gitbash-dropped fam_positive '[P] home-gitbash' $PSY '(?:(?:mnt|cygdrive)/)?' '(?:mnt/)'
BRKG home-pct-dropped fam_positive '[P] home-pct-posix' $PSY '    for t in (text, once, _unquote(once)):' '    for t in (text,):'
BRKG home-pct-once fam_positive '[P] home-pct-twice' $PSY '    for t in (text, once, _unquote(once)):' '    for t in (text, once):'
BRKG home-placeholder-flagged fam_negative '[N] home-ph-angle' $PSY '_HOME_NAME = r"(\w[^' '_HOME_NAME = r"(.[^'
BRKG home-template-flagged fam_negative '[N] home-ph-template' $PSY ' or _template_follows(t, m.end(2), name)' ''
BRKG home-prompt-as-template fam_positive '[P] home-prompt-dollar' $PSY '(a == "$" and (b == "{" or word))' '(a == "$")'
BRKG home-percent-brace-as-template fam_positive '[P] home-prompt-percent' $PSY '(a in ("%", "{") and word)' '(a in ("%", "{"))'
BRKG home-tag-as-template fam_positive '[P] home-html-tag' $PSY '(a == "<" and name[-1] in "-_")' '(a == "<")'
BRKG home-runner-flagged fam_negative '[N] home-runner' $PSY '    "runner", "runneradmin", "vsts",' '    "vsts",'
BRKG home-agent-flagged fam_negative '[N] home-agent' $PSY '"circleci", "linuxbrew", "agent", "shared",' '"circleci", "linuxbrew", "shared",'
BRKG home-image-accounts-flagged fam_negative '[N] home-image-accounts' $PSY '    "node", "vscode", "codespace", "ubuntu", "ec2-user", "jovyan", "jenkins", "postgres", "www-data", "nobody", "git",
    "app", "appuser", "travis", "gitpod", "vagrant", "pi", "admin", "dev",' ''
BRKG home-slot-word-flagged fam_negative '[N] home-slot-words' $PSY '"user", "username", "name", "you", "me"))' '"name"))'
BRKG home-slot-spelling-flagged fam_negative '[N] home-slot-spellings' $PSY 'or _HOME_SLOT.fullmatch(name)' ''
BRKG home-exempt-by-word fam_positive '[P] home-name-test' $PSY '"user", "username", "name", "you", "me"))' '"user", "username", "name", "you", "me", "foo", "test"))'
BRKG home-trailing-dot-kept fam_negative '[N] home-runner-sentence-end' $PSY 'name = m.group(2).rstrip(".")' 'name = m.group(2)'
BRKG home-digest-strict fam_home '[H] invalid UTF-8 in a home path' $PSY '    return hashlib.sha256(v.encode("utf-8", "surrogateescape")).hexdigest()' '    return hashlib.sha256(v.encode("utf-8")).hexdigest()'
BRKG home-allow-by-path fam_home '[H] the allowlist hash of a home prefix' $PSY '        if ("home-path", v) not in seen and digest(v) not in allow:' '        if ("home-path", v) not in seen and not allow:'
BRKG exit-always-zero fam_payload '[C] an IP in the BODY of a commit message' $PSY '    return gc.RED if total else gc.OK' '    return gc.OK'

PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in fam_payload fam_allow fam_pr; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes the payload, allowlist and --pr families"

echo; summary
