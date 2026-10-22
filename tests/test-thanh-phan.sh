#!/bin/bash
# =============================================================================
# Plugin vibemaestro-sdlc — thành phần nạp được: skill + hook qua CLI `claude plugin`
# =============================================================================
# Chạy: bash tests/test-thanh-phan.sh
#       PLUGIN_REQUIRE_CLAUDE=1 bash …   # thiếu `claude` thì ĐỎ (mặc định: SKIP kêu to)
#
# Phần tĩnh: mỗi skills/<tên>/SKILL.md có frontmatter name khớp thư mục, description kiểu "Use when:", và mọi
# đường script trong skill trỏ tới file CÓ THẬT của plugin. Phần CLI (không cần login/model; CLAUDE_CONFIG_DIR +
# HOME tạm, nguồn chép sang thư mục tạm): `validate` plugin + marketplace xanh, cài từ marketplace cục bộ, `details`
# liệt kê đủ hook + tám skill.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
H0=$(tree_hash "$SRC_ROOT" 2>/dev/null)
SKILLS="init-kb intake brainstorm spec plan ship install-gates batonrun coordinator-bootstrap release local-parallel"

echo "== phần 1: skill có mặt, đúng khuôn =="
for s in $SKILLS; do
  F="$PLUGIN/skills/$s/SKILL.md"
  [ -f "$F" ] && ok "skills/$s/SKILL.md có mặt" || { bad "thiếu skills/$s/SKILL.md"; continue; }
  eq "$(sed -n 1p "$F")" '---' "skills/$s: mở đầu bằng frontmatter"
  eq "$(sed -n 2p "$F")" "name: $s" "skills/$s: name khớp tên thư mục"
  has "$(sed -n 3p "$F")" 'description: "Use when:' "skills/$s: description 'Use when:'"
  eq "$(sed -n 4p "$F")" '---' "skills/$s: frontmatter đóng ở dòng 4"
done
mkdir -p "$TMP/sk"; printf 'x\n' > "$TMP/sk/f"
eq "$(sed -n 2p "$TMP/sk/f")" '' "đối chứng dụng cụ: sed -n 2p trên file một dòng trả rỗng (assert 'name:' có thể đỏ)"
eq "$(ls "$PLUGIN/skills" | wc -l | tr -d ' ')" 11 "đúng mười một thư mục skill (không skill lạ)"
for s in $SKILLS; do
  for ref in $(grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9_./-]+' "$PLUGIN/skills/$s/SKILL.md" 2>/dev/null | sed 's|^\${CLAUDE_PLUGIN_ROOT}/||' | sort -u); do
    [ -f "$PLUGIN/$ref" ] && ok "skills/$s: \${CLAUDE_PLUGIN_ROOT}/$ref là file có thật" || bad "skills/$s trỏ tới \${CLAUDE_PLUGIN_ROOT}/$ref — KHÔNG có file"
  done
done
printf 'x ${CLAUDE_PLUGIN_ROOT}/scripts/khong-co.py y\n' | grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9_./-]+' | sed 's|^\${CLAUDE_PLUGIN_ROOT}/||' | { read -r r; [ ! -f "$PLUGIN/$r" ] && ok "đối chứng dụng cụ: ref tới file không tồn tại bị bắt" || bad "dụng cụ không bắt ref chết"; }
N=$(cat "$PLUGIN"/skills/*/SKILL.md 2>/dev/null | grep -c '\${CLAUDE_PLUGIN_ROOT}/scripts/'); [ "$N" -gt 0 ] && ok "skill dùng \${CLAUDE_PLUGIN_ROOT}/scripts/… ($N chỗ)" || bad "skill không trỏ script nào của plugin"
eq "$(find "$PLUGIN" -type l | wc -l | tr -d " ")" 0 "không symlink nào trong plugin"

echo "== phần 2: CLI claude plugin (offline, không model) =="
if ! command -v claude >/dev/null 2>&1; then
  if [ "${PLUGIN_REQUIRE_CLAUDE:-}" = 1 ]; then bad "không có 'claude' mà PLUGIN_REQUIRE_CLAUDE=1"; else
    echo "  SKIP *** thiếu 'claude' trên máy này — phần 2 KHÔNG chạy ***"; fi
  summary; exit $?
fi
export CLAUDE_CONFIG_DIR="$TMP/cfg"; mkdir -p "$CLAUDE_CONFIG_DIR"
cl() { claude "$@" 2>&1; }
CP="$TMP/repo"; mkdir -p "$CP"; (cd "$SRC_ROOT" && tar --exclude=.git -cf - .) | tar -x -C "$CP"; find "$CP" -name __pycache__ -prune -exec rm -rf {} +
O=$(cl plugin validate "$CP/plugins/vibemaestro-sdlc"); rc=$?
eq "$rc" 0 "validate plugin (có skills/): rc 0"; has "$O" 'Validation passed' "validate plugin: passed"; empty "$(printf '%s\n' "$O" | grep '❯' | grep -v 'No version specified')" "validate plugin: no warning but the missing version (no version in private)"
O=$(cl plugin validate "$CP"); rc=$?
eq "$rc" 0 "validate marketplace: rc 0"; has "$O" 'Validation passed' "validate marketplace: passed"; empty "$(printf '%s\n' "$O" | grep '❯' | grep -v 'No version specified')" "validate marketplace: no warning but the missing versions"
# đối chứng: skill sai khuôn thì validate phải bắt được (nếu không, 'xanh' ở trên vô nghĩa)
BADP="$TMP/bad"; cp -r "$CP/plugins/vibemaestro-sdlc" "$BADP"; printf -- '---\nname: [hỏng\n---\n' > "$BADP/skills/intake/SKILL.md"
O=$(cl plugin validate "$BADP"); rc=$?
if [ "$rc" != 0 ] || printf '%s' "$O" | grep -q 'arning'; then ok "đối chứng: SKILL.md frontmatter hỏng → validate đỏ hoặc cảnh báo (rc $rc)"; else bad "validate không nhìn skill: frontmatter hỏng mà rc 0, không cảnh báo"; fi

cl plugin marketplace add "$CP" >/dev/null; rc=$?; eq "$rc" 0 "marketplace add <thư mục>: rc 0"
NAME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$CP/.claude-plugin/marketplace.json")
O=$(cl plugin install "vibemaestro-sdlc@$NAME"); rc=$?
eq "$rc" 0 "install từ marketplace cục bộ: rc 0"; has "$O" 'Successfully installed' "install: thành công"
O=$(cl plugin details "vibemaestro-sdlc@$NAME")
has "$O" 'Skills (11)' "details: 11 skill"
has "$O" 'Hooks (2)' "details: hook SessionStart + PreToolUse"
for s in $SKILLS; do has "$O" "$s" "details: liệt kê skill $s"; done
# đối chứng: bỏ một skill thì details đếm 10 (số 11 ở trên không phải cố định do CLI)
CP2="$TMP/repo2"; cp -r "$CP" "$CP2"; rm -rf "$CP2/plugins/vibemaestro-sdlc/skills/ship"
export CLAUDE_CONFIG_DIR="$TMP/cfg2"; mkdir -p "$CLAUDE_CONFIG_DIR"
cl plugin marketplace add "$CP2" >/dev/null; cl plugin install "vibemaestro-sdlc@$NAME" >/dev/null
O=$(cl plugin details "vibemaestro-sdlc@$NAME")
has "$O" 'Skills (10)' "đối chứng: bỏ skills/ship → details đếm 10 skill"
hasnt "$(printf '%s\n' "$O" | grep -F 'Skills (')" 'ship' "đối chứng: ship không còn trong dòng liệt kê skill"

eq "$(tree_hash "$SRC_ROOT")" "$H0" "G2: phần CLI không ghi vào cây repo (test chạy trên bản chép)"
echo; summary
