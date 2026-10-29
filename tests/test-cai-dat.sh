#!/bin/bash
# =============================================================================
# Plugin vibemaestro-sdlc — manifest, marketplace, cài đặt qua CLI, thông tin nhạy cảm
# =============================================================================
# Chạy: bash tests/test-cai-dat.sh
#       PLUGIN_REQUIRE_CLAUDE=1 bash …   # thiếu `claude` thì ĐỎ (mặc định: phần CLI SKIP, kêu to)
#
# PHẦN 1 tĩnh (không cần `claude`): manifest, marketplace ở gốc repo, symlink, quét thông tin nhạy cảm,
#         workflow CI chạy đúng bộ test.
# PHẦN 2 CLI (cần `claude`, KHÔNG cần login hay model): `claude plugin validate | marketplace add | install |
#         list | details | update` — luôn với CLAUDE_CONFIG_DIR + HOME trong thư mục tạm, nên không chạm `~/.claude`
#         và không ghi vào cây repo (nguồn được CHÉP sang thư mục tạm trước).
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
MP="$SRC_ROOT/.claude-plugin/marketplace.json"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"

H0=$(tree_hash "$SRC_ROOT" 2>/dev/null)
# the version the manifest must carry: none on the private tree, the CHANGELOG's released version on the public export (none before
# the first release); TS names the tree (fixtures/lib.sh tree_shape)
TS=$(tree_shape "$SRC_ROOT"); WV=$(want_version "$SRC_ROOT" "$PLUGIN")
echo "== phần 1: manifest và marketplace =="
[ -f "$PLUGIN/.claude-plugin/plugin.json" ] && ok "có plugins/vibemaestro-sdlc/.claude-plugin/plugin.json" || bad "thiếu plugin.json"
[ -f "$MP" ] && ok "có marketplace ở GỐC repo: .claude-plugin/marketplace.json" || bad "thiếu marketplace.json ở gốc repo"
[ -f "$PLUGIN/hooks/hooks.json" ] && ok "có hooks/hooks.json" || bad "thiếu hooks.json"
python3 - "$PLUGIN/.claude-plugin/plugin.json" "$MP" "$PLUGIN/hooks/hooks.json" "$WV" <<'PY' && ok "JSON hợp lệ và đúng khuôn (tên, version ${WV:-none} on the $TS tree, không userConfig/hub, marketplace trỏ đúng plugin, hooks có wrapper)" || bad "manifest/marketplace/hooks sai khuôn"
import json, sys
p, m, h = (json.load(open(f)) for f in sys.argv[1:4])
assert p["name"] == "vibemaestro-sdlc", p["name"]
assert (p.get("version") == sys.argv[4] if sys.argv[4] else "version" not in p) and p.get("description"), \
    "version %r: the private repo carries no version key, the export its CHANGELOG's released one (%r)" % (p.get("version", "<absent>"), sys.argv[4])
assert "userConfig" not in p, "plugin không còn cấu hình vị trí hub"
assert "hub" not in json.dumps(p).lower() and "gitops" not in json.dumps(p).lower()
assert m["name"] == "vibemaestro", m["name"]
ents = {e["name"]: e for e in m["plugins"]}
assert ents["vibemaestro-sdlc"]["source"] == "./plugins/vibemaestro-sdlc", ents
assert m.get("description")
hk = h["hooks"]
assert set(hk) == {"SessionStart", "PreToolUse"}, set(hk)
PY
N=$(find "$SRC_ROOT" -path "$SRC_ROOT/.git" -prune -o -type l -print | wc -l | tr -d " ")
eq "$N" 0 "repo không có symlink (symlink trỏ ra ngoài plugin bị bỏ khi cài vào cache)"
mkdir -p "$TMP/sl" && ln -s /nonexistent "$TMP/sl/l" && eq "$(find "$TMP/sl" -type l | wc -l | tr -d " ")" 1 "đối chứng dụng cụ: find -type l thấy symlink"

echo "== phần 1: không chứa thông tin nhạy cảm / đường dẫn máy cá nhân =="
# Quét mọi thứ NGOẠI TRỪ tests/ (chính các file test chứa mẫu quét làm chuỗi thử).
scan_tree() {  # scan_tree <root> → every file outside .git, tests/ and scripts/public-tree.allow
  # that one path holds, by design, the made-up home paths and addresses the tests feed their detectors; it is an owner-merge
  # path, so the owner's review is the control for what lives there. Only that exact path: no other file of scripts/ is exempt.
  (cd "$1" && find . -path ./.git -prune -o -path ./tests -prune -o -path ./scripts/public-tree.allow -prune -o -type f ! -name '*.pyc' -print0 | sort -z | xargs -0 cat; true)
}
SCAN="$TMP/scan.txt"; scan_tree "$SRC_ROOT" > "$SCAN"
HX="$TMP/home-planted"; mkdir -p "$HX/other"; printf 'WORK = "/home/bob"\n' > "$HX/other/x.py"
eq "$(scan_tree "$HX" | grep -cE -e '/home/[a-z]')" 1 "control: a planted /home/<name> line is in the scan"
nonempty "$(head -c 200 "$SCAN")" "đối chứng dụng cụ: bản quét có nội dung (không xanh vì quét rỗng)"
IP_RX='\b([0-9]{1,3}\.){3}[0-9]{1,3}\b'
priv_free() { grep -E "$IP_RX" | grep -vE '\b(127\.0\.0\.1|0\.0\.0\.0|10\.[0-9.]+|192\.168\.[0-9.]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9.]+)\b' || true; }
eq "$(priv_free < "$SCAN" | wc -l | tr -d ' ')" 0 "không có IP công cộng trong repo"
printf 'máy %s.%s.%s.%s\n' 52 14 7 9 | priv_free | grep -q . && ok "đối chứng dương: một IP công cộng làm máy quét IP đỏ" || bad "máy quét IP không bắt được ca dương"
# a Claude Code settings file pasted into the repo shows as the JSON key; the plugin's rule packs name the key in code and docs
for pat in '/home/[a-z]' '/Users/[a-z]' '"enabledPlugins"[[:space:]]*:' 'ghp_[A-Za-z0-9]{20}' 'github_pat_' 'AKIA[0-9A-Z]{12}' '-----BEGIN [A-Z ]*PRIVATE KEY' '\b[0-9]{12}\b'; do
  c=$(grep -cE -e "$pat" "$SCAN"); eq "$c" 0 "không có mẫu '$pat' trong repo"
done
eq "$(printf '{\n  "enabledPlugins": {"x@y": true}\n}\nreads `enabledPlugins` and d.get("enabledPlugins")\n' | grep -cE -e '"enabledPlugins"[[:space:]]*:')" 1 \
  "đối chứng dụng cụ: mẫu enabledPlugins bắt một file settings dán vào repo, không bắt tên khoá trong code hay tài liệu"
EMAIL_RX='[A-Za-z0-9._-]+@[A-Za-z0-9-]+\.[a-z]{2,}'
eq "$(grep -cE -e "$EMAIL_RX" "$SCAN")" 0 "không có địa chỉ email trong repo (kể cả hai lõi: không còn ngoại lệ)"
HY="$TMP/scripts-planted"; mkdir -p "$HY/scripts"; printf 'WORK = "/home/bob"\nmail a@b.invalid\n' > "$HY/scripts/other.sh"; cp "$HY/scripts/other.sh" "$HY/scripts/public-tree.allow"
eq "$(scan_tree "$HY" | grep -cE -e "/home/[a-z]|$EMAIL_RX")" 2 "control: only the allow file is exempt; a home path and an address planted in another scripts/ file still show in the scan"
printf 'x /home/ai/y\nmail a@b.invalid\nghp_%s\n' "$(printf 'a%.0s' $(seq 1 20))" | grep -cE -e '/home/[a-z]|[A-Za-z0-9._-]+@[A-Za-z0-9-]+\.[a-z]{2,}|ghp_[A-Za-z0-9]{20}' | { read -r c; eq "$c" 3 "đối chứng dụng cụ: các mẫu quét thấy ca dương (đường dẫn máy, email, token)"; }

echo "== phần 1: CI chạy đúng bộ test, job tests không cần secret =="
WF="$SRC_ROOT/.github/workflows/test.yml"
if [ -f "$WF" ]; then
  has "$(cat "$WF")" 'bash tests/run-all.sh' "workflow chạy 'bash tests/run-all.sh'"
  has "$(cat "$WF")" 'pull_request' "workflow chạy trên pull_request"
  # the one secret is KIT_TERMS, read by the scan-terms job only (tests/test-scan-ci-workflow.sh)
  hasnt "$(sed -e 's/secrets\.KIT_TERMS//g' "$WF")" 'secrets.' "workflow không dùng secret nào ngoài KIT_TERMS"
  python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); assert "secrets." not in str(d["jobs"]["tests"])' "$WF" && ok "job tests không dùng secret nào" || bad "job tests dùng một secret"
  hasnt "$(cat "$WF")" 'token:' "workflow không truyền token tự chọn"
  has "$(cat "$WF")" 'PLUGIN_REQUIRE_CLAUDE' "workflow buộc phần CLI claude phải chạy (thiếu CLI thì đỏ, không bỏ qua êm)"
  uses_var_runner() { grep -qxF "    runs-on: \${{ vars.CI_RUNNER || (github.repository_visibility == 'public' && 'ubuntu-latest' || fromJSON('CI_RUNNER is not set in a private repository')) }}" "$1"; }
  uses_var_runner "$WF" && ok "workflow: runs-on lấy từ vars.CI_RUNNER; chưa đặt thì repo riêng lỗi ngay, repo công khai dùng ubuntu-latest (runs-on)" || bad "workflow: runs-on không theo vars.CI_RUNNER (runs-on)"
  printf 'jobs:\n  tests:\n    runs-on: ubuntu-latest\n' > "$TMP/wf-hardcoded.yml"
  uses_var_runner "$TMP/wf-hardcoded.yml" && bad "đối chứng âm: runs-on cứng ubuntu-latest vẫn qua phép kiểm runs-on" || ok "đối chứng âm: runs-on cứng ubuntu-latest bị phép kiểm runs-on bắt"
  python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); assert d["jobs"]["tests"]["steps"]' "$WF" && ok "workflow: YAML hợp lệ, có bước" || bad "workflow YAML hỏng"
else
  echo "  (chưa có .github/workflows/test.yml — kiểm ở commit thêm CI)"
fi

echo "== phần 2: CLI claude plugin (offline, không model) =="
if ! command -v claude >/dev/null 2>&1; then
  if [ "${PLUGIN_REQUIRE_CLAUDE:-}" = 1 ]; then bad "không có 'claude' mà PLUGIN_REQUIRE_CLAUDE=1"; else
    echo "  SKIP *** thiếu 'claude' trên máy này — phần 2 (validate/marketplace/install) KHÔNG chạy ***"; fi
  summary; exit $?
fi
export CLAUDE_CONFIG_DIR="$TMP/cfg"; mkdir -p "$CLAUDE_CONFIG_DIR"
cl() { claude "$@" 2>&1; }
CP="$TMP/repo"; mkdir -p "$CP"; (cd "$SRC_ROOT" && tar --exclude=.git -cf - .) | tar -x -C "$CP"; find "$CP" -name __pycache__ -prune -exec rm -rf {} +

O=$(cl plugin validate "$CP/plugins/vibemaestro-sdlc"); rc=$?
eq "$rc" 0 "claude plugin validate <plugin> rc 0"; has "$O" 'Validation passed' "validate plugin: passed"
# the only warning is the missing version, on purpose: the public release sets the version (a released export has none to warn about)
other_warnings() { printf '%s\n' "$1" | grep '❯' | grep -v 'No version specified'; }
empty "$(other_warnings "$O")" "validate plugin: no warning but the missing version"
if [ -z "$WV" ]; then has "$O" 'No version specified' "validate plugin: …which it names"
else hasnt "$O" 'No version specified' "validate plugin: released ($WV), no missing version is named"; fi
O=$(cl plugin validate "$CP"); rc=$?
eq "$rc" 0 "claude plugin validate <marketplace: gốc repo> rc 0"; has "$O" 'Validation passed' "validate marketplace: passed"
empty "$(other_warnings "$O")" "validate marketplace: no warning but the missing versions"
# đối chứng: validate CÓ thể đỏ
BADP="$TMP/bad"; cp -r "$CP/plugins/vibemaestro-sdlc" "$BADP"
python3 - "$BADP/.claude-plugin/plugin.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["version"] = 5; json.dump(d, open(p, "w"))
PY
O=$(cl plugin validate "$BADP"); rc=$?
ne "$rc" 0 "đối chứng: version sai kiểu → validate đỏ (rc $rc)"

O=$(cl plugin marketplace add "$CP"); rc=$?
eq "$rc" 0 "marketplace add <thư mục chứa .claude-plugin/marketplace.json> rc 0"
NAME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$CP/.claude-plugin/marketplace.json")
O=$(cl plugin install "vibemaestro-sdlc@$NAME"); rc=$?
eq "$rc" 0 "plugin install vibemaestro-sdlc@$NAME rc 0"; has "$O" 'Successfully installed' "install: thành công"
O=$(cl plugin list)
has "$O" "vibemaestro-sdlc@$NAME" "plugin list: có plugin"
if [ -z "$WV" ]; then has "$O" "Version: unknown" "plugin list: a directory marketplace without git and no version: unknown (measured M4)"
else has "$O" "Version: $WV" "plugin list: a released manifest: Version: $WV"; fi
has "$O" 'enabled' "plugin list: enabled"
O=$(cl plugin details "vibemaestro-sdlc@$NAME")
has "$O" 'SessionStart' "details: hook SessionStart"; has "$O" 'PreToolUse' "details: hook PreToolUse"
echo '# doi' >> "$CP/plugins/vibemaestro-sdlc/scripts/session-start.py"
O=$(cl plugin update "vibemaestro-sdlc@$NAME")
CACHE=$(find "$CLAUDE_CONFIG_DIR/plugins/cache" -name session-start.py 2>/dev/null | head -1)
nonempty "$CACHE" "có bản chép plugin trong cache của CLI"
if [ -z "$WV" ]; then
  has "$O" 'refreshed from source' "update after a source edit (no version, a directory without git): refreshed from source"
  has "$(cat "$CACHE")" '# doi' "the cache copy follows the source (no version: no bump needed)"
else   # measured: a released version is the install's key, so a source edit without a bump is not an update
  has "$O" "already at the latest version ($WV)" "update after a source edit (released $WV, no bump): already at the latest version"
  hasnt "$(cat "$CACHE")" '# doi' "the cache copy keeps the installed bytes (a released version needs a bump)"
fi

echo "== phần 2: symlink trỏ ra ngoài plugin bị bỏ khi cài (nên plugin không được dựa vào symlink) =="
PM="$TMP/probe-mk"; mkdir -p "$PM/.claude-plugin" "$PM/plugins/pp/.claude-plugin" "$PM/plugins/pp/scripts" "$TMP/ngoai-plugin"
echo NGOAI > "$TMP/ngoai-plugin/secret.txt"
printf '%s\n' '{"name":"probe-mk","description":"d","owner":{"name":"t"},"plugins":[{"name":"pp","source":"./plugins/pp","description":"d"}]}' > "$PM/.claude-plugin/marketplace.json"
printf '%s\n' '{"name":"pp","version":"0.0.1","description":"d","author":{"name":"t"}}' > "$PM/plugins/pp/.claude-plugin/plugin.json"
echo 'print(1)' > "$PM/plugins/pp/scripts/a.py"
ln -s a.py "$PM/plugins/pp/scripts/link-trong.py"
ln -s ../../../../ngoai-plugin/secret.txt "$PM/plugins/pp/scripts/link-ngoai.txt"
cl plugin marketplace add "$PM" >/dev/null; O=$(cl plugin install pp@probe-mk); eq "$?" 0 "cài plugin có symlink ra ngoài: rc 0 (không báo lỗi)"
PC=$(find "$CLAUDE_CONFIG_DIR/plugins/cache/probe-mk" -type d -name scripts | head -1)
[ -L "$PC/link-trong.py" ] && ok "bản chép trong cache GIỮ symlink trỏ vào trong plugin (đối chứng dương)" || bad "cache không giữ symlink trong plugin ($PC)"
[ ! -e "$PC/link-ngoai.txt" ] && [ ! -L "$PC/link-ngoai.txt" ] && ok "bản chép trong cache BỎ symlink trỏ ra ngoài plugin" || bad "cache vẫn có symlink trỏ ra ngoài"

eq "$(tree_hash "$SRC_ROOT")" "$H0" "G2: cả phần 2 không ghi vào cây repo (test chạy trên bản chép)"

summary
