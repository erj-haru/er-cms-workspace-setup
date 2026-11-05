#!/bin/bash
# =============================================================================
# setup-workspace 補助スクリプト
#
# Est Rouge CMS（est-rouge-cms-demo）を編集者の Mac に Clone するまでを担当する。
# Claude Code の Skill「/setup-workspace」から呼び出される。
#
# 使い方:
#   bash setup.sh check            環境（macOS / Git / gh / ログイン / 権限）を確認
#   bash setup.sh accounts         ログイン済みの GitHub アカウントを表示（変更なし）
#   bash setup.sh switch <名前>    ログイン済みの別アカウントに切り替える（利用者の承認後）
#   bash setup.sh login            ブラウザで GitHub にログインする（利用者の承認後）
#   bash setup.sh suggest          おすすめの保存先を表示
#   bash setup.sh plan  <保存先>   保存先を確認するだけ（何も変更しない）
#   bash setup.sh clone <保存先>   Clone する（正しい Clone が既にあれば再利用）
#   bash setup.sh verify <保存先>  Clone 済みフォルダを確認する（何も変更しない）
#
# 終了コード:
#   0  成功
#   1  利用者の対応が必要（ツール未導入・未ログイン・権限なし など）
#   2  失敗（Clone 失敗・Clone 後の確認失敗・想定外のエラー）
#   3  保存先が使えない（不正な指定・別のフォルダが既にある など）
#   64 使い方の誤り
#
# 出力の最後に「KEY=value」形式の行を出す（Claude が結果を判定するため）。
#
# 安全方針:
#   - 認証情報（トークン・パスワード）を表示・保存しない
#   - 既存のファイルやフォルダを削除・上書きしない（rm は使わない）
#   - 既存リポジトリに対して fetch / pull / reset / commit / push をしない
#   - ソフトウェアのインストールやログアウトをしない
#   - GitHub のワンタイムコードは画面に出さず、クリップボード経由で渡す
#
# macOS 標準の /bin/bash（3.2）で動くように書いている。
# =============================================================================

set -u
umask 022

readonly REPO_SLUG="erj-haru/est-rouge-cms-demo"
readonly REPO_URL="https://github.com/${REPO_SLUG}.git"
readonly REPO_DIRNAME="est-rouge-cms-demo"
readonly DEFAULT_PARENT_NAME="EstRouge"
# Clone 後に存在を確認する CMS のファイル
readonly REQUIRED_FILES="package.json astro.config.mjs compose.yaml .claude/skills/setup-editor/SKILL.md .claude/skills/cms-help/SKILL.md"

readonly EXIT_OK=0
readonly EXIT_ACTION=1
readonly EXIT_FAIL=2
readonly EXIT_DEST=3
readonly EXIT_USAGE=64

# Claude Desktop から起動した場合、Homebrew の場所が PATH に入っていないことがある。
# 既定では Homebrew の標準の場所を PATH の末尾に補う（既存の PATH が優先）。
# テストでは SETUP_WORKSPACE_EXTRA_PATH="" として実機のツールを見ないようにする。
extra_path="${SETUP_WORKSPACE_EXTRA_PATH-/opt/homebrew/bin:/usr/local/bin}"
if [ -n "$extra_path" ]; then
  old_ifs=$IFS
  IFS=:
  for d in $extra_path; do
    case ":${PATH}:" in
      *":${d}:"*) ;;
      *) [ -d "$d" ] && PATH="${PATH}:${d}" ;;
    esac
  done
  IFS=$old_ifs
  export PATH
fi

# -----------------------------------------------------------------------------
# 出力用
# -----------------------------------------------------------------------------
say() { printf '%s\n' "$*"; }
RESULT_EMITTED=0
kv() {
  [ "$1" = RESULT ] && RESULT_EMITTED=1
  printf '%s=%s\n' "$1" "$2"
}

# 想定外の理由（スクリプトの不具合など）で終了した場合に、成功や「要対応」と
# 誤解されないよう、必ず終了コード 2 と RESULT=UNEXPECTED_ERROR を返す
on_exit() {
  local rc=$?
  # ログイン待ちの途中で終了した場合は、gh の処理も止める
  if [ -n "${GH_PID:-}" ]; then kill "$GH_PID" 2>/dev/null; fi
  if [ -n "${LOGIN_PID:-}" ]; then kill "$LOGIN_PID" 2>/dev/null; fi
  if [ $rc -ne 0 ] && [ $rc -ne 64 ] && [ "$RESULT_EMITTED" -eq 0 ]; then
    printf '%s\n' "❌ 予期しないエラーで処理を中断しました。" "RESULT=UNEXPECTED_ERROR"
    exit 2
  fi
}
trap on_exit EXIT

# 外部コマンドのエラー文から、URL に含まれうる認証情報を伏せる
sanitize() { sed -E 's#(https?://)[^/@[:space:]]+@#\1***@#g'; }

# -----------------------------------------------------------------------------
# ツールの確認
# -----------------------------------------------------------------------------
is_macos() {
  [ "$(uname -s 2>/dev/null)" = "Darwin" ]
}

# macOS の /usr/bin/git は、開発者ツールが未導入だと実行に失敗するため、実際に動かして確認する
has_git() {
  command -v git >/dev/null 2>&1 && git --version >/dev/null 2>&1
}

has_gh() {
  command -v gh >/dev/null 2>&1 && gh --version >/dev/null 2>&1
}

has_brew() {
  command -v brew >/dev/null 2>&1
}

to_lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# 対象リポジトリの URL かどうか（https / ssh の書き方の違いと大文字小文字を許容）
url_matches_repo() {
  local u
  u=$(to_lower "$1")
  u=$(printf '%s' "$u" | sed -E 's#^https://[^/@]+@#https://#')
  u=${u%/}
  u=${u%.git}
  local slug
  slug=$(to_lower "$REPO_SLUG")
  case "$u" in
    "https://github.com/${slug}" | "git@github.com:${slug}" | "ssh://git@github.com/${slug}") return 0 ;;
  esac
  return 1
}

# -----------------------------------------------------------------------------
# check: 環境確認
# -----------------------------------------------------------------------------
cmd_check() {
  say "== 準備状況の確認 =="

  if ! is_macos; then
    say "❌ このパソコンは macOS ではないようです。現在この手順は Mac のみに対応しています。"
    kv RESULT UNSUPPORTED_OS
    return $EXIT_ACTION
  fi
  say "✅ Mac を確認しました"

  local brew_state=no
  if has_brew; then brew_state=yes; fi

  local missing=""
  if has_git; then
    say "✅ Git（ファイルの履歴を管理する道具）: 使えます（$(git --version 2>/dev/null)）"
  else
    say "❌ Git（ファイルの履歴を管理する道具）: 見つかりません"
    missing="git"
  fi

  if has_gh; then
    say "✅ GitHub CLI（gh）: 使えます（$(gh --version 2>/dev/null | sed -n '1p')）"
  else
    say "❌ GitHub CLI（gh）: 見つかりません"
    missing="${missing:+${missing},}gh"
  fi

  if [ -n "$missing" ]; then
    if [ "$brew_state" = yes ]; then
      say "ℹ️ Homebrew（Mac 用のソフト追加ツール）は使えます"
    else
      say "ℹ️ Homebrew（Mac 用のソフト追加ツール）は見つかりません"
    fi
    say "→ 不足しているソフトの追加が必要です。"
    kv RESULT NEED_INSTALL
    kv MISSING "$missing"
    kv BREW "$brew_state"
    return $EXIT_ACTION
  fi

  kv BREW "$brew_state"
  report_auth
}

# -----------------------------------------------------------------------------
# GitHub 認証（アカウントの確認・切り替え・ログイン）
#
# - トークン・パスワード・ワンタイムコードは画面に出さない
# - ログアウトは一切しない
# - 切り替え（switch）とログイン（login）は、Skill が利用者の承認を得てから呼ぶ
# -----------------------------------------------------------------------------
readonly GH_HOST="github.com"
readonly DEVICE_URL="https://github.com/login/device"
readonly LOGIN_RE='^[A-Za-z0-9][A-Za-z0-9-]{0,38}$'
LOGIN_TIMEOUT="${SETUP_WORKSPACE_LOGIN_TIMEOUT:-540}"

# 秘密情報（ワンタイムコード・トークン・URL 内の認証情報）を伏せる
mask_secrets() {
  sed -E \
    -e 's/[A-Z0-9]{4}-[A-Z0-9]{4}/****-****/g' \
    -e 's/(gh[opusr]_|github_pat_)[A-Za-z0-9_]+/\1***/g' \
    -e 's#(https?://)[^/@[:space:]]+@#\1***@#g'
}

is_network_error() {
  case "$(to_lower "$1")" in
    *"error connecting"* | *"could not resolve host"* | *"no such host"* | *timeout* | *"timed out"* | *"network is unreachable"*) return 0 ;;
  esac
  return 1
}

# github.com の認証済みアカウント一覧を読み込む（トークンは読まない）
#   ACCT_LINES: 「ログイン名<TAB>true|false<TAB>状態」の行
#   ACTIVE_LOGIN / ACTIVE_STATE / ACTIVE_ERROR: 現在有効なアカウント
#   失敗時（古い gh で --json に未対応など）は 1 を返す
ACCT_LINES=""
ACTIVE_LOGIN=""
ACTIVE_STATE=""
ACTIVE_ERROR=""
load_accounts() {
  ACCT_LINES=""
  ACTIVE_LOGIN=""
  ACTIVE_STATE=""
  ACTIVE_ERROR=""
  local out l a st er
  out=$(gh auth status --hostname "$GH_HOST" --json hosts \
    --jq '(.hosts["github.com"] // [])[] | [.login, (.active|tostring), .state, (.error // "")] | @tsv' 2>/dev/null) || return 1
  while IFS=$'\t' read -r l a st er; do
    [ -z "$l" ] && continue
    ACCT_LINES="${ACCT_LINES}${l}"$'\t'"${a}"$'\t'"${st}"$'\n'
    if [ "$a" = "true" ]; then
      ACTIVE_LOGIN="$l"
      ACTIVE_STATE="$st"
      ACTIVE_ERROR="$er"
    fi
  done <<<"$out"
  return 0
}

# 認証済みアカウント（状態が正常なもの）をカンマ区切りで返す
known_accounts() {
  local l a st list=""
  while IFS=$'\t' read -r l a st; do
    [ -z "$l" ] && continue
    [ "$st" = "success" ] && list="${list:+${list},}${l}"
  done <<<"$ACCT_LINES"
  printf '%s' "$list"
}

# 指定したアカウントの、一覧上の正式な表記と状態を探す（大文字小文字を区別しない）
FOUND_LOGIN=""
FOUND_STATE=""
find_account() {
  local want l a st
  want=$(to_lower "$1")
  FOUND_LOGIN=""
  FOUND_STATE=""
  while IFS=$'\t' read -r l a st; do
    [ -z "$l" ] && continue
    if [ "$(to_lower "$l")" = "$want" ]; then
      FOUND_LOGIN="$l"
      FOUND_STATE="$st"
      return 0
    fi
  done <<<"$ACCT_LINES"
  return 1
}

# 対象リポジトリへのアクセス確認: ok / denied / network
check_repo_access() {
  local out
  if out=$(gh repo view "$REPO_SLUG" --json nameWithOwner --jq .nameWithOwner 2>&1) &&
    [ "$(to_lower "$out")" = "$(to_lower "$REPO_SLUG")" ]; then
    printf 'ok'
  elif is_network_error "$out"; then
    printf 'network'
  else
    printf 'denied'
  fi
}

# ログイン状態とリポジトリへのアクセスを確認して報告する（check と、切り替え・ログイン後の再確認で共通）
#   $1: 直前に行った操作（unchanged / switched / logged_in）。省略時は出力しない
report_auth() {
  local action="${1-}"
  [ -n "$action" ] && kv ACTION "$action"

  local login="" known=""
  if load_accounts; then
    kv AUTH_MODE json
    known=$(known_accounts)
    kv KNOWN_ACCOUNTS "$known"
    if [ -z "$ACTIVE_LOGIN" ]; then
      say "❌ GitHub にログインしていません"
      kv RESULT NEED_LOGIN
      return $EXIT_ACTION
    fi
    if [ "$ACTIVE_STATE" != "success" ]; then
      if [ "$ACTIVE_STATE" = "timeout" ] || is_network_error "$ACTIVE_ERROR"; then
        say "❌ GitHub に接続できませんでした。インターネット接続を確認してください。"
        kv RESULT NETWORK_ERROR
        return $EXIT_FAIL
      fi
      say "❌ アカウント「${ACTIVE_LOGIN}」のログインの有効期限が切れているか、無効になっています"
      kv ACCOUNT "$ACTIVE_LOGIN"
      kv RESULT NEED_LOGIN
      return $EXIT_ACTION
    fi
    login="$ACTIVE_LOGIN"
  else
    # 古い gh（--json 非対応）向け。この場合、切り替え・ログインは手動で案内する
    kv AUTH_MODE legacy
    local status_out
    if ! status_out=$(gh auth status --hostname "$GH_HOST" 2>&1); then
      if is_network_error "$status_out"; then
        say "❌ GitHub に接続できませんでした。インターネット接続を確認してください。"
        kv RESULT NETWORK_ERROR
        return $EXIT_FAIL
      fi
      say "❌ GitHub にログインしていません（またはログインの有効期限が切れています）"
      kv RESULT NEED_LOGIN
      return $EXIT_ACTION
    fi
    login=$(gh api user --jq .login 2>/dev/null) || login=""
    if [ -z "$login" ]; then
      say "❌ ログイン中の GitHub アカウント名を確認できませんでした。インターネット接続を確認してください。"
      kv RESULT NETWORK_ERROR
      return $EXIT_FAIL
    fi
  fi

  say "✅ GitHub にログイン済み（使用中のアカウント: ${login}）"
  kv ACCOUNT "$login"

  case "$(check_repo_access)" in
    ok)
      say "✅ CMS のリポジトリ（${REPO_SLUG}）にアクセスできます"
      kv RESULT READY
      return $EXIT_OK
      ;;
    network)
      say "❌ GitHub に接続できませんでした。インターネット接続を確認してください。"
      kv RESULT NETWORK_ERROR
      return $EXIT_FAIL
      ;;
    *)
      say "❌ アカウント「${login}」では CMS のリポジトリ（${REPO_SLUG}）にアクセスできません"
      kv RESULT NO_REPO_ACCESS
      return $EXIT_ACTION
      ;;
  esac
}

require_mac_and_gh() {
  if ! is_macos; then
    say "❌ このパソコンは macOS ではないようです。現在この手順は Mac のみに対応しています。"
    kv RESULT UNSUPPORTED_OS
    return $EXIT_ACTION
  fi
  if ! has_gh; then
    say "❌ GitHub CLI（gh）が見つかりません。先に「check」で準備状況を確認してください。"
    kv RESULT NEED_INSTALL
    kv MISSING gh
    return $EXIT_ACTION
  fi
  return $EXIT_OK
}

# accounts: 認証済みアカウントの一覧（変更なし）
cmd_accounts() {
  local rc
  require_mac_and_gh
  rc=$?
  [ $rc -eq 0 ] || return $rc
  if ! load_accounts; then
    say "❌ この GitHub CLI ではアカウントの一覧を取得できません（古い版の可能性があります）。"
    kv RESULT AUTH_UNSUPPORTED
    return $EXIT_ACTION
  fi
  local l a st mark
  say "== この Mac で GitHub にログイン済みのアカウント =="
  if [ -z "$ACCT_LINES" ]; then
    say "（まだありません）"
  fi
  while IFS=$'\t' read -r l a st; do
    [ -z "$l" ] && continue
    mark=""
    [ "$a" = "true" ] && mark="（使用中）"
    if [ "$st" = "success" ]; then
      say "- ${l}${mark}"
    else
      say "- ${l}${mark} ※ログインのやり直しが必要"
    fi
  done <<<"$ACCT_LINES"
  kv ACTIVE_ACCOUNT "$ACTIVE_LOGIN"
  kv KNOWN_ACCOUNTS "$(known_accounts)"
  kv RESULT OK
  return $EXIT_OK
}

# switch <アカウント>: 認証済みの別アカウントへ切り替える（利用者の承認後に呼ぶこと）
cmd_switch() {
  local want="$1" rc
  require_mac_and_gh
  rc=$?
  [ $rc -eq 0 ] || return $rc
  if ! [[ "$want" =~ $LOGIN_RE ]]; then
    say "❌ アカウント名の形式が正しくありません。"
    kv RESULT INVALID_ACCOUNT
    return $EXIT_ACTION
  fi
  if ! load_accounts; then
    say "❌ この GitHub CLI ではアカウントの切り替えができません（古い版の可能性があります）。"
    kv RESULT AUTH_UNSUPPORTED
    return $EXIT_ACTION
  fi
  if ! find_account "$want"; then
    say "❌ アカウント「${want}」は、この Mac ではまだログインしていません。新しくログインが必要です。"
    kv KNOWN_ACCOUNTS "$(known_accounts)"
    kv RESULT ACCOUNT_NOT_FOUND
    return $EXIT_ACTION
  fi
  if [ "$FOUND_STATE" != "success" ]; then
    say "❌ アカウント「${FOUND_LOGIN}」のログインは有効期限が切れているか無効です。ログインのやり直しが必要です。"
    kv RESULT ACCOUNT_NEEDS_LOGIN
    return $EXIT_ACTION
  fi
  if [ "$(to_lower "$ACTIVE_LOGIN")" = "$(to_lower "$FOUND_LOGIN")" ]; then
    say "ℹ️ アカウント「${FOUND_LOGIN}」は既に使用中です。切り替えは行いません。"
    report_auth unchanged
    return $?
  fi

  local out
  if ! out=$(gh auth switch --hostname "$GH_HOST" --user "$FOUND_LOGIN" 2>&1); then
    say "❌ アカウントの切り替えに失敗しました。"
    [ -n "$out" ] && printf '%s\n' "$out" | mask_secrets | sed -n '1,5p'
    kv RESULT SWITCH_FAILED
    return $EXIT_FAIL
  fi
  # 実際に切り替わったかを確かめる
  if ! load_accounts || [ "$(to_lower "$ACTIVE_LOGIN")" != "$(to_lower "$FOUND_LOGIN")" ]; then
    say "❌ 切り替えの結果を確認できませんでした（使用中: ${ACTIVE_LOGIN:-不明}）。"
    kv RESULT SWITCH_FAILED
    return $EXIT_FAIL
  fi
  say "✅ 使用するアカウントを「${FOUND_LOGIN}」に切り替えました（他のアカウントのログインはそのまま残っています）"
  report_auth switched
}

# login: ブラウザでの GitHub ログインを開始し、完了を待つ（利用者の承認後に呼ぶこと）
#   - 確認用のワンタイムコードは gh がクリップボードにコピーする。画面には一切表示しない
#   - ブラウザで確認ページを開く。ログインと承認は利用者本人がブラウザで行う
#   - 既存のアカウントはログアウトしない（新しいアカウントが追加され、使用中になる）
LOGIN_PID=""
GH_PID=""
stop_login_process() {
  # 終了メッセージ（Terminated など）を出さないよう、標準エラーを閉じて止める
  {
    [ -n "$GH_PID" ] && kill "$GH_PID"
    [ -n "$LOGIN_PID" ] && kill "$LOGIN_PID" && wait "$LOGIN_PID"
  } 2>/dev/null
  GH_PID=""
  LOGIN_PID=""
}

clear_clipboard_code() {
  local code="$1"
  [ -z "$code" ] && return 0
  if [ "$(pbpaste 2>/dev/null)" = "$code" ]; then
    printf '' | pbcopy 2>/dev/null && say "🧹 クリップボードに残っていた確認用コードを消去しました"
  fi
}

cmd_login() {
  local rc
  require_mac_and_gh
  rc=$?
  [ $rc -eq 0 ] || return $rc

  # 必要な機能があるかを先に確かめ、なければ何も始めずに止まる
  local help
  help=$(gh auth login --help 2>&1) || help=""
  case "$help" in
    *--clipboard*) ;;
    *)
      say "❌ この GitHub CLI は、この画面からのログインに対応していません（古い版の可能性があります）。"
      kv RESULT LOGIN_UNSUPPORTED
      return $EXIT_ACTION
      ;;
  esac
  local tool
  for tool in open pbcopy pbpaste mkfifo mktemp; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      say "❌ ログインに必要な Mac の機能（${tool}）が見つかりません。"
      kv RESULT LOGIN_UNSUPPORTED
      return $EXIT_ACTION
    fi
  done
  case "$LOGIN_TIMEOUT" in
    '' | *[!0-9]*) LOGIN_TIMEOUT=540 ;;
  esac

  # gh の出力は名前付きパイプで受け取り、ファイルには残さない
  local tmpd fifo
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/setup-workspace-login.XXXXXX") || tmpd=""
  if [ -z "$tmpd" ]; then
    say "❌ 一時的な作業場所を用意できませんでした。"
    kv RESULT LOGIN_FAILED
    return $EXIT_FAIL
  fi
  chmod 700 "$tmpd"
  fifo="${tmpd}/gh-login"
  if ! mkfifo -m 600 "$fifo"; then
    rmdir "$tmpd" 2>/dev/null
    say "❌ 一時的な作業場所を用意できませんでした。"
    kv RESULT LOGIN_FAILED
    return $EXIT_FAIL
  fi

  say "⏳ GitHub へのログインを開始します"
  (
    gh auth login --hostname "$GH_HOST" --git-protocol https --web --clipboard </dev/null 2>&1 &
    p=$!
    printf '__SW_GH_PID__ %s\n' "$p"
    wait "$p"
    printf '__SW_GH_EXIT__ %s\n' "$?"
  ) >"$fifo" &
  LOGIN_PID=$!
  exec 3<"$fifo"
  # 名前付きパイプは開いた後すぐに消す（読み取りは続けられる）
  rm -f "$fifo"
  rmdir "$tmpd" 2>/dev/null

  local start=$SECONDS line code="" copied=0 opened=0 gh_rc="" errtext="" timed_out=0 unsupported=0
  while :; do
    if IFS= read -r -t 1 line <&3; then
      case "$line" in
        "__SW_GH_PID__ "*)
          GH_PID="${line#__SW_GH_PID__ }"
          ;;
        "__SW_GH_EXIT__ "*)
          gh_rc="${line#__SW_GH_EXIT__ }"
          break
          ;;
        *"copied to clipboard"*)
          copied=1
          code=$(printf '%s' "$line" | sed -nE 's/.*([A-Z0-9]{4}-[A-Z0-9]{4}).*/\1/p')
          say "✅ 確認用のコードをクリップボードにコピーしました（安全のため画面には表示しません）"
          ;;
        *"login/device"*)
          if [ $copied -ne 1 ]; then
            # コードをクリップボードに渡せない場合は、画面に表示しないために中止する
            unsupported=1
            stop_login_process
            break
          fi
          if [ $opened -eq 0 ]; then
            opened=1
            # 開く URL は gh の出力からではなく、固定の公式 URL を使う
            if open "$DEVICE_URL" >/dev/null 2>&1; then
              say "🌐 ブラウザで GitHub の確認ページ（${DEVICE_URL}）を開きました"
              kv BROWSER_OPENED yes
            else
              say "⚠️ ブラウザを自動で開けませんでした。ブラウザで ${DEVICE_URL} を開いてください"
              kv BROWSER_OPENED no
            fi
            say "⏳ ブラウザでのログインと承認を待っています（最大 $(((LOGIN_TIMEOUT + 59) / 60)) 分）"
          fi
          ;;
        *)
          errtext="${errtext}${line}"$'\n'
          ;;
      esac
    else
      # 読み取りの時間切れ、または出力の終わり
      if ! kill -0 "$LOGIN_PID" 2>/dev/null; then
        break
      fi
      if [ $((SECONDS - start)) -ge "$LOGIN_TIMEOUT" ]; then
        timed_out=1
        stop_login_process
        break
      fi
    fi
  done
  exec 3<&-
  [ -n "$LOGIN_PID" ] && wait "$LOGIN_PID" 2>/dev/null
  LOGIN_PID=""
  GH_PID=""
  clear_clipboard_code "$code"

  if [ $unsupported -eq 1 ]; then
    say "❌ 確認用のコードをクリップボードにコピーできなかったため、ログインを中止しました（コードを画面に表示しないため）。"
    kv RESULT LOGIN_UNSUPPORTED
    return $EXIT_ACTION
  fi
  if [ $timed_out -eq 1 ]; then
    say "❌ 時間内にブラウザでの承認が完了しなかったため、ログインを中止しました。"
    kv RESULT LOGIN_TIMEOUT
    return $EXIT_ACTION
  fi
  if [ "$gh_rc" != "0" ]; then
    local lower
    lower=$(to_lower "$errtext")
    case "$lower" in
      *denied* | *cancel*)
        say "❌ ブラウザで承認がキャンセルされました。"
        kv RESULT LOGIN_DENIED
        return $EXIT_ACTION
        ;;
      *expired*)
        say "❌ 確認用のコードの有効期限が切れました。"
        kv RESULT LOGIN_EXPIRED
        return $EXIT_ACTION
        ;;
    esac
    if is_network_error "$errtext"; then
      say "❌ GitHub に接続できませんでした。インターネット接続を確認してください。"
      kv RESULT NETWORK_ERROR
      return $EXIT_FAIL
    fi
    say "❌ ログインに失敗しました。"
    if [ -n "$errtext" ]; then
      say "--- エラー内容 ---"
      printf '%s' "$errtext" | mask_secrets | sed -n '1,10p'
      say "------------------"
    fi
    kv RESULT LOGIN_FAILED
    return $EXIT_FAIL
  fi

  say "✅ GitHub へのログインが完了しました"
  report_auth logged_in
}

# -----------------------------------------------------------------------------
# 保存先の解決と検証
# -----------------------------------------------------------------------------
HOME_REAL=""
DEST=""
DEST_ERROR=""

# ホームディレクトリを確認する（固定のユーザー名やパスは使わない）
check_home() {
  if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then
    DEST_ERROR="ホームフォルダを確認できませんでした。"
    return 1
  fi
  HOME_REAL=$(cd -P "$HOME" 2>/dev/null && pwd -P) || HOME_REAL=""
  if [ -z "$HOME_REAL" ] || [ "$HOME_REAL" = "/" ]; then
    DEST_ERROR="ホームフォルダを確認できませんでした。"
    return 1
  fi
  return 0
}

# 入力を Clone 先のフルパスに変換する。
# 最後のフォルダ名が est-rouge-cms-demo でなければ、その中に est-rouge-cms-demo を作る。
resolve_dest() {
  local p="$1"
  DEST=""
  DEST_ERROR=""

  check_home || return 1

  if [ -z "$p" ]; then
    DEST_ERROR="保存先が指定されていません。"
    return 1
  fi
  case "$p" in
    *[[:cntrl:]]*)
      DEST_ERROR="保存先に改行などの特殊な文字が含まれています。"
      return 1
      ;;
  esac

  # 先頭の ~ をホームフォルダに置き換える
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="${HOME%/}/${p#\~/}" ;;
    "~"*)
      DEST_ERROR="「~ユーザー名」の形式は使えません。ご自身のホームフォルダ内の場所を指定してください。"
      return 1
      ;;
  esac

  case "$p" in
    /*) ;;
    *)
      DEST_ERROR="保存先は「/Users/…」または「~/…」のような完全な場所で指定してください（指定: ${p}）。"
      return 1
      ;;
  esac

  # 連続した / をまとめ、末尾の / を取り除く
  while :; do
    case "$p" in
      *//*) p="${p//\/\//\/}" ;;
      *) break ;;
    esac
  done
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done

  # 「.」「..」や隠しフォルダ（. で始まる名前）は使わない
  local rest="${p#/}" comp
  local old_ifs=$IFS
  IFS=/
  # shellcheck disable=SC2086
  set -f
  for comp in $rest; do
    case "$comp" in
      . | ..)
        IFS=$old_ifs; set +f
        DEST_ERROR="保存先に「.」や「..」は使えません。"
        return 1
        ;;
      .*)
        IFS=$old_ifs; set +f
        DEST_ERROR="隠しフォルダ（名前が「.」で始まるフォルダ）は保存先に使えません。"
        return 1
        ;;
    esac
  done
  set +f
  IFS=$old_ifs

  if [ "${p##*/}" != "$REPO_DIRNAME" ]; then
    p="${p%/}/${REPO_DIRNAME}"
  fi

  local home="${HOME%/}"
  case "$p" in
    "$home"/*) ;;
    *)
      DEST_ERROR="保存先はホームフォルダ（${home}）の中にしてください（指定: ${p}）。"
      return 1
      ;;
  esac
  case "$p" in
    "$home/Library" | "$home/Library/"* | "$home/Applications" | "$home/Applications/"*)
      DEST_ERROR="「Library」「Applications」フォルダの中は保存先に使えません。"
      return 1
      ;;
  esac

  # 既にある一番近い親フォルダを探し、実際の場所（エイリアス等を解決した場所）を確認する
  local parent="${p%/*}"
  [ -z "$parent" ] && parent="/"
  local anc="$parent"
  while [ ! -e "$anc" ] && [ ! -L "$anc" ]; do
    anc="${anc%/*}"
    [ -z "$anc" ] && anc="/"
  done
  if [ ! -d "$anc" ]; then
    DEST_ERROR="保存先の途中「${anc}」がフォルダではありません。別の場所を指定してください。"
    return 1
  fi
  local anc_real
  anc_real=$(cd -P "$anc" 2>/dev/null && pwd -P) || anc_real=""
  case "$anc_real" in
    "$HOME_REAL" | "$HOME_REAL"/*) ;;
    *)
      DEST_ERROR="保存先「${anc}」は実際にはホームフォルダの外を指しています。別の場所を指定してください。"
      return 1
      ;;
  esac
  if [ ! -w "$anc_real" ]; then
    DEST_ERROR="「${anc}」に書き込む権限がありません。別の場所を指定してください。"
    return 1
  fi

  DEST="$p"
  return 0
}

# 保存先の状態を調べる（何も変更しない）
#   absent / empty / reuse / incomplete-repo / other-repo / broken-repo / plain-dir / not-directory
STATE=""
FOUND_REMOTE=""
MISSING_FILES=""

find_missing_files() {
  local dir="$1" f
  MISSING_FILES=""
  for f in $REQUIRED_FILES; do
    [ -f "${dir}/${f}" ] || MISSING_FILES="${MISSING_FILES:+${MISSING_FILES} }${f}"
  done
  [ -z "$MISSING_FILES" ]
}

dir_is_empty() {
  (
    shopt -s nullglob dotglob
    set -- "$1"/*
    [ $# -eq 0 ]
  )
}

inspect_dest() {
  local dest="$1"
  STATE=""
  FOUND_REMOTE=""
  MISSING_FILES=""

  if [ -L "$dest" ]; then
    STATE="not-directory"
    return 0
  fi
  if [ ! -e "$dest" ]; then
    STATE="absent"
    return 0
  fi
  if [ ! -d "$dest" ]; then
    STATE="not-directory"
    return 0
  fi
  if [ ! -r "$dest" ] || [ ! -x "$dest" ]; then
    STATE="plain-dir"
    return 0
  fi
  if dir_is_empty "$dest"; then
    STATE="empty"
    return 0
  fi
  if [ -e "${dest}/.git" ]; then
    local top dest_real
    dest_real=$(cd -P "$dest" 2>/dev/null && pwd -P) || dest_real=""
    top=$(git -C "$dest" rev-parse --show-toplevel 2>/dev/null) || top=""
    if [ -z "$top" ] || [ "$top" != "$dest_real" ]; then
      STATE="broken-repo"
      return 0
    fi
    # insteadOf などで書き換えられない、設定上の値をそのまま読む
    FOUND_REMOTE=$(git -C "$dest" config --get remote.origin.url 2>/dev/null) || FOUND_REMOTE=""
    if [ -n "$FOUND_REMOTE" ] && url_matches_repo "$FOUND_REMOTE"; then
      if find_missing_files "$dest"; then
        STATE="reuse"
      else
        STATE="incomplete-repo"
      fi
    else
      STATE="other-repo"
    fi
    return 0
  fi
  STATE="plain-dir"
  return 0
}

explain_state() {
  local dest="$1"
  case "$STATE" in
    absent)
      say "✅ 保存先「${dest}」はまだありません。ここに新しく Clone できます。"
      ;;
    empty)
      say "✅ 保存先「${dest}」は空のフォルダです。ここに Clone できます。"
      ;;
    reuse)
      say "✅ 保存先「${dest}」には、CMS が既に正しく Clone されています。このフォルダをそのまま使います。"
      ;;
    incomplete-repo)
      say "❌ 保存先「${dest}」は CMS のリポジトリですが、必要なファイルが見つかりません: ${MISSING_FILES}"
      say "   中身を変更しないため、ここで止めます。このフォルダはそのままにして、別の保存先を指定するか、担当者に相談してください。"
      ;;
    other-repo)
      say "❌ 保存先「${dest}」には、別の Git リポジトリがあります（接続先: ${FOUND_REMOTE:-なし}）。"
      say "   このフォルダは変更しません。別の保存先を指定してください。"
      ;;
    broken-repo)
      say "❌ 保存先「${dest}」には Git の管理情報がありますが、正しく読み取れませんでした。"
      say "   このフォルダは変更しません。別の保存先を指定してください。"
      ;;
    plain-dir)
      say "❌ 保存先「${dest}」には、既に別のファイルやフォルダが入っています。"
      say "   上書きしないため、ここで止めます。別の保存先を指定してください。"
      ;;
    not-directory)
      say "❌ 保存先「${dest}」には、フォルダではないもの（ファイルやエイリアス）があります。"
      say "   上書きしないため、ここで止めます。別の保存先を指定してください。"
      ;;
  esac
}

# plan / clone / verify 共通の前処理。成功時に DEST と STATE が決まる。
prepare() {
  local input="$1"
  if ! is_macos; then
    say "❌ このパソコンは macOS ではないようです。現在この手順は Mac のみに対応しています。"
    kv RESULT UNSUPPORTED_OS
    return $EXIT_ACTION
  fi
  if ! has_git; then
    say "❌ Git が見つかりません。先に「check」で準備状況を確認してください。"
    kv RESULT NEED_INSTALL
    kv MISSING git
    return $EXIT_ACTION
  fi
  if ! resolve_dest "$input"; then
    say "❌ ${DEST_ERROR}"
    kv RESULT INVALID_DEST
    return $EXIT_DEST
  fi
  inspect_dest "$DEST"
  return $EXIT_OK
}

state_is_usable() {
  case "$STATE" in
    absent | empty | reuse) return 0 ;;
  esac
  return 1
}

report_repo_status() {
  local dest="$1" branch changes line
  branch=$(git -C "$dest" symbolic-ref --short -q HEAD 2>/dev/null) || branch=""
  changes=0
  # --no-optional-locks: 確認のためだけに管理情報を書き換えない
  while IFS= read -r line; do
    changes=$((changes + 1))
  done < <(git --no-optional-locks -C "$dest" status --porcelain 2>/dev/null)
  kv BRANCH "${branch:-unknown}"
  kv LOCAL_CHANGES "$changes"
  if [ "$changes" -gt 0 ]; then
    say "ℹ️ このフォルダには、まだ保存（コミット）されていない変更が ${changes} 件あります。消さずにそのまま残しています。"
  fi
}

# Clone 後の確認（何も変更しない）
verify_clone() {
  local dest="$1"
  local ok=0 remote
  if [ ! -d "$dest" ] || [ ! -e "${dest}/.git" ]; then
    say "❌ 「${dest}」に Clone されたフォルダが見つかりません。"
    return 1
  fi
  remote=$(git -C "$dest" config --get remote.origin.url 2>/dev/null) || remote=""
  if [ -n "$remote" ] && url_matches_repo "$remote"; then
    say "✅ 接続先: ${remote}"
  else
    say "❌ 接続先が CMS のリポジトリではありません（接続先: ${remote:-なし}）"
    ok=1
  fi
  if find_missing_files "$dest"; then
    say "✅ CMS に必要なファイルがそろっています"
  else
    say "❌ CMS に必要なファイルが見つかりません: ${MISSING_FILES}"
    ok=1
  fi
  return $ok
}

# -----------------------------------------------------------------------------
# suggest / plan / verify / clone
# -----------------------------------------------------------------------------
cmd_suggest() {
  if ! check_home; then
    say "❌ ${DEST_ERROR}"
    kv RESULT INVALID_DEST
    return $EXIT_DEST
  fi
  local d="${HOME%/}/${DEFAULT_PARENT_NAME}/${REPO_DIRNAME}"
  say "おすすめの保存先: ${d}"
  kv SUGGESTED_DEST "$d"
  return $EXIT_OK
}

cmd_plan() {
  local rc
  prepare "${1-}"
  rc=$?
  [ $rc -eq 0 ] || return $rc
  explain_state "$DEST"
  kv DEST "$DEST"
  kv STATE "$STATE"
  if state_is_usable; then
    kv RESULT OK
    return $EXIT_OK
  fi
  kv RESULT DEST_CONFLICT
  return $EXIT_DEST
}

cmd_verify() {
  local rc
  prepare "${1-}"
  rc=$?
  [ $rc -eq 0 ] || return $rc
  kv DEST "$DEST"
  if verify_clone "$DEST"; then
    report_repo_status "$DEST"
    kv RESULT VERIFIED
    return $EXIT_OK
  fi
  kv RESULT VERIFY_FAILED
  return $EXIT_FAIL
}

explain_clone_error() {
  local err
  err=$(to_lower "$1")
  case "$err" in
    *"could not resolve host"* | *"failed to connect"* | *"connection timed out"* | *"network is unreachable"* | *"operation timed out"*)
      say "原因: インターネットに接続できませんでした。"
      say "対処: Wi-Fi などの接続を確認してから、もう一度 /setup-workspace を実行してください。"
      ;;
    *"repository not found"* | *"authentication failed"* | *"could not read username"* | *"permission denied (publickey)"* | *"access denied"* | *"403"*)
      say "原因: GitHub のアカウントに、このリポジトリを取得する権限がないようです。"
      say "対処: ログイン中のアカウントが正しいか確認し、必要なら管理者にリポジトリへの招待を依頼してください。"
      ;;
    *"no space left"*)
      say "原因: Mac の空き容量が足りません。"
      say "対処: 不要なファイルを整理して空き容量を増やしてから、もう一度実行してください。"
      ;;
    *"permission denied"* | *"operation not permitted"* | *"read-only file system"*)
      say "原因: 保存先のフォルダに書き込めませんでした。"
      say "対処: ホームフォルダ内の別の場所（例: ~/${DEFAULT_PARENT_NAME}）を指定してください。"
      ;;
    *"already exists and is not an empty directory"*)
      say "原因: 保存先に別のファイルが作られていました。"
      say "対処: 中身を確認し、別の保存先を指定してください（このフォルダは変更していません）。"
      ;;
    *)
      say "原因: 予期しないエラーが発生しました。"
      say "対処: 時間をおいてもう一度実行してください。解決しない場合は、下のエラー内容を担当者に伝えてください。"
      ;;
  esac
}

cmd_clone() {
  local rc
  prepare "${1-}"
  rc=$?
  [ $rc -eq 0 ] || return $rc
  explain_state "$DEST"
  kv DEST "$DEST"
  kv STATE "$STATE"

  case "$STATE" in
    reuse)
      if verify_clone "$DEST"; then
        report_repo_status "$DEST"
        say "ℹ️ 既存のフォルダは更新（Pull）していません。最新化は CMS の Skill に任せてください。"
        kv RESULT REUSED
        return $EXIT_OK
      fi
      kv RESULT VERIFY_FAILED
      return $EXIT_FAIL
      ;;
    absent | empty) ;;
    *)
      kv RESULT DEST_CONFLICT
      return $EXIT_DEST
      ;;
  esac

  if ! has_gh; then
    say "❌ GitHub CLI（gh）が見つかりません。先に「check」で準備状況を確認してください。"
    kv RESULT NEED_INSTALL
    kv MISSING gh
    return $EXIT_ACTION
  fi

  # 足りない親フォルダを作る（失敗時は、作った空のフォルダだけを片付ける）
  local parent created d
  parent="${DEST%/*}"
  created=""
  d="$parent"
  while [ ! -e "$d" ]; do
    created="${d}
${created}"
    d="${d%/*}"
  done
  if ! mkdir -p "$parent" 2>/dev/null; then
    say "❌ 保存先のフォルダ「${parent}」を作成できませんでした。"
    say "対処: ホームフォルダ内の別の場所を指定してください。"
    kv RESULT CLONE_FAILED
    return $EXIT_FAIL
  fi

  say "⏳ Clone しています: ${REPO_URL} → ${DEST}"
  local err
  # - GIT_TERMINAL_PROMPT=0: パスワード入力待ちで止まらないようにする
  # - 認証は gh のログイン情報を一時的に使う（Git の設定ファイルは変更しない）
  err=$(GIT_TERMINAL_PROMPT=0 git \
    -c credential.helper= \
    -c 'credential.helper=!gh auth git-credential' \
    clone --quiet -- "$REPO_URL" "$DEST" 2>&1 >/dev/null)
  rc=$?

  if [ $rc -ne 0 ]; then
    say "❌ Clone に失敗しました。"
    explain_clone_error "$err"
    if [ -n "$err" ]; then
      say "--- エラー内容 ---"
      printf '%s\n' "$err" | sanitize | sed -n '1,15p'
      say "------------------"
    fi
    # 今回作った空の親フォルダだけを片付ける（rmdir は空でないフォルダを消さない）
    local line
    while IFS= read -r line; do
      [ -n "$line" ] && rmdir "$line" 2>/dev/null
    done < <(printf '%s' "$created" | sed '1!G;h;$!d')
    if [ "$STATE" = absent ] && [ -e "$DEST" ]; then
      say "ℹ️ 途中まで作られたフォルダ「${DEST}」が残っています。中身を確認のうえ、不要ならご自身で削除してください。"
    fi
    kv RESULT CLONE_FAILED
    return $EXIT_FAIL
  fi

  say "✅ Clone が完了しました"
  if verify_clone "$DEST"; then
    report_repo_status "$DEST"
    kv RESULT CLONED
    return $EXIT_OK
  fi
  say "❌ Clone はできましたが、内容の確認に失敗しました。フォルダは削除せずに残しています。"
  say "対処: 担当者に上の内容を伝えてください。"
  kv RESULT VERIFY_FAILED
  return $EXIT_FAIL
}

usage() {
  cat <<'EOF'
使い方:
  bash setup.sh check            環境を確認する
  bash setup.sh accounts         ログイン済みの GitHub アカウントを表示する
  bash setup.sh switch <名前>    ログイン済みの別アカウントに切り替える（承認後に実行）
  bash setup.sh login            ブラウザで GitHub にログインする（承認後に実行）
  bash setup.sh suggest          おすすめの保存先を表示する
  bash setup.sh plan  <保存先>   保存先を確認する（変更しない）
  bash setup.sh clone <保存先>   Clone する（正しい Clone が既にあれば再利用）
  bash setup.sh verify <保存先>  Clone 済みフォルダを確認する（変更しない）
EOF
}

main() {
  local sub="${1-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    check) [ $# -eq 0 ] || { usage; return $EXIT_USAGE; }; cmd_check ;;
    accounts) [ $# -eq 0 ] || { usage; return $EXIT_USAGE; }; cmd_accounts ;;
    switch) [ $# -eq 1 ] || { usage; return $EXIT_USAGE; }; cmd_switch "$1" ;;
    login) [ $# -eq 0 ] || { usage; return $EXIT_USAGE; }; cmd_login ;;
    suggest) [ $# -eq 0 ] || { usage; return $EXIT_USAGE; }; cmd_suggest ;;
    plan) [ $# -eq 1 ] || { usage; return $EXIT_USAGE; }; cmd_plan "$1" ;;
    clone) [ $# -eq 1 ] || { usage; return $EXIT_USAGE; }; cmd_clone "$1" ;;
    verify) [ $# -eq 1 ] || { usage; return $EXIT_USAGE; }; cmd_verify "$1" ;;
    help | -h | --help) usage; return $EXIT_OK ;;
    *) usage; return $EXIT_USAGE ;;
  esac
}

main "$@"
exit $?
