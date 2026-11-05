#!/bin/bash
# =============================================================================
# 配布用 ZIP を作る: dist/setup-workspace.zip
#
# ZIP の中身（Claude の Skill アップロード仕様に合わせ、最上位にフォルダを置く）:
#   setup-workspace/SKILL.md
#   setup-workspace/references/setup-guide.md
#   setup-workspace/scripts/setup.sh
#
# 使い方: bash scripts/package-skill.sh [出力先 ZIP のパス]
# =============================================================================
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
SKILL_NAME="setup-workspace"
SRC="${ROOT}/skills/${SKILL_NAME}"
OUT="${1:-${ROOT}/dist/${SKILL_NAME}.zip}"

# ZIP に入れるファイル（これ以外は入れない）
FILES=(
  "SKILL.md"
  "references/setup-guide.md"
  "scripts/setup.sh"
)

for f in "${FILES[@]}"; do
  if [ ! -f "${SRC}/${f}" ]; then
    echo "❌ 必要なファイルがありません: skills/${SKILL_NAME}/${f}" >&2
    exit 1
  fi
done
bash -n "${SRC}/scripts/setup.sh"

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/package-skill.XXXXXX")
trap '/bin/rm -rf "$STAGE"' EXIT

for f in "${FILES[@]}"; do
  mkdir -p "${STAGE}/${SKILL_NAME}/$(dirname "$f")"
  cp "${SRC}/${f}" "${STAGE}/${SKILL_NAME}/${f}"
done
chmod 755 "${STAGE}/${SKILL_NAME}/scripts/setup.sh"
chmod 644 "${STAGE}/${SKILL_NAME}/SKILL.md" "${STAGE}/${SKILL_NAME}/references/setup-guide.md"

mkdir -p "$(dirname "$OUT")"
OUT_ABS="$(cd "$(dirname "$OUT")" && pwd -P)/$(basename "$OUT")"
TMP_ZIP="${STAGE}/out.zip"
(cd "$STAGE" && zip -q -r -X "$TMP_ZIP" "$SKILL_NAME")
mv -f "$TMP_ZIP" "$OUT_ABS"

echo "✅ 作成しました: ${OUT_ABS}"
unzip -l "$OUT_ABS"
