# shellcheck shell=bash
# =============================================================================
# Dụng cụ cho suite thủ tục (init-kb / intake / plan / ship) và suite độc lập
# =============================================================================
# `source` SAU lib.sh (cần git_, ok/bad). Không chạy gì khi source.
# Lõi (`intent_branch.py`, `open_pr.py`) và adapter chạy là bản THẬT trong plugin; chỉ `gh` là giả (đặt đầu
# PATH, ghi log), nên không lệnh nào tới GitHub thật.
# =============================================================================

# mk_gh <bindir> — `gh` giả. Biến môi trường khi chạy:
#   GH_LOG      mỗi lệnh gh ghi 2 dòng: CWD=… và ARGV: [a] [b]…
#   GH_CLOSING_JSON / GH_CLOSING_AFTER / GH_PRVIEW_FAIL / GH_PRVIEW_HANG   `pr view` trả GH_CLOSING_JSON (mặc định `[]`) từ lần gọi thứ
#                         GH_CLOSING_AFTER+1 trở đi (trước đó `[]`, mô phỏng GitHub điền chậm); GH_PRVIEW_FAIL: rc 1
#   GH_STDIN    nếu đặt, stdin của `gh pr create` được ghi vào file đó (thân PR)
#   GH_LABELS_FILE        nếu đặt: file liệt kê các nhãn đang có (mỗi dòng một nhãn). `issue create --label X` hỏng
#                         (rc 1, như gh thật) khi X không có trong file; `label create X` thêm X, hoặc rc 1 nếu đã có.
#   GH_LABEL_CREATE_FAIL  nếu đặt: `label create` luôn rc 1 và `issue create` luôn rc 1 (mô phỏng thiếu quyền)
mk_gh() {
  mkdir -p "$1"
  cat > "$1/gh" <<'GH'
#!/bin/bash
{ printf 'CWD=%s\n' "$PWD"; printf 'ARGV:'; for a in "$@"; do printf ' [%s]' "$a"; done; echo; } >> "${GH_LOG:-/dev/null}"
case "$1 $2" in
  "label create") [ -n "${GH_LABEL_CREATE_FAIL:-}" ] && { echo "HTTP 403: label create refused" >&2; exit 1; }
                  if [ -n "${GH_LABELS_FILE:-}" ]; then
                    grep -qxF "$3" "$GH_LABELS_FILE" && { echo "label with name \"$3\" already exists" >&2; exit 1; }
                    echo "$3" >> "$GH_LABELS_FILE"
                  fi;;
  "issue create") [ -n "${GH_LABEL_CREATE_FAIL:-}" ] && { echo "HTTP 403: issue create refused" >&2; exit 1; }
                  if [ -n "${GH_LABELS_FILE:-}" ]; then
                    prev=""; for a in "$@"; do
                      [ "$prev" = "--label" ] && ! grep -qxF "$a" "$GH_LABELS_FILE" && { echo "could not add label: '$a' not found" >&2; exit 1; }
                      prev="$a"; done
                  fi
                  echo "https://github.com/acme/app-demo/issues/42";;
  "repo view")    echo "acme/app-demo";;
  "pr view")      [ -n "${GH_PRVIEW_FAIL:-}" ] && exit 1
                  [ -n "${GH_PRVIEW_HANG:-}" ] && exec sleep 30
                  c="${GH_LOG:-/dev/null}.cnt"; n=$(cat "$c" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$c"
                  if [ "$n" -le "${GH_CLOSING_AFTER:-0}" ]; then echo "[]"; else
                    # real gh prints coloured multi-line JSON when colour is forced; mimic it so the core must ask for plain output
                    if [ -n "${CLICOLOR_FORCE:-}" ]; then printf '\033[1;38m[\033[m\n %s\n\033[1;38m]\033[m\n' "$(echo "${GH_CLOSING_JSON:-[]}" | tr -d '[]')"
                    else echo "${GH_CLOSING_JSON:-[]}"; fi
                  fi;;
  "pr create")    if [ -n "${GH_STDIN:-}" ]; then cat > "$GH_STDIN"; else cat >/dev/null; fi
                  echo "https://github.com/acme/app-demo/pull/7";;
esac
exit 0
GH
  chmod +x "$1/gh"
}

# mk_app_remote <dir> — repo app giả CÓ origin (bare, ở <dir>.git); nhánh mặc định main; chưa có kb/.
mk_app_remote() {
  local a=$1
  git_ init -q --bare -b main "$a.git"
  git_ init -q -b main "$a"
  mkdir -p "$a/src"; echo 'x' > "$a/src/main.ts"
  git_ -C "$a" add -A; git_ -C "$a" commit -qm c1
  git_ -C "$a" remote add origin "$a.git"
  git_ -C "$a" push -q origin main
  git_ -C "$a" fetch -q origin
}

# tree_hash_all <dir> — băm MỌI file kể cả file bị .gitignore (như __pycache__), bỏ .git.
# Khác tree_hash của lib.sh ở chỗ nó cũng băm đường dẫn: tạo thư mục rỗng/đổi tên cũng lộ.
tree_hash_all() {
  (cd "$1" && find . -path ./.git -prune -o -print | LC_ALL=C sort | while IFS= read -r p; do
     if [ -f "$p" ]; then printf '%s %s\n' "$p" "$(sha1sum < "$p" | cut -d' ' -f1)"; else printf '%s\n' "$p"; fi
   done | sha1sum | cut -d' ' -f1)
}

# bố cục kb/ tối thiểu mà `kb.py init` phải dựng và các lệnh `new` phải giữ nguyên — kiểm độc lập với kb.py:
# bốn thư mục, README, current-state, tên file theo ngày, không thư mục lạ. In mỗi lỗi một dòng; rc 0 = đạt.
kb_layout_problems() {  # <thư mục kb> [tên thư mục thêm được phép: dành cho kb/ của chính repo này, vd. ports]
  local kb=$1 d f n x rc=0; shift
  for d in intent specs plans decisions; do [ -d "$kb/$d" ] || { echo "thiếu kb/$d/"; rc=1; }; done
  for f in README.md current-state.md; do [ -f "$kb/$f" ] || { echo "thiếu kb/$f"; rc=1; }; done
  for d in "$kb"/*/; do
    n=$(basename "$d")
    case "$n" in intent|specs|plans|decisions) ;; *) for x in "$@"; do [ "$n" = "$x" ] && continue 2; done; echo "thư mục lạ kb/$n/"; rc=1;; esac
  done
  for f in "$kb"/intent/*.md "$kb"/specs/*.md "$kb"/plans/*.md "$kb"/decisions/*.md; do
    [ -e "$f" ] || continue
    printf '%s' "$(basename "$f")" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*\.md$' || { echo "tên sai khuôn: ${f#"$kb"/}"; rc=1; }
  done
  return $rc
}
