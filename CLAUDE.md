# er-cms-workspace-setup — 開発ルール

Est Rouge CMS の初回導入 Skill `/setup-workspace` のリポジトリです。概要・使い方は [README.md](README.md) を参照してください。

## Git 運用（必須）

改善・修正を実装したら、特別な指示がなくても次を必ず行う。

1. テスト: `bash scripts/test-setup.sh`（すべて成功するまで Push しない。失敗したら原因を直してから）
2. 差分レビュー: `git diff` で変更内容を確認する（認証情報・生成物が含まれていないか）
3. コミット
4. 作業ブランチへ Push
5. 必要に応じて PR を作成
6. コミット SHA と PR の URL を報告する

禁止事項:

- `main` への直接 Push
- force push
- PR の自動マージ
- 既存の未コミット変更を勝手に破棄すること
- 認証情報や、生成された配布用 ZIP（`dist/*.zip`）など不要なファイルのコミット

## 開発上の注意

- Skill 本体は `skills/setup-workspace/` だけ。配布用 ZIP にはここだけが入る（`bash scripts/package-skill.sh`）。
- `setup.sh` は macOS 標準の `/bin/bash`（3.2）で動くように書く（連想配列・`${var,,}` などは使わない）。
- テストではインストーラー・認証コマンドを絶対に実際に実行しない。外部コマンドは `tests/mocks/` のモックに差し替え、システムの場所は `SETUP_WORKSPACE_ROOT` で一時フォルダに置き換える。新しい外部コマンドを使う場合は、モックを追加し `tests/setup.test.sh` の `ALWAYS_MOCKS` か `SYSTEM_TOOLS` に登録する。
- 本番とテストで異なるロジックを書かない（環境変数で変えてよいのは、場所・待ち時間などの値だけ）。
- `sudo` を使わない。管理者の確認は macOS の正式な画面に任せる。
- CMS 本体（erj-haru/est-rouge-cms-demo）のコードは変更しない。
