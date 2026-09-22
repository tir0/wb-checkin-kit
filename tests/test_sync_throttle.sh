#!/bin/bash
# ==============================================================================
# 同步器「推送节流」回归测试
# ==============================================================================
#   bash tests/test_sync_throttle.sh
#
# 设计原则：不复制一份逻辑来测（那样测的是副本、不是产物）。
# 这里构造一个隔离环境，端到端运行**真实的** local/wb-sync-credentials.sh：
#   - 假的 HOME          → 状态目录、凭据文件都落在临时目录里
#   - 本地裸仓库          → 代替 GitHub，可离线、可 stat 提交数
#   - PATH 影子 curl      → 固定返回 200，避免依赖网络与真实凭据
#
# 验证的决策表（节流引入于 2026-09-21）：
#   A 远端还没快照              → 必须推（否则云端永远空着）
#   B 与远端完全一致            → 静默退出，不产生提交
#   C 有变化 + 在节流窗口内     → 跳过推送
#   D 有变化 + --force          → 绕过窗口，推送
#   E 有变化 + 窗口已过         → 推送
#   F 远端快照被删 + 窗口内     → 仍必须推
# 以及健壮性用例：
#   G 未知参数                  → 退出码 64
#   H rebase 残留 + detached HEAD → 自愈并推送
#   I  多种陈旧锁（含 refs/heads）→ 全部清理并推送（脚本自己造的锁也要能清）
#   I2 锁很新鲜                  → 跳过（退出码 11）且不误删
#   J  只改通知地址 + 窗口内     → 仍必须推（地址随快照下发，配置变更不吃节流）
#   J2 地址也没变                → 静默退出
#   K  工作副本有未推送的非密文提交 → 保住（退出码 13），不被 checkout -f 抹掉
#   K2 未推送提交只含密文        → 照旧硬对齐推送（重试路径不被保护逻辑挡死）
# ==============================================================================
set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/local/wb-sync-credentials.sh}"
[ -f "$SCRIPT" ] || { echo "找不到同步器脚本：$SCRIPT"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_HOME="$TMP/home"
STATE="$FAKE_HOME/.wb-checkin"
BIN="$TMP/bin"
ORIGIN="$TMP/origin.git"
SEED="$TMP/seed"
KEY="$STATE/key"
CONF="$STATE/config"
CRED="$FAKE_HOME/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info"
THROTTLE="$STATE/last_push.epoch"

mkdir -p "$STATE" "$BIN" "$(dirname "$CRED")"

# ---- 密钥（与真实环境同一套 openssl 参数）----
openssl rand -hex 32 >"$KEY"
chmod 600 "$KEY"

# ---- 影子 curl：脚本只看 HTTP 码，固定给 200 ----
cat >"$BIN/curl" <<'SHIM'
#!/bin/bash
printf '200'
SHIM
chmod +x "$BIN/curl"

# ---- 本地裸仓库，充当 origin ----
git init --bare -q -b main "$ORIGIN"
mkdir -p "$SEED"
git -C "$SEED" init -q -b main .
git -C "$SEED" config user.name  'seed'
git -C "$SEED" config user.email 'seed@localhost'
git -C "$SEED" remote add origin "$ORIGIN"

encrypt_to() {  # $1=明文 json  $2=输出文件
  printf '%s' "$1" >"$TMP/plain.json"
  openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -salt \
    -in "$TMP/plain.json" -out "$2" -pass "file:$KEY" 2>/dev/null
}
mkdir -p "$SEED/state"
encrypt_to '{"schema":1,"access_token":"SEEDTOKEN","uid":"test-uid"}' \
  "$SEED/state/credentials.enc"
git -C "$SEED" add -A
git -C "$SEED" commit -q -m 'seed'
git -C "$SEED" push -q origin main

jq -n --arg u "$ORIGIN" --arg b main '{repo_url:$u, branch:$b}' >"$CONF"
chmod 600 "$CONF"

write_conf() {  # $1 = notify_webhook（空则视为不配通知）
  if [ -n "${1:-}" ]; then
    jq -n --arg u "$ORIGIN" --arg b main --arg w "$1" \
      '{repo_url:$u, branch:$b, notify_webhook:$w}' >"$CONF"
  else
    jq -n --arg u "$ORIGIN" --arg b main '{repo_url:$u, branch:$b}' >"$CONF"
  fi
  chmod 600 "$CONF"
}

write_cred() {  # $1 = accessToken
  jq -n --arg t "$1" \
    '{auth:{accessToken:$t,lastRefreshTime:1,expiresAt:2},account:{uid:"test-uid"}}' >"$CRED"
}

commits() { git -C "$ORIGIN" rev-list --count main 2>/dev/null || echo 0; }

remote_token() {
  git -C "$ORIGIN" show main:state/credentials.enc 2>/dev/null \
    | openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 \
        -pass "file:$KEY" 2>/dev/null \
    | jq -r '.access_token // empty' 2>/dev/null
}

remote_hook() {   # 远端快照里随密文一起下发的通知地址
  git -C "$ORIGIN" show main:state/credentials.enc 2>/dev/null \
    | openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 \
        -pass "file:$KEY" 2>/dev/null \
    | jq -r '.notify_webhook // empty' 2>/dev/null
}

run_sync() {  # 透传参数（如 --force）
  HOME="$FAKE_HOME" PATH="$BIN:/usr/bin:/bin" /bin/bash "$SCRIPT" "$@" >/dev/null 2>&1
  return $?
}

RESULTS=()
check() {  # $1=标签  $2=条件
  RESULTS+=("$2")
  printf '  %s %s\n' "$([ "$2" = "0" ] && echo '✓' || echo '✗')" "$1"
}

echo "同步器：$SCRIPT"
echo

# ---------- A) 远端已有快照，但本机凭据不同 → 推 ----------
echo "[A] 首次推送（无节流文件）"
write_cred "TOKENA"
BEFORE="$(commits)"
run_sync; RC=$?
check "退出码 0（实际 ${RC}）" "$([ "$RC" = "0" ] && echo 0 || echo 1)"
check "新增提交（${BEFORE} → $(commits)）" "$([ "$(commits)" -gt "$BEFORE" ] && echo 0 || echo 1)"
check "远端快照已更新为 TOKENA（实际 $(remote_token)）" \
      "$([ "$(remote_token)" = "TOKENA" ] && echo 0 || echo 1)"
check "已写入节流基准时刻" "$([ -f "$THROTTLE" ] && echo 0 || echo 1)"

# ---------- B) 与远端一致 → 静默退出 ----------
echo "[B] 内容与远端一致"
BEFORE="$(commits)"
run_sync; RC=$?
check "退出码 0（实际 ${RC}）" "$([ "$RC" = "0" ] && echo 0 || echo 1)"
check "未新增提交" "$([ "$(commits)" = "$BEFORE" ] && echo 0 || echo 1)"

# ---------- C) 有变化但在节流窗口内 → 跳过 ----------
echo "[C] 凭据变化，但距上次推送不足阈值"
write_cred "TOKENB"
BEFORE="$(commits)"
run_sync; RC=$?
check "退出码 0（实际 ${RC}）" "$([ "$RC" = "0" ] && echo 0 || echo 1)"
check "未新增提交（被节流）" "$([ "$(commits)" = "$BEFORE" ] && echo 0 || echo 1)"
check "远端仍是 TOKENA 而非 TOKENB" "$([ "$(remote_token)" = "TOKENA" ] && echo 0 || echo 1)"

# ---------- D) --force 绕过节流 ----------
echo "[D] 同上，但加 --force"
BEFORE="$(commits)"
run_sync --force; RC=$?
check "退出码 0（实际 ${RC}）" "$([ "$RC" = "0" ] && echo 0 || echo 1)"
check "已推送（${BEFORE} → $(commits)）" "$([ "$(commits)" -gt "$BEFORE" ] && echo 0 || echo 1)"
check "远端已更新为 TOKENB（实际 $(remote_token)）" \
      "$([ "$(remote_token)" = "TOKENB" ] && echo 0 || echo 1)"

# ---------- E) 窗口已过 → 推 ----------
echo "[E] 把节流基准改到很久以前"
write_cred "TOKENC"
BEFORE="$(commits)"
echo "$(( $(date +%s) - 100000 ))" >"$THROTTLE"
run_sync; RC=$?
check "退出码 0（实际 ${RC}）" "$([ "$RC" = "0" ] && echo 0 || echo 1)"
check "已推送（窗口已过）" "$([ "$(commits)" -gt "$BEFORE" ] && echo 0 || echo 1)"
check "远端已更新为 TOKENC（实际 $(remote_token)）" \
      "$([ "$(remote_token)" = "TOKENC" ] && echo 0 || echo 1)"

# ---------- F) 远端无快照 → 节流不生效 ----------
echo "[F] 远端快照被删除，且节流窗口内"
write_cred "TOKEND"
echo "$(date +%s)" >"$THROTTLE"          # 基准设为刚刚
# seed 克隆已落后于 origin（前面的用例往 origin 推过提交），先对齐再删
git -C "$SEED" fetch -q origin main
git -C "$SEED" reset --hard -q origin/main
git -C "$SEED" rm -q state/credentials.enc
git -C "$SEED" commit -q -m 'drop snapshot'
if ! git -C "$SEED" push -q origin main 2>/dev/null; then
  echo "  ! 测试前置失败：无法从 origin 删除快照"
fi
BEFORE="$(commits)"
run_sync; RC=$?
check "退出码 0（实际 ${RC}）" "$([ "$RC" = "0" ] && echo 0 || echo 1)"
check "仍推送（不能因节流让云端空着）" "$([ "$(commits)" -gt "$BEFORE" ] && echo 0 || echo 1)"
check "远端恢复为 TOKEND（实际 $(remote_token)）" \
      "$([ "$(remote_token)" = "TOKEND" ] && echo 0 || echo 1)"

# ---------- G) 参数校验 ----------
echo "[G] 参数校验"
run_sync --nonsense; RC=$?
check "未知参数退出码 64（实际 ${RC}）" "$([ "$RC" = "64" ] && echo 0 || echo 1)"

# ---------- H) 工作副本被 git 状态污染后能自愈 ----------
# 背景：脚本早先的重试循环用 git rebase，冲突时会留下 rebase-merge 目录，
# 且 HEAD 变 detached、分支停在旧位置，之后每一轮都失败（2026-09-21 真实踩到，
# main 漂到 ahead 68）。现改为「清状态 + checkout -f -B 硬对齐」，这个用例
# 就是把当时的污染原样造出来，验证脚本能自己恢复，不需要人工介入。
echo "[H] 工作副本残留 rebase 状态 + detached HEAD + 分支漂移"
WORK="$FAKE_HOME/.wb-checkin/repo"
write_cred "TOKENE"
mkdir -p "$WORK/.git/rebase-merge"
printf 'refs/heads/main\n' >"$WORK/.git/rebase-merge/head-name"
git -C "$WORK" checkout -q --detach HEAD
git -C "$WORK" branch -f main HEAD~1 2>/dev/null || true
BEFORE="$(commits)"
run_sync --force; RC=$?
check "退出码 0（实际 ${RC}）" "$([ "$RC" = "0" ] && echo 0 || echo 1)"
check "残留 rebase 状态已清除" \
      "$([ -e "$WORK/.git/rebase-merge" ] && echo 1 || echo 0)"
check "HEAD 已回到 main 分支（实际 $(git -C "$WORK" rev-parse --abbrev-ref HEAD)）" \
      "$([ "$(git -C "$WORK" rev-parse --abbrev-ref HEAD)" = "main" ] && echo 0 || echo 1)"
check "分支漂移已修复（main == origin/main）" \
      "$([ "$(git -C "$WORK" rev-parse main)" = "$(git -C "$WORK" rev-parse origin/main)" ] && echo 0 || echo 1)"
check "已推送 TOKENE（实际 $(remote_token)）" \
      "$([ "$(remote_token)" = "TOKENE" ] && echo 0 || echo 1)"

# ---------- I) 多类型锁残留 → 全部清理 ----------
# 背景：git 的锁不止 index.lock。2026-09-21 实测历史重写后 .git 下残留
# packed-refs.lock / gc.pid.lock，旧脚本只兜底 index.lock，于是 checkout 报
# "Unable to create '.../packed-refs.lock': File exists"，同步永久卡住。
# 这里把三种锁一起造出来（mtime 拨到 2020 年 = 陈旧），验证脚本能全清并继续推送。
echo "[I] 残留多类型陈旧锁（index.lock + packed-refs.lock + gc.pid.lock + refs/heads/main.lock）"
write_cred "TOKENF"
for _lk in index.lock packed-refs.lock gc.pid.lock; do
  : >"$WORK/.git/$_lk"
  touch -t 202001010000 "$WORK/.git/$_lk"
done
# 这一类是脚本自己的 `checkout -f -B` 被中断时会造出来的（写 refs/heads/<branch>）。
# 单层 glob 扫不到 refs 下那层 → 锁清不掉 → 每轮 checkout 都报 File exists 而永久卡死。
mkdir -p "$WORK/.git/refs/heads"
: >"$WORK/.git/refs/heads/main.lock"
touch -t 202001010000 "$WORK/.git/refs/heads/main.lock"
BEFORE="$(commits)"
run_sync --force; RC=$?
check "退出码 0（实际 ${RC}）" "$([ "$RC" = "0" ] && echo 0 || echo 1)"
check "index.lock 已清理" "$([ -e "$WORK/.git/index.lock" ] && echo 1 || echo 0)"
check "packed-refs.lock 已清理" "$([ -e "$WORK/.git/packed-refs.lock" ] && echo 1 || echo 0)"
check "gc.pid.lock 已清理" "$([ -e "$WORK/.git/gc.pid.lock" ] && echo 1 || echo 0)"
check "refs/heads/main.lock 已清理" \
      "$([ -e "$WORK/.git/refs/heads/main.lock" ] && echo 1 || echo 0)"
check "已推送 TOKENF（实际 $(remote_token)）" \
      "$([ "$(remote_token)" = "TOKENF" ] && echo 0 || echo 1)"

# ---------- I2) 新鲜锁 → 跳过，且不能误删 ----------
# 锁很新说明大概率真有另一个 git 进程在写。这时删锁会破坏对方操作，
# 正确行为是本次跳过（退出码 11），把锁留给下一轮再判断。
echo "[I2] 锁很新鲜（疑似并发写入中）→ 跳过且不清理"
write_cred "TOKENG"
: >"$WORK/.git/index.lock"            # mtime = 现在
BEFORE="$(commits)"
run_sync --force; RC=$?
check "退出码 11（实际 ${RC}）" "$([ "$RC" = "11" ] && echo 0 || echo 1)"
check "未新增提交" "$([ "$(commits)" = "$BEFORE" ] && echo 0 || echo 1)"
check "新鲜锁被保留（未误删）" "$([ -e "$WORK/.git/index.lock" ] && echo 0 || echo 1)"
check "远端未变，仍是 TOKENF（实际 $(remote_token)）" \
      "$([ "$(remote_token)" = "TOKENF" ] && echo 0 || echo 1)"
rm -f "$WORK/.git/index.lock"

# ---------- J) 只改通知地址 → 必须立刻生效，不吃节流 ----------
# 背景：通知地址随加密快照下发给云端（不再依赖手工设 Secret），所以本机改地址
# 后必须能推上去。但凭据指纹不变 → 若只比对凭据，就会被判成「无需同步」或
# 被节流窗口挡住，用户会以为「配了却没生效」。故地址另有独立指纹，且改地址
# 时强制绕过节流（此刻节流基准刚刚写过，正是窗口内的情形）。
echo "[J] 凭据未变、只改通知地址，且处于节流窗口内"
write_cred "TOKENF"                     # 与远端一致，确保只差通知地址
write_conf "https://oapi.dingtalk.com/robot/send?access_token=TESTHOOK"
echo "$(date +%s)" >"$THROTTLE"         # 基准设为刚刚 = 窗口内
BEFORE="$(commits)"
run_sync; RC=$?                          # 刻意不加 --force
check "退出码 0（实际 ${RC}）" "$([ "$RC" = "0" ] && echo 0 || echo 1)"
check "仍推送（配置变更不受节流约束）" \
      "$([ "$(commits)" -gt "$BEFORE" ] && echo 0 || echo 1)"
check "远端快照已带上通知地址" \
      "$([ -n "$(remote_hook)" ] && echo 0 || echo 1)"
check "远端地址与配置一致" \
      "$([ "$(remote_hook)" = "https://oapi.dingtalk.com/robot/send?access_token=TESTHOOK" ] && echo 0 || echo 1)"

# ---------- J2) 地址也没变 → 静默退出，不再刷提交 ----------
echo "[J2] 地址与远端一致"
BEFORE="$(commits)"
run_sync; RC=$?
check "退出码 0（实际 ${RC}）" "$([ "$RC" = "0" ] && echo 0 || echo 1)"
check "未新增提交" "$([ "$(commits)" = "$BEFORE" ] && echo 0 || echo 1)"

# ---------- K) 工作副本里出现未推送的【非密文】提交 → 保住，不得静默丢弃 ----------
# 背景：脚本原先一律 `checkout -f -B origin/main` 硬对齐，其注释假设「本地提交
# 没有保留价值」—— 那只对同步器自己造的密文提交成立。这个工作副本与开发副本是
# 两个独立仓库（install.sh 各自 clone），正常不会出现非密文提交；但一旦被人手动
# 动过（排障时进来改文件），硬对齐就会静默抹掉它：毫无提示，只在远端看不到结果。
# 正确行为：未推送提交里含非密文文件 → 停下告警并写日志（退出码 13），交给人处理。
echo "[K] 工作副本里有未推送的非密文提交"
write_cred "TOKENH"
DEV_SHA=""
printf 'local dev note\n' >"$WORK/DEV-NOTE.txt"
git -C "$WORK" add DEV-NOTE.txt
git -C "$WORK" -c user.name=dev -c user.email=dev@localhost \
  commit -q -m '本地开发提交（未推送）' 2>/dev/null
DEV_SHA="$(git -C "$WORK" rev-parse HEAD 2>/dev/null)"
BEFORE="$(commits)"
run_sync --force; RC=$?
check "退出码 13（实际 ${RC}）" "$([ "$RC" = "13" ] && echo 0 || echo 1)"
check "本地提交仍在 main 上（未被对齐动作抹掉）" \
      "$([ -n "$DEV_SHA" ] && [ "$(git -C "$WORK" rev-parse HEAD 2>/dev/null)" = "$DEV_SHA" ] && echo 0 || echo 1)"
check "被改动的文件没被回退" "$([ -f "$WORK/DEV-NOTE.txt" ] && echo 0 || echo 1)"
check "未污染远端（远端提交数不变）" "$([ "$(commits)" = "$BEFORE" ] && echo 0 || echo 1)"
check "远端快照未被动（仍是 TOKENF，实际 $(remote_token)）" \
      "$([ "$(remote_token)" = "TOKENF" ] && echo 0 || echo 1)"
check "日志里留下了可排查的记录" \
      "$(grep -q '未推送的本地提交' "$STATE/sync.log" && echo 0 || echo 1)"

# ---------- K2) 对照组：未推送提交若只动密文 → 仍按原逻辑硬对齐 ----------
# 这条是 K 的反向保障。同步器的「push 失败 → 硬对齐 → 重新落盘 → 重推」重试路径
# 依赖 checkout -f 丢掉自己那份密文提交；若保护逻辑把纯密文提交也拦住，
# 重试路径就会被自己的保护挡死（比原问题更糟）。所以必须验证它不拦。
echo "[K2] 未推送提交只含密文快照 → 照旧对齐并推送"
git -C "$WORK" reset --hard -q origin/main
check "已回到干净态（开发提交的文件随之移除）" \
      "$([ -f "$WORK/DEV-NOTE.txt" ] && echo 1 || echo 0)"
printf 'stale local ciphertext\n' >"$WORK/state/credentials.enc"
git -C "$WORK" add state/credentials.enc
git -C "$WORK" -c user.name=dev -c user.email=dev@localhost \
  commit -q -m 'chore: 本地密文快照（未推送）' 2>/dev/null
BEFORE="$(commits)"
run_sync --force; RC=$?
check "退出码 0（未被保护逻辑挡住，实际 ${RC}）" "$([ "$RC" = "0" ] && echo 0 || echo 1)"
check "已推送新快照（${BEFORE} → $(commits)）" "$([ "$(commits)" -gt "$BEFORE" ] && echo 0 || echo 1)"
check "远端已更新为 TOKENH（实际 $(remote_token)）" \
      "$([ "$(remote_token)" = "TOKENH" ] && echo 0 || echo 1)"

TOTAL="${#RESULTS[@]}"
OK=$(printf '%s\n' "${RESULTS[@]}" | grep -c '^0$')
echo
echo "=============================================="
echo "通过 ${OK}/${TOTAL} 项"
[ "$OK" = "$TOTAL" ]
