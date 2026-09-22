#!/bin/bash
# ==============================================================================
# 回归测试：他人账号「加入 → 导入」全链路（local/join.sh → local/add-peer.sh）
# ==============================================================================
#   bash tests/test_peer_join.sh
#
# 为什么需要它
#   这条链路跨两个脚本、跨两台机器，而且失败方式都很安静：
#     · join.sh 把死凭据做成分享文件 → 要等云端跑失败才发现；
#     · add-peer.sh 密钥与密文不匹配却照样落盘 → 云端一律解不开；
#     · 密钥/凭据被打印到屏幕或写进日志 → 泄露且无人察觉。
#   所以这里在沙箱里真跑一遍：真加密、真解密、真调接口（本地桩），
#   并把三件「静默失败」逐条钉住。
#
# 依赖：bash、jq、openssl、curl、git、python3（本地桩服务器）
# ==============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PROBE="$(mktemp -d "${TMPDIR:-/tmp}/wb-join-XXXXXX")"
STUB_PID=""
cleanup() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
  rm -rf "$PROBE"
}
trap cleanup EXIT

pass=0; fail=0
ok()  { printf '  \xe2\x9c\x93 %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \xe2\x9c\x97 %s\n' "$1"; fail=$((fail+1)); }

PYTHON="${PYTHON:-python3}"
for c in jq openssl curl git "$PYTHON"; do
  command -v "$c" >/dev/null 2>&1 || { echo "缺少依赖：$c"; exit 1; }
done

# 沙箱仓库：一个只含脚本与 state/ 的临时 git 仓库
mkdir -p "$PROBE/repo/local" "$PROBE/repo/state" "$PROBE/state"
cp "$REPO/local/join.sh" "$REPO/local/add-peer.sh" "$PROBE/repo/local/"
cp -r "$REPO/scripts" "$PROBE/repo/"
git -C "$PROBE/repo" init -q --initial-branch=main
git -C "$PROBE/repo" remote add origin git@github.com:SomeOwner/some-repo.git
git -C "$PROBE/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

# 假的本机登录态（模拟朋友的 WorkBuddy 桌面端）
FAKE_TOKEN="eyJhbGciOiJIUzI1NiJ9.fake-token-for-test.zzz"
FAKE_UID="05381c3b-8cc0-4ce0-ac74-69ca96730756"
HOOK="https://oapi.dingtalk.com/robot/send?access_token=HOOKSECRET"
cat >"$PROBE/cred.json" <<JSON
{"auth":{"accessToken":"${FAKE_TOKEN}","lastRefreshTime":1789695329435,"expiresAt":1794447328838},
 "account":{"uid":"${FAKE_UID}"}}
JSON

# 本地桩：POST 一律返回 200（或 401，取决于 mode）
# ⚠️ 桩的输出必须重定向到文件：它是后台进程，若继承本脚本的 stdout，
#    调用方（如 `bash tests/... | tail`）会因为管道迟迟不关而一直等 EOF。
start_stub() {
  local mode="$1"
  "$PYTHON" - "$PROBE/port" "$mode" >"$PROBE/stub.log" 2>&1 <<'PY' &
import http.server, socketserver, sys
port_file, mode = sys.argv[1], sys.argv[2]
code = 401 if mode == "401" else 200

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"code":0}')

    def log_message(self, *a):
        pass

with socketserver.TCPServer(("127.0.0.1", 0), Handler) as srv:
    with open(port_file, "w") as fh:
        fh.write(str(srv.server_address[1]))
    srv.serve_forever()
PY
  STUB_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$PROBE/port" ] && break
    sleep 0.3
  done
  [ -s "$PROBE/port" ] || { echo "本地桩启动失败"; sed 's/^/  /' "$PROBE/stub.log"; exit 1; }
  echo "http://127.0.0.1:$(cat "$PROBE/port")/checkin"
}

echo "── 1) 朋友侧：join.sh 生成分享文件（凭据有效）──"
STUB_URL="$(start_stub 200)"
OUT="$PROBE/join.log"
WB_CRED_FILE="$PROBE/cred.json" WB_STATUS_URL="$STUB_URL" \
  bash "$PROBE/repo/local/join.sh" --name alice --notify "$HOOK" \
  --out "$PROBE/share.json" >"$OUT" 2>&1
RC=$?
[ "$RC" = "0" ] && ok "join.sh 退出码 0" || bad "join.sh 退出码 $RC"
[ -f "$PROBE/share.json" ] && ok "已生成分享文件" || bad "没生成分享文件"
[ "$(stat -f %Lp "$PROBE/share.json")" = "600" ] \
  && ok "分享文件权限 600" || bad "分享文件权限不是 600"
grep -q '"enc_b64"' "$PROBE/share.json" && ok "分享文件含密文" || bad "分享文件缺密文"
grep -q '"key"' "$PROBE/share.json" && ok "分享文件含密钥（默认单文件模式）" \
  || bad "分享文件缺密钥"
grep -q "凭据校验通过" "$OUT" && ok "做过凭据有效性校验" || bad "没做凭据校验"

echo "── 2) 朋友侧：屏幕输出不得出现凭据或机器人地址 ──"
grep -q "$FAKE_TOKEN" "$OUT" && bad "输出里出现了 token！" || ok "输出无 token"
grep -q "HOOKSECRET" "$OUT" && bad "输出里出现了机器人令牌！" || ok "输出无机器人令牌"
grep -q "$FAKE_UID" "$OUT" && bad "输出里出现了 uid！" || ok "输出无 uid"

echo "── 3) 朋友侧：凭据 401 时必须拒绝生成分享文件 ──"
kill "$STUB_PID" 2>/dev/null; STUB_PID=""
rm -f "$PROBE/port"
STUB_URL_401="$(start_stub 401)"
OUT401="$PROBE/join401.log"
WB_CRED_FILE="$PROBE/cred.json" WB_STATUS_URL="$STUB_URL_401" \
  bash "$PROBE/repo/local/join.sh" --name alice \
  --out "$PROBE/share401.json" >"$OUT401" 2>&1
RC=$?
[ "$RC" != "0" ] && ok "死凭据时退出码非 0" || bad "死凭据居然成功了"
[ -f "$PROBE/share401.json" ] && bad "死凭据也生成了分享文件！" \
  || ok "死凭据不生成分享文件"
grep -q "401" "$OUT401" && ok "明确说明是 401" || bad "没说明原因"

echo "── 4) 仓库主侧：add-peer.sh 导入 ──"
kill "$STUB_PID" 2>/dev/null; STUB_PID=""
rm -f "$PROBE/port"
STUB_URL="$(start_stub 200)"
OUTA="$PROBE/add.log"
WB_STATE_DIR="$PROBE/state" WB_STATUS_URL="$STUB_URL" \
  bash "$PROBE/repo/local/add-peer.sh" "$PROBE/share.json" \
  --no-push >"$OUTA" 2>&1
RC=$?
[ "$RC" = "0" ] && ok "add-peer.sh 退出码 0" || bad "add-peer.sh 退出码 $RC"
[ -f "$PROBE/repo/state/peers/alice.enc" ] && ok "已落盘 state/peers/alice.enc" \
  || bad "快照没落盘"
[ -f "$PROBE/state/peer-keys.json" ] && ok "已写入密钥登记簿" || bad "没有登记簿"
[ "$(stat -f %Lp "$PROBE/state/peer-keys.json")" = "600" ] \
  && ok "登记簿权限 600" || bad "登记簿权限不是 600"
grep -q "解密验证通过" "$OUTA" && ok "导入前先做了解密验证" || bad "没做解密验证"
grep -q "$FAKE_TOKEN" "$OUTA" && bad "导入输出里出现了 token！" || ok "导入输出无 token"
KEY="$(jq -r '.alice' "$PROBE/state/peer-keys.json")"
grep -q "$KEY" "$OUTA" && bad "导入输出里打印了密钥明文！" \
  || ok "导入输出不含密钥明文（只打码显示）"
grep -q '{"alice":"\*\*\*\*"}' "$OUTA" && ok "Secret 预览已打码" || bad "Secret 预览没打码"

echo "── 5) 落盘的快照确实能被登记簿里的密钥解开（独立复核）──"
DEC="$(export RT_KEY="$KEY"; openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -md sha256 -in "$PROBE/repo/state/peers/alice.enc" -pass env:RT_KEY 2>/dev/null || true)"
printf '%s' "$DEC" | jq -e '.access_token and .uid' >/dev/null 2>&1 \
  && ok "解密成功且字段完整" || bad "解不开或字段缺失"
printf '%s' "$DEC" | jq -r '.notify_webhook' | grep -q "HOOKSECRET" \
  && ok "通知地址已随快照一起带过来" || bad "通知地址没带过来"
printf '%s' "$DEC" | jq -r '.peer_slug' | grep -qx "alice" \
  && ok "快照里记了账号标识" || bad "快照缺账号标识"

echo "── 6) 密钥与密文不匹配时必须拒绝导入 ──"
kill "$STUB_PID" 2>/dev/null; STUB_PID=""
rm -f "$PROBE/port"
STUB_URL="$(start_stub 200)"
cp "$PROBE/share.json" "$PROBE/tampered.json"
# 把密钥替换成另一把随机密钥（等价于「文件被改动 / 发错了密钥」）
WRONG="$(openssl rand -hex 32)"
jq --arg k "$WRONG" '.key = $k' "$PROBE/share.json" >"$PROBE/tampered.json"
OUTT="$PROBE/tamper.log"
WB_STATE_DIR="$PROBE/state2" WB_STATUS_URL="$STUB_URL" \
  bash "$PROBE/repo/local/add-peer.sh" "$PROBE/tampered.json" \
  --as tampered --no-push >"$OUTT" 2>&1
RC=$?
[ "$RC" != "0" ] && ok "密钥不匹配时退出码非 0" || bad "密钥不匹配竟然导入成功"
[ -f "$PROBE/repo/state/peers/tampered.enc" ] \
  && bad "密钥不匹配却仍然落盘了！" || ok "密钥不匹配不落盘"
grep -q "解密失败" "$OUTT" && ok "明确报出解密失败" || bad "没报解密失败"

echo "── 7) --list / --remove ──"
OUTL="$(WB_STATE_DIR="$PROBE/state" bash "$PROBE/repo/local/add-peer.sh" --list 2>&1)"
printf '%s' "$OUTL" | grep -q "alice" && ok "--list 列出账号" || bad "--list 没列出账号"
printf '%s' "$OUTL" | grep -q "$KEY" && bad "--list 打印了密钥！" || ok "--list 不打印密钥"
WB_STATE_DIR="$PROBE/state" bash "$PROBE/repo/local/add-peer.sh" \
  --remove alice --no-push >/dev/null 2>&1
[ -f "$PROBE/repo/state/peers/alice.enc" ] && bad "--remove 没删掉快照" \
  || ok "--remove 删掉了快照"
jq -e '.alice' "$PROBE/state/peer-keys.json" >/dev/null 2>&1 \
  && bad "--remove 没清掉登记簿里的密钥" || ok "--remove 清掉了登记簿密钥"

echo
printf '════ 结果：通过 %s 项，失败 %s 项 ════\n' "$pass" "$fail"
[ "$fail" = "0" ] || exit 1
