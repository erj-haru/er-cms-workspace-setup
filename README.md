# er-cms-workspace-setup — Est Rouge CMS 初回導入 Skill（`/setup-workspace`）

Est Rouge CMS（[erj-haru/est-rouge-cms-demo](https://github.com/erj-haru/est-rouge-cms-demo)）を、編集担当者の Mac に **Clone するまで** を Claude に手伝ってもらうための Skill です。

> 本リポジトリは CMS 本体とは独立しています。CMS 本体のコードは変更しません。

---

## 1. このSkillの目的

CMS 本体には `/setup-editor`・`/draft-news`・`/cms-help` などの Skill がありますが、これらは **CMS のリポジトリを Clone した後** でないと使えません。
一方で、編集担当者に Git・Homebrew・GitHub CLI のインストール、GitHub へのログイン、Clone を手作業で行ってもらうのは負担が大きいため、その部分だけを担う初回導入専用の Skill として `/setup-workspace` を用意しました。

**編集者にターミナルを開かせない** ことを最優先にしています。コマンドは Claude が実行し、編集者は「承認」「macOS の確認画面の操作（パスワード・Touch ID・同意）」「ブラウザでの GitHub ログイン」だけを行います。

```
/setup-workspace（このリポジトリ）                                    CMS 本体の Skill
──────────────────────────────────────────────────────────          ─────────────────────
環境チェック → 不足ソフトの追加 → GitHub 認証 → 保存先 → Clone →  /setup-editor → /cms-help → …
             （開発者ツール・Homebrew・gh）
```

---

## 2. 編集者向けの最短導入手順

1. Slack で共有された **`setup-workspace.zip`** をダウンロードする（ZIP は展開しなくて構いません）
2. Claude Desktop に Skill を登録する（→ [4. Claude Desktop での利用方法](#4-claude-desktop-での利用方法)）
3. Claude Desktop の「Code」タブで新しいセッションを開き、`/setup-workspace` と入力する
4. Claude の案内に沿って進める
   - まず Mac の状態を自動で確認し、足りないソフト（Apple の開発者ツール・Homebrew・GitHub CLI）をまとめて教えてくれます
   - ソフトごとに「追加してよいか」聞かれます。承認すると Claude が追加を進めます。ターミナルを開いたり、コマンドをコピーしたりする必要はありません
   - 途中で macOS の確認画面が出たら、ご自身で「インストール」「同意する」を押し、Mac のパスワード（または Touch ID）を入力してください（パスワードはチャットに入力しません）
   - 途中で止まっても、もう一度 `/setup-workspace` を実行すれば続きから再開できます
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

### 確認済み（公式ドキュメントの記載。2026-11-05 時点）

- claude.ai／Claude アプリでは、**Customize → Skills →「+」→「+ Create skill」→「Upload a skill」** から ZIP をアップロードできる（[Using Skills in Claude](https://support.claude.com/en/articles/12512180-using-skills-in-claude)）。
  - ZIP の最上位に Skill のフォルダ（`setup-workspace/SKILL.md`）が必要。本リポジトリの ZIP はこの形式。
  - Skill の利用には「コード実行（Code execution）」の有効化が必要。Team / Enterprise プランでは管理者による有効化が必要。
  - アップロード時の SKILL.md の項目は `name` / `description` / `license` / `compatibility` / `metadata` / `allowed-tools` に限られる。本 Skill は `name` と `description` のみ使用（テストで確認）。
- Claude Code は、個人用 Skill を `~/.claude/skills/<名前>/SKILL.md` から読み込み、`/<名前>` で呼び出せる（[Claude Code Skills](https://code.claude.com/docs/en/skills)）。SKILL.md 内の `${CLAUDE_SKILL_DIR}` は、その Skill のフォルダに置き換えられる。

### 開発者の Mac で確認できたこと（2026-11-05）

- 設定画面からアップロードした ZIP の Skill が、**Code タブのローカルセッションに同期され、`anthropic-skills:setup-workspace` という名前で一覧に表示された**。
  - 同期先: `~/Library/Application Support/Claude/local-agent-mode-sessions/skills-plugin/…/skills/setup-workspace/`
  - 同期されたファイルからは **実行権限が外れていた**（`setup.sh` が `-rw-r--r--`）。本 Skill はスクリプトを常に `bash` で呼び出すため、影響はない。
- Code タブの Bash から、`gh auth switch`（実アカウント間）・`gh auth login --web --clipboard` の開始（隔離した設定）・Homebrew 公式 `.pkg` の署名確認ができた（詳細は下の表）。

### 未検証（実機での確認が必要）

- 同期された Skill を、`/setup-workspace` と `/anthropic-skills:setup-workspace` のどちらで呼び出せるか（一覧には後者の名前で表示）。
- 同期された Skill で `${CLAUDE_SKILL_DIR}` が正しく置き換わるか。
- **ソフトが入っていない Mac での一連の流れ**（開発者の Mac にはすべて入っているため未実施）:
  - Code タブの Bash から実行した `xcode-select --install` で、macOS の確認画面が表示されるか
  - `open` で開いた Homebrew 公式インストーラーで、管理者の確認（パスワード・Touch ID）を経てインストールが完了するか
  - 学校・会社の管理端末で、制限された場合に止まること
- Code タブでの「フォルダを開く」操作の正確な画面名称。
- ブラウザでの許可まで行ったログインの完了と、非対話のログインで Git の認証設定（`gh auth setup-git` 相当）が行われるか。

### Code タブ内での実行の確認状況

| 項目 | 状況 |
|---|---|
| 環境の検出（CPU・開発者ツール・Git・Homebrew・gh・管理者・管理端末） | ✅ 確認済み（読み取りのみ） |
| インストール済みのソフトを入れ直さない（`install-clt` / `install-brew` / `install-gh` が「導入済み」で終わる） | ✅ 確認済み |
| Homebrew 公式 `.pkg` の取得と署名確認（Team ID `927JGANW46`・Apple の公証・Gatekeeper） | ✅ 確認済み（ダウンロードして検証のみ。インストールは未実施）。署名のない `.pkg` は拒否されることも確認 |
| `xcode-select --install` で確認画面が出る | ⚠️ 未確認（開発者の Mac には導入済み） |
| Homebrew インストーラーでのインストール完了 | ⚠️ 未確認（開発者の Mac には導入済み） |
| `gh auth status --json` でのアカウント一覧 | ✅ 確認済み |
| 実アカウント間の `gh auth switch` と、切り替え後の権限の再確認 | ✅ 確認済み（承認を得て tacoskiy → erj-haru → tacoskiy） |
| `gh auth login --web --clipboard` の非対話での開始 | ✅ 確認済み（隔離した設定）。gh は非対話ではブラウザを開かないため、スクリプトが `open` で公式ページを開く |
| ブラウザでの許可まで行ったログイン完了 | ⚠️ 未確認 |

### 方法 A：設定画面からアップロード（推奨）

1. Claude Desktop を開き、**Customize → Skills →「+」→「+ Create skill」→「Upload a skill」** で `setup-workspace.zip` を選ぶ
   （以前の版がある場合は、古い Skill を削除または置き換えてからアップロードする）
2. Skill の一覧で `setup-workspace` が有効になっていることを確認する
3. 「Code」タブで新しいセッションを開き、`/setup-workspace` と入力する（候補に `anthropic-skills:setup-workspace` と表示される場合はそれを選ぶ）

### 方法 B：個人用 Skill として配置（方法 A で使えない場合）

Claude Code の公式の読み込み場所 `~/.claude/skills/` に置く方法です。ターミナルで次を実行します（ZIP がダウンロードフォルダにある場合）。

```bash
mkdir -p ~/.claude/skills && unzip -n ~/Downloads/setup-workspace.zip -d ~/.claude/skills/
```

`-n` は既存ファイルを上書きしない指定です。古い版を置き換える場合は、先に `~/.claude/skills/setup-workspace` フォルダを Finder でゴミ箱に移してから実行してください。
その後、「Code」タブで新しいセッションを開き `/setup-workspace` と入力します。

### 新しい ZIP での実機検証の手順

1. `bash scripts/package-skill.sh` で ZIP を作り直し、方法 A で **古い Skill を置き換えて** アップロードする
2. Code タブで新しいセッションを開き、Skill 一覧の説明文が新しい版（「Mac の環境（CPU・Apple の開発者ツール…）を自動で調べ」で始まる）になっていることを確認する
3. `/setup-workspace` を実行し、最初の確認（`check`）でソフトの一覧・CPU・管理者の有無が表示されることを確認する
4. **ソフトが入っていない Mac（検証用の別ユーザーや別の Mac）** で次を確認する
   1. 不足ソフトがまとめて提示され、ソフトごとに承認を求められること
   2. 開発者ツール: 確認画面が表示され、完了後に自動で次へ進むこと
   3. Homebrew: 署名確認の後にインストーラーが開き、パスワード（Touch ID）の入力後に完了が検出されること
   4. gh: 画面操作なしで追加されること
   5. 途中でインストーラーを閉じた後、もう一度 `/setup-workspace` で続きから再開できること
5. GitHub の新規ログインをブラウザでの許可まで行い、`RESULT=READY` まで進むこと
6. Clone 後、そのフォルダを Code タブで開いて CMS の `/setup-editor` が動くこと（`gh` が見つかるか）
7. 確認できた内容に合わせて、この README の「未検証」を更新する

---

## 5. `/setup-workspace` の処理内容

| 段階 | 内容 | Claude が勝手に行わないこと |
|---|---|---|
| 1. 環境チェック | macOS・CPU（Apple シリコン / Intel / Rosetta）・Apple の開発者ツール・Git・Homebrew（実際の場所）・gh・管理者か・管理端末か・ログイン状態・アカウント・リポジトリへのアクセス・既存の Clone。PATH に登録されていないだけのツールも標準の場所から見つける | 何も変更しない |
| 2. 不足ソフトの提示 | 足りないものと追加の順番（開発者ツール → Homebrew → gh）をまとめて説明 | — |
| 3. 承認・追加 | ソフトごとに個別に承認を得て、Claude が実行。開発者ツールは `xcode-select --install`（確認画面は本人が操作）、Homebrew は公式 `.pkg` を取得・署名確認して macOS のインストーラーで開く（管理者の確認は本人）、gh は `brew install gh`。完了を実際に確認してから次へ | `sudo` の使用、パスワードの受け渡し、管理制限の回避、ネット上のスクリプトの実行、インストール済みソフトの入れ直し |
| 3'. PATH | Homebrew が今後のターミナルでも使えるか確認し、必要な場合だけ承認を得てシェルの設定に 1 回だけ追記 | 承認なしの設定変更、重複した追記 |
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
| `/setup-workspace` が候補に出てこない | Skill が有効か確認（`anthropic-skills:setup-workspace` と表示される場合あり）。方法 A で出ない場合は方法 B を試す。Claude Desktop を再起動して新しいセッションを開く |
| 開発者ツールの確認画面が出ない／「入手できない」と表示される | 画面の後ろに隠れていないか確認。「入手できない」は管理ポリシーの可能性があるため、管理者に相談 |
| Homebrew の追加が「管理者でない」で止まる | Mac の管理者の協力が必要。管理者に相談 |
| Homebrew のインストーラーを閉じてしまった | もう一度 `/setup-workspace` を実行（続きから再開。署名確認からやり直す） |
| Intel Mac で Homebrew を入れられない | 公式 `.pkg` が Apple シリコン専用のため。案内に沿ってターミナルで公式の手順を実行（この部分だけ手動） |
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
bash skills/setup-workspace/scripts/setup.sh install-clt        # 開発者ツール（承認後のみ）
bash skills/setup-workspace/scripts/setup.sh install-brew       # Homebrew 公式 .pkg（承認後のみ）
bash skills/setup-workspace/scripts/setup.sh install-gh         # brew install gh（承認後のみ）
bash skills/setup-workspace/scripts/setup.sh wait clt|brew      # 完了待ち（再開用）
bash skills/setup-workspace/scripts/setup.sh path-status        # PATH 設定の確認（変更なし）
bash skills/setup-workspace/scripts/setup.sh persist-path       # シェル設定への追記（承認後のみ）
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
- macOS 標準の `/bin/bash`（3.2）で動作。Node.js は不要。外部コマンドはすべて macOS 標準（`uname` `sysctl` `xcode-select` `id` `profiles` `tr` `sed` `cat` `tail` `sleep` `mkdir` `rmdir` `mktemp` `chmod` `rm`、ログイン・インストール時の `open` `pbcopy` `pbpaste` `mkfifo` `curl` `pkgutil` `spctl`）と、検出した `git` `gh` `brew`。
- **環境の検出**: CPU は `sysctl hw.optional.arm64` と `uname -m` で判定（Rosetta も判別）。Homebrew は PATH に加えて `/opt/homebrew/bin/brew`・`/usr/local/bin/brew` を探し、見つかればこのプロセスの PATH に `bin`・`sbin` を加えます（`brew shellenv` が PATH に加えるものと同じ。`eval` はしません）。Git は開発者ツールの有無を `xcode-select -p` で先に確かめ、未導入時に `/usr/bin/git` を実行して確認画面を勝手に出さないようにしています。
- **開発者ツール**: `xcode-select --install`（macOS 標準）で確認画面を出し、`xcode-select -p` と Git が使えるようになるまで待ちます（最大 540 秒、`SETUP_WORKSPACE_INSTALL_TIMEOUT`）。時間切れは `INSTALL_WAITING` で、`wait clt` で再開できます。
- **Homebrew**: GitHub の公式リリース情報から `https://github.com/Homebrew/brew/releases/download/…/Homebrew*.pkg` だけを受け付けて HTTPS で取得し、`pkgutil --check-signature`（Developer ID Installer・Team ID `927JGANW46`・Apple の公証）と `spctl --assess --type install`（Gatekeeper）の両方を満たした場合だけ `open` で macOS のインストーラーを開きます。管理者の確認はインストーラーが出す macOS の正式な画面で本人が行い、**`sudo` は使いません**。公式 `.pkg` は Apple シリコン専用のため、Intel Mac では `BREW_AUTO_UNSUPPORTED` として手動手順を案内します。公式 `.pkg` は `/etc/paths.d/homebrew` を作るため、通常はシェル設定の追記が不要です。
- **gh**: `brew install gh` を実行し、`gh --version` で確認します。失敗時はネットワーク・処理中（ロック）・権限を判別して案内します。
- **PATH の永続化**: `/etc/paths`・`/etc/paths.d/*`・シェルの設定ファイルに Homebrew の `bin` か `brew shellenv` が既にあれば何もしません。ない場合だけ、承認後に `~/.zprofile`（bash は `~/.bash_profile`）の末尾へ目印付きで 1 回だけ追記します。
- `login` の仕組み: `gh auth login --hostname github.com --git-protocol https --web --clipboard` を標準入力なしで起動し、出力は名前付きパイプで受け取ってファイルに残しません。gh が確認用コードをクリップボードにコピーしたことを確認してから、固定の URL（`https://github.com/login/device`）を `open` で開きます。コードをクリップボードに渡せない場合は、画面に出さないために中止します（`LOGIN_UNSUPPORTED`）。許可を待つのは最大 540 秒（`SETUP_WORKSPACE_LOGIN_TIMEOUT`）で、時間切れや中断のときは gh の処理を止めます。終了時、クリップボードにコードが残っていれば消去します。
- `switch` は、ログイン済みで状態が正常なアカウントにだけ切り替えます。既に使用中なら何もしません（`ACTION=unchanged`）。アカウント名は GitHub の名前の規則で検証します。
- `switch` / `login` の後は、`check` と同じ処理で、使用中のアカウントとリポジトリへのアクセスを再確認します（`RESULT=READY` で完了）。
- 外部コマンドは PATH から探すため、PATH の先頭にモックを置けば差し替えられます。`/opt/homebrew`・`/Library/Developer`・`/etc/paths.d` などのシステムの場所は `SETUP_WORKSPACE_ROOT`（通常は空）を基準に参照するため、テストでは一時フォルダに置き換えられます。

### テスト

```bash
bash scripts/test-setup.sh
```

- 一時ディレクトリに偽のホームフォルダと偽のシステムの場所（`SETUP_WORKSPACE_ROOT`）を作り、PATH をモックと最低限のシステムコマンドだけにして実行します。実際の GitHub アカウント・ログイン状態・既存リポジトリ・Homebrew・開発者ツールには一切触れません（`~/.gitconfig` も読み書きしません）。
- **インストーラーや認証コマンドが意図せず実行されないことの保証**: `curl` `xcode-select` `pkgutil` `spctl` `open` `brew` `gh` `sudo` `softwareupdate` `installer` はすべてモックで、本物は PATH に入りません（テスト「20」で、テスト環境から本物が見えないことを確認しています）。さらに `setup.sh` に `sudo`・`softwareupdate`・`installer -pkg` の実行が含まれていないことも検査します。
- 本番と同じ `setup.sh` をそのまま実行します（テスト専用の分岐はありません）。
- モックは呼び出しを記録し、`push` / `pull` / `fetch` / `reset` / `gh auth logout|token|refresh|setup-git` / `brew uninstall|upgrade|update` / `sudo` などが呼ばれていないこと、確認だけの処理でインストール（`brew install`・`xcode-select --install`・`curl`・`.pkg` を開く）や `gh auth switch` / `gh auth login` が呼ばれていないことも確認します。
- gh のモックは、ログイン済みアカウントをテスト用の一時ファイルで管理します。`open` / `pbcopy` / `pbpaste` もモックにするため、本物のブラウザ・クリップボード・GitHub の認証情報には触れません。
- すべてのテストで、トークンや確認用コードが出力に含まれていないことを自動で確認します。
- `package.test.sh` は ZIP を一時ディレクトリに作って展開し、ファイル一覧・SKILL.md の書式を確認したうえで、**展開した `setup.sh`（実行権限を外した状態）で全テストをもう一度実行** します。
- `shellcheck` が入っていれば自動で実行します。

主なテストケース: Git・gh 導入済み／Git 未導入／gh 未導入（Homebrew あり・なし）／未ログイン／接続不可／アカウント表示／権限なし／正常な Clone（空白・日本語のパス、空フォルダ含む）／既存の正しい Clone の再利用（SSH 形式の接続先含む）／別リポジトリ・接続先なし・必須ファイル欠落／通常フォルダ・ファイル・隠しファイルのみ／Clone 失敗（接続・権限）と空の親フォルダの片付け／再実行（未保存の変更の保持）／不正な保存先（空・相対・ホーム外・`..`・隠しフォルダ・`Library`・`~user`・ホーム外を指すエイリアス・改行・途中がファイル）／使い方の誤り／Clone 後の検証失敗（必須ファイル欠落・接続先違い）／macOS 以外。
GitHub 認証: アカウント一覧／使用中アカウントに権限がない／別アカウントへの切り替えと再確認後の Clone 再開／使用中なら切り替えない／大文字小文字／未ログインのアカウント／不正なアカウント名／切り替え失敗／有効期限切れのアカウント／切り替え後も権限なし／新規ログインと再確認後の Clone 再開／既存アカウントを残したままの追加／許可のキャンセル／コードの期限切れ／時間切れ（gh の停止）／コードをクリップボードに渡せない／古い gh（`--clipboard`・`--json` 非対応）／ブラウザを開けない／ネットワークエラー／想定外の失敗（秘密情報を伏せる）／ログイン後も権限なし／gh なし・macOS 以外。
ソフトの検出と追加: すべて未導入／Git だけ／Git と開発者ツール／Homebrew だけ／gh だけ不足（追加と再実行で入れ直さない）／PATH 未登録の Homebrew・gh・Git／Intel Mac の Homebrew／Rosetta／管理端末・管理者でない／開発者ツールの追加・完了待ちの時間切れと再開・管理ポリシーで禁止・「導入済み」なのに Git なし／Homebrew の追加・導入済み・管理者権限なし・開発者ツールなし・Intel Mac・情報取得の失敗・公式以外の URL・ダウンロード失敗・空ファイル・署名なし・別の署名者・公証なし・Gatekeeper の拒否・インストール途中の中断と再実行での復旧・`wait` での再開／gh の追加失敗（ネットワーク・処理中・権限）と中断からの復旧・Homebrew なし／PATH の追記（既存設定の保持・重複なし・既に設定済み・bash・未対応のシェル）／何もない Mac から Clone まで（途中の中断から再開）／インストールを断った場合／使い方の誤り／macOS 以外。

### ZIP 生成

```bash
bash scripts/package-skill.sh                 # dist/setup-workspace.zip
bash scripts/package-skill.sh /path/to/x.zip  # 出力先を指定
```
