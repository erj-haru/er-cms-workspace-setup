#!/bin/bash
# =============================================================================
# すべてのテストを実行する
#   1. setup.sh の正常系・異常系テスト（モック使用。実環境は変更しない）
#   2. 配布用 ZIP の検証（一時ディレクトリで作成・展開して確認）
# 使い方: bash scripts/test-setup.sh
# =============================================================================
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
rc=0

echo "=== setup.sh のテスト ==="
bash "$ROOT/tests/setup.test.sh" || rc=1

echo ""
echo "=== 配布用 ZIP のテスト ==="
bash "$ROOT/tests/package.test.sh" || rc=1

if command -v shellcheck >/dev/null 2>&1; then
  echo ""
  echo "=== shellcheck ==="
  shellcheck -S warning "$ROOT/skills/setup-workspace/scripts/setup.sh" "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh "$ROOT"/tests/mocks/* || rc=1
fi

echo ""
if [ $rc -eq 0 ]; then echo "✅ すべてのテストに成功しました"; else echo "❌ 失敗したテストがあります"; fi
exit $rc
