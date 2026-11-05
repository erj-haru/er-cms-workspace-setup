#!/bin/bash
# =============================================================================
# setup.sh のテスト
#
# - 一時ディレクトリに「偽のホームフォルダ」を作り、その中だけで動かす
# - git / gh / brew / uname / sysctl / xcode-select / id / profiles / curl / pkgutil / spctl /
#   open / pbcopy / pbpaste / sudo / softwareupdate / installer はモック（tests/mocks）に差し替える
#   （git の clone 以外は本物の git に渡すが、GitHub には一切接続しない）
# - /opt/homebrew・/Library/Developer・/etc/paths.d などシステムの場所は、
#   SETUP_WORKSPACE_ROOT で一時フォルダ（$T/root）に置き換える
# - インストーラー・認証コマンドの本物は PATH に入れないため、テスト中に実行されることはない
# - PATH はモックと最低限のシステムコマンドだけにするため、
#   開発者の Mac に入っている本物の gh やログイン状態は使われない
#
# 使い方: bash tests/setup.test.sh [テスト対象の setup.sh]
#   引数を省略すると skills/setup-workspace/scripts/setup.sh をテストする。
# =============================================================================

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
SCRIPT="${1:-${ROOT}/skills/setup-workspace/scripts/setup.sh}"
MOCKS="${ROOT}/tests/mocks"
BASH_BIN=/bin/bash

REAL_GIT=$(command -v git) || { echo "テストには開発者の Mac に git が必要です" >&2; exit 2; }
ORIG_PATH="$PATH"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/setup-workspace-test.XXXXXX")
cleanup() { /bin/rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

PASS=0
FAIL=0
CURRENT=""

# setup.sh が使うシステムコマンド（これ以外は PATH に入れない）
SYSTEM_TOOLS="tr sed mkdir rmdir ls mktemp mkfifo rm chmod cat tail sleep"
# テストの判定で使うコマンド
TEST_TOOLS="grep"
# モックが使うコマンド
MOCK_TOOLS="awk mv ln touch"
# 常にモックにするコマンド（本物のインストーラー・ブラウザ・クリップボード・管理者権限は使わない）
ALWAYS_MOCKS="uname sysctl xcode-select id profiles curl pkgutil spctl open pbcopy pbpaste sudo softwareupdate installer"
# モックの確認用コード（画面に出てはいけない）
MOCK_CODE="WXYZ-9876"

# ----------------------------------------------------------------------------
# テスト環境
# ----------------------------------------------------------------------------
# new_env <モックの種類...>   例: new_env git gh brew uname
# （open / pbcopy / pbpaste は常にモックにする。本物のブラウザやクリップボードは使わない）
new_env() {
  T=$(mktemp -d "${TMP_ROOT}/case.XXXXXX")
  T=$(cd -P "$T" && pwd -P)
  mkdir -p "$T/home" "$T/bin" "$T/sys" "$T/outside" "$T/root" "$T/state"
  SYSROOT="$T/root"
  HOME_DIR="$T/home"
  LOG="$T/calls.log"
  : > "$LOG"
  local tool
  for tool in $SYSTEM_TOOLS $MOCK_TOOLS; do
    ln -s "$(command -v "$tool")" "$T/sys/$tool"
  done
  for tool in "$@" $ALWAYS_MOCKS; do
    ln -sf "$MOCKS/$tool" "$T/bin/$tool"
  done
  GH_STATE="$T/gh-state"
  CLIPBOARD="$T/clipboard"
  GH_PIDFILE="$T/gh-login.pid"
  # Git の個人設定（~/.gitconfig）を読まない・書かない
  : > "$T/gitconfig"
  MOCK_ENV=()
}

# run_setup <サブコマンド> [引数]   → OUT / RC にセット
run_setup() {
  OUT=$(env -i \
    HOME="$HOME_DIR" \
    PATH="$T/bin:$T/sys" \
    LANG=ja_JP.UTF-8 \
    TMPDIR="$T" \
    SHELL=/bin/zsh \
    SETUP_WORKSPACE_ROOT="$SYSROOT" \
    SETUP_WORKSPACE_POLL_INTERVAL=1 \
    SETUP_WORKSPACE_INSTALL_TIMEOUT=8 \
    MOCK_ROOT="$SYSROOT" \
    MOCK_DIR="$MOCKS" \
    MOCK_STATE_DIR="$T/state" \
    GIT_CONFIG_GLOBAL="$T/gitconfig" \
    GIT_CONFIG_NOSYSTEM=1 \
    MOCK_LOG="$LOG" \
    MOCK_REAL_GIT="$REAL_GIT" \
    MOCK_ORIG_PATH="$ORIG_PATH" \
    MOCK_GH_STATE="$GH_STATE" \
    MOCK_CLIPBOARD="$CLIPBOARD" \
    MOCK_GH_PIDFILE="$GH_PIDFILE" \
    ${MOCK_ENV[@]+"${MOCK_ENV[@]}"} \
    "$BASH_BIN" "$SCRIPT" "$@" 2>&1)
  RC=$?
  # どのテストでも、秘密情報（トークン・ワンタイムコード）が画面に出てはいけない
  case "$OUT" in
    *MOCKSECRET* | *LEAKEDTOKEN* | *"$MOCK_CODE"*) fail "秘密情報が出力に含まれている" ;;
  esac
}

# モックの gh にログイン済みアカウントを設定する: set_accounts "alice success yes" "bob success no"
set_accounts() {
  : > "$GH_STATE"
  local line
  for line in "$@"; do echo "$line" >> "$GH_STATE"; done
}
active_account() { awk '$3=="yes"{print $1}' "$GH_STATE"; }
has_account() { awk -v u="$1" '$1==u{f=1} END{exit !f}' "$GH_STATE"; }

# 本物の git で、テスト用のリポジトリを作る
make_repo() {
  local dir="$1" remote="$2"
  PATH="$ORIG_PATH" GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1 "$REAL_GIT" init -q "$dir"
  if [ -n "$remote" ]; then
    PATH="$ORIG_PATH" GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1 "$REAL_GIT" -C "$dir" remote add origin "$remote"
  fi
}

# ----------------------------------------------------------------------------
# 判定
# ----------------------------------------------------------------------------
fail() {
  FAIL=$((FAIL + 1))
  echo "  ✗ [${CURRENT}] $*"
  echo "    --- 出力 (RC=${RC-}) ---"
  printf '%s\n' "${OUT-}" | sed 's/^/    | /'
}
ok() { PASS=$((PASS + 1)); }

assert_rc() { if [ "$RC" -eq "$1" ]; then ok; else fail "終了コード: 期待 $1 / 実際 $RC"; fi; }
assert_out() {
  case "$OUT" in
    *"$1"*) ok ;;
    *) fail "出力に「$1」が含まれていない" ;;
  esac
}
assert_not_out() {
  case "$OUT" in
    *"$1"*) fail "出力に「$1」が含まれている" ;;
    *) ok ;;
  esac
}
assert_exists() { if [ -e "$1" ]; then ok; else fail "存在しない: $1"; fi; }
assert_absent() { if [ ! -e "$1" ] && [ ! -L "$1" ]; then ok; else fail "存在してはいけない: $1"; fi; }
assert_log() {
  if grep -qF -- "$1" "$LOG"; then ok; else fail "呼び出し記録に「$1」がない"; fi
}
assert_not_log() {
  if grep -qE -- "$1" "$LOG"; then fail "禁止された呼び出し「$1」がある: $(grep -E -- "$1" "$LOG" | head -n1)"; else ok; fi
}
assert_count_log() {
  local n
  n=$(grep -cE -- "$1" "$LOG")
  if [ "$n" -eq "$2" ]; then ok; else fail "「$1」の呼び出し回数: 期待 $2 / 実際 $n"; fi
}
# 危険な操作を一切していないこと
assert_safe_calls() {
  assert_not_log '^git .*(push|pull|fetch|reset|checkout|clean|stash|commit|config --(global|add|unset)|remote (set-url|remove|add))'
  assert_not_log '^gh (auth (logout|token|refresh|setup-git)|pr |repo (clone|create|delete|fork))'
  assert_not_log 'show-token'
  assert_not_log '^brew (uninstall|reinstall|upgrade|update|tap|untap|link|unlink|cleanup|autoremove)'
  assert_not_log '^(sudo|softwareupdate|installer) '
}
# ソフトのインストールを一切始めていないこと（確認だけの処理で使う）
assert_no_install() {
  assert_not_log '^brew install'
  assert_not_log '^xcode-select --install'
  assert_not_log '^curl '
  assert_not_log '^open .*\.pkg'
  assert_not_log '^(sudo|softwareupdate|installer) '
}
# システムの場所（$T/root）に、Homebrew や開発者ツールを置く
install_fake_clt() {
  mkdir -p "$SYSROOT/Library/Developer/CommandLineTools/usr/bin"
  ln -sf "$MOCKS/git" "$SYSROOT/Library/Developer/CommandLineTools/usr/bin/git"
}
install_fake_brew() {
  local prefix="$SYSROOT/${1:-opt/homebrew}"
  mkdir -p "$prefix/bin" "$prefix/sbin"
  ln -sf "$MOCKS/brew" "$prefix/bin/brew"
}
install_fake_gh_in_brew() {
  ln -sf "$MOCKS/gh" "$SYSROOT/${1:-opt/homebrew}/bin/gh"
}
# アカウントの切り替え・ログインをしていないこと（確認だけの処理で使う）
assert_no_auth_change() {
  assert_not_log '^gh auth switch'
  assert_not_log '^gh auth login .*--web'
}

begin() { CURRENT="$1"; echo "▶ $1"; }

# ============================================================================
# テストケース
# ============================================================================

# ---- 1. Git と gh が導入済み -------------------------------------------------
begin "01 Git と gh が導入済み（準備完了）"
new_env git gh brew uname
run_setup check
assert_rc 0
assert_out "RESULT=READY"
assert_out "✅ Git"
assert_out "✅ GitHub CLI"
assert_out "BREW=yes"
assert_not_out "MOCKSECRET"
assert_safe_calls
assert_no_auth_change

# ---- 2. Git が未導入 --------------------------------------------------------
begin "02 Git が未導入"
new_env gh brew uname
run_setup check
assert_rc 1
assert_out "RESULT=NEED_INSTALL"
assert_out "MISSING=git"
assert_out "BREW=yes"
assert_out "❌ Git"
# Git がないと Clone 系の処理も止まる
run_setup clone "~/EstRouge"
assert_rc 1
assert_out "RESULT=NEED_INSTALL"
assert_absent "$HOME_DIR/EstRouge"

# ---- 3. gh が未導入 ---------------------------------------------------------
begin "03 gh が未導入（Homebrew あり）"
new_env git brew uname
run_setup check
assert_rc 1
assert_out "MISSING=gh"
assert_out "BREW=yes"
assert_safe_calls

begin "03b gh と Git が未導入（Homebrew もなし）"
new_env uname
run_setup check
assert_rc 1
assert_out "MISSING=git,gh"
assert_out "BREW=no"
assert_out "❌ Homebrew（Mac 用のソフト追加ツール）: 見つかりません"

begin "03c gh が未導入のときは Clone しない"
new_env git uname
run_setup clone "~/EstRouge"
assert_rc 1
assert_out "MISSING=gh"
assert_absent "$HOME_DIR/EstRouge"
assert_count_log '^git .*clone' 0

# ---- 4. GitHub 未認証 -------------------------------------------------------
begin "04 GitHub 未認証"
new_env git gh brew uname
MOCK_ENV=(MOCK_GH_AUTH=none)
run_setup check
assert_rc 1
assert_out "RESULT=NEED_LOGIN"
assert_not_out "MOCKSECRET"
assert_not_out "ACCOUNT="
assert_safe_calls
assert_no_auth_change

begin "04b GitHub に接続できない"
new_env git gh brew uname
MOCK_ENV=(MOCK_GH_AUTH=offline)
run_setup check
assert_rc 2
assert_out "RESULT=NETWORK_ERROR"
assert_safe_calls

# ---- 5. 認証済みアカウントの確認 -------------------------------------------
begin "05 ログイン中のアカウントを表示する"
new_env git gh brew uname
MOCK_ENV=(MOCK_GH_USER=hanako-editor)
run_setup check
assert_rc 0
assert_out "ACCOUNT=hanako-editor"
assert_out "アカウント: hanako-editor"
assert_not_out "MOCKSECRET"
assert_no_auth_change

begin "05b アカウントにリポジトリの権限がない"
new_env git gh brew uname
MOCK_ENV=(MOCK_GH_USER=other-person MOCK_GH_REPO_ACCESS=someone-else)
run_setup check
assert_rc 1
assert_out "RESULT=NO_REPO_ACCESS"
assert_out "ACCOUNT=other-person"
assert_safe_calls

# ---- 6. 正常な Clone --------------------------------------------------------
begin "06 正常な Clone"
new_env git gh brew uname
run_setup suggest
assert_rc 0
assert_out "SUGGESTED_DEST=$HOME_DIR/EstRouge/est-rouge-cms-demo"
run_setup plan "~/EstRouge"
assert_rc 0
assert_out "STATE=absent"
assert_absent "$HOME_DIR/EstRouge"   # plan は何も作らない
run_setup clone "~/EstRouge"
assert_rc 0
assert_out "RESULT=CLONED"
assert_out "DEST=$HOME_DIR/EstRouge/est-rouge-cms-demo"
assert_out "接続先: https://github.com/erj-haru/est-rouge-cms-demo.git"
assert_exists "$HOME_DIR/EstRouge/est-rouge-cms-demo/.claude/skills/setup-editor/SKILL.md"
assert_log "clone --quiet -- https://github.com/erj-haru/est-rouge-cms-demo.git $HOME_DIR/EstRouge/est-rouge-cms-demo"
assert_safe_calls

begin "06b 保存先にフルパス・空白・日本語を含む場所"
new_env git gh brew uname
run_setup clone "$HOME_DIR/書類 置き場/est-rouge-cms-demo/"
assert_rc 0
assert_out "RESULT=CLONED"
assert_exists "$HOME_DIR/書類 置き場/est-rouge-cms-demo/package.json"

begin "06c 空のフォルダには Clone できる"
new_env git gh brew uname
mkdir -p "$HOME_DIR/EstRouge/est-rouge-cms-demo"
run_setup clone "~/EstRouge/est-rouge-cms-demo"
assert_rc 0
assert_out "STATE=empty"
assert_out "RESULT=CLONED"

# ---- 7. 既存の正しい Clone の再利用 ----------------------------------------
begin "07 既存の正しい Clone を再利用"
new_env git gh brew uname
run_setup clone "~/EstRouge"
assert_rc 0
run_setup clone "~/EstRouge"
assert_rc 0
assert_out "STATE=reuse"
assert_out "RESULT=REUSED"
assert_count_log '^git .*clone' 1
assert_safe_calls

begin "07b SSH 形式の接続先でも正しい Clone として再利用"
new_env git gh brew uname
mkdir -p "$HOME_DIR/EstRouge"
D="$HOME_DIR/EstRouge/est-rouge-cms-demo"
make_repo "$D" "git@github.com:erj-haru/est-rouge-cms-demo.git"
mkdir -p "$D/.claude/skills/setup-editor" "$D/.claude/skills/cms-help"
touch "$D/package.json" "$D/astro.config.mjs" "$D/compose.yaml" "$D/.claude/skills/setup-editor/SKILL.md" "$D/.claude/skills/cms-help/SKILL.md"
run_setup clone "~/EstRouge"
assert_rc 0
assert_out "RESULT=REUSED"
assert_count_log '^git .*clone' 0

# ---- 8. 保存先に別のリポジトリが存在 ---------------------------------------
begin "08 保存先に別のリポジトリがある"
new_env git gh brew uname
D="$HOME_DIR/EstRouge/est-rouge-cms-demo"
mkdir -p "$HOME_DIR/EstRouge"
make_repo "$D" "https://github.com/someone/another-repo.git"
echo "大切なメモ" > "$D/memo.txt"
run_setup clone "~/EstRouge"
assert_rc 3
assert_out "STATE=other-repo"
assert_out "RESULT=DEST_CONFLICT"
assert_out "another-repo"
assert_exists "$D/memo.txt"
assert_count_log '^git .*clone' 0
assert_safe_calls

begin "08b 保存先が接続先のない Git リポジトリ"
new_env git gh brew uname
D="$HOME_DIR/EstRouge/est-rouge-cms-demo"
mkdir -p "$HOME_DIR/EstRouge"
make_repo "$D" ""
touch "$D/a.txt"
run_setup clone "~/EstRouge"
assert_rc 3
assert_out "STATE=other-repo"

begin "08c 正しい接続先だが CMS のファイルがない"
new_env git gh brew uname
D="$HOME_DIR/EstRouge/est-rouge-cms-demo"
mkdir -p "$HOME_DIR/EstRouge"
make_repo "$D" "https://github.com/erj-haru/est-rouge-cms-demo.git"
touch "$D/README.md"
run_setup clone "~/EstRouge"
assert_rc 3
assert_out "STATE=incomplete-repo"
assert_exists "$D/README.md"

# ---- 9. 保存先に通常のフォルダが存在 ---------------------------------------
begin "09 保存先に通常のフォルダがある"
new_env git gh brew uname
D="$HOME_DIR/EstRouge/est-rouge-cms-demo"
mkdir -p "$D/写真"
echo "data" > "$D/写真/a.jpg"
run_setup clone "~/EstRouge"
assert_rc 3
assert_out "STATE=plain-dir"
assert_out "別の保存先を指定してください"
assert_exists "$D/写真/a.jpg"
assert_count_log '^git .*clone' 0

begin "09b 保存先にファイルがある"
new_env git gh brew uname
mkdir -p "$HOME_DIR/EstRouge"
echo "file" > "$HOME_DIR/EstRouge/est-rouge-cms-demo"
run_setup clone "~/EstRouge"
assert_rc 3
assert_out "STATE=not-directory"
assert_count_log '^git .*clone' 0

begin "09c 保存先が隠しファイルだけを含むフォルダ"
new_env git gh brew uname
D="$HOME_DIR/EstRouge/est-rouge-cms-demo"
mkdir -p "$D"
touch "$D/.DS_Store"
run_setup clone "~/EstRouge"
assert_rc 3
assert_out "STATE=plain-dir"

# ---- 10. Clone 失敗 ---------------------------------------------------------
begin "10 Clone 失敗（ネットワーク）"
new_env git gh brew uname
MOCK_ENV=(MOCK_GIT_CLONE=fail-network)
run_setup clone "~/EstRouge/新しいフォルダ"
assert_rc 2
assert_out "RESULT=CLONE_FAILED"
assert_out "インターネットに接続できませんでした"
assert_out "Could not resolve host"
assert_not_out "RESULT=CLONED"
assert_absent "$HOME_DIR/EstRouge"     # 今回作った空のフォルダは片付ける

begin "10b Clone 失敗（権限なし）"
new_env git gh brew uname
mkdir -p "$HOME_DIR/Work"
touch "$HOME_DIR/Work/keep.txt"
MOCK_ENV=(MOCK_GIT_CLONE=fail-notfound)
run_setup clone "~/Work"
assert_rc 2
assert_out "RESULT=CLONE_FAILED"
assert_out "権限がないようです"
assert_exists "$HOME_DIR/Work/keep.txt"   # 元からあったフォルダは残す
assert_absent "$HOME_DIR/Work/est-rouge-cms-demo"

# ---- 11. 同じ処理の再実行 ---------------------------------------------------
begin "11 再実行しても既存の変更を壊さない"
new_env git gh brew uname
run_setup check
assert_rc 0
run_setup clone "~/EstRouge"
assert_rc 0
D="$HOME_DIR/EstRouge/est-rouge-cms-demo"
echo "編集中の内容" >> "$D/package.json"
echo "下書き" > "$D/draft.md"
for i in 1 2 3; do
  run_setup clone "~/EstRouge"
  assert_rc 0
  assert_out "RESULT=REUSED"
done
assert_out "LOCAL_CHANGES=2"
assert_out "変更が 2 件あります"
assert_exists "$D/draft.md"
if grep -q "編集中の内容" "$D/package.json"; then ok; else fail "未コミットの変更が失われた"; fi
run_setup verify "~/EstRouge"
assert_rc 0
assert_out "RESULT=VERIFIED"
assert_count_log '^git .*clone' 1
assert_safe_calls

# ---- 12. 不正な保存先指定 ---------------------------------------------------
begin "12 不正な保存先指定"
new_env git gh brew uname
ln -s "$T/outside" "$HOME_DIR/link-outside"
for bad in \
  "" \
  "EstRouge" \
  "./EstRouge" \
  "/tmp/EstRouge" \
  "$T/outside" \
  "~/EstRouge/../../outside" \
  "~/.hidden/place" \
  "~/Library/EstRouge" \
  "~root/EstRouge" \
  "~/link-outside" \
  "~/link-outside/sub" \
  "$(printf '~/Est\nRouge')"; do
  run_setup clone "$bad"
  if [ "$RC" -ne 3 ]; then fail "「${bad}」が拒否されなかった"; else ok; fi
  assert_out "RESULT=INVALID_DEST"
done
assert_count_log '^git .*clone' 0
assert_absent "$T/outside/est-rouge-cms-demo"
assert_absent "$T/outside/sub"
assert_absent "$HOME_DIR/EstRouge"

begin "12b 途中にファイルがある保存先"
new_env git gh brew uname
echo x > "$HOME_DIR/notdir"
run_setup clone "~/notdir/sub"
assert_rc 3
assert_out "RESULT=INVALID_DEST"

begin "12c 使い方の誤り"
new_env git gh brew uname
run_setup clone
assert_rc 64
run_setup unknown
assert_rc 64
run_setup check extra
assert_rc 64

# ---- 13. Clone 後の検証失敗 ------------------------------------------------
begin "13 Clone 後の検証失敗（必要なファイルがない）"
new_env git gh brew uname
MOCK_ENV=(MOCK_GIT_CLONE=missing-files)
run_setup clone "~/EstRouge"
assert_rc 2
assert_out "RESULT=VERIFY_FAILED"
assert_out "必要なファイルが見つかりません"
assert_not_out "RESULT=CLONED"
assert_exists "$HOME_DIR/EstRouge/est-rouge-cms-demo"   # 削除はしない

begin "13b Clone 後の検証失敗（接続先が違う）"
new_env git gh brew uname
MOCK_ENV=(MOCK_GIT_CLONE=wrong-remote)
run_setup clone "~/EstRouge"
assert_rc 2
assert_out "RESULT=VERIFY_FAILED"
assert_out "接続先が CMS のリポジトリではありません"

begin "13c verify で Clone されていないフォルダを確認"
new_env git gh brew uname
run_setup verify "~/EstRouge"
assert_rc 2
assert_out "RESULT=VERIFY_FAILED"

# ---- 14. macOS 以外 ---------------------------------------------------------
begin "14 macOS 以外では止まる"
new_env git gh brew uname
MOCK_ENV=(MOCK_UNAME=Linux)
run_setup check
assert_rc 1
assert_out "RESULT=UNSUPPORTED_OS"
run_setup clone "~/EstRouge"
assert_rc 1
assert_absent "$HOME_DIR/EstRouge"

# ============================================================================
# GitHub アカウントの確認・切り替え・ログイン
# （モックの gh の状態ファイルだけを変更する。実際の認証情報には触れない）
# ============================================================================

# ---- 15. アカウント一覧 ------------------------------------------------------
begin "15 ログイン済みアカウントの一覧（変更なし）"
new_env git gh brew uname
set_accounts "alice success yes" "bob success no" "carol error no"
run_setup accounts
assert_rc 0
assert_out "alice（使用中）"
assert_out "- bob"
assert_out "carol ※ログインのやり直しが必要"
assert_out "ACTIVE_ACCOUNT=alice"
assert_out "KNOWN_ACCOUNTS=alice,bob"
assert_no_auth_change
assert_safe_calls

begin "15b 使用中のアカウントに権限がなく、別のアカウントがある"
new_env git gh brew uname
set_accounts "alice success yes" "bob success no"
MOCK_ENV=(MOCK_GH_REPO_ACCESS=bob)
run_setup check
assert_rc 1
assert_out "RESULT=NO_REPO_ACCESS"
assert_out "ACCOUNT=alice"
assert_out "KNOWN_ACCOUNTS=alice,bob"
assert_no_auth_change
if [ "$(active_account)" = alice ]; then ok; else fail "check で使用中のアカウントが変わった"; fi

# ---- 16. アカウント切り替え --------------------------------------------------
begin "16 別の認証済みアカウントへ切り替え → 再確認で準備完了"
new_env git gh brew uname
set_accounts "alice success yes" "bob success no"
MOCK_ENV=(MOCK_GH_REPO_ACCESS=bob)
run_setup switch bob
assert_rc 0
assert_out "ACTION=switched"
assert_out "ACCOUNT=bob"
assert_out "RESULT=READY"
assert_log "gh auth switch --hostname github.com --user bob"
assert_log "gh repo view erj-haru/est-rouge-cms-demo"
if [ "$(active_account)" = bob ]; then ok; else fail "bob が使用中になっていない"; fi
if has_account alice; then ok; else fail "alice のログインが消えた"; fi
assert_safe_calls
# 切り替え後に Clone を再開できる
run_setup clone "~/EstRouge"
assert_rc 0
assert_out "RESULT=CLONED"

begin "16b 正しいアカウントが既に使用中なら切り替えない"
new_env git gh brew uname
set_accounts "alice success yes" "bob success no"
run_setup switch alice
assert_rc 0
assert_out "ACTION=unchanged"
assert_out "RESULT=READY"
assert_not_log '^gh auth switch'

begin "16c 大文字小文字の違いは同じアカウントとして扱う"
new_env git gh brew uname
set_accounts "alice success yes" "bob success no"
run_setup switch BOB
assert_rc 0
assert_log "gh auth switch --hostname github.com --user bob"

begin "16d ログインしていないアカウントには切り替えない"
new_env git gh brew uname
set_accounts "alice success yes"
run_setup switch dave
assert_rc 1
assert_out "RESULT=ACCOUNT_NOT_FOUND"
assert_not_log '^gh auth switch'

begin "16e 不正なアカウント名"
new_env git gh brew uname
set_accounts "alice success yes" "bob success no"
for bad in "" "-bob" "bob;rm" "bob alice" "../bob" "$(printf 'bob\nalice')" "a234567890123456789012345678901234567890"; do
  run_setup switch "$bad"
  if [ "$RC" -eq 1 ]; then ok; else fail "「${bad}」が拒否されなかった（RC=$RC）"; fi
  assert_out "RESULT=INVALID_ACCOUNT"
done
assert_not_log '^gh auth switch'

begin "16f 切り替えの失敗"
new_env git gh brew uname
set_accounts "alice success yes" "bob success no"
MOCK_ENV=(MOCK_GH_SWITCH=fail)
run_setup switch bob
assert_rc 2
assert_out "RESULT=SWITCH_FAILED"
assert_out "切り替えに失敗しました"
if [ "$(active_account)" = alice ]; then ok; else fail "失敗したのに使用中のアカウントが変わった"; fi

begin "16g 有効期限切れのアカウントには切り替えない"
new_env git gh brew uname
set_accounts "alice success yes" "bob error no"
run_setup switch bob
assert_rc 1
assert_out "RESULT=ACCOUNT_NEEDS_LOGIN"
assert_not_log '^gh auth switch'

begin "16h 切り替え後もリポジトリにアクセスできない"
new_env git gh brew uname
set_accounts "alice success yes" "bob success no"
MOCK_ENV=(MOCK_GH_REPO_ACCESS=nobody)
run_setup switch bob
assert_rc 1
assert_out "ACTION=switched"
assert_out "RESULT=NO_REPO_ACCESS"
assert_not_out "RESULT=READY"

# ---- 17. 新規ログイン --------------------------------------------------------
begin "17 未ログインから新規ログイン → 再確認で準備完了 → Clone 再開"
new_env git gh brew uname
set_accounts
MOCK_ENV=(MOCK_GH_LOGIN=ok MOCK_GH_LOGIN_USER=new-editor)
run_setup login
assert_rc 0
assert_out "クリップボードにコピーしました"
assert_out "BROWSER_OPENED=yes"
assert_out "ACTION=logged_in"
assert_out "ACCOUNT=new-editor"
assert_out "RESULT=READY"
assert_log "gh auth login --hostname github.com --git-protocol https --web --clipboard"
assert_log "open https://github.com/login/device"
if [ ! -s "$CLIPBOARD" ]; then ok; else fail "クリップボードにコードが残っている"; fi
assert_safe_calls
run_setup clone "~/EstRouge"
assert_rc 0
assert_out "RESULT=CLONED"

begin "17b 既存アカウントを残したまま新しいアカウントを追加"
new_env git gh brew uname
set_accounts "alice success yes"
MOCK_ENV=(MOCK_GH_LOGIN=ok MOCK_GH_LOGIN_USER=work-account MOCK_GH_REPO_ACCESS=work-account)
run_setup login
assert_rc 0
assert_out "ACCOUNT=work-account"
if has_account alice; then ok; else fail "既存アカウント alice のログインが消えた"; fi
if [ "$(active_account)" = work-account ]; then ok; else fail "新しいアカウントが使用中になっていない"; fi
assert_not_log 'logout'

begin "17c ブラウザで承認がキャンセルされた"
new_env git gh brew uname
set_accounts "alice success yes"
MOCK_ENV=(MOCK_GH_LOGIN=denied)
run_setup login
assert_rc 1
assert_out "RESULT=LOGIN_DENIED"
assert_not_out "RESULT=READY"
if [ ! -s "$CLIPBOARD" ]; then ok; else fail "クリップボードにコードが残っている"; fi
if [ "$(active_account)" = alice ]; then ok; else fail "失敗したのに使用中のアカウントが変わった"; fi

begin "17d 確認用コードの有効期限切れ"
new_env git gh brew uname
set_accounts
MOCK_ENV=(MOCK_GH_LOGIN=expired)
run_setup login
assert_rc 1
assert_out "RESULT=LOGIN_EXPIRED"

begin "17e 承認待ちの時間切れ（gh の処理を止める）"
new_env git gh brew uname
set_accounts
MOCK_ENV=(MOCK_GH_LOGIN=hang SETUP_WORKSPACE_LOGIN_TIMEOUT=2)
t0=$SECONDS
run_setup login
assert_rc 1
assert_out "RESULT=LOGIN_TIMEOUT"
if [ $((SECONDS - t0)) -lt 15 ]; then ok; else fail "時間切れで止まるまでに時間がかかりすぎた"; fi
if [ -f "$GH_PIDFILE" ] && ! kill -0 "$(cat "$GH_PIDFILE")" 2>/dev/null; then ok; else fail "gh のログイン処理が残っている"; fi
if [ ! -s "$CLIPBOARD" ]; then ok; else fail "クリップボードにコードが残っている"; fi

begin "17f コードをクリップボードに渡せない場合は中止（画面に表示しない）"
new_env git gh brew uname
set_accounts
MOCK_ENV=(MOCK_GH_LOGIN=noclip)
run_setup login
assert_rc 1
assert_out "RESULT=LOGIN_UNSUPPORTED"
assert_not_log '^open '
if [ -f "$GH_PIDFILE" ] && ! kill -0 "$(cat "$GH_PIDFILE")" 2>/dev/null; then ok; else fail "gh のログイン処理が残っている"; fi

begin "17g 古い gh（--clipboard 非対応）ではログインを始めない"
new_env git gh brew uname
set_accounts
MOCK_ENV=(MOCK_GH_CLIPBOARD=unsupported)
run_setup login
assert_rc 1
assert_out "RESULT=LOGIN_UNSUPPORTED"
assert_not_log '^gh auth login .*--web'

begin "17h ブラウザを自動で開けなくても続行する"
new_env git gh brew uname
set_accounts
MOCK_ENV=(MOCK_GH_LOGIN=ok MOCK_OPEN=fail)
run_setup login
assert_rc 0
assert_out "BROWSER_OPENED=no"
assert_out "https://github.com/login/device を開いてください"
assert_out "RESULT=READY"

begin "17i ログイン中のネットワークエラー"
new_env git gh brew uname
set_accounts
MOCK_ENV=(MOCK_GH_LOGIN=network)
run_setup login
assert_rc 2
assert_out "RESULT=NETWORK_ERROR"

begin "17j 想定外のログイン失敗（エラー内の秘密情報を伏せる）"
new_env git gh brew uname
set_accounts
MOCK_ENV=(MOCK_GH_LOGIN=error)
run_setup login
assert_rc 2
assert_out "RESULT=LOGIN_FAILED"
assert_out "gho_***"
assert_not_out "user:pw"

begin "17k ログイン後もリポジトリにアクセスできない"
new_env git gh brew uname
set_accounts
MOCK_ENV=(MOCK_GH_LOGIN=ok MOCK_GH_LOGIN_USER=private-account MOCK_GH_REPO_ACCESS=someone-else)
run_setup login
assert_rc 1
assert_out "ACTION=logged_in"
assert_out "RESULT=NO_REPO_ACCESS"

# ---- 18. 古い gh・環境の不足 -------------------------------------------------
begin "18 古い gh（--json 非対応）でも確認はでき、切り替えは手動案内になる"
new_env git gh brew uname
MOCK_ENV=(MOCK_GH_JSON=unsupported MOCK_GH_USER=legacy-user)
run_setup check
assert_rc 0
assert_out "AUTH_MODE=legacy"
assert_out "ACCOUNT=legacy-user"
assert_out "RESULT=READY"
run_setup switch someone
assert_rc 1
assert_out "RESULT=AUTH_UNSUPPORTED"
run_setup accounts
assert_rc 1
assert_out "RESULT=AUTH_UNSUPPORTED"
assert_no_auth_change

begin "18b gh がない・macOS 以外では切り替え・ログインしない"
new_env git uname
run_setup login
assert_rc 1
assert_out "RESULT=NEED_INSTALL"
run_setup switch bob
assert_rc 1
assert_out "RESULT=NEED_INSTALL"
new_env git gh uname
MOCK_ENV=(MOCK_UNAME=Linux)
run_setup login
assert_rc 1
assert_out "RESULT=UNSUPPORTED_OS"
assert_no_auth_change

begin "18c 使い方の誤り（認証関連）"
new_env git gh uname
run_setup switch
assert_rc 64
run_setup switch a b
assert_rc 64
run_setup login extra
assert_rc 64
assert_no_auth_change
# ============================================================================
# ソフトの検出と追加（Command Line Tools / Homebrew / gh / PATH）
# （インストーラー・ダウンロード・管理者権限はすべてモック。実機には一切触れない）
# ============================================================================

# テスト環境で、本物のインストーラー類が PATH から見えないこと
begin "20 テスト環境では本物のインストーラー・認証コマンドに届かない"
new_env uname
for c in curl sudo softwareupdate installer xcode-select open brew gh git pkgutil spctl; do
  p=$(env -i PATH="$T/bin:$T/sys" /bin/bash -c "command -v $c" 2>/dev/null)
  case "$p" in
    "" | "$T/bin/"*) ok ;;
    *) fail "本物の $c が見えている: $p" ;;
  esac
done
if grep -nE '(^|[;&|(` ])sudo([[:space:]]|$)' "$SCRIPT" | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null; then
  fail "setup.sh に sudo の実行が含まれている"
else ok; fi
if grep -nE '(^|[;&|(` ])(softwareupdate|installer -pkg)' "$SCRIPT" | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null; then
  fail "setup.sh に softwareupdate / installer の実行が含まれている"
else ok; fi

# ---- 21. 環境の検出 ----------------------------------------------------------
begin "21 Git・gh・Homebrew がすべて未導入（何もインストールしない）"
new_env
run_setup check
assert_rc 1
assert_out "RESULT=NEED_INSTALL"
assert_out "MISSING=git,gh"
assert_out "INSTALL_PLAN=clt,brew,gh"
assert_out "NEXT=install-clt"
assert_out "CLT=missing"
assert_out "BREW=no"
assert_out "CPU=apple_silicon"
assert_out "BREW_AUTO_INSTALL=yes"
assert_no_install
assert_safe_calls
# Git が使えない状態で /usr/bin/git を実行しない（インストール画面が勝手に出るため）
mkdir -p "$SYSROOT/usr/bin"
ln -sf "$MOCKS/git" "$SYSROOT/usr/bin/git"
MOCK_ENV=(PATH="$SYSROOT/usr/bin:$T/bin:$T/sys")   # macOS と同じく /usr/bin/git が PATH にある
: > "$LOG"
run_setup check
assert_out "GIT=no"
assert_not_log '^git --version'

begin "22 Git だけ存在する"
new_env git
run_setup check
assert_rc 1
assert_out "GIT=yes"
assert_out "MISSING=gh"
assert_out "INSTALL_PLAN=clt,brew,gh"   # Homebrew には開発者ツールが必要
assert_no_install

begin "22b Git と開発者ツールが存在する"
new_env
install_fake_clt
run_setup check
assert_rc 1
assert_out "CLT=installed"
assert_out "GIT=yes"
assert_out "INSTALL_PLAN=brew,gh"
assert_out "NEXT=install-brew"

begin "23 Homebrew だけ存在する"
new_env brew
run_setup check
assert_rc 1
assert_out "BREW=yes"
assert_out "MISSING=git,gh"
assert_out "INSTALL_PLAN=clt,gh"
assert_no_install

begin "24 gh だけ不足している → Homebrew で追加 → 再実行で入れ直さない"
new_env git brew
install_fake_clt
run_setup check
assert_rc 1
assert_out "INSTALL_PLAN=gh"
assert_out "NEXT=install-gh"
run_setup install-gh
assert_rc 0
assert_out "RESULT=GH_READY"
assert_out "ACTION=installed"
assert_log "brew install gh"
run_setup check
assert_rc 0
assert_out "RESULT=READY"
run_setup install-gh
assert_rc 0
assert_out "ACTION=unchanged"
assert_count_log '^brew install' 1
assert_safe_calls

begin "25 PATH に登録されていない Homebrew・gh・Git を見つける"
new_env
install_fake_clt
install_fake_brew
install_fake_gh_in_brew
run_setup check
assert_rc 0
assert_out "BREW=yes"
assert_out "BREW_ON_PATH=no"
assert_out "BREW_PREFIX=$SYSROOT/opt/homebrew"
assert_out "PATH）に登録されていなかったため"
assert_out "GH=yes"
assert_out "GIT=yes"
assert_out "RESULT=READY"
assert_no_install
# PATH 外の Homebrew・gh でも Clone まで進められる
run_setup clone "~/EstRouge"
assert_rc 0
assert_out "RESULT=CLONED"

begin "25b Intel Mac の Homebrew（/usr/local）を見つける"
new_env
MOCK_ENV=(MOCK_CPU=intel MOCK_ARCH=x86_64)
install_fake_clt
install_fake_brew usr/local
install_fake_gh_in_brew usr/local
run_setup check
assert_rc 0
assert_out "CPU=intel"
assert_out "BREW_PREFIX=$SYSROOT/usr/local"
assert_out "RESULT=READY"

begin "25c Apple シリコンの互換モード（Rosetta）を判別する"
new_env git gh brew
MOCK_ENV=(MOCK_ARCH=x86_64)
run_setup check
assert_out "CPU=apple_silicon"
assert_out "ROSETTA=yes"

begin "25d 管理下の Mac・管理者でないユーザーを表示する"
new_env git gh brew
MOCK_ENV=(MOCK_MANAGED=yes MOCK_ADMIN=no)
run_setup check
assert_out "MANAGED=yes"
assert_out "IS_ADMIN=no"
assert_out "学校・会社などの管理下"

# ---- 26. 開発者ツール（Git） ------------------------------------------------
begin "26 開発者ツールの追加 → 完了を確認 → 再実行で入れ直さない"
new_env
run_setup install-clt
assert_rc 0
assert_out "ACTION=install_requested"
assert_out "RESULT=CLT_READY"
assert_exists "$SYSROOT/Library/Developer/CommandLineTools/usr/bin/git"
run_setup install-clt
assert_rc 0
assert_out "ACTION=unchanged"
assert_count_log '^xcode-select --install' 1
assert_safe_calls

begin "26b 開発者ツールの完了待ちが時間切れ → wait で続きから再開"
new_env
MOCK_ENV=(MOCK_CLT_INSTALL=pending SETUP_WORKSPACE_INSTALL_TIMEOUT=2)
run_setup install-clt
assert_rc 1
assert_out "RESULT=INSTALL_WAITING"
assert_out "NEXT=wait clt"
install_fake_clt   # 利用者が画面でインストールを完了した
run_setup wait clt
assert_rc 0
assert_out "RESULT=CLT_READY"
assert_count_log '^xcode-select --install' 1

begin "26c 開発者ツールのインストールが管理ポリシーで禁止されている"
new_env
MOCK_ENV=(MOCK_CLT_INSTALL=error)
run_setup install-clt
assert_rc 2
assert_out "RESULT=CLT_FAILED"
assert_out "管理者に相談してください"
assert_not_out "RESULT=CLT_READY"

begin "26d 「既に入っている」と言われたが Git がない"
new_env
MOCK_ENV=(MOCK_CLT_INSTALL=already)
run_setup install-clt
assert_rc 2
assert_out "RESULT=CLT_FAILED"

# ---- 27. Homebrew -------------------------------------------------------------
begin "27 Homebrew の追加（公式インストーラーを確認してから開く）"
new_env
install_fake_clt
run_setup install-brew
assert_rc 0
assert_out "インストーラーが Homebrew 公式のもの"
assert_out "ACTION=installer_opened"
assert_out "RESULT=BREW_READY"
assert_out "BREW_PATH_PERSISTED=yes"
assert_log "curl -fsSL --proto =https --tlsv1.2 --max-time 60 https://api.github.com/repos/Homebrew/brew/releases/latest"
assert_log "https://github.com/Homebrew/brew/releases/download/9.9.9/Homebrew.pkg"
assert_log "pkgutil --check-signature"
assert_log "spctl --assess --type install"
assert_log "open $T/setup-workspace-brew."
assert_exists "$SYSROOT/opt/homebrew/bin/brew"
if ls -d "$T"/setup-workspace-brew.* >/dev/null 2>&1; then fail "ダウンロードしたインストーラーが残っている"; else ok; fi
assert_safe_calls
# 続けて gh を追加し、確認まで進める
run_setup install-gh
assert_rc 0
assert_out "RESULT=GH_READY"

begin "27b Homebrew が既にあれば入れ直さない"
new_env git
install_fake_clt
install_fake_brew
run_setup install-brew
assert_rc 0
assert_out "ACTION=unchanged"
assert_out "RESULT=BREW_READY"
assert_no_install

begin "27c 管理者権限がない"
new_env
install_fake_clt
MOCK_ENV=(MOCK_ADMIN=no)
run_setup install-brew
assert_rc 1
assert_out "RESULT=NO_ADMIN"
assert_no_install

begin "27d 開発者ツールがないと Homebrew は入れない"
new_env
run_setup install-brew
assert_rc 1
assert_out "RESULT=NEED_CLT"
assert_out "NEXT=install-clt"
assert_no_install

begin "27e Intel Mac では自動で入れない（手動の案内へ）"
new_env
install_fake_clt
MOCK_ENV=(MOCK_CPU=intel MOCK_ARCH=x86_64)
run_setup install-brew
assert_rc 1
assert_out "RESULT=BREW_AUTO_UNSUPPORTED"
assert_no_install

begin "27f Homebrew インストール失敗: 情報を取得できない"
new_env
install_fake_clt
MOCK_ENV=(MOCK_CURL_API=fail)
run_setup install-brew
assert_rc 2
assert_out "RESULT=BREW_DOWNLOAD_FAILED"
assert_not_log '^open '
assert_not_log 'Homebrew\.pkg'

begin "27g Homebrew インストール失敗: 公式以外の配布元は使わない"
new_env
install_fake_clt
MOCK_ENV=(MOCK_CURL_API=badurl)
run_setup install-brew
assert_rc 2
assert_out "RESULT=BREW_DOWNLOAD_FAILED"
assert_not_log 'evil\.example\.com'
assert_not_log '^open '

begin "27h Homebrew インストール失敗: ダウンロードできない・空のファイル"
for mode in fail empty; do
  new_env
  install_fake_clt
  MOCK_ENV=(MOCK_CURL_PKG=$mode)
  run_setup install-brew
  assert_rc 2
  assert_out "RESULT=BREW_DOWNLOAD_FAILED"
  assert_not_log '^(open|pkgutil|spctl) '
  if ls -d "$T"/setup-workspace-brew.* >/dev/null 2>&1; then fail "作業フォルダが残っている"; else ok; fi
done

begin "27i Homebrew インストール失敗: 署名を確認できないものは実行しない"
for sig in unsigned wrongteam notnotarized; do
  new_env
  install_fake_clt
  MOCK_ENV=(MOCK_PKG_SIG=$sig)
  run_setup install-brew
  assert_rc 2
  assert_out "RESULT=BREW_VERIFY_FAILED"
  assert_not_log '^open '
  if ls "$T"/setup-workspace-brew.*/Homebrew.pkg >/dev/null 2>&1; then fail "検証に失敗したファイルが残っている"; else ok; fi
done
new_env
install_fake_clt
MOCK_ENV=(MOCK_SPCTL=reject)
run_setup install-brew
assert_rc 2
assert_out "RESULT=BREW_VERIFY_FAILED"
assert_not_log '^open '

begin "27j インストール途中での中断 → 再実行で続きから復旧"
new_env
install_fake_clt
MOCK_ENV=(MOCK_PKG_INSTALL=cancel SETUP_WORKSPACE_INSTALL_TIMEOUT=2)
run_setup install-brew
assert_rc 1
assert_out "RESULT=INSTALL_WAITING"
assert_out "NEXT=wait brew"
assert_absent "$SYSROOT/opt/homebrew/bin/brew"
# もう一度実行すると、改めて確認してからインストーラーを開き直す
MOCK_ENV=(MOCK_PKG_INSTALL=ok)
run_setup install-brew
assert_rc 0
assert_out "RESULT=BREW_READY"
assert_count_log '^open .*\.pkg' 2
# 以後は入れ直さない
run_setup install-brew
assert_out "ACTION=unchanged"
assert_count_log '^open .*\.pkg' 2

begin "27k インストーラーで完了した後に wait で再開"
new_env
install_fake_clt
MOCK_ENV=(MOCK_PKG_INSTALL=cancel SETUP_WORKSPACE_INSTALL_TIMEOUT=2)
run_setup install-brew
assert_out "RESULT=INSTALL_WAITING"
install_fake_brew
run_setup wait brew
assert_rc 0
assert_out "RESULT=BREW_READY"

# ---- 28. gh の追加の失敗と復旧 ---------------------------------------------
begin "28 gh の追加失敗（ネットワーク・実行中・権限）"
for mode in network:NETWORK_ERROR locked:BREW_BUSY permission:BREW_PERMISSION; do
  new_env git brew
  MOCK_ENV=(MOCK_BREW_GH=${mode%%:*})
  run_setup install-gh
  assert_rc 2
  assert_out "RESULT=${mode#*:}"
  assert_not_out "RESULT=GH_READY"
done

begin "28b gh の追加が途中で中断 → 再実行で復旧"
new_env git brew
MOCK_ENV=(MOCK_BREW_GH=interrupt-once)
run_setup install-gh
assert_rc 2
assert_out "RESULT=GH_INSTALL_FAILED"
run_setup install-gh
assert_rc 0
assert_out "RESULT=GH_READY"

begin "28c Homebrew がなければ gh は追加しない"
new_env git
run_setup install-gh
assert_rc 1
assert_out "RESULT=NEED_BREW"
assert_no_install

# ---- 29. PATH の永続化 -------------------------------------------------------
begin "29 PATH の設定が必要か確認 → 必要な場合だけ 1 回追記"
new_env git
install_fake_brew
printf 'export FOO=1\nalias ll="ls -l"' > "$HOME_DIR/.zprofile"   # 末尾に改行なし
run_setup path-status
assert_rc 0
assert_out "BREW_PATH_PERSISTED=no"
assert_out "PROFILE_FILE=$HOME_DIR/.zprofile"
run_setup persist-path
assert_rc 0
assert_out "RESULT=PATH_PERSISTED"
if grep -qx 'export FOO=1' "$HOME_DIR/.zprofile" && grep -qx 'alias ll="ls -l"' "$HOME_DIR/.zprofile"; then ok; else fail "既存の設定が壊れた"; fi
if grep -qF "eval \"\$($SYSROOT/opt/homebrew/bin/brew shellenv)\"" "$HOME_DIR/.zprofile"; then ok; else fail "brew shellenv が追記されていない"; fi
run_setup persist-path
assert_rc 0
assert_out "RESULT=ALREADY_CONFIGURED"
n=$(grep -c 'brew shellenv' "$HOME_DIR/.zprofile")
if [ "$n" -eq 1 ]; then ok; else fail "設定が重複して追記された（${n} 件）"; fi
run_setup path-status
assert_out "BREW_PATH_PERSISTED=yes"

begin "29b 既に設定済み（/etc/paths.d または自分の設定）なら追記しない"
new_env git
install_fake_brew
mkdir -p "$SYSROOT/etc/paths.d"
echo "$SYSROOT/opt/homebrew/bin" > "$SYSROOT/etc/paths.d/homebrew"
run_setup persist-path
assert_out "RESULT=ALREADY_CONFIGURED"
assert_absent "$HOME_DIR/.zprofile"
new_env git
install_fake_brew
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' > "$HOME_DIR/.zshrc"
run_setup persist-path
assert_out "RESULT=ALREADY_CONFIGURED"
assert_absent "$HOME_DIR/.zprofile"

begin "29c bash は .bash_profile、それ以外のシェルは自動で変更しない"
new_env git
install_fake_brew
MOCK_ENV=(SHELL=/bin/bash)
run_setup persist-path
assert_out "RESULT=PATH_PERSISTED"
assert_exists "$HOME_DIR/.bash_profile"
new_env git
install_fake_brew
MOCK_ENV=(SHELL=/opt/homebrew/bin/fish)
run_setup persist-path
assert_rc 1
assert_out "RESULT=UNSUPPORTED_SHELL"

# ---- 30. 何もない状態から Clone まで（再実行で復旧） ---------------------------
begin "30 何もない Mac から Clone まで（途中で止まっても続きから）"
new_env
set_accounts
run_setup check
assert_out "NEXT=install-clt"
run_setup install-clt
assert_out "RESULT=CLT_READY"
run_setup check
assert_out "NEXT=install-brew"
MOCK_ENV=(MOCK_BREW_GH=interrupt-once)
run_setup install-brew
assert_out "RESULT=BREW_READY"
run_setup check
assert_out "NEXT=install-gh"
run_setup install-gh
assert_rc 2                       # 1 回目は中断
run_setup check
assert_out "NEXT=install-gh"      # 再確認すると、続きは gh から
run_setup install-gh
assert_out "RESULT=GH_READY"
run_setup check
assert_out "RESULT=NEED_LOGIN"
MOCK_ENV=(MOCK_GH_LOGIN=ok MOCK_GH_LOGIN_USER=editor)
run_setup login
assert_out "RESULT=READY"
run_setup clone "~/EstRouge"
assert_rc 0
assert_out "RESULT=CLONED"
run_setup check
assert_rc 0
assert_out "EXISTING_CLONE=$HOME_DIR/EstRouge/est-rouge-cms-demo"
assert_count_log '^xcode-select --install' 1
assert_count_log '^open .*\.pkg' 1
assert_safe_calls

begin "31 インストールを断った場合（確認だけ繰り返しても何も変わらない）"
new_env
for i in 1 2; do
  run_setup check
  assert_rc 1
  assert_out "RESULT=NEED_INSTALL"
done
assert_no_install
if [ -z "$(ls -A "$SYSROOT")" ]; then ok; else fail "システムの場所に変更がある"; fi
if [ -z "$(ls -A "$HOME_DIR")" ]; then ok; else fail "ホームフォルダに変更がある"; fi

begin "32 使い方の誤り（インストール関連）"
new_env
run_setup wait
assert_rc 64
run_setup wait gh
assert_rc 64
run_setup install-gh now
assert_rc 64
assert_no_install

begin "33 macOS 以外ではインストールしない"
new_env
MOCK_ENV=(MOCK_UNAME=Linux)
for c in install-clt install-brew install-gh; do
  run_setup "$c"
  assert_rc 1
  assert_out "RESULT=UNSUPPORTED_OS"
done
assert_no_install

# ============================================================================
echo ""
echo "結果: 成功 ${PASS} 件 / 失敗 ${FAIL} 件（対象: ${SCRIPT}）"
[ "$FAIL" -eq 0 ]
