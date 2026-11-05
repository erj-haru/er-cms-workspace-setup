#!/bin/bash
# =============================================================================
# 配布用 ZIP のテスト
# - 一時ディレクトリに ZIP を作り、展開結果に必要なファイルがすべてあるか確認する
# - SKILL.md の書式（claude.ai へのアップロードで使える項目だけか）を確認する
# - 展開した setup.sh（実行権限を外した状態）で、setup.test.sh の全テストを実行する
# =============================================================================
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/package-test.XXXXXX")
trap '/bin/rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $*"; }

echo "▶ ZIP を作成"
if bash "$ROOT/scripts/package-skill.sh" "$TMP/setup-workspace.zip" > "$TMP/build.log" 2>&1; then ok; else fail "ZIP の作成に失敗"; cat "$TMP/build.log"; fi

echo "▶ ZIP の中身"
mkdir -p "$TMP/x"
(cd "$TMP/x" && unzip -q "$TMP/setup-workspace.zip") || fail "展開に失敗"
ACTUAL=$(cd "$TMP/x" && find . -type f | sed 's#^\./##' | LC_ALL=C sort)
EXPECTED=$(printf '%s\n' \
  "setup-workspace/SKILL.md" \
  "setup-workspace/references/setup-guide.md" \
  "setup-workspace/scripts/setup.sh" | LC_ALL=C sort)
if [ "$ACTUAL" = "$EXPECTED" ]; then ok; else fail "ファイル一覧が違う:"; echo "$ACTUAL" | sed 's/^/    /'; fi
TOP=$(cd "$TMP/x" && ls -A)
if [ "$TOP" = "setup-workspace" ]; then ok; else fail "最上位が setup-workspace フォルダだけになっていない: $TOP"; fi
for f in SKILL.md references/setup-guide.md scripts/setup.sh; do
  if cmp -s "$ROOT/skills/setup-workspace/$f" "$TMP/x/setup-workspace/$f"; then ok; else fail "元ファイルと内容が違う: $f"; fi
done

echo "▶ SKILL.md の書式"
SK="$TMP/x/setup-workspace/SKILL.md"
if [ "$(sed -n '1p' "$SK")" = "---" ]; then ok; else fail "先頭が --- ではない"; fi
FM=$(awk 'NR==1{next} /^---$/{exit} {print}' "$SK")
KEYS=$(printf '%s\n' "$FM" | sed -n 's/^\([A-Za-z_-]*\):.*/\1/p')
for k in $KEYS; do
  case "$k" in
    name | description | license | compatibility | metadata | allowed-tools) ok ;;
    *) fail "claude.ai のアップロードで使えない項目: $k" ;;
  esac
done
NAME=$(printf '%s\n' "$FM" | sed -n 's/^name: *//p')
if [ "$NAME" = "setup-workspace" ]; then ok; else fail "name がフォルダ名と違う: $NAME"; fi
if printf '%s' "$NAME" | grep -Eq '^[a-z0-9-]{1,64}$'; then ok; else fail "name の書式が不正: $NAME"; fi
DESC=$(printf '%s\n' "$FM" | sed -n 's/^description: *//p')
DLEN=$(printf '%s' "$DESC" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')
if [ -n "$DESC" ] && [ "$DLEN" -le 1024 ]; then ok; else fail "description が空または 1024 文字超: $DLEN"; fi
if grep -q 'scripts/setup.sh' "$SK"; then ok; else fail "SKILL.md がスクリプトを参照していない"; fi
if grep -q 'references/setup-guide.md' "$SK"; then ok; else fail "SKILL.md が案内文を参照していない"; fi

echo "▶ 展開したスクリプトで全テストを実行（実行権限なし）"
chmod 644 "$TMP/x/setup-workspace/scripts/setup.sh"
if bash "$ROOT/tests/setup.test.sh" "$TMP/x/setup-workspace/scripts/setup.sh" > "$TMP/inner.log" 2>&1; then
  ok
  tail -n 1 "$TMP/inner.log" | sed 's/^/    /'
else
  fail "展開したスクリプトでのテストに失敗"
  grep -E '✗|結果' "$TMP/inner.log" | sed 's/^/    /'
fi

echo ""
echo "結果: 成功 ${PASS} 件 / 失敗 ${FAIL} 件（ZIP の検証）"
[ "$FAIL" -eq 0 ]
