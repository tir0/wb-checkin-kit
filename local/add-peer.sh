#!/bin/bash
# ==============================================================================
# 导入一个他人账号（仓库主侧，在本机执行）
# ==============================================================================
# 对方跑完 local/join.sh 后会把一个「分享文件」发给你，本脚本负责：
#   1. 校验分享文件结构 + 账号标识（防路径穿越：slug 只允许 [a-z0-9_-]）
#   2. 先解密验证一遍 —— 文件与密钥不匹配、密文损坏，都在这一步拦住
#   3. 再调接口验证该凭据当前可用（401 直接拒绝，不让死凭据进仓库）
#   4. 落盘到 state/peers/<slug>.enc，并在本机登记簿里记下它的密钥
#   5. 把完整的 WB_PEER_KEYS 复制到剪贴板（不打印明文），提示去更新 Secret
#   6. 默认提交并推送（--no-push 可只落盘）
#
# 用法：
#   bash local/add-peer.sh ~/Downloads/wb-checkin-alice-20260922.json
#   bash local/add-peer.sh <文件> --as alice           # 改名
#   bash local/add-peer.sh <文件> --key <64位hex>      # 对方用 --split 时单独给的密钥
#   bash local/add-peer.sh <文件> --no-push            # 只落盘不推送
#   bash local/add-peer.sh <文件> --offline            # 跳过接口校验（离线/排障）
#   bash local/add-peer.sh --list                      # 看已导入的账号与密钥齐备情况
#   bash local/add-peer.sh --remove alice              # 移除账号
#
# 为什么密钥集中在你手里
#   云端要解开每个人的快照才能签到，所以密钥必须进仓库 Secret。但你拿到的是
#   「加密用的密钥」，不是对方的登录凭据本身；且一人一钥 —— 某个账号的分享
#   文件泄露，也只能解开他自己那一份。移除账号时请同时更新 Secret。
# ==============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

STATE_DIR="${WB_STATE_DIR:-$HOME/.wb-checkin}"
REG_FILE="$STATE_DIR/peer-keys.json"     # 本机密钥登记簿（600，只在本机）
PEER_DIR_REL="state/peers"
STATUS_URL="${WB_STATUS_URL:-https://copilot.tencent.com/v2/billing/meter/checkin-activity-status}"

SHARE_ARG=""
AS_SLUG=""
KEY_ARG=""
NO_PUSH=0
OFFLINE=0
MODE="add"

say() { printf '%s\n' "$*"; }
die() { say "✗ $*"; exit 1; }
warn() { say "⚠ $*"; }

# remote → 网页地址（与 install.sh 里同一套推导，避免写死仓库）
web_url_of() {
  case "$1" in
    git@*:*)     printf 'https://%s' "$(printf '%s' "$1" | sed -e 's/^git@//' -e 's/:/\//')" ;;
    ssh://git@*) printf 'https://%s' "$(printf '%s' "$1" | sed -e 's|^ssh://git@||')" ;;
    https://*|http://*) printf '%s' "$1" ;;
    *)           printf '' ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --as)      shift; AS_SLUG="${1:-}" ;;
    --as=*)    AS_SLUG="${1#*=}" ;;
    --key)     shift; KEY_ARG="${1:-}" ;;
    --key=*)   KEY_ARG="${1#*=}" ;;
    --no-push) NO_PUSH=1 ;;
    --offline) OFFLINE=1 ;;
    --list)    MODE="list" ;;
    --remove)  shift; MODE="remove"; AS_SLUG="${1:-}" ;;
    --remove=*) MODE="remove"; AS_SLUG="${1#*=}" ;;
    -h|--help) sed -n '2,34p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)        die "未知参数：$1（--help 看用法）" ;;
    *)         SHARE_ARG="$1" ;;
  esac
  shift
done

for cmd in jq openssl curl git; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖：${cmd}（jq 可用 brew install jq 安装）"
done
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
OPENSSL_BIN="$(command -v openssl)"

[ -d "$REPO_DIR/.git" ] || die "$REPO_DIR 不是 git 仓库（本脚本要写 state/peers/ 并推送）"

mkdir -p "$STATE_DIR" "$REPO_DIR/$PEER_DIR_REL"
chmod 700 "$STATE_DIR"

# 登记簿读写（没有就建空对象）
reg_get() { [ -f "$REG_FILE" ] && jq -r --arg k "$1" '.[$k] // empty' "$REG_FILE" 2>/dev/null || true; }
reg_all() { [ -f "$REG_FILE" ] && jq -c '.' "$REG_FILE" 2>/dev/null || echo '{}'; }

valid_slug() {
  printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9_-]{0,31}$'
}

WEB_URL="$(web_url_of "$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)")"
WEB_URL="${WEB_URL%.git}"

# 密钥变更后统一收尾：落盘登记簿 + 复制到剪贴板 + 打印 Secret 更新指引
finish_keys() {
  local tmp
  tmp="$(mktemp)"
  reg_all | jq '.' >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$REG_FILE"
  chmod 600 "$REG_FILE"

  if command -v pbcopy >/dev/null 2>&1; then
    jq -c '.' "$REG_FILE" | pbcopy
    say ""
    say "完整密钥 JSON 已复制到剪贴板（不打印明文）："
  else
    say ""
    say "把下面这条 JSON 整段填进 Secret（内容含密钥，注意别外传）："
  fi
  # 只显示账号名，值一律打码
  say "  $(jq -c 'with_entries(.value = "****")' "$REG_FILE")"
  say ""
  say "下一步：更新仓库 Secret WB_PEER_KEYS"
  if [ -n "$WEB_URL" ]; then
    say "  打开 ${WEB_URL}/settings/secrets/actions"
    say "  编辑 WB_PEER_KEYS → 直接粘贴（内容已在剪贴板）→ 保存"
  else
    say "  打开仓库 Settings → Secrets and variables → Actions → WB_PEER_KEYS"
  fi
}

# ---------------------------------------------------------------- --list
if [ "$MODE" = "list" ]; then
  say "=== 已导入账号（${PEER_DIR_REL}/）==="
  found=0
  for f in "$REPO_DIR/$PEER_DIR_REL"/*.enc; do
    [ -e "$f" ] || continue
    found=1
    slug="$(basename "$f" .enc)"
    key="$(reg_get "$slug")"
    extra=""
    if [ -n "$key" ]; then
      export LIST_KEY="$key"
      # 同样按退出码判定：错密钥时 openssl 会先吐垃圾再报错
      if plain="$("$OPENSSL_BIN" enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 \
            -in "$f" -pass env:LIST_KEY 2>/dev/null)"; then
        exp="$(printf '%s' "$plain" | jq -r '.token_expires_at_ms // empty' 2>/dev/null)"
        hook="$(printf '%s' "$plain" | jq -r 'if (.notify_webhook // "") == "" then "仓库兜底" else "自带机器人" end' 2>/dev/null)"
        if [ -n "$exp" ]; then
          days=$(( (exp / 1000 - $(date +%s)) / 86400 ))
          extra="｜凭据剩 ${days} 天｜通知：${hook}"
        else
          extra="｜通知：${hook}"
        fi
        plain=""
      else
        extra="｜⚠ 用登记簿里的密钥解不开（对方可能换过凭据，让他重发一份）"
      fi
      unset LIST_KEY
    else
      extra="｜⚠ 登记簿里没有密钥"
    fi
    say "  · ${slug}${extra}"
  done
  [ "$found" = "1" ] || say "  （空）"
  say ""
  say "登记簿：${REG_FILE}"
  # 双向核对：文件 ↔ 登记簿
  reg_keys="$(reg_all | jq -r 'keys[]' 2>/dev/null || true)"
  for k in $reg_keys; do
    [ -f "$REPO_DIR/$PEER_DIR_REL/${k}.enc" ] || warn "登记簿有 ${k}，但仓库里没有对应快照（请用 --remove ${k} 清理）"
  done
  exit 0
fi

# ---------------------------------------------------------------- --remove
if [ "$MODE" = "remove" ]; then
  slug="$AS_SLUG"
  valid_slug "$slug" || die "账号标识不合法：${slug:-（空）}"
  removed=0
  if [ -f "$REPO_DIR/$PEER_DIR_REL/${slug}.enc" ]; then
    rm -f "$REPO_DIR/$PEER_DIR_REL/${slug}.enc"
    say "已删除 ${PEER_DIR_REL}/${slug}.enc"
    removed=1
  fi
  if [ -n "$(reg_get "$slug")" ]; then
    tmp="$(mktemp)"; jq --arg k "$slug" 'del(.[$k])' "$REG_FILE" >"$tmp"
    chmod 600 "$tmp"; mv "$tmp" "$REG_FILE"; chmod 600 "$REG_FILE"
    say "已从登记簿移除 ${slug}"
    removed=1
  fi
  [ "$removed" = "1" ] || warn "没找到该账号：${slug}"

  if [ "$removed" = "1" ] && [ "$NO_PUSH" != "1" ]; then
    git -C "$REPO_DIR" add "$PEER_DIR_REL/${slug}.enc" >/dev/null 2>&1 || true
    if git -C "$REPO_DIR" diff --cached --quiet; then
      say "（快照文件已不在版本控制里，无需提交）"
    else
      git -C "$REPO_DIR" commit -q -m "chore: 移除多账号 ${slug} [skip ci]" \
        && git -C "$REPO_DIR" push -q origin HEAD 2>/dev/null \
        && say "已推送" || warn "提交/推送失败，请手动 git push"
    fi
  fi
  finish_keys
  exit 0
fi

# ---------------------------------------------------------------- 导入
[ -n "$SHARE_ARG" ] || die "用法：bash local/add-peer.sh <分享文件>（--help 看全部用法）"

TMP_DIR="$(mktemp -d)"; chmod 700 "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

# 1) 取到「分享内容」：可能是文件、直接粘的一行 base64、或 stdin
RAW="$TMP_DIR/raw.txt"
if [ "$SHARE_ARG" = "-" ]; then
  cat >"$RAW"
elif [ -f "$SHARE_ARG" ]; then
  cat "$SHARE_ARG" >"$RAW"
elif command -v base64 >/dev/null 2>&1; then
  printf '%s' "$SHARE_ARG" >"$RAW"      # 当作 --print 输出的一行 base64
else
  die "既不是文件也不是可识别的分享码：$SHARE_ARG"
fi

tr -d '\r' <"$RAW" >"$RAW.clean" && mv "$RAW.clean" "$RAW"

SLUG=""
KEY=""
ENC_B64=""

if jq -e '.enc_b64' "$RAW" >/dev/null 2>&1; then
  # 单文件模式
  SLUG="$(jq -r '.slug // empty' "$RAW")"
  KEY="$(jq -r '.key // empty' "$RAW")"
  ENC_B64="$(jq -r '.enc_b64 // empty' "$RAW")"
  say "[1/5] 已读取分享文件（单文件模式）"
elif grep -Eq '^[A-Za-z0-9+/=]+$' "$RAW" && [ "$(wc -l <"$RAW" | tr -d ' ')" = "1" ]; then
  # 可能是「--print 输出的 base64(JSON)」，也可能是 split 模式的纯密文
  if "$OPENSSL_BIN" base64 -d -A -in "$RAW" 2>/dev/null | jq -e '.enc_b64' >/dev/null 2>&1; then
    "$OPENSSL_BIN" base64 -d -A -in "$RAW" >"$TMP_DIR/share.json"
    SLUG="$(jq -r '.slug // empty' "$TMP_DIR/share.json")"
    KEY="$(jq -r '.key // empty' "$TMP_DIR/share.json")"
    ENC_B64="$(jq -r '.enc_b64 // empty' "$TMP_DIR/share.json")"
    say "[1/5] 已解析分享码（单文件模式）"
  else
    ENC_B64="$(cat "$RAW")"
    KEY="$KEY_ARG"
    SLUG="$AS_SLUG"
    say "[1/5] 已读取密文（--split 模式：密钥需用 --key 单独提供）"
  fi
else
  die "认不出这个分享内容（应为 join.sh 生成的文件、或它打印的一行分享码）"
fi

[ -n "$ENC_B64" ] || die "分享内容里没有密文"
[ -n "$KEY" ] || die "缺少密钥：请用 --key <64位hex> 提供（--split 模式），或改用单文件分享"
printf '%s' "$KEY" | grep -Eq '^[0-9a-fA-F]{32,128}$' || die "密钥格式不对（应为 openssl rand -hex 32 的 64 位十六进制）"

# 账号标识：以 --as 为准，其次用分享文件里的，最后退到随机名
[ -n "$AS_SLUG" ] && SLUG="$AS_SLUG"
[ -n "$SLUG" ] || SLUG="peer$(date +%m%d%H%M)"
SLUG="$(printf '%s' "$SLUG" | tr 'A-Z' 'a-z' | tr ' ' '-' | tr -cd 'a-z0-9_-')"
valid_slug "$SLUG" || die "账号标识不合法：${SLUG}（只能用 a-z 0-9 _ -，且以字母/数字开头）"

# 2) 解密验证：文件与密钥不匹配必须在这里拦住，而不是等云端静默失败
printf '%s' "$ENC_B64" | "$OPENSSL_BIN" base64 -d -A >"$TMP_DIR/credentials.enc" 2>/dev/null \
  || die "密文不是合法 base64（分享文件可能被改动或截断）"

export ADD_KEY="$KEY"
# ⚠️ 必须按【退出码】判定，不能只看有没有输出：用错密钥时 openssl 会先把
#    解密出的垃圾块写到 stdout，再以退出码 1 报 bad decrypt。若只看输出是否
#    为空，就会把「密钥不匹配」误报成「解密成功但内容不完整」——一个会把人
#    引向错误方向的提示。$() 的退出码就是里面命令的退出码，所以能这样判。
if ! PLAIN="$("$OPENSSL_BIN" enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 \
        -in "$TMP_DIR/credentials.enc" -pass env:ADD_KEY 2>/dev/null)"; then
  unset ADD_KEY
  die "解密失败：密钥与密文不匹配（或密文损坏）。请让对方重新发一份分享文件。"
fi
unset ADD_KEY
printf '%s' "$PLAIN" | jq -e '.access_token and .uid' >/dev/null 2>&1 \
  || die "密文能解开但不是预期内容（缺少 access_token / uid）。请让对方重发分享文件。"
say "[2/5] 解密验证通过（密钥与密文匹配）"

TOKEN="$(printf '%s' "$PLAIN" | jq -r '.access_token')"
UIDV="$(printf '%s' "$PLAIN" | jq -r '.uid')"
HOOK="$(printf '%s' "$PLAIN" | jq -r '.notify_webhook // empty')"
EXP="$(printf '%s' "$PLAIN" | jq -r '.token_expires_at_ms // empty')"
SNAP="$(printf '%s' "$PLAIN" | jq -r '.synced_at_utc // "-"')"

# 3) 接口验证：不让一个已经失效的凭据进仓库（否则要等云端跑失败才发现）
if [ "$OFFLINE" = "1" ]; then
  say "[3/5] 已跳过接口校验（--offline）"
else
  HTTP_CODE="$(curl -s -m 15 --noproxy '*' -o /dev/null -w '%{http_code}' \
    -X POST "$STATUS_URL" -K - <<CURL_CFG 2>/dev/null || echo "000"
header = "Authorization: Bearer ${TOKEN}"
header = "X-User-Id: ${UIDV}"
header = "Content-Type: application/json"
header = "Accept: application/json"
data = "{}"
CURL_CFG
)"
  if [ "$HTTP_CODE" = "401" ]; then
    die "该凭据已被服务端拒绝（HTTP 401）。请让对方重新登录桌面端后重跑 local/join.sh。"
  fi
  if [ "$HTTP_CODE" = "200" ]; then
    say "[3/5] 接口校验通过（HTTP 200）"
  else
    warn "接口校验未返回 200（HTTP=${HTTP_CODE}，可能是网络问题），仍继续导入。"
  fi
fi

# 4) 落盘
cp "$TMP_DIR/credentials.enc" "$REPO_DIR/$PEER_DIR_REL/${SLUG}.enc"
say "[4/5] 已写入 ${PEER_DIR_REL}/${SLUG}.enc"

tmp="$(mktemp)"
{ reg_all; } | jq --arg k "$SLUG" --arg v "$KEY" '. + {($k): $v}' >"$tmp"
chmod 600 "$tmp"; mv "$tmp" "$REG_FILE"; chmod 600 "$REG_FILE"
say "      已登记密钥（本机 ${REG_FILE}，权限 600）"

# 通知与有效期提示（不打印地址）
if [ -n "$HOOK" ]; then
  say "      通知：该账号自带机器人（回执会直接发给他）"
else
  say "      通知：该账号未带机器人 —— 将由仓库兜底 Secret WB_NOTIFY_WEBHOOK 接手（未设则静默，签到不受影响）"
fi
if [ -n "$EXP" ] && printf '%s' "$EXP" | grep -Eq '^[0-9]+$'; then
  DAYS=$(( (EXP / 1000 - $(date +%s)) / 86400 ))
  if [ "$DAYS" -lt 0 ]; then
    warn "该凭据显示已过期 ${DAYS#-} 天（接口却仍可用的话，说明 expiresAt 字段仅供参考）"
  else
    say "      凭据剩余有效期约 ${DAYS} 天（快照时间 ${SNAP}）"
  fi
fi

# 5) 提交推送
if [ "$NO_PUSH" = "1" ]; then
  say "[5/5] 已跳过提交/推送（--no-push）"
else
  git -C "$REPO_DIR" add "$PEER_DIR_REL/${SLUG}.enc"
  if git -C "$REPO_DIR" diff --cached --quiet; then
    say "[5/5] 快照内容与仓库一致，无需提交"
  elif git -C "$REPO_DIR" commit -q -m "chore: 导入多账号 ${SLUG} [skip ci]" \
       && git -C "$REPO_DIR" push -q origin HEAD 2>/dev/null; then
    say "[5/5] 已提交并推送"
  else
    warn "[5/5] 提交或推送失败 —— 请手动执行：git -C \"$REPO_DIR\" push origin HEAD"
  fi
fi

finish_keys
say ""
say "验证（可选但推荐）"
say "  到 Actions 页面点一次 Run workflow，看「多账号签到」步骤里 ${SLUG} 的结果；"
say "  或在本机直接跑一次（@ 后面是密钥登记簿，密钥不进命令行历史）："
say "    WB_PEER_KEYS=@$REG_FILE python3 scripts/wb_peers.py --only ${SLUG}"
say ""
say "之后每次沉淀"
say "  logs/runs.md 会一行一个账号地记录（账号列即 ${SLUG}）。"
say "  对方凭据过期时，通知会直接指名 ${SLUG}，你让他重跑 join.sh 即可。"
