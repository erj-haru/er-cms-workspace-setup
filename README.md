# er-cms-workspace-setup — Est Rouge CMS 初回導入 Skill（`/setup-workspace`）

Est Rouge CMS（[erj-haru/est-rouge-cms-demo](https://github.com/erj-haru/est-rouge-cms-demo)）を、編集担当者の Mac に **Clone するまで** を Claude に手伝ってもらうための Skill です。

> 本リポジトリは CMS 本体とは独立しています。CMS 本体のコードは変更しません。

---

## 1. このSkillの目的

CMS 本体には `/setup-editor`・`/draft-news`・`/cms-help` などの Skill がありますが、これらは **CMS のリポジトリを Clone した後** でないと使えません。
一方で、編集担当者に Git や GitHub CLI のインストール、GitHub へのログイン、Clone を手作業で行ってもらうのは負担が大きいため、その部分だけを担う初回導入専用の Skill として `/setup-workspace` を用意しました。

```
/setup-workspace（このリポジトリ）           CMS 本体の Skill
───────────────────────────────            ─────────────────────
環境確認 → ログイン確認 → 保存先決定 → Clone  →  /setup-editor → /cms-help → /draft-news …
```

---

## 2. 編集者向けの最短導入手順

1. Slack で共有された **`setup-workspace.zip`** をダウンロードする（ZIP は展開しなくて構いません）
2. Claude Desktop に Skill を登録する（→ [4. Claude Desktop での利用方法](#4-claude-desktop-での利用方法)）
3. Claude Desktop の「Code」タブで新しいセッションを開き、`/setup-workspace` と入力する
4. Claude の案内に沿って進める
   - 足りないソフトがあれば、追加してよいか聞かれます
   - GitHub アカウントの切り替えやログインの開始は、Claude が画面内で行います。あなたが行うのは「どのアカウントを使うかの選択」「操作の承認」「ブラウザでのログインと許可」だけです
   - ログインの確認用コードは自動でクリップボードにコピーされます。ブラウザの入力欄に `command` + `V` で貼り付けてください（パスワードやコードを Claude に伝える必要はありません）
   - 保存先を聞かれたら、分からなければ「おまかせ」で大丈夫です（ホームフォルダ内の `EstRouge/est-rouge-cms-demo` を提案します）
5. 完了したら、案内されたフォルダを「Code」タブで開き、`/setup-editor` を実行する

---

## 3. ZIP の配布方法（管理者向け）

1. 開発者の Mac で ZIP を作る
   ```bash
   bash scripts/package-skill.sh
   ```
   → `dist/setup-workspace.zip` ができます。
2. Slack の配布用チャンネルに `dist/setup-workspace.zip` を添付し、この README の「2. 編集者向けの最短導入手順」へのリンクを添える
3. ZIP を更新したときは、ファイル名を変えずに再投稿し、古い投稿には「更新しました」と追記する

ZIP の構成（Skill に必要なものだけが入っており、他のリポジトリのスクリプトには依存しません）:

```
setup-workspace/
├── SKILL.md                     Claude への操作手順
├── references/setup-guide.md    編集者向けの案内文・トラブル対応
└── scripts/setup.sh             確認・Clone を行う補助スクリプト（macOS 標準の bash で動作）
```

---

## 4. Claude Desktop での利用方法

> ⚠️ **未検証事項があります。** 下の「確認済み（公式ドキュメント）」と「未検証」を区別して読んでください。

### 確認済み（公式ドキュメントの記載。2026-11-05 時点）

- claude.ai／Claude アプリでは、**Customize → Skills →「+」→「+ Create skill」→「Upload a skill」** から ZIP をアップロードできる（[Using Skills in Claude](https://support.claude.com/en/articles/12512180-using-skills-in-claude)）。
  - ZIP の最上位に Skill のフォルダ（`setup-workspace/SKILL.md`）が必要。本リポジトリの ZIP はこの形式。
  - Skill の利用には「コード実行（Code execution）」の有効化が必要。Team / Enterprise プランでは管理者による有効化が必要。
  - アップロード時の SKILL.md の項目は `name` / `description` / `license` / `compatibility` / `metadata` / `allowed-tools` に限られる。本 Skill は `name` と `description` のみ使用（テストで確認）。
- Claude Code は、個人用 Skill を `~/.claude/skills/<名前>/SKILL.md` から読み込み、`/<名前>` で呼び出せる（[Claude Code Skills](https://code.claude.com/docs/en/skills)）。SKILL.md 内の `${CLAUDE_SKILL_DIR}` は、その Skill のフォルダに置き換えられる。
- Claude Code（v2.1.273 以降、claude.ai アカウントでログイン時）は、claude.ai に登録した Skill を `~/.claude/skills/synced/` に同期する（同上）。

### 未検証（実機での確認が必要）

- **Claude Desktop の設定画面からアップロードした Skill が、「Code」タブのローカルセッションで `/setup-workspace` として使えるか。** 公式ドキュメントに明記がなく、未確認です。
- 同期された Skill で `${CLAUDE_SKILL_DIR}` が正しく置き換わるか、ZIP 経由でスクリプトが実行できるか。
  （スクリプトは常に `bash` 経由で呼び出すため、実行権限が失われても動作する設計にしています。）
- Code タブでの「フォルダを開く」操作の正確な画面名称。
- Code タブからの GitHub ログイン（`login`）で、実際にブラウザでの許可まで行い、ログインが完了すること（下の「GitHub 認証の確認状況」を参照）。

### GitHub 認証の確認状況（Code タブ内での実行）

| 項目 | 状況 |
|---|---|
| Code タブの Bash から `gh auth status --json` でアカウント一覧を取得 | ✅ 確認済み（実アカウントで読み取りのみ） |
| Code タブの Bash から `gh auth switch --hostname github.com --user …` を非対話で実行 | ✅ 確認済み（隔離した設定と偽のトークンで実行。切り替わり、もう一方のアカウントも残ることを確認） |
| 実アカウント間の切り替え（切り替え後の権限の再確認を含む） | ⚠️ 未確認（実際のログイン状態を変えるため、承認を得てから実施する） |
| Code タブの Bash から `gh auth login --web --clipboard` を非対話で開始 | ✅ 確認済み（隔離した設定で実行）。gh はコードをクリップボードにコピーするが、**非対話ではブラウザを自動で開かない** ため、スクリプトが `open` で公式の確認ページを開く |
| コードを画面に出さない／時間切れで gh を止める／終了時にクリップボードのコードを消す | ✅ 確認済み（隔離した設定で実行、時間切れまで） |
| ブラウザでの許可まで行ったログイン完了と、その後の再確認 | ⚠️ 未確認（本人がブラウザで許可する必要がある） |
| 非対話のログインで、Git の認証設定（`gh auth setup-git` 相当）が行われるか | ⚠️ 未確認（Clone には不要。CMS 側の Skill で Push する際に影響する可能性あり） |

### 方法 A：設定画面からアップロード（第一候補・要実機検証）

1. Claude Desktop を開き、**Customize → Skills →「+」→「+ Create skill」→「Upload a skill」** で `setup-workspace.zip` を選ぶ
2. Skill の一覧で `setup-workspace` が有効になっていることを確認する
3. 「Code」タブで新しいセッションを開き、`/setup-workspace` と入力する

### 方法 B：個人用 Skill として配置（方法 A で使えない場合）

Claude Code の公式の読み込み場所 `~/.claude/skills/` に置く方法です。ターミナルで次を実行します（ZIP がダウンロードフォルダにある場合）。

```bash
mkdir -p ~/.claude/skills && unzip -n ~/Downloads/setup-workspace.zip -d ~/.claude/skills/
```

`-n` は既存ファイルを上書きしない指定です。古い版を置き換える場合は、先に `~/.claude/skills/setup-workspace` フォルダを Finder でゴミ箱に移してから実行してください。
その後、「Code」タブで新しいセッションを開き `/setup-workspace` と入力します。

---

## 5. `/setup-workspace` の処理内容

| 段階 | 内容 | Claude が勝手に行わないこと |
|---|---|---|
| 1. 環境確認 | macOS か / Git・GitHub CLI（gh）が使えるか / GitHub にログイン済みか / ログイン中のアカウント / CMS リポジトリにアクセスできるか | — |
| 2. ソフトの追加 | 不足があれば Homebrew などでの追加方法を日本語で案内。`brew install git` / `brew install gh` は内容を説明し、**明示的な了承を得てから** 実行 | Homebrew 本体のインストールやネット上のスクリプトの実行（本人がターミナルで実施） |
| 3. アカウント | ログイン済みアカウントの一覧を示して選んでもらう。別アカウントへの切り替え（`gh auth switch`）や新規ログイン（`gh auth login --web`）は、**承認を得てから** Claude が画面内で実行し、完了後に使用中のアカウントとリポジトリへのアクセスを再確認。自動でできない場合のみターミナルでの手動操作を案内 | パスワード・トークン・確認用コードの要求や表示、ログアウト、承認なしの切り替え、ブラウザでの許可 |
| 4. 保存先 | 保存先をたずね、分からなければ `~/EstRouge/est-rouge-cms-demo` を提案。ホームフォルダ内のみ許可 | 固定のユーザー名・パスの使用 |
| 5. Clone | URL と保存先を提示して了承を得てから Clone。正しい Clone が既にあれば再利用 | 既存フォルダの上書き・削除、既存リポジトリの Pull・リセット |
| 6. 確認・案内 | 接続先（remote URL）と CMS の必須ファイルを確認し、次の手順を案内 | コミット・Push・PR 作成、CMS 本体の変更 |

保存先の判定（スクリプトの `plan` / `clone`）:

| 保存先の状態 | 動作 |
|---|---|
| 存在しない／空のフォルダ | Clone する |
| CMS が正しく Clone 済み（接続先が一致し、必須ファイルがある） | そのまま再利用（Pull しない。未保存の変更も残す） |
| 別のリポジトリ／接続先がないリポジトリ／壊れたリポジトリ | 停止して別の保存先を案内 |
| ファイルが入った通常のフォルダ／ファイル／エイリアス | 停止して別の保存先を案内 |
| ホームフォルダ外・`Library`・隠しフォルダ・`..` を含む・相対パス など | 不正な指定として停止 |

入力した場所の最後のフォルダ名が `est-rouge-cms-demo` でない場合は、その中に `est-rouge-cms-demo` を作ります（例: `~/EstRouge` → `~/EstRouge/est-rouge-cms-demo`）。

Clone では Git の設定ファイルを変更せず、gh のログイン情報をその場限りで使います（`git -c credential.helper='!gh auth git-credential' clone …`）。
必須ファイル: `package.json` / `astro.config.mjs` / `compose.yaml` / `.claude/skills/setup-editor/SKILL.md` / `.claude/skills/cms-help/SKILL.md`。

---

## 6. Clone 完了後の `/setup-editor` への引き継ぎ

完了時、Claude は次の 4 点を案内します。

1. Clone したフォルダの場所
2. Claude Desktop の「Code」タブで、そのフォルダを作業フォルダとして新しいセッションを開く方法
3. そのセッションで CMS 本体の **`/setup-editor`** を実行すること（Docker の確認・Astro プレビューの起動は CMS 側が担当）
4. セットアップ後は **`/cms-help`** で使い方を確認できること

Docker・Astro・記事管理・PR 操作は、この Skill では扱いません。

---

## 7. トラブルシューティング

| 症状 | 対処 |
|---|---|
| `/setup-workspace` が候補に出てこない | Skill が有効か確認。方法 A で出ない場合は方法 B を試す。Claude Desktop を再起動して新しいセッションを開く |
| Git を実行すると「コマンドライン・デベロッパツール」のインストール画面が出る | 「インストール」を押して完了を待ち、もう一度 `/setup-workspace` |
| ソフトを入れたのに「見つかりません」 | Claude Desktop を再起動。スクリプトは `/opt/homebrew/bin`・`/usr/local/bin` も探します |
| ログインしたのに未ログインと表示される | 有効期限切れの可能性。`/setup-workspace` からログインをやり直す |
| 「リポジトリにアクセスできません」 | 使用中のアカウントが会社用か確認し、画面の案内に沿って切り替え・ログインを行う。招待メールを承認、または管理者に招待を依頼 |
| ログイン時にブラウザが開かない | ブラウザで https://github.com/login/device を開き、`command` + `V` でコードを貼り付ける |
| コードが無効・貼り付けられない | 時間切れかクリップボードの上書き。ログインをもう一度始める |
| 画面内でログイン・切り替えができないと言われた | gh が古い可能性。`brew upgrade gh` で更新するか、案内に沿ってターミナルで手動操作 |
| Clone に失敗する | 表示された「原因」「対処」に従う（接続・権限・容量・書き込み権限を判定して案内します） |
| 「保存先が使えない」と言われる | 指定した場所に別のフォルダがあります。そのフォルダには触れていないので、別の保存先を指定 |
| Clone 後の確認に失敗 | フォルダは削除していません。表示内容を担当者に共有 |
| 途中で止まった | 何度実行しても安全です。もう一度 `/setup-workspace` を実行（正しい Clone は再利用されます） |

編集者向けの詳しい案内文は [skills/setup-workspace/references/setup-guide.md](skills/setup-workspace/references/setup-guide.md) にあります。

---

## 8. 開発者向け

### 構成

```
er-cms-workspace-setup/
├── skills/setup-workspace/       Skill 本体（ZIP に入るのはここだけ）
│   ├── SKILL.md
│   ├── references/setup-guide.md
│   └── scripts/setup.sh
├── scripts/
│   ├── package-skill.sh          ZIP 生成
│   └── test-setup.sh             全テストの実行
├── tests/
│   ├── setup.test.sh             setup.sh の正常系・異常系テスト
│   ├── package.test.sh           ZIP の展開結果の検証
│   └── mocks/                    git / gh / uname / brew のモック
├── dist/                         ZIP の出力先（ZIP は .gitignore 対象）
└── README.md
```

### 補助スクリプト `setup.sh`

```bash
bash skills/setup-workspace/scripts/setup.sh check              # 環境確認（変更なし）
bash skills/setup-workspace/scripts/setup.sh accounts           # ログイン済みアカウントの一覧（変更なし）
bash skills/setup-workspace/scripts/setup.sh switch <アカウント>  # 別アカウントへ切り替え＋再確認（承認後のみ）
bash skills/setup-workspace/scripts/setup.sh login              # ブラウザでのログイン＋再確認（承認後のみ）
bash skills/setup-workspace/scripts/setup.sh suggest            # おすすめの保存先
bash skills/setup-workspace/scripts/setup.sh plan  "~/EstRouge" # 保存先の確認（変更なし）
bash skills/setup-workspace/scripts/setup.sh clone "~/EstRouge" # Clone／再利用
bash skills/setup-workspace/scripts/setup.sh verify "~/EstRouge" # Clone 済みの確認（変更なし）
```

- 終了コード: `0` 成功 / `1` 利用者の対応が必要 / `2` 失敗（想定外のエラーを含む） / `3` 保存先が使えない / `64` 使い方の誤り
- 出力の最後に `RESULT=…`・`DEST=…` などの `KEY=value` 行を出し、Claude はそれで判定します。
- macOS 標準の `/bin/bash`（3.2）で動作。Node.js は不要。外部コマンドは `git` `gh` `uname` `tr` `sed` `mkdir` `rmdir`、ログイン時のみ `open` `pbcopy` `pbpaste` `mkfifo` `mktemp` `rm` `chmod`（いずれも macOS 標準）。
- `login` の仕組み: `gh auth login --hostname github.com --git-protocol https --web --clipboard` を標準入力なしで起動し、出力は名前付きパイプで受け取ってファイルに残しません。gh が確認用コードをクリップボードにコピーしたことを確認してから、固定の URL（`https://github.com/login/device`）を `open` で開きます。コードをクリップボードに渡せない場合は、画面に出さないために中止します（`LOGIN_UNSUPPORTED`）。許可を待つのは最大 540 秒（`SETUP_WORKSPACE_LOGIN_TIMEOUT`）で、時間切れや中断のときは gh の処理を止めます。終了時、クリップボードにコードが残っていれば消去します。
- `switch` は、ログイン済みで状態が正常なアカウントにだけ切り替えます。既に使用中なら何もしません（`ACTION=unchanged`）。アカウント名は GitHub の名前の規則で検証します。
- `switch` / `login` の後は、`check` と同じ処理で、使用中のアカウントとリポジトリへのアクセスを再確認します（`RESULT=READY` で完了）。
- 外部コマンドは PATH から探すため、PATH の先頭にモックを置けば差し替えられます。Claude Desktop から起動した場合に備え、Homebrew の標準の場所を PATH の末尾に補います（`SETUP_WORKSPACE_EXTRA_PATH` で変更可能。テストでは空にして実機のツールを見ないようにしています）。

### テスト

```bash
bash scripts/test-setup.sh
```

- 一時ディレクトリに偽のホームフォルダを作り、PATH をモックと最低限のシステムコマンドだけにして実行します。実際の GitHub アカウント・ログイン状態・既存リポジトリには一切触れません（`~/.gitconfig` も読み書きしません）。
- 本番と同じ `setup.sh` をそのまま実行します（テスト専用の分岐はありません）。
- モックは呼び出しを記録し、`push` / `pull` / `fetch` / `reset` / `gh auth logout|token|refresh|setup-git` / `brew` などが呼ばれていないこと、確認だけの処理で `gh auth switch` / `gh auth login` が呼ばれていないことも確認します。
- gh のモックは、ログイン済みアカウントをテスト用の一時ファイルで管理します。`open` / `pbcopy` / `pbpaste` もモックにするため、本物のブラウザ・クリップボード・GitHub の認証情報には触れません。
- すべてのテストで、トークンや確認用コードが出力に含まれていないことを自動で確認します。
- `package.test.sh` は ZIP を一時ディレクトリに作って展開し、ファイル一覧・SKILL.md の書式を確認したうえで、**展開した `setup.sh`（実行権限を外した状態）で全テストをもう一度実行** します。
- `shellcheck` が入っていれば自動で実行します。

主なテストケース: Git・gh 導入済み／Git 未導入／gh 未導入（Homebrew あり・なし）／未ログイン／接続不可／アカウント表示／権限なし／正常な Clone（空白・日本語のパス、空フォルダ含む）／既存の正しい Clone の再利用（SSH 形式の接続先含む）／別リポジトリ・接続先なし・必須ファイル欠落／通常フォルダ・ファイル・隠しファイルのみ／Clone 失敗（接続・権限）と空の親フォルダの片付け／再実行（未保存の変更の保持）／不正な保存先（空・相対・ホーム外・`..`・隠しフォルダ・`Library`・`~user`・ホーム外を指すエイリアス・改行・途中がファイル）／使い方の誤り／Clone 後の検証失敗（必須ファイル欠落・接続先違い）／macOS 以外。
GitHub 認証: アカウント一覧／使用中アカウントに権限がない／別アカウントへの切り替えと再確認後の Clone 再開／使用中なら切り替えない／大文字小文字／未ログインのアカウント／不正なアカウント名／切り替え失敗／有効期限切れのアカウント／切り替え後も権限なし／新規ログインと再確認後の Clone 再開／既存アカウントを残したままの追加／許可のキャンセル／コードの期限切れ／時間切れ（gh の停止）／コードをクリップボードに渡せない／古い gh（`--clipboard`・`--json` 非対応）／ブラウザを開けない／ネットワークエラー／想定外の失敗（秘密情報を伏せる）／ログイン後も権限なし／gh なし・macOS 以外。

### ZIP 生成

```bash
bash scripts/package-skill.sh                 # dist/setup-workspace.zip
bash scripts/package-skill.sh /path/to/x.zip  # 出力先を指定
```
