#!/bin/bash
# ==============================================================================
# 一键安装：本机凭据同步器（launchd）
# ==============================================================================
# 做这些事：
#   1. 生成加密密钥（已存在则保留），并把密钥复制到剪贴板
#   2. pre-flight：用与同步器相同的 openssl 做一次加解密往返自检
#   3. 把同步器脚本复制到 ~/.wb-checkin/（TCC 允许 launchd 读取的位置）
#   4. 写入配置、准备独立工作副本（克隆私有仓库）
#   5. 安装并加载 launchd 任务，然后核对真实退出码
#   6. 打印剩下的手工步骤（把密钥填进 GitHub Secret）
#
# 幂等：可重复运行，不会重置密钥，也不会重复克隆。
# 卸载：bash local/install.sh --uninstall
# ==============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

LABEL="com.user.wb-checkin-sync"
STATE_DIR="$HOME/.wb-checkin"
WORK_DIR="$STATE_DIR/repo"
KEY_FILE="$STATE_DIR/key"
CONF_FILE="$STATE_DIR/config"
INSTALLED_SCRIPT="$STATE_DIR/wb-sync-credentials.sh"
CRED_FILE="$HOME/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info"
PLIST_SRC="$SELF_DIR/$LABEL.plist.template"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"

say() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------- 卸载
if [ "${1:-}" = "--uninstall" ]; then
  say "=== 卸载凭据同步器 ==="
  launchctl bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 && say "  已停止并移除 launchd 任务" || say "  任务本来就没在跑"
  rm -f "$PLIST_DST" && say "  已删除 $PLIST_DST"
  say ""
  say "  状态目录 $STATE_DIR 保留（含密钥与日志）。"
  say "  如需彻底清除：rm -rf $STATE_DIR"
  say "  （清除后记得同时删掉仓库 Secret WB_TOKEN_KEY 与 state/credentials.enc）"
  exit 0
fi

say "=== WorkBuddy 凭据同步器安装 ==="
say "仓库目录 : $REPO_DIR"
say ""

# 可选参数：--notify <webhook 地址> 直接把通知渠道写进本机配置。
# 地址会随凭据一起 AES 加密上传，不必再到 GitHub 上手工建 Secret。
NOTIFY_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --notify)   shift; NOTIFY_ARG="${1:-}" ;;
    --notify=*) NOTIFY_ARG="${1#*=}" ;;
  esac
  shift
done

[ -f "$SELF_DIR/wb-sync-credentials.sh" ] || { say "✗ 找不到同步器脚本"; exit 1; }
[ -f "$PLIST_SRC" ] || { say "✗ 找不到 $PLIST_SRC"; exit 1; }
[ -d "$REPO_DIR/.git" ] || { say "✗ $REPO_DIR 不是 git 仓库"; exit 1; }

for cmd in jq openssl git curl pbcopy; do
  command -v "$cmd" >/dev/null 2>&1 || { say "✗ 缺少依赖：$cmd"; exit 1; }
done

mkdir -p "$STATE_DIR" "$HOME/Library/LaunchAgents"
chmod 700 "$STATE_DIR"

# ---------------------------------------------------------------- 1) 密钥
if [ -s "$KEY_FILE" ]; then
  say "[1/6] 密钥已存在，保持不变：$KEY_FILE"
else
  openssl rand -hex 32 >"$KEY_FILE"
  chmod 600 "$KEY_FILE"
  say "[1/6] 已生成新密钥：${KEY_FILE}（权限 600）"
fi
pbcopy <"$KEY_FILE"
say "      密钥已复制到剪贴板（未在屏幕上显示）"

# ---------------------------------------------------------------- 2) pre-flight
# 用与同步器相同的 openssl 做一次真实往返，避免「装完了才发现解不开」。
OPENSSL_BIN="$(PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" command -v openssl)"
PROBE="$(mktemp -d)"
chmod 700 "$PROBE"
printf '{"probe":"roundtrip"}' >"$PROBE/a.json"
if "$OPENSSL_BIN" enc -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -salt \
     -in "$PROBE/a.json" -out "$PROBE/a.enc" -pass "file:$KEY_FILE" 2>/dev/null \
   && "$OPENSSL_BIN" enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 \
     -in "$PROBE/a.enc" -pass "file:$KEY_FILE" >"$PROBE/b.json" 2>/dev/null \
   && cmp -s "$PROBE/a.json" "$PROBE/b.json"; then
  say "[2/6] 加解密自检通过（$("$OPENSSL_BIN" version 2>/dev/null)）"
else
  say "[2/6] ✗ 加解密自检失败，请检查 openssl 版本"
  rm -rf "$PROBE"
  exit 1
fi
rm -rf "$PROBE"

# ---------------------------------------------------------------- 3) 安装脚本副本
# macOS TCC 会拦掉 launchd 对 ~/Documents 的访问，所以脚本必须放在允许的位置。
# 改动 local/wb-sync-credentials.sh 后重新运行本脚本即可更新。
cp "$SELF_DIR/wb-sync-credentials.sh" "$INSTALLED_SCRIPT"
chmod +x "$INSTALLED_SCRIPT"
say "[3/6] 同步器已安装到 $INSTALLED_SCRIPT"

# ---------------------------------------------------------------- 4) 配置与工作副本
BRANCH="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"
REPO_URL="$(git -C "$REPO_DIR" remote get-url origin)"
# 重装时保留已有的 notify_webhook，别把用户配好的通知渠道抹掉。
# --notify 优先级最高，可用于改地址。
EXISTING_NOTIFY="$(jq -r '.notify_webhook // empty' "$CONF_FILE" 2>/dev/null || true)"
NOTIFY_WEBHOOK="${NOTIFY_ARG:-$EXISTING_NOTIFY}"
if [ -n "$NOTIFY_WEBHOOK" ]; then
  jq -n --arg u "$REPO_URL" --arg b "$BRANCH" --arg w "$NOTIFY_WEBHOOK" \
    '{repo_url:$u, branch:$b, notify_webhook:$w}' >"$CONF_FILE"
else
  jq -n --arg u "$REPO_URL" --arg b "$BRANCH" '{repo_url:$u, branch:$b}' >"$CONF_FILE"
fi
chmod 600 "$CONF_FILE"
say "[4/6] 已写入配置（remote=$(printf '%s' "$REPO_URL" | sed 's#.*:##')，分支=${BRANCH}）"
if [ -n "$NOTIFY_WEBHOOK" ]; then
  say "      通知渠道已配置（$(_notify_kind_hint "$NOTIFY_WEBHOOK")）"
else
  say "      未配置通知渠道（想每天收回执：重跑本脚本并加 --notify <地址>）"
fi

if [ -d "$WORK_DIR/.git" ]; then
  git -C "$WORK_DIR" remote set-url origin "$REPO_URL"
  say "      独立工作副本已存在：$WORK_DIR"
else
  rm -rf "$WORK_DIR"
  if git clone -q --branch "$BRANCH" "$REPO_URL" "$WORK_DIR" 2>/dev/null; then
    git -C "$WORK_DIR" config user.name  'wb-checkin sync'
    git -C "$WORK_DIR" config user.email 'wb-checkin-sync@localhost'
    say "      已克隆独立工作副本：$WORK_DIR"
  else
    say "      ⚠ 克隆失败（网络或 SSH 问题），同步器会在下次运行时自行重试"
  fi
fi

# ---------------------------------------------------------------- 5) launchd
sed -e "s|__SCRIPT_PATH__|$INSTALLED_SCRIPT|g" \
    -e "s|__CRED_FILE__|$CRED_FILE|g" \
    -e "s|__STATE_DIR__|$STATE_DIR|g" \
    "$PLIST_SRC" >"$PLIST_DST"

launchctl bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || true
if launchctl bootstrap "gui/$UID_NUM" "$PLIST_DST" >/dev/null 2>&1; then
  say "[5/6] 任务已加载（launchctl bootstrap）"
elif launchctl load -w "$PLIST_DST" >/dev/null 2>&1; then
  say "[5/6] 任务已加载（launchctl load 回退）"
else
  say "[5/6] ⚠ 自动加载失败，请手动执行：launchctl load -w \"$PLIST_DST\""
fi

# 真正验证一次：不只看加载成功，还要看退出码
launchctl kickstart -k "gui/$UID_NUM/$LABEL" >/dev/null 2>&1
sleep 12
EXIT_CODE="$(launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null \
  | awk -F'= ' '/last exit code/ {print $2; exit}' | tr -d ' ')"
if [ "$EXIT_CODE" = "0" ]; then
  say "      首次运行退出码 0 ✓（同步日志：$STATE_DIR/sync.log）"
else
  say "      ⚠ 首次运行退出码 ${EXIT_CODE:-未知}，请看 $STATE_DIR/launchd.err.log 与 $STATE_DIR/sync.log"
fi

# ---------------------------------------------------------------- 6) 收尾
# 仓库网页地址从 remote 推导，不写死 —— 本项目会被分发给别人用（每人一个自己的仓库），
# 写死的话朋友会看到「作者仓库」的设置页，白填一个 Secret 到无关仓库上。
web_url_of() {
  case "$1" in
    git@*:*)     printf 'https://%s' "$(printf '%s' "$1" | sed -e 's/^git@//' -e 's/:/\//')" ;;
    ssh://git@*) printf 'https://%s' "$(printf '%s' "$1" | sed -e 's|^ssh://git@||')" ;;
    https://*|http://*) printf '%s' "$1" ;;
    *)           printf '' ;;
  esac
}
WEB_URL="$(web_url_of "$REPO_URL")"
WEB_URL="${WEB_URL%.git}"

say ""
say "[6/6] 还需要你在网页上做一步："
if [ -n "$WEB_URL" ]; then
  say "      打开 ${WEB_URL}/settings/secrets/actions"
  say "      New repository secret → Name 填  WB_TOKEN_KEY"
  say "      Secret 直接粘贴（密钥已在剪贴板里）"
  say ""
  say "      然后到 ${WEB_URL}/actions 点一次 Run workflow 验证。"
else
  say "      ⚠ 没读到仓库远程地址，请先给本仓库配 remote（git remote add origin …）后重跑。"
fi
say ""
say "通知（可选，不需要在 GitHub 上设任何东西）"
say "  本机配置 $CONF_FILE 里的 notify_webhook 字段会随凭据一起加密上传，"
say "  云端解密后自动注入，仓库里只有密文、Actions 日志里也会打码。"
say ""
say "  设置 / 修改地址："
say "      bash \"$SELF_DIR/install.sh\" --notify 'https://oapi.dingtalk.com/robot/send?access_token=...'"
say "  改完会自动立即生效（只改地址会绕过节流），无需再动 GitHub。"
say "  支持钉钉 / 企业微信（oapi.dingtalk.com、qyapi.weixin.qq.com）、Server 酱，"
say "  以及其他通用 JSON 渠道。不配就完全静默、不影响签到。"
say "  钉钉机器人注意：安全设置里的「自定义关键词」必须包含 签到，否则钉钉会以"
say "  errcode 310000 静默拒收（脚本能识别并如实记日志，不会报成已发送）。"
say ""
say "  也可以在 Settings → Secrets 里删掉不再使用的 WB_ACCESS_TOKEN / WB_UID。"
say ""
say "多账号（可选：帮朋友的账号一起签，对方不必有 GitHub 账号）"
say "  朋友在他自己机器上跑一次："
say "      bash local/join.sh --name alice --notify '<他自己的机器人地址>'"
say "  他把生成的分享文件发给你，你在本机导入："
say "      bash local/add-peer.sh ~/Downloads/wb-checkin-alice-*.json"
say "  脚本会自动落盘、把密钥 JSON 放进剪贴板并提示更新 Secret WB_PEER_KEYS。"
say "  两条链路互不影响：本机同步器（上面这套）仍然只服务你自己的账号。"
say "  详见仓库根目录 README.md 的「多账号」一节。"
say ""
say "常用命令"
say "  查看同步日志   tail -f $STATE_DIR/sync.log"
say "  手动同步一次   bash $INSTALLED_SCRIPT --force   （--force 绕过节流）"
say "  任务状态       launchctl print gui/$UID_NUM/$LABEL | grep -E 'state|last exit'"
say "  卸载           bash \"$SELF_DIR/install.sh\" --uninstall"
say ""
say "注意：你的 ~/Documents/GitHub/wb-checkin 工作副本不会自动跟随"
say "      （launchd 无权访问 ~/Documents），需要时自己 git pull 即可。"
