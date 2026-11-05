#!/bin/bash
# =============================================================================
# setup-workspace 補助スクリプト
#
# Est Rouge CMS（est-rouge-cms-demo）を編集者の Mac に Clone するまでを担当する。
# Claude Code の Skill「/setup-workspace」から呼び出される。
#
# 使い方:
#   bash setup.sh check            環境（macOS / CPU / 開発者ツール / Git / Homebrew / gh / ログイン / 権限）を確認
#   bash setup.sh install-clt      Apple の開発者ツール（Git を含む）を追加（利用者の承認後）
#   bash setup.sh install-brew     Homebrew 公式インストーラーを取得・確認して開く（利用者の承認後）
#   bash setup.sh install-gh       Homebrew で GitHub CLI を追加（利用者の承認後）
#   bash setup.sh wait <clt|brew>  インストールの完了を待つ（途中からの再開用）
#   bash setup.sh path-status      Homebrew が今後のターミナルでも使えるか確認（変更なし）
#   bash setup.sh persist-path     シェルの設定に brew shellenv を追記（必要な場合のみ・利用者の承認後）
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
#   - 既存のファイルやフォルダを削除・上書きしない（rm は自分で作った一時ファイルにだけ使う）
#   - 既存リポジトリに対して fetch / pull / reset / commit / push をしない
#   - インストールは install-* を明示的に呼んだときだけ行う。sudo は使わない
#     （管理者の確認は macOS の正式な画面に任せる）。インストール済みのものは入れ直さない
#   - ログアウトをしない
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
# 環境の検出
#
# - PATH に登録されていないだけのツールを「未導入」と誤判定しないよう、
#   Homebrew・Git・gh の標準の場所も探し、見つかればこのプロセスの PATH に加える
#   （brew shellenv が PATH に加える bin / sbin と同じ。設定ファイルは変更しない）
# - macOS の /usr/bin/git は、開発者ツールが未導入だと実行時にインストール画面を出すため、
#   開発者ツールの有無を先に確かめてから実行する
# - SYS_ROOT はシステムの場所の基準（通常は空 = 実際のルート）。テストでは一時フォルダを
#   指定し、実機の /opt/homebrew や /Library を見ないようにする
# -----------------------------------------------------------------------------
SYS_ROOT="${SETUP_WORKSPACE_ROOT:-}"
INSTALL_TIMEOUT="${SETUP_WORKSPACE_INSTALL_TIMEOUT:-540}"
POLL_INTERVAL="${SETUP_WORKSPACE_POLL_INTERVAL:-5}"
case "$INSTALL_TIMEOUT" in '' | *[!0-9]*) INSTALL_TIMEOUT=540 ;; esac
case "$POLL_INTERVAL" in '' | *[!0-9]* | 0) POLL_INTERVAL=5 ;; esac

# Homebrew 公式の macOS 用インストーラー（.pkg）の配布元と署名者（Apple Developer の Team ID）
readonly BREW_RELEASE_API="https://api.github.com/repos/Homebrew/brew/releases/latest"
readonly BREW_PKG_URL_PREFIX="https://github.com/Homebrew/brew/releases/download/"
readonly BREW_PKG_TEAM_ID="927JGANW46"

path_prepend() {
  case ":${PATH}:" in
    *":$1:"*) ;;
    *) PATH="$1${PATH:+:${PATH}}" ;;
  esac
  export PATH
}

is_macos() {
  [ "$(uname -s 2>/dev/null)" = "Darwin" ]
}

# 検出結果
CPU=""            # apple_silicon / intel
ARCH=""           # uname -m の値（arm64 / x86_64）
ROSETTA="no"      # Apple シリコンで Intel 用として動いているか
BREW_EXPECTED_PREFIX=""
CLT_OK=0
DEV_DIR=""
GIT_PATH=""
GIT_ON_PATH="no"
BREW_PATH=""
BREW_PREFIX=""
BREW_ON_PATH="no"
GH_PATH=""
GH_ON_PATH="no"
IS_ADMIN="unknown"
MANAGED="unknown"

detect_arch() {
  ARCH=$(uname -m 2>/dev/null) || ARCH=""
  if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then
    CPU="apple_silicon"
    [ "$ARCH" = "x86_64" ] && ROSETTA="yes"
    BREW_EXPECTED_PREFIX="${SYS_ROOT}/opt/homebrew"
  else
    CPU="intel"
    BREW_EXPECTED_PREFIX="${SYS_ROOT}/usr/local"
  fi
}

detect_clt() {
  CLT_OK=0
  DEV_DIR=$(xcode-select -p 2>/dev/null) || DEV_DIR=""
  if [ -n "$DEV_DIR" ] && [ -d "$DEV_DIR" ]; then
    CLT_OK=1
  fi
}

# 実際に動く git を探す（見つかった場所を PATH に加える）
detect_git() {
  GIT_PATH=""
  GIT_ON_PATH="no"
  local first cand
  first=$(command -v git 2>/dev/null) || first=""
  for cand in "$first" \
    "${SYS_ROOT}/Library/Developer/CommandLineTools/usr/bin/git" \
    "${DEV_DIR:+${DEV_DIR}/usr/bin/git}" \
    "${BREW_PREFIX:+${BREW_PREFIX}/bin/git}"; do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    # 開発者ツールがない状態で /usr/bin/git を実行すると、インストール画面が勝手に出てしまう
    if [ "$cand" = "${SYS_ROOT}/usr/bin/git" ] && [ $CLT_OK -ne 1 ]; then
      continue
    fi
    if "$cand" --version >/dev/null 2>&1; then
      GIT_PATH="$cand"
      [ "$cand" = "$first" ] && GIT_ON_PATH="yes"
      path_prepend "${cand%/*}"
      return 0
    fi
  done
  return 1
}

detect_brew() {
  BREW_PATH=""
  BREW_PREFIX=""
  BREW_ON_PATH="no"
  local first cand
  first=$(command -v brew 2>/dev/null) || first=""
  for cand in "$first" "${SYS_ROOT}/opt/homebrew/bin/brew" "${SYS_ROOT}/usr/local/bin/brew"; do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    BREW_PATH="$cand"
    [ "$cand" = "$first" ] && BREW_ON_PATH="yes"
    BREW_PREFIX=$("$cand" --prefix 2>/dev/null) || BREW_PREFIX=""
    if [ -z "$BREW_PREFIX" ] || [ ! -d "$BREW_PREFIX" ]; then
      BREW_PREFIX="${cand%/bin/brew}"
    fi
    # brew shellenv と同じく、このプロセスの PATH に bin と sbin を加える
    [ -d "${BREW_PREFIX}/sbin" ] && path_prepend "${BREW_PREFIX}/sbin"
    path_prepend "${BREW_PREFIX}/bin"
    path_prepend "${cand%/*}"
    return 0
  done
  return 1
}

detect_gh() {
  GH_PATH=""
  GH_ON_PATH="no"
  local first cand
  first=$(command -v gh 2>/dev/null) || first=""
  for cand in "$first" "${BREW_PREFIX:+${BREW_PREFIX}/bin/gh}" "${SYS_ROOT}/opt/homebrew/bin/gh" "${SYS_ROOT}/usr/local/bin/gh"; do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    if "$cand" --version >/dev/null 2>&1; then
      GH_PATH="$cand"
      [ "$cand" = "$first" ] && GH_ON_PATH="yes"
      path_prepend "${cand%/*}"
      return 0
    fi
  done
  return 1
}

detect_admin() {
  local groups g
  IS_ADMIN="unknown"
  groups=$(id -Gn 2>/dev/null) || return 0
  IS_ADMIN="no"
  for g in $groups; do
    [ "$g" = "admin" ] && IS_ADMIN="yes"
  done
}

# 学校・会社の管理（MDM）下にあるか（参考情報。判定できなければ unknown）
detect_managed() {
  local out
  MANAGED="unknown"
  out=$(profiles status -type enrollment 2>/dev/null) || return 0
  case "$out" in
    *"MDM enrollment: Yes"* | *"Enrolled via DEP: Yes"*) MANAGED="yes" ;;
    *"MDM enrollment: No"*) MANAGED="no" ;;
  esac
}

# まとめて検出する（macOS のときだけ呼ぶ）
detect_all() {
  detect_arch
  detect_clt
  detect_brew
  detect_git
  detect_gh
}

DETECTED=0
ensure_detected() {
  [ $DETECTED -eq 1 ] && return 0
  detect_all
  DETECTED=1
}
has_git() { ensure_detected; [ -n "$GIT_PATH" ]; }
has_gh() { ensure_detected; [ -n "$GH_PATH" ]; }

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

# Homebrew の bin が、今後開くターミナル（ログインシェル）でも使えるか
#   /etc/paths・/etc/paths.d（公式 .pkg は /etc/paths.d/homebrew を作る）か、
#   シェルの設定ファイルに brew shellenv / bin の場所が書かれていれば「使える」
PROFILE_FILE=""
brew_path_persisted() {
  local bin="${BREW_PREFIX}/bin" f line content
  for f in "${SYS_ROOT}/etc/paths" "${SYS_ROOT}"/etc/paths.d/*; do
    [ -f "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      [ "$line" = "$bin" ] && return 0
    done <"$f"
  done
  for f in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.zlogin" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.profile"; do
    [ -f "$f" ] || continue
    content=$(cat "$f" 2>/dev/null) || continue
    case "$content" in
      *"brew shellenv"* | *"${bin}"*) return 0 ;;
    esac
  done
  return 1
}

choose_profile_file() {
  case "${SHELL##*/}" in
    zsh | "") PROFILE_FILE="$HOME/.zprofile" ;;
    bash) PROFILE_FILE="$HOME/.bash_profile" ;;
    *) PROFILE_FILE="" ;;
  esac
}

# 既定の保存先に、正しい Clone が既にあるか
existing_default_clone() {
  [ -n "$GIT_PATH" ] || return 1
  resolve_dest "~/${DEFAULT_PARENT_NAME}" >/dev/null 2>&1 || return 1
  inspect_dest "$DEST"
  [ "$STATE" = "reuse" ]
}

# -----------------------------------------------------------------------------
# check: 環境確認（何も変更しない）
# -----------------------------------------------------------------------------
cmd_check() {
  say "== 準備状況の確認 =="

  if ! is_macos; then
    say "❌ このパソコンは macOS ではないようです。現在この手順は Mac のみに対応しています。"
    kv RESULT UNSUPPORTED_OS
    return $EXIT_ACTION
  fi
  detect_all
  detect_admin
  detect_managed

  local cpu_label="Intel"
  [ "$CPU" = "apple_silicon" ] && cpu_label="Apple シリコン"
  say "✅ Mac を確認しました（${cpu_label}）"
  [ "$ROSETTA" = "yes" ] && say "ℹ️ Intel 用の互換モード（Rosetta）で動いています"

  if [ $CLT_OK -eq 1 ]; then
    say "✅ Apple の開発者ツール（Command Line Tools）: 入っています"
  else
    say "❌ Apple の開発者ツール（Command Line Tools）: 入っていません"
  fi
  if [ -n "$GIT_PATH" ]; then
    say "✅ Git（ファイルの履歴を管理する道具）: 使えます（$(git --version 2>/dev/null)）"
  else
    say "❌ Git（ファイルの履歴を管理する道具）: 見つかりません"
  fi
  if [ -n "$BREW_PATH" ]; then
    say "✅ Homebrew（Mac 用のソフト追加ツール）: 使えます（${BREW_PREFIX}）"
    [ "$BREW_ON_PATH" = "no" ] && say "   ※ 入っていましたが、コマンドの検索先（PATH）に登録されていなかったため、この処理の中で補いました"
  else
    say "❌ Homebrew（Mac 用のソフト追加ツール）: 見つかりません"
  fi
  if [ -n "$GH_PATH" ]; then
    say "✅ GitHub CLI（gh）: 使えます（$(gh --version 2>/dev/null | sed -n '1p')）"
  else
    say "❌ GitHub CLI（gh）: 見つかりません"
  fi
  [ "$MANAGED" = "yes" ] && say "ℹ️ この Mac は学校・会社などの管理下にあります。インストールが制限されている場合があります"
  [ "$IS_ADMIN" = "no" ] && say "ℹ️ このユーザーは Mac の管理者ではありません。ソフトの追加には管理者の協力が必要な場合があります"

  kv OS macos
  kv CPU "$CPU"
  kv ARCH "$ARCH"
  kv ROSETTA "$ROSETTA"
  kv CLT "$([ $CLT_OK -eq 1 ] && echo installed || echo missing)"
  kv GIT "$([ -n "$GIT_PATH" ] && echo yes || echo no)"
  kv BREW "$([ -n "$BREW_PATH" ] && echo yes || echo no)"
  if [ -n "$BREW_PATH" ]; then
    kv BREW_PREFIX "$BREW_PREFIX"
    kv BREW_ON_PATH "$BREW_ON_PATH"
    kv BREW_PATH_PERSISTED "$(brew_path_persisted && echo yes || echo no)"
  fi
  kv GH "$([ -n "$GH_PATH" ] && echo yes || echo no)"
  kv IS_ADMIN "$IS_ADMIN"
  kv MANAGED "$MANAGED"

  # 足りないもの（MISSING）と、入れる順番（INSTALL_PLAN）
  local missing="" plan=""
  [ -n "$GIT_PATH" ] || missing="git"
  [ -n "$GH_PATH" ] || missing="${missing:+${missing},}gh"
  if [ -z "$GIT_PATH" ] || { [ -z "$GH_PATH" ] && [ -z "$BREW_PATH" ] && [ $CLT_OK -ne 1 ]; }; then
    plan="clt"
  fi
  if [ -z "$GH_PATH" ]; then
    [ -z "$BREW_PATH" ] && plan="${plan:+${plan},}brew"
    plan="${plan:+${plan},}gh"
  fi

  if [ -n "$plan" ]; then
    local brew_auto=yes
    [ "$CPU" = "apple_silicon" ] || brew_auto=no
    say "→ 次のソフトの追加が必要です（この順番で進めます）: ${plan}"
    kv MISSING "$missing"
    kv INSTALL_PLAN "$plan"
    kv BREW_AUTO_INSTALL "$brew_auto"
    kv NEXT "install-${plan%%,*}"
    kv RESULT NEED_INSTALL
    return $EXIT_ACTION
  fi

  if existing_default_clone; then
    kv EXISTING_CLONE "$DEST"
  fi
  report_auth
}

# -----------------------------------------------------------------------------
# ソフトの追加（Skill が利用者の承認を得てから、1 つずつ呼ぶ）
#
# - sudo は使わない。管理者の確認が必要な場合は macOS の正式な画面（インストーラー）に任せる
# - インストール済みのものは入れ直さない
# - 途中で止まっても、もう一度実行すれば続きから再開できる
# -----------------------------------------------------------------------------

# 指定した条件が満たされるまで待つ: wait_until <確認用の関数> <残り秒数>
wait_until() {
  local fn="$1" limit="$2" start=$SECONDS
  while :; do
    "$fn" && return 0
    [ $((SECONDS - start)) -ge "$limit" ] && return 1
    sleep "$POLL_INTERVAL"
  done
}

clt_ready() {
  detect_clt
  [ $CLT_OK -eq 1 ] && detect_git
}

brew_ready() {
  detect_brew && "$BREW_PATH" --version >/dev/null 2>&1
}

report_clt_ready() {
  say "✅ Apple の開発者ツールと Git が使えるようになりました（$(git --version 2>/dev/null)）"
  kv RESULT CLT_READY
  return $EXIT_OK
}

# install-clt: Apple の開発者ツール（Git を含む）を、macOS 標準の方法で追加する
cmd_install_clt() {
  if ! is_macos; then
    say "❌ このパソコンは macOS ではないようです。"
    kv RESULT UNSUPPORTED_OS
    return $EXIT_ACTION
  fi
  detect_all
  if [ $CLT_OK -eq 1 ] && [ -n "$GIT_PATH" ]; then
    say "ℹ️ Apple の開発者ツールは既に入っています。入れ直しはしません。"
    kv ACTION unchanged
    report_clt_ready
    return $?
  fi
  if [ $CLT_OK -ne 1 ] && [ -n "$GIT_PATH" ]; then
    say "ℹ️ Git は既に使えます（開発者ツールは Homebrew の追加時に必要になります）。"
  fi

  local out rc
  out=$(xcode-select --install 2>&1)
  rc=$?
  case "$(to_lower "$out")" in
    *"already installed"*)
      if clt_ready; then
        kv ACTION unchanged
        report_clt_ready
        return $?
      fi
      say "❌ 開発者ツールは入っているとのことですが、Git を確認できませんでした。"
      say "対処: Mac の「システム設定」→「一般」→「ソフトウェアアップデート」で更新を確認してください。"
      kv RESULT CLT_FAILED
      return $EXIT_FAIL
      ;;
  esac
  if [ $rc -ne 0 ]; then
    say "❌ 開発者ツールのインストールを開始できませんでした。"
    [ -n "$out" ] && printf '%s\n' "$out" | mask_secrets | sed -n '1,5p'
    say "学校や会社の Mac では、管理者によってインストールが制限されている場合があります。その場合は管理者に相談してください。"
    kv RESULT CLT_FAILED
    return $EXIT_FAIL
  fi
  kv ACTION install_requested
  say "🖥 画面に「コマンドライン・デベロッパツール」のインストール確認が表示されます。"
  say "   「インストール」を押し、利用許諾に「同意する」を選んでください。完了まで待っています（最大 $(((INSTALL_TIMEOUT + 59) / 60)) 分）。"
  wait_install clt
}

# wait <clt|brew>: インストールの完了を待つだけ（何も始めない）。途中から再開するときに使う
wait_install() {
  case "$1" in
    clt)
      if wait_until clt_ready "$INSTALL_TIMEOUT"; then
        report_clt_ready
        return $?
      fi
      say "⏳ まだ開発者ツールのインストールが終わっていません。"
      say "   画面の表示に従って進めてください。エラーが表示された場合や、確認画面が見当たらない場合は教えてください。"
      kv NEXT "wait clt"
      kv RESULT INSTALL_WAITING
      return $EXIT_ACTION
      ;;
    brew)
      if wait_until brew_ready "$INSTALL_TIMEOUT"; then
        report_brew_ready
        return $?
      fi
      say "⏳ まだ Homebrew のインストールが終わっていません。"
      say "   インストーラーの画面で最後まで進めてください。エラーが表示された場合や、画面を閉じてしまった場合は教えてください。"
      kv NEXT "wait brew"
      kv RESULT INSTALL_WAITING
      return $EXIT_ACTION
      ;;
  esac
  usage
  return $EXIT_USAGE
}

cmd_wait() {
  if ! is_macos; then
    kv RESULT UNSUPPORTED_OS
    return $EXIT_ACTION
  fi
  detect_all
  wait_install "$1"
}

BREW_PKG_DIR=""
report_brew_ready() {
  # インストールが終わったら、ダウンロードしたインストーラーを片付ける（自分で作ったファイルのみ）
  if [ -n "$BREW_PKG_DIR" ] && [ -f "${BREW_PKG_DIR}/Homebrew.pkg" ]; then
    rm -f "${BREW_PKG_DIR}/Homebrew.pkg"
    rmdir "$BREW_PKG_DIR" 2>/dev/null
  fi
  say "✅ Homebrew が使えるようになりました（${BREW_PREFIX}、$("$BREW_PATH" --version 2>/dev/null | sed -n '1p')）"
  kv BREW_PREFIX "$BREW_PREFIX"
  kv BREW_PATH_PERSISTED "$(brew_path_persisted && echo yes || echo no)"
  kv RESULT BREW_READY
  return $EXIT_OK
}

# ダウンロード済みのインストーラーが、Homebrew 公式の署名・Apple の公証を受けたものか確かめる
verify_brew_pkg() {
  local pkg="$1" sig gk
  sig=$(pkgutil --check-signature "$pkg" 2>&1) || return 1
  case "$sig" in
    *"Developer ID Installer:"*"(${BREW_PKG_TEAM_ID})"*) ;;
    *) return 1 ;;
  esac
  case "$sig" in
    *"Notarization: trusted by the Apple notary service"*) ;;
    *) return 1 ;;
  esac
  gk=$(spctl --assess --type install -vv "$pkg" 2>&1) || return 1
  case "$gk" in
    *accepted*"Notarized Developer ID"*) return 0 ;;
  esac
  return 1
}

# install-brew: Homebrew 公式のインストーラー（.pkg）を取得・確認し、macOS のインストーラーで開く
cmd_install_brew() {
  if ! is_macos; then
    say "❌ このパソコンは macOS ではないようです。"
    kv RESULT UNSUPPORTED_OS
    return $EXIT_ACTION
  fi
  detect_all
  detect_admin
  if [ -n "$BREW_PATH" ]; then
    say "ℹ️ Homebrew は既に入っています（${BREW_PREFIX}）。入れ直しはしません。"
    kv ACTION unchanged
    report_brew_ready
    return $?
  fi
  if [ "$CPU" != "apple_silicon" ]; then
    say "❌ この Mac（Intel）では、Homebrew をこの画面から自動で入れることができません。"
    say "   （Homebrew 公式の Mac 用インストーラーは Apple シリコン専用のため）"
    kv RESULT BREW_AUTO_UNSUPPORTED
    return $EXIT_ACTION
  fi
  if [ $CLT_OK -ne 1 ]; then
    say "❌ 先に Apple の開発者ツール（Command Line Tools）を入れる必要があります。"
    kv NEXT install-clt
    kv RESULT NEED_CLT
    return $EXIT_ACTION
  fi
  if [ "$IS_ADMIN" = "no" ]; then
    say "❌ このユーザーは Mac の管理者ではないため、Homebrew を入れることができません。"
    say "   学校や会社の Mac の場合は、管理者に相談してください。"
    kv RESULT NO_ADMIN
    return $EXIT_ACTION
  fi
  local tool
  for tool in curl pkgutil spctl open mktemp; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      say "❌ インストールに必要な Mac の機能（${tool}）が見つかりません。"
      kv RESULT BREW_INSTALL_FAILED
      return $EXIT_FAIL
    fi
  done

  local start=$SECONDS meta url
  say "⏳ Homebrew 公式の配布元から、インストーラーの情報を取得しています"
  if ! meta=$(curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 "$BREW_RELEASE_API" 2>&1); then
    say "❌ インストーラーの情報を取得できませんでした。インターネット接続を確認してください。"
    kv RESULT BREW_DOWNLOAD_FAILED
    return $EXIT_FAIL
  fi
  url=$(printf '%s\n' "$meta" | sed -nE 's#.*"browser_download_url"[[:space:]]*:[[:space:]]*"(https://github\.com/Homebrew/brew/releases/download/[A-Za-z0-9._-]+/Homebrew[A-Za-z0-9._-]*\.pkg)".*#\1#p' | sed -n '1p')
  case "$url" in
    "${BREW_PKG_URL_PREFIX}"*.pkg) ;;
    *)
      say "❌ 公式のインストーラーが見つかりませんでした。安全のため、何も実行せずに中止します。"
      kv RESULT BREW_DOWNLOAD_FAILED
      return $EXIT_FAIL
      ;;
  esac

  BREW_PKG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/setup-workspace-brew.XXXXXX") || BREW_PKG_DIR=""
  if [ -z "$BREW_PKG_DIR" ]; then
    say "❌ 一時的な作業場所を用意できませんでした。"
    kv RESULT BREW_INSTALL_FAILED
    return $EXIT_FAIL
  fi
  chmod 700 "$BREW_PKG_DIR"
  local pkg="${BREW_PKG_DIR}/Homebrew.pkg"
  say "⏳ インストーラーをダウンロードしています（150MB 程度。数分かかることがあります）"
  if ! curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --max-time 420 -o "$pkg" "$url" 2>/dev/null || [ ! -s "$pkg" ]; then
    rm -f "$pkg"
    rmdir "$BREW_PKG_DIR" 2>/dev/null
    say "❌ インストーラーをダウンロードできませんでした。何も実行していません。インターネット接続を確認して、もう一度お試しください。"
    kv RESULT BREW_DOWNLOAD_FAILED
    return $EXIT_FAIL
  fi
  if ! verify_brew_pkg "$pkg"; then
    rm -f "$pkg"
    rmdir "$BREW_PKG_DIR" 2>/dev/null
    say "❌ ダウンロードしたインストーラーが、Homebrew 公式の署名付きのものと確認できませんでした。安全のため、実行せずに削除しました。"
    kv RESULT BREW_VERIFY_FAILED
    return $EXIT_FAIL
  fi
  say "✅ インストーラーが Homebrew 公式のもの（Apple の確認済み）であることを確認しました"

  if ! open "$pkg" >/dev/null 2>&1; then
    say "❌ macOS のインストーラーを開けませんでした。"
    kv RESULT BREW_INSTALL_FAILED
    return $EXIT_FAIL
  fi
  kv ACTION installer_opened
  say "🖥 macOS の「インストーラー」が開きました。画面の指示に従って「続ける」「インストール」を押してください。"
  say "   途中で Mac のパスワード（または Touch ID）を求められます。これは macOS の正式な確認画面です。ご本人が入力してください（このチャットには入力しないでください）。"
  local remaining=$((INSTALL_TIMEOUT - (SECONDS - start)))
  [ $remaining -lt 30 ] && remaining=30
  INSTALL_TIMEOUT=$remaining
  wait_install brew
}

# install-gh: Homebrew で GitHub CLI を追加する
cmd_install_gh() {
  if ! is_macos; then
    say "❌ このパソコンは macOS ではないようです。"
    kv RESULT UNSUPPORTED_OS
    return $EXIT_ACTION
  fi
  detect_all
  if [ -n "$GH_PATH" ]; then
    say "ℹ️ GitHub CLI（gh）は既に入っています。入れ直しはしません。"
    say "✅ $(gh --version 2>/dev/null | sed -n '1p')"
    kv ACTION unchanged
    kv RESULT GH_READY
    return $EXIT_OK
  fi
  if [ -z "$BREW_PATH" ]; then
    say "❌ 先に Homebrew を入れる必要があります。"
    kv NEXT install-brew
    kv RESULT NEED_BREW
    return $EXIT_ACTION
  fi
  say "⏳ Homebrew で GitHub CLI（gh）を追加しています（1〜数分かかります）"
  local out rc
  out=$(HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1 "$BREW_PATH" install gh </dev/null 2>&1)
  rc=$?
  if detect_gh; then
    say "✅ GitHub CLI（gh）が使えるようになりました（$(gh --version 2>/dev/null | sed -n '1p')）"
    kv ACTION installed
    kv RESULT GH_READY
    return $EXIT_OK
  fi
  say "❌ GitHub CLI（gh）を追加できませんでした。"
  local lower
  lower=$(to_lower "$out")
  case "$lower" in
    *"already locked"* | *"another active homebrew"* | *"is locked"*)
      say "原因: Homebrew が別の処理を実行中です。"
      say "対処: 少し待ってから、もう一度お試しください。"
      kv RESULT BREW_BUSY
      ;;
    *"could not resolve host"* | *"failed to download"* | *"failed to connect"* | *"timed out"* | *"curl:"*)
      say "原因: インターネットに接続できなかったか、ダウンロードに失敗しました。"
      say "対処: 接続を確認して、もう一度お試しください（途中まで進んだ分は再利用されます）。"
      kv RESULT NETWORK_ERROR
      ;;
    *"permission denied"* | *"not writable"* | *"operation not permitted"*)
      say "原因: Homebrew のフォルダに書き込む権限がありません。"
      say "対処: Homebrew を入れたユーザーと違うユーザーの可能性があります。管理者に相談してください。"
      kv RESULT BREW_PERMISSION
      ;;
    *)
      say "原因: 予期しないエラーです（終了コード ${rc}）。もう一度お試しください。解決しない場合は下の内容を担当者に伝えてください。"
      kv RESULT GH_INSTALL_FAILED
      ;;
  esac
  if [ -n "$out" ]; then
    say "--- エラー内容（最後の部分） ---"
    printf '%s\n' "$out" | mask_secrets | tail -n 8
    say "--------------------------------"
  fi
  return $EXIT_FAIL
}

# path-status: Homebrew が今後のターミナルでも使えるか確認する（変更なし）
cmd_path_status() {
  is_macos || { kv RESULT UNSUPPORTED_OS; return $EXIT_ACTION; }
  detect_all
  if [ -z "$BREW_PATH" ]; then
    say "ℹ️ Homebrew は入っていません。"
    kv RESULT NO_BREW
    return $EXIT_ACTION
  fi
  choose_profile_file
  kv BREW_PREFIX "$BREW_PREFIX"
  kv PROFILE_FILE "$PROFILE_FILE"
  if brew_path_persisted; then
    say "✅ Homebrew は、今後開くターミナルでもそのまま使えます（設定の追加は不要です）"
    kv BREW_PATH_PERSISTED yes
  else
    say "ℹ️ Homebrew は、今後開くターミナルからは見つからない状態です"
    kv BREW_PATH_PERSISTED no
  fi
  kv RESULT OK
  return $EXIT_OK
}

readonly PROFILE_MARK_BEGIN="# >>> Est Rouge setup-workspace: Homebrew >>>"
readonly PROFILE_MARK_END="# <<< Est Rouge setup-workspace: Homebrew <<<"

# persist-path: シェルの設定ファイルに brew shellenv を 1 回だけ追記する（利用者の承認後）
cmd_persist_path() {
  is_macos || { kv RESULT UNSUPPORTED_OS; return $EXIT_ACTION; }
  detect_all
  if [ -z "$BREW_PATH" ]; then
    kv RESULT NO_BREW
    return $EXIT_ACTION
  fi
  if brew_path_persisted; then
    say "ℹ️ 既に設定されています。何も変更しません。"
    kv RESULT ALREADY_CONFIGURED
    return $EXIT_OK
  fi
  choose_profile_file
  if [ -z "$PROFILE_FILE" ]; then
    say "❌ お使いのシェル（${SHELL:-不明}）の設定には自動で対応していません。"
    kv RESULT UNSUPPORTED_SHELL
    return $EXIT_ACTION
  fi
  if [ -e "$PROFILE_FILE" ] && { [ ! -f "$PROFILE_FILE" ] || [ ! -w "$PROFILE_FILE" ]; }; then
    say "❌ 設定ファイル「${PROFILE_FILE}」に書き込めません。何も変更していません。"
    kv RESULT PERSIST_FAILED
    return $EXIT_FAIL
  fi
  # 既存の内容は変えず、末尾に追記するだけ（最後に改行がなければ補う）
  {
    if [ -s "$PROFILE_FILE" ] && [ -n "$(tail -c 1 "$PROFILE_FILE")" ]; then
      printf '\n'
    fi
    printf '\n%s\n' "$PROFILE_MARK_BEGIN"
    printf 'eval "$(%s shellenv)"\n' "${BREW_PREFIX}/bin/brew"
    printf '%s\n' "$PROFILE_MARK_END"
  } >>"$PROFILE_FILE" || {
    say "❌ 設定ファイル「${PROFILE_FILE}」に書き込めませんでした。"
    kv RESULT PERSIST_FAILED
    return $EXIT_FAIL
  }
  say "✅ 「${PROFILE_FILE}」の末尾に Homebrew の設定を追加しました（既存の内容は変更していません）"
  kv PROFILE_FILE "$PROFILE_FILE"
  kv RESULT PATH_PERSISTED
  return $EXIT_OK
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
  bash setup.sh install-clt      Apple の開発者ツール（Git）を追加する（承認後に実行）
  bash setup.sh install-brew     Homebrew を追加する（承認後に実行）
  bash setup.sh install-gh       GitHub CLI を追加する（承認後に実行）
  bash setup.sh wait <clt|brew>  インストールの完了を待つ
  bash setup.sh path-status      Homebrew の PATH 設定を確認する
  bash setup.sh persist-path     シェルの設定に Homebrew を追記する（承認後に実行）
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
    install-clt) [ $# -eq 0 ] || { usage; return $EXIT_USAGE; }; cmd_install_clt ;;
    install-brew) [ $# -eq 0 ] || { usage; return $EXIT_USAGE; }; cmd_install_brew ;;
    install-gh) [ $# -eq 0 ] || { usage; return $EXIT_USAGE; }; cmd_install_gh ;;
    wait)
      [ $# -eq 1 ] || { usage; return $EXIT_USAGE; }
      case "$1" in clt | brew) cmd_wait "$1" ;; *) usage; return $EXIT_USAGE ;; esac
      ;;
    path-status) [ $# -eq 0 ] || { usage; return $EXIT_USAGE; }; cmd_path_status ;;
    persist-path) [ $# -eq 0 ] || { usage; return $EXIT_USAGE; }; cmd_persist_path ;;
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
