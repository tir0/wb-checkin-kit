#!/bin/bash
# ==============================================================================
# WorkBuddy 签到凭据同步器（本机 → 私有仓库）
# ==============================================================================
# 为什么需要它
#   accessToken 是本机绑定的凭据，副本有保质期：JWT 实测 55 天失效，
#   且「凭证格式换代 / 重新登录」会让旧副本立即作废，所以不能「复制一次、
#   以后不管」。本脚本只做一件事：把最新凭据加密后提交到私有仓库，
#   供云端 Actions 解密使用。签到这个动作仍然完全在云端执行。
#
#   ⚠️ 但也不必高频推送。日常换发【不会】吊销旧 token —— 2026-09-21 实测
#   跨越 3.3 天的 8 份历史快照全部仍返回 HTTP 200。所以本脚本带推送节流
#   （MIN_PUSH_INTERVAL），否则仓库会被凭据提交淹没：清理前实测
#   52 个凭据提交占了总提交量的 66%。需要立即推送时加 --force。
#
# 为什么用独立工作副本（$STATE_DIR/repo）而不是直接用 ~/Documents 里的仓库
#   macOS 的 TCC 会拦掉 launchd 上下文对 ~/Documents 的访问（实测读取即报
#   "Operation not permitted"）。而凭据文件与 ~/.wb-checkin 是允许访问的。
#   因此本脚本在 ~/.wb-checkin/repo 维护一份独立克隆；
#   你的 ~/Documents/GitHub/wb-checkin 工作副本由你自己 git pull 保持同步。
#
# 由谁触发（见同目录 plist 模板）
#   RunAtLoad 登录时 / WatchPaths 凭据文件被改写时 / StartInterval 每 30 分钟兜底
#
# 通知配置（可选）
#   ~/.wb-checkin/config 里加一个 "notify_webhook" 字段即可，云端工作流解密
#   快照后会自动注入 NOTIFY_WEBHOOK，不需要在 GitHub 上手工设 Secret。
#   地址含机器人令牌、等同密钥，所以随密文一起走：不进日志、不进命令行。
#   只改地址（凭据没变）时会绕过节流立即推送，改完即生效。
#
# 安全约定
#   - 绝不在标准输出、日志、命令行参数中出现 accessToken / uid / 密钥 / 通知地址明文
#   - 密钥只存在于 ~/.wb-checkin/key（600）与仓库 Secret WB_TOKEN_KEY
#   - 仓库里只提交 AES-256-CBC 密文，无密钥不可解
#
# 退出码：0 正常（含「无需同步」「被节流跳过」）· 64 参数错误 · 其余见各分支日志
# ==============================================================================
set -uo pipefail

# launchd 的 PATH 极简（不含 Homebrew），这里显式补上。
# 优先用 Homebrew 的 OpenSSL 3.x：与 GitHub runner（Ubuntu + OpenSSL 3.x）
# 同族，避免 macOS 自带 LibreSSL 在 PBKDF2 细节上产生差异。
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# WorkBuddy 会话会注入一个坏代理（127.0.0.1:53647），会让 git 报 502；
# launchd 环境里通常没有，但为稳妥一律清掉。git 走 SSH 直连，不需要代理。
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy

# SSH 直连、不交互，避免 launchd 环境下卡住等待输入
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"

STATE_DIR="$HOME/.wb-checkin"
WORK_DIR="$STATE_DIR/repo"
CONF_FILE="$STATE_DIR/config"
KEY_FILE="$STATE_DIR/key"
HASH_FILE="$STATE_DIR/last.sha256"
LOG_FILE="$STATE_DIR/sync.log"
ENC_REL="state/credentials.enc"
CRED_FILE="$HOME/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info"
LOCK_MAX_AGE=120   # .git 下的 *.lock 超过这个秒数视为陈旧残留

# 推送节流：距上次成功推送不足这个秒数就跳过（默认 20 小时 ≈ 每天最多一次）。
# 依据：token 是 JWT 实测 55 天有效，且旧快照不因换发失效，
# 所以云端手里那份快照在两次推送之间始终可用。
MIN_PUSH_INTERVAL="${WB_MIN_PUSH_INTERVAL:-72000}"
case "$MIN_PUSH_INTERVAL" in ''|*[!0-9]*) MIN_PUSH_INTERVAL=72000 ;; esac
THROTTLE_FILE="$STATE_DIR/last_push.epoch"

# --force 绕过节流（排障时手动推一次用）。plist 无参调用，所以默认走节流。
FORCE=0
for _arg in "$@"; do
  case "$_arg" in
    --force|-f) FORCE=1 ;;
    *) printf '未知参数：%s\n用法：%s [--force]\n' "$_arg" "${0##*/}" >&2; exit 64 ;;
  esac
done

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"; }

# 告警出口。同步器的失败大多是静默的（launchd 后台跑、没人看日志），
# 而此时 Workflow 侧的签到链路还没拿到凭据、还没到能发通知的那一步 ——
# 于是「最需要通知的场景恰好没有通知」。这里的机器人地址成了唯一可用通道。
#
# 刻意做成「永不改变退出码、失败也只是一行日志」：通知是旁挂载荷，
# 它坏了不该把真正的失败原因掩盖掉。
# 渠道形态与 scripts/wb_core.py 保持一致（钉钉/企微/Server酱/通用 JSON）。
notify() {
  _hook="$1"; _title="$2"; _text="$3"
  [ -n "$_hook" ] || { log "  （未配置通知渠道，告警只写日志）"; return 0; }
  case "$_hook" in
    *qyapi.weixin.qq.com*)
      _body="$(printf '{"msgtype":"text","text":{"content":"%s\n%s"}}' "$_title" "$_text")" ;;
    *sctapi.ftqq.com*|*sc.ftqq.com*)
      _body="" ;;
    *)
      _body="$(printf '{"text":"%s\n%s"}' "$_title" "$_text")" ;;
  esac
  if [ -n "$_body" ]; then
    curl -s -m 10 --noproxy '*' -o /dev/null \
      -H 'Content-Type: application/json' -d "$_body" "$_hook" 2>/dev/null \
      || log "  （告警发送失败，详见 sync.log）"
  else
    curl -s -m 10 --noproxy '*' -o /dev/null \
      --data-urlencode "title=$_title" --data-urlencode "desp=$_text" "$_hook" 2>/dev/null \
      || log "  （告警发送失败，详见 sync.log）"
  fi
}

if [ -f "$LOG_FILE" ] && [ "$(wc -c <"$LOG_FILE")" -gt 1048576 ]; then
  tail -300 "$LOG_FILE" >"$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

for cmd in jq openssl git curl; do
  command -v "$cmd" >/dev/null 2>&1 || { log "缺少依赖：${cmd}（PATH=${PATH}）"; exit 1; }
done

[ -r "$CRED_FILE" ] || { log "读不到凭据文件（桌面端未登录？）：$CRED_FILE"; exit 2; }
[ -f "$KEY_FILE" ]  || { log "缺少密钥文件，请先运行 local/install.sh"; exit 3; }
[ -f "$CONF_FILE" ] || { log "缺少配置 ${CONF_FILE}，请先运行 local/install.sh"; exit 3; }

REPO_URL="$(jq -r '.repo_url // empty' "$CONF_FILE")"
BRANCH="$(jq -r '.branch // "main"' "$CONF_FILE")"
[ -n "$REPO_URL" ] || { log "配置里没有 repo_url，请重新运行 local/install.sh"; exit 3; }

# 通知渠道地址（可选）。放在这里而不是 Secret：整个通知链路的配置都跟着
# 已有的加密同步通道走，配置源单一，也不会因为「忘了设 Secret」而静默无回执。
# 环境变量 WB_NOTIFY_WEBHOOK 优先，便于临时覆盖/排障。
NOTIFY_WEBHOOK="${WB_NOTIFY_WEBHOOK:-$(jq -r '.notify_webhook // empty' "$CONF_FILE" 2>/dev/null)}"

# ---------- 1) 读取当前凭据 ----------
ACCESS_TOKEN="$(jq -r '.auth.accessToken // empty' "$CRED_FILE" 2>/dev/null)"
WB_UID="$(jq -r '.account.uid // empty' "$CRED_FILE" 2>/dev/null)"
ROTATED_AT="$(jq -r '.auth.lastRefreshTime // 0' "$CRED_FILE" 2>/dev/null)"
EXPIRES_AT="$(jq -r '.auth.expiresAt // 0' "$CRED_FILE" 2>/dev/null)"

if [ -z "$ACCESS_TOKEN" ] || [ -z "$WB_UID" ] || [ "$ACCESS_TOKEN" = "null" ]; then
  log "凭据文件里没有可用的 accessToken / uid，跳过"
  exit 4
fi

# ── 1.5) 凭据形态闸门（2026-09-25 事故后新增，别删）──────────────────────
# 桌面端从 2026-09-23 起对凭据文件启用了静态加密（At-Rest Encryption,
# policy=fields）。此后 .auth.accessToken 不再是 JWT 明文，而是一个封套：
#     { "$wbEncrypted": 1, "envelope": "<base64>" }
# 解开它用的对称保护密钥由 daemon 启动时与服务端握手获得，只存在于进程内存，
# 本机离线无法还原 —— 也就是说这条抓取明文 token 的路被产品侧关闭了。
#
# jq -r '.auth.accessToken' 会把这个**对象**序列化成带换行的 JSON 字符串。
# 若照样加密推上去，会接连造成两个后果：
#   ① 云端拿它当 Bearer 用 → 401（不可用的凭据覆盖了仍在生效的旧快照）；
#   ② 更隐蔽：它是多行的，写入 GITHUB_ENV 时 GitHub 判 "Invalid format"，
#      「解出最新凭据」整步失败 → 签到步骤被 skip，runs.md 里只留下一行
#      skipped —— 表现就是连续两天静默不签到（2026-09-23 22:59 起 6 次全 skipped）。
#
# 所以这里必须 fail-fast：保留远端上一份可用快照，绝不拿不可用凭据去覆盖，
# 并通过当时唯一还能触达用户的通道（通知机器人）明确告警。
case "$ACCESS_TOKEN" in
  *wbEncrypted*|*envelope*|'{'*)
    log "凭据已被桌面端加密（At-Rest）：无法读取明文 token，本次不推送"
    log "  原因：$CRED_FILE 中 .auth.accessToken 是加密封套，密钥只在 daemon 内存里"
    log "  影响：云端继续沿用远端上一份快照，直到它过期为止"
    notify "$NOTIFY_WEBHOOK" "WorkBuddy 签到：凭据已被桌面端加密，自动签到将失效" \
      "桌面端启用了凭据静态加密，同步器读不到明文 token。
云端会沿用上一份快照直到其过期。
原因：$(basename "$CRED_FILE") 中 accessToken 为加密封套，密钥只在进程内存中。
详见 ~/.wb-checkin/sync.log"
    exit 14 ;;
esac

# 顺带的形态检查：JWT 与旧式不透明串都不含空白字符。一旦出现空白，必然是
# 多行的 JSON（见上）或被意外截断 —— 推上去同样会让 GITHUB_ENV 写入失败。
case "$ACCESS_TOKEN" in
  *[![:graph:]]*)
    log "凭据形态异常（含空白字符），拒绝推送以免破坏云端 GITHUB_ENV 注入"
    notify "$NOTIFY_WEBHOOK" "WorkBuddy 签到：本机凭据形态异常" \
      "accessToken 含空白字符，推送已中止（保留云端上一份快照）。
详见 ~/.wb-checkin/sync.log"
    exit 14 ;;
esac

NEW_HASH="$(printf '%s\n%s' "$ACCESS_TOKEN" "$WB_UID" | shasum -a 256 | awk '{print $1}')"

# 通知配置的独立指纹。必须单独算：只改通知地址时凭据指纹不变，
# 若只比对凭据，换 webhook 会被判成「无需同步」而永远不生效。
# 用 printf '%s'（不带换行），与远端侧保持同一公式。
NEW_CFG_HASH="$(printf '%s' "$NOTIFY_WEBHOOK" | shasum -a 256 | awk '{print $1}')"

# ---------- 2) 准备独立工作副本 ----------
if [ ! -d "$WORK_DIR/.git" ]; then
  rm -rf "$WORK_DIR"
  if ! git clone -q --branch "$BRANCH" "$REPO_URL" "$WORK_DIR" >>"$LOG_FILE" 2>&1; then
    log "克隆仓库失败：$REPO_URL"
    exit 7
  fi
  git -C "$WORK_DIR" config user.name  'wb-checkin sync'
  git -C "$WORK_DIR" config user.email 'wb-checkin-sync@localhost'
fi

# ---------- 3) 陈旧锁兜底 ----------
# git 被中断（进程被杀、沙箱拦截、断电）会留下 .git/index.lock，之后所有
# git 写操作（checkout/add/commit）都会失败，而脚本若只检查「暂存区无差异」
# 就会误判成「内容无变化」。实测 2026-09-20 就因此丢过一次凭据同步。
# 2026-09-21 又踩到第二类：历史重写后 .git 下残留 packed-refs.lock 与
# gc.pid.lock —— 原先只兜底 index.lock，清不掉它俩，git 一律报
# "Unable to create '.../packed-refs.lock': File exists" 而卡死同步。
# 因此扫描 .git 下的 *.lock，并且只在锁确实陈旧时才清理。
# 2026-09-22 再补一类：本脚本自己用 `checkout -f -B` 写 refs/heads/<branch>，
# 若那一瞬间被中断（沙箱拦截 / 进程被杀），就会留下 .git/refs/heads/main.lock
# —— 而单层 glob（.git/*.lock）扫不到它，等于「脚本自己造的锁自己清不掉」，
# 之后每轮 git 一律报 "Unable to create ...: File exists" 而永久卡死。
# 所以这里必须把 refs 下那一层也覆盖上。
for LOCK_FILE in "$WORK_DIR"/.git/*.lock "$WORK_DIR"/.git/refs/*/*.lock; do
  [ -e "$LOCK_FILE" ] || continue          # glob 未命中时会得到字面量，跳过
  LOCK_NAME="${LOCK_FILE##*/}"
  LOCK_MTIME="$(stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0)"
  LOCK_AGE=$(( $(date +%s) - LOCK_MTIME ))
  if [ "$LOCK_MTIME" != "0" ] && [ "$LOCK_AGE" -gt "$LOCK_MAX_AGE" ]; then
    rm -f "$LOCK_FILE" && log "清理陈旧 ${LOCK_NAME}（已存在 ${LOCK_AGE}s）"
  else
    log "${LOCK_NAME} 疑似正在使用（${LOCK_AGE}s），本次跳过，下次重试"
    exit 11
  fi
done

# 上一轮若在推送重试里做过 rebase 且中断，会留下 rebase-merge 等状态目录，
# 之后每一轮 git 操作都会失败或行为诡异（2026-09-21 实际踩到：main 分支漂到
# ahead 68、HEAD 变 detached、连 rebase --abort 都失败）。工作副本只承载密文
# 快照，没有需要保留的本地改动，所以直接清掉这些状态。
for _st in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD; do
  if [ -e "$WORK_DIR/.git/$_st" ]; then
    rm -rf "$WORK_DIR/.git/$_st"
    log "清理残留的 git 状态：.git/$_st"
  fi
done

if ! git -C "$WORK_DIR" fetch -q origin "$BRANCH" >>"$LOG_FILE" 2>&1; then
  log "git fetch 失败（网络？），本次跳过，下次重试"
  exit 8
fi

# 这里用 checkout -f -B 而不是 reset --hard：
# reset 只移动「当前 HEAD」，若上一轮把 HEAD 弄成 detached，main 分支会永远
# 停在旧位置。checkout -f -B 会重建分支并强制对齐远端，顺带修好 detached。
#
# ⚠️ checkout -f 会连本地未推送的提交一起丢掉。这个工作副本常态下只承载密文
# 快照（同步器自己造的密文提交丢了也无妨），但它偶尔可能被人手动动过（排障时
# 进来改文件、或其它工具留下的提交），那时硬对齐就等于「静默丢东西」：没有
# 任何提示，只在远端看不到结果。所以对齐前先分辨未推送提交的「性质」：
#   只动密文快照 → 同步器自己推失败留下的，无保留价值，照旧对齐（重试路径不变）
#   动了其它文件 → 停下告警并写日志（退出码 13），交给人处理，绝不静默丢
# 注：本工作副本与 ~/Documents 下的开发副本是两个**独立仓库**（install.sh 各自
# clone，inode 不同），所以正常情况不会出现「非密文」的未推送提交；此分支是兜底。
LOCAL_AHEAD="$(git -C "$WORK_DIR" rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo 0)"
case "$LOCAL_AHEAD" in ''|*[!0-9]*) LOCAL_AHEAD=0 ;; esac
if [ "$LOCAL_AHEAD" -gt 0 ]; then
  # -x 整行匹配 + -F 字面量，避免密文路径被当正则误判
  DEV_FILES="$(git -C "$WORK_DIR" diff --name-only "origin/$BRANCH..HEAD" 2>/dev/null \
    | grep -v -x -F "$ENC_REL" | head -5)"
  if [ -n "$DEV_FILES" ]; then
    log "发现 ${LOCAL_AHEAD} 个未推送的本地提交，且含非密文文件，已跳过远端对齐以免静默丢弃："
    printf '%s\n' "$DEV_FILES" | while IFS= read -r _f; do log "    ${_f}"; done
    log "处理：确认这些提交无用后，在 ${WORK_DIR} 里 git reset --hard origin/${BRANCH} 即可恢复同步。"
    exit 13
  fi
fi

if ! git -C "$WORK_DIR" checkout -q -f -B "$BRANCH" "origin/$BRANCH" >>"$LOG_FILE" 2>&1; then
  log "工作副本对齐远端失败，本次跳过，下次重试"
  exit 12
fi

# ---------- 4) 是否真的已经同步？以「远端快照」为准，而不是本地指纹文件 ----------
# 关键：last.sha256 只记录「上一次成功加密过的内容」，推送失败时它也可能
# 已被写入。若仅凭它判断「无变化」，就会永久静默停更（云端一直用旧 token）。
# 因此这里把远端密文解出来，与当前凭据逐字节比对，得出唯一可信结论。
REMOTE_HASH=""
if [ -s "$WORK_DIR/$ENC_REL" ]; then
  R_PLAIN="$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 \
      -in "$WORK_DIR/$ENC_REL" -pass "file:$KEY_FILE" 2>/dev/null)"
  R_TOK="$(printf '%s' "$R_PLAIN" | jq -r '.access_token // empty' 2>/dev/null)"
  R_UID="$(printf '%s' "$R_PLAIN" | jq -r '.uid // empty' 2>/dev/null)"
  if [ -n "$R_TOK" ] && [ -n "$R_UID" ]; then
    # 必须与上面 NEW_HASH 用完全相同的拼接公式。
    # 踩过的坑：先前写成 `jq -r '"\(.a)\n\(.b)"'` 直接接 shasum，
    # jq -r 会追加一个尾部换行，而 NEW_HASH 用的是 printf '%s\n%s'（无尾部换行），
    # 两者永不相等 → 每轮都误判「未同步」而重复推送。别改回那种写法。
    REMOTE_HASH="$(printf '%s\n%s' "$R_TOK" "$R_UID" | shasum -a 256 | awk '{print $1}')"
    # 老快照里没有 notify_webhook 字段 → 取到空串，与「本机也没配」等价，
    # 因此升级本脚本不会引发一次无意义的重推。
    R_HOOK="$(printf '%s' "$R_PLAIN" | jq -r '.notify_webhook // empty' 2>/dev/null)"
    REMOTE_CFG_HASH="$(printf '%s' "$R_HOOK" | shasum -a 256 | awk '{print $1}')"
  fi
fi

if [ -n "$REMOTE_HASH" ] && [ "$NEW_HASH" = "$REMOTE_HASH" ] \
   && [ "$NEW_CFG_HASH" = "$REMOTE_CFG_HASH" ]; then
  printf '%s\n' "$NEW_HASH" >"$HASH_FILE"; chmod 600 "$HASH_FILE"
  exit 0   # 远端已是最新，静默退出（最常见的路径，不写日志避免刷屏）
fi

# 凭据没变、只有通知配置变了 → 立刻推送，不吃节流。
# 节流是为了压制 token 换发造成的提交堆积；通知地址属于「人改了一次、
# 期望马上生效」的配置，让它等满 20 小时窗口毫无意义。
if [ -n "$REMOTE_HASH" ] && [ "$NEW_HASH" = "$REMOTE_HASH" ] \
   && [ "$NEW_CFG_HASH" != "$REMOTE_CFG_HASH" ]; then
  FORCE=1
  log "通知配置有变化，本次绕过节流直接推送"
fi

# ---------- 4.5) 推送节流 ----------
# 走到这里说明「本机凭据与远端快照不同」，但不同 ≠ 需要立刻推：
# 远端那份仍是有效凭据，云端照常签到。每次换发都提交只会把仓库刷满。
# 不节流的三种情形：--force / 远端还没有快照 / 距上次推送已超过阈值。
if [ "$FORCE" != "1" ] && [ -n "$REMOTE_HASH" ] && [ -f "$THROTTLE_FILE" ]; then
  LAST_PUSH_AT="$(cat "$THROTTLE_FILE" 2>/dev/null || echo 0)"
  case "$LAST_PUSH_AT" in ''|*[!0-9]*) LAST_PUSH_AT=0 ;; esac
  SECS_SINCE=$(( $(date +%s) - LAST_PUSH_AT ))
  if [ "$LAST_PUSH_AT" -gt 0 ] && [ "$SECS_SINCE" -ge 0 ] \
     && [ "$SECS_SINCE" -lt "$MIN_PUSH_INTERVAL" ]; then
    # 静默跳过：换发很频繁，写日志会把 sync.log 刷爆
    exit 0
  fi
fi

# ---------- 5) 先验证可用性，避免把死凭据推上去 ----------
HTTP_CODE="$(curl -s -m 15 --noproxy '*' -o /dev/null -w '%{http_code}' \
  -X POST 'https://copilot.tencent.com/v2/billing/meter/checkin-activity-status' \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "X-User-Id: $WB_UID" \
  -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -d '{}' 2>/dev/null)"
# curl 连不上时 -w 已经会输出 000，这里只需吞掉非零退出码。
# （早先写成 `|| echo "000"` 导致日志里出现 HTTP=000000 这种看不懂的值。）

if [ "$HTTP_CODE" = "401" ]; then
  log "本机凭据已被服务端拒绝（401），不推送。桌面端重新登录后本脚本会自动恢复。"
  exit 5
fi
# 走到这一支说明 curl 根本没连上（000 = 连接失败/超时），不是凭据本身被拒。
# 原写法「仍继续推送以免误判」在 2026-09-25 出了事：网络抖动期间恰好撞上桌面端
# 凭据格式换代，于是把不可用凭据推进了仓库，覆盖掉了仍然生效的旧快照。
# 校准原则：**未知的凭据不要推**。远端那份 JWT 通常还有几十天有效期，
# 少更新一次无损可用性；推错了则直接让云端连续失败且不好回滚。
if [ "$HTTP_CODE" != "200" ]; then
  log "凭据可用性无法确认（HTTP=${HTTP_CODE}，连接失败/超时），本次不推送。"
  log "  判据：只有显式 401 才是「凭据已被服务端拒绝」的确定结论；"
  log "        探测失败只说明这次没能连通，不代表凭据失效。"
  log "  影响：远端继续沿用上一份快照；网络恢复后本脚本会自动重试。"
  exit 15
fi

# ---------- 6) 加密 ----------
TMP_DIR="$(mktemp -d)"
chmod 700 "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

jq -n \
  --arg t "$ACCESS_TOKEN" \
  --arg u "$WB_UID" \
  --arg w "$NOTIFY_WEBHOOK" \
  --arg r "$ROTATED_AT" \
  --arg e "$EXPIRES_AT" \
  --arg s "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  '{schema:1, access_token:$t, uid:$u, notify_webhook:$w,
    token_rotated_at_ms:$r, token_expires_at_ms:$e, synced_at_utc:$s}' \
  >"$TMP_DIR/plain.json"
chmod 600 "$TMP_DIR/plain.json"

if ! openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -salt \
      -in "$TMP_DIR/plain.json" -out "$TMP_DIR/credentials.enc" \
      -pass "file:$KEY_FILE" 2>>"$LOG_FILE"; then
  log "加密失败，终止（openssl: $(openssl version 2>/dev/null)）"
  exit 6
fi

# ---------- 7) 落盘、提交、推送 ----------
mkdir -p "$WORK_DIR/state"
cp "$TMP_DIR/credentials.enc" "$WORK_DIR/$ENC_REL"

# add 必须显式判成败：失败时绝不能往下走（否则会把指纹误写成「已同步」）
if ! git -C "$WORK_DIR" add "$ENC_REL" >>"$LOG_FILE" 2>&1; then
  log "git add 失败（磁盘锁或权限？），本次跳过，指纹不更新"
  exit 13
fi

if git -C "$WORK_DIR" diff --cached --quiet; then
  printf '%s\n' "$NEW_HASH" >"$HASH_FILE"; chmod 600 "$HASH_FILE"
  log "密文与远端一致，无需提交"
  exit 0
fi

git -C "$WORK_DIR" commit -q -m "chore: 同步凭据快照 $(date -u '+%Y-%m-%d %H:%M') UTC [skip ci]" \
  || { log "提交失败"; exit 9; }

PUSHED=0
for i in 1 2 3; do
  if git -C "$WORK_DIR" push -q origin "HEAD:$BRANCH" >>"$LOG_FILE" 2>&1; then
    PUSHED=1
    break
  fi
  log "第 $i 次推送失败，5 秒后重试"
  sleep 5
  git -C "$WORK_DIR" fetch -q origin "$BRANCH" >>"$LOG_FILE" 2>&1 || true
  # 刻意不用 git rebase：一旦冲突就会把工作副本留在 rebase 中途，之后每一轮
  # 都被卡住（2026-09-21 踩过）。工作副本只承载密文快照，本地提交没有保留
  # 价值 —— 硬对齐远端后重新落盘、重新提交，语义更简单，也不会留下残状态。
  for _st in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD; do
    rm -rf "$WORK_DIR/.git/$_st" 2>/dev/null || true
  done
  git -C "$WORK_DIR" checkout -q -f -B "$BRANCH" "origin/$BRANCH" >>"$LOG_FILE" 2>&1 || true
  cp "$TMP_DIR/credentials.enc" "$WORK_DIR/$ENC_REL" 2>/dev/null || true
  git -C "$WORK_DIR" add "$ENC_REL" >>"$LOG_FILE" 2>&1 || true
  git -C "$WORK_DIR" commit -q \
    -m "chore: 同步凭据快照 $(date -u '+%Y-%m-%d %H:%M') UTC [skip ci]" \
    >>"$LOG_FILE" 2>&1 || true
done

if [ "$PUSHED" = "1" ]; then
  printf '%s\n' "$NEW_HASH" >"$HASH_FILE"; chmod 600 "$HASH_FILE"
  date +%s >"$THROTTLE_FILE"   # 节流基准时刻（仅成功推送后更新）
  log "凭据已同步（指纹 ${NEW_HASH:0:12}），云端将在下次调度使用"
  exit 0
fi

# 推送失败时【不】写指纹文件 —— 保证下一轮一定会重试，不会静默停更
log "连续 3 次推送失败（网络或 SSH 认证问题），指纹未更新，下次运行会重试"
exit 10
