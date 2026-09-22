#!/bin/bash
# ==============================================================================
# 加入一个已存在的签到仓库（他人账号侧，只需跑这一次）
# ==============================================================================
# 做这些事：
#   1. 检查依赖
#   2. 读本机 WorkBuddy 登录态（桌面端必须处于登录状态）
#   3. 先调接口验证凭据可用 —— 401 直接终止，不生成没用的分享文件
#   4. 为这个账号单独生成一把密钥（openssl rand -hex 32）
#   5. 加密凭据 → 产出一个「分享文件」，发给仓库主人即可
#
# 你不必拥有 GitHub 账号，也不必装任何常驻程序：签到这个动作由仓库主人的
# 云端任务完成，你只负责把「一次性的凭据副本」交给他。
#
# Windows 用户请看同目录的 join.ps1（等价实现，单文件、无需 WSL/openssl/jq）。
#
# 用法：
#   bash local/join.sh --name 你的昵称 --notify '钉钉/企微机器人地址'
#   bash local/join.sh --name alice                     # 不配通知也行
#   bash local/join.sh --name alice --split             # 密文与密钥分开送（更稳妥）
#   bash local/join.sh --name alice --print             # 额外打印一行可粘贴的分享码
#
# 关于安全（务必读一眼）
#   分享文件里同时装着「上了锁的箱子」（密文）和「钥匙」（密钥）。
#   · 默认模式：一个文件发出去，最省事；请只发给你信任的仓库主人，
#     发完把桌面上的文件删掉（对方收到后也用不着留着）。
#   · --split 模式：密文进文件、密钥只显示在屏幕上，你分两个渠道发
#     （例如文件走微信、密钥走另一个渠道）。多一步，但任何一个渠道泄露
#     都不足以解开凭据。
#
# 有效期
#   凭据是 JWT，实测 55 天失效；桌面端重新登录也可能顶掉旧凭据。
#   届时重跑本脚本，把新的分享文件发回即可（旧文件不用删，覆盖即可）。
# ==============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

CRED_FILE="${WB_CRED_FILE:-$HOME/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info}"
# 端点可覆盖：只为测试（tests/test_peer_join.sh 用本地桩）与将来换域名。
STATUS_URL="${WB_STATUS_URL:-https://copilot.tencent.com/v2/billing/meter/checkin-activity-status}"

NAME=""
NOTIFY=""
OUT_PATH=""
SPLIT=0
DO_PRINT=0
STATUS_ONLY=0
OFFLINE=0

say() { printf '%s\n' "$*"; }
die() { say "✗ $*"; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name)   shift; NAME="${1:-}" ;;
    --name=*) NAME="${1#*=}" ;;
    --notify) shift; NOTIFY="${1:-}" ;;
    --notify=*) NOTIFY="${1#*=}" ;;
    --out)    shift; OUT_PATH="${1:-}" ;;
    --out=*)  OUT_PATH="${1#*=}" ;;
    --split)  SPLIT=1 ;;
    --print)  DO_PRINT=1 ;;
    --status-only) STATUS_ONLY=1 ;;
    --offline) OFFLINE=1 ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "未知参数：$1（--help 看用法）" ;;
  esac
  shift
done

# ---------------------------------------------------------------- 依赖
for cmd in jq openssl curl shasum base64; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖：${cmd}（jq 可用 brew install jq 安装）"
done

# 与仓库主链路一致：优先用 Homebrew 的 OpenSSL 3.x，避免与云端 runner 的
# LibreSSL/OpenSSL 差异导致 PBKDF2 行为不一致。
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
OPENSSL_BIN="$(command -v openssl)"

say "=== 加入 WorkBuddy 自动签到（他人账号侧）==="
say ""

# ---------------------------------------------------------------- 1) 读凭据
[ -r "$CRED_FILE" ] || die "读不到本机登录态：$CRED_FILE
   请先打开 WorkBuddy 桌面端并完成登录，再重跑本脚本。"

ACCESS_TOKEN="$(jq -r '.auth.accessToken // empty' "$CRED_FILE" 2>/dev/null)"
WB_UID="$(jq -r '.account.uid // empty' "$CRED_FILE" 2>/dev/null)"
EXPIRES_AT="$(jq -r '.auth.expiresAt // 0' "$CRED_FILE" 2>/dev/null)"
ROTATED_AT="$(jq -r '.auth.lastRefreshTime // 0' "$CRED_FILE" 2>/dev/null)"

[ -n "$ACCESS_TOKEN" ] && [ "$ACCESS_TOKEN" != "null" ] || die "登录态里没有 accessToken，请重新登录桌面端。"
[ -n "$WB_UID" ] && [ "$WB_UID" != "null" ] || die "登录态里没有 uid，请重新登录桌面端。"
say "[1/4] 已读取本机登录态（不显示内容）"

# 账号标识：不给就用 uid 派生一个，仓库主那边可以用 --as 改名
if [ -z "$NAME" ]; then
  NAME="u$(printf '%s' "$WB_UID" | tr -d - | cut -c1-6)"
  say "      未指定 --name，自动取账号标识：${NAME}（仓库主可在导入时改名）"
else
  # 归一化：小写、空格转连字符、剔除非 [a-z0-9_-] 字符
  NAME="$(printf '%s' "$NAME" | tr 'A-Z' 'a-z' | tr ' ' '-' | tr -cd 'a-z0-9_-')"
fi
[ -n "$NAME" ] || die "账号标识为空，请用 --name 指定（只能用 a-z 0-9 _ -，如 --name alice）"

# ---------------------------------------------------------------- 2) 验证凭据
# 为什么先验证：一个过期的凭据交出去，对方要等到云端跑失败才知道，
# 那时还得再找你一轮。这里花一次请求就能提前拦住。
# 凭据用 stdin 配置传给 curl，不进 argv（ps 看不到）。
HTTP_CODE="000"
if [ "$OFFLINE" = "1" ]; then
  say "⚠ --offline：跳过凭据校验。仅用于离线演练，不要用它生成正式分享文件。"
else
  HTTP_CODE="$(curl -s -m 15 --noproxy '*' -o /dev/null -w '%{http_code}' \
    -X POST "$STATUS_URL" -K - <<CURL_CFG 2>/dev/null || echo "000"
header = "Authorization: Bearer ${ACCESS_TOKEN}"
header = "X-User-Id: ${WB_UID}"
header = "Content-Type: application/json"
header = "Accept: application/json"
data = "{}"
CURL_CFG
)"
fi

if [ "$OFFLINE" = "1" ]; then
  say "[2/4] 已跳过凭据校验（--offline）"
else
  if [ "$HTTP_CODE" = "401" ]; then
    die "凭据已被服务端拒绝（HTTP 401）。请确认桌面端处于登录状态（必要时退出重登）后重跑。"
  fi
  if [ "$HTTP_CODE" != "200" ]; then
    say "⚠ 凭据校验未返回 200（HTTP=${HTTP_CODE}，可能是网络问题）。"
    say "  网络恢复后建议重跑本脚本再验证一次；继续生成分享文件也可，但请留意云端首次运行结果。"
  else
    say "[2/4] 凭据校验通过（HTTP 200）"
  fi
fi

if [ "$STATUS_ONLY" = "1" ]; then
  say "      仅校验模式，未生成分享文件。"
  exit 0
fi

# ---------------------------------------------------------------- 3) 加密
KEY="$("$OPENSSL_BIN" rand -hex 32)"

TMP_DIR="$(mktemp -d)"
chmod 700 "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

jq -n \
  --arg t "$ACCESS_TOKEN" \
  --arg u "$WB_UID" \
  --arg w "$NOTIFY" \
  --arg r "$ROTATED_AT" \
  --arg e "$EXPIRES_AT" \
  --arg s "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg n "$NAME" \
  '{schema:2, peer_slug:$n, access_token:$t, uid:$u, notify_webhook:$w,
    token_rotated_at_ms:$r, token_expires_at_ms:$e, synced_at_utc:$s}' \
  >"$TMP_DIR/plain.json"
chmod 600 "$TMP_DIR/plain.json"

# 密钥用环境变量交给 openssl（-pass env:），不进 argv —— ps 里看不到，
# 也不会写进任何本机配置。
export JOIN_KEY="$KEY"

"$OPENSSL_BIN" enc -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -salt \
  -in "$TMP_DIR/plain.json" -out "$TMP_DIR/credentials.enc" -pass "env:JOIN_KEY" \
  2>/dev/null || die "加密失败（openssl 版本异常？）"
say "[3/4] 已加密（AES-256-CBC / PBKDF2 20 万次）"
say "      密钥仅存在于本次生成结果中，不会写入本机任何配置"

# ---------------------------------------------------------------- 4) 产出分享文件
ENC_B64="$("$OPENSSL_BIN" base64 -A -in "$TMP_DIR/credentials.enc")"

STAMP="$(date '+%Y%m%d')"
[ -n "$OUT_PATH" ] || OUT_PATH="$HOME/Desktop/wb-checkin-${NAME}-${STAMP}.json"

if [ "$SPLIT" = "1" ]; then
  # 只把密文落文件，密钥单独显示
  printf '%s\n' "$ENC_B64" >"$OUT_PATH"
  chmod 600 "$OUT_PATH"
  say ""
  say "[4/4] 已生成「密文文件」："
  say "      ${OUT_PATH}"
  say ""
  say "      密钥（另一条渠道单独发给仓库主，别和文件走同一个渠道）："
  say "      ${KEY}"
  say ""
  say "      ⚠ 这串密钥只显示这一次，复制好再关窗口（本机不留副本）。"
else
  jq -n --arg v "1" --arg n "$NAME" --arg k "$KEY" --arg e "$ENC_B64" \
    --arg r "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{v:$v, slug:$n, key:$k, enc_b64:$e, created_at_utc:$r}' >"$OUT_PATH"
  chmod 600 "$OUT_PATH"
  say ""
  say "[4/4] 已生成分享文件："
  say "      ${OUT_PATH}"
fi

if [ "$DO_PRINT" = "1" ] && [ "$SPLIT" = "0" ]; then
  say ""
  say "      —— 分享码（不想传文件的话，把下面一整行发过去）——"
  "$OPENSSL_BIN" base64 -A -in "$OUT_PATH"
fi

say ""
say "接下来"
say "  1. 把上面这个文件发给仓库主人（微信传文件即可）。"
say "  2. 他导入后会更新仓库 Secret，之后你的账号就会跟着他的云端任务自动签到。"
if [ -n "$NOTIFY" ]; then
  say "  3. 通知：已配置你自己的机器人（签到回执会直接发给你）。"
else
  say "  3. 通知：未配置。想要每日回执，重跑本脚本并加 --notify '你的机器人地址'。"
fi
say ""
say "什么时候要重跑"
say "  凭据约 55 天后过期；桌面端重新登录也可能让旧凭据失效。"
say "  出现两种情况之一，重跑本脚本并把新文件发回去即可："
say "    · 你自己没再收到签到回执；"
say "    · 仓库主告诉你「该账号凭据已失效」。"
say ""
say "安全提醒"
say "  文件里含你的凭据密文（默认模式还含密钥），等同于把钥匙和箱子一起寄出。"
say "  只发给你信任的仓库主；发送后建议删除本机这份（rm '${OUT_PATH}'）。"
