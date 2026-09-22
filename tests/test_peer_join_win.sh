#!/bin/bash
# ==============================================================================
# 回归测试：Windows 朋友侧 join.ps1 → 仓库主侧 add-peer.sh
# ==============================================================================
#   bash tests/test_peer_join_win.sh
#
# 为什么需要它
#   join.ps1 是 join.sh 的 Windows 等价物，但它换了一套完全不同的加解密实现
#   （.NET 的 Rfc2898DeriveBytes + Aes，而不是 openssl 命令行）。这条缝最容易
#   悄悄裂开：**密文格式只要差一个字节，仓库主那边就是一律解不开**，而朋友
#   手上没有 openssl，自己发现不了。所以这里必须真跑：
#     1. 用 PowerShell 真的产出一份分享文件；
#     2. 用仓库主侧的 openssl 真的把它解开（跨实现互操作）；
#     3. 再走一遍 add-peer.sh，确认能落盘入库。
#
# 静态断言永远执行；端到端部分需要本机有 pwsh（PowerShell 7）。
# 没有 pwsh 时会明确打印「跳过」，不会假装通过。
#   · 装了 PowerShell 的 macOS/Linux：PATH 里有 pwsh 即可
#   · 想指定路径：WB_PWSH=/path/to/pwsh bash tests/test_peer_join_win.sh
# ==============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PROBE="$(mktemp -d "${TMPDIR:-/tmp}/wb-joinwin-XXXXXX")"
STUB_PID=""
cleanup() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
  rm -rf "$PROBE"
}
trap cleanup EXIT

pass=0; fail=0; skip=0
ok()   { printf '  \xe2\x9c\x93 %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \xe2\x9c\x97 %s\n' "$1"; fail=$((fail+1)); }
note() { printf '  - %s\n' "$1"; skip=$((skip+1)); }

JOINPS="$REPO/local/join.ps1"
PYTHON="${PYTHON:-python3}"
for c in jq openssl curl git "$PYTHON"; do
  command -v "$c" >/dev/null 2>&1 || { echo "缺少依赖：$c"; exit 1; }
done

# 只取「会真正执行的代码行」：剥掉 <# ... #> 帮助块与整行注释。
# 为什么需要：断言要盯的是代码与实际输出文案，而不是注释。否则帮助块里那句
# 「不要用 ✓ ✗ ⚠」会被当成违规——守卫自己被自己绊倒。
emit_lines() {
  # 先剥掉开头的 UTF-8 BOM：否则第一行是「\xEF\xBB\xBF<#」，
  # awk 的 /^[[:space:]]*<#/ 匹配不上，整段帮助块会被当成代码（守卫失效）。
  local body="$PROBE/ps.body"
  if [ "$(head -c 3 "$JOINPS" | od -An -tx1 | tr -d ' ')" = "efbbbf" ]; then
    tail -c +4 "$JOINPS" >"$body"
  else
    cp "$JOINPS" "$body"
  fi
  awk '/^[[:space:]]*<#/{skip=1; next} skip && /#>/{skip=0; next} !skip && !/^[[:space:]]*#/{print}' "$body"
}

# ==============================================================================
echo "── 1) 静态：文件形态与中文 Windows 兼容性 ──"
# ==============================================================================
[ -f "$JOINPS" ] && ok "local/join.ps1 存在" || bad "找不到 local/join.ps1"

# PowerShell 5.1 对「无 BOM 的 UTF-8」按系统代码页（中文系统是 GBK）解码，
# 中文提示会整段变乱码 —— 所以这个 BOM 是功能性的，不是风格问题。
BOM="$(head -c 3 "$JOINPS" | od -An -tx1 | tr -d ' ')"
[ "$BOM" = "efbbbf" ] && ok "带 UTF-8 BOM（PS 5.1 读中文必需）" \
  || bad "缺少 UTF-8 BOM（PS 5.1 下中文会乱码），实际 ${BOM:-空}"
[ "$(head -c 6 "$JOINPS" | od -An -tx1 | tr -d ' ')" != "efbbbfefbbbf" ] \
  && ok "只有一个 BOM，没有重复" || bad "出现了重复 BOM"

# ✓ ✗ ⚠ 不在 GBK 字符集里，中文控制台（代码页 936）会显示成问号
for glyph in "✓" "✗" "⚠"; do
  if emit_lines | grep -q -- "$glyph"; then
    bad "用了 GBK 显示不出的符号：${glyph}（中文 Windows 控制台会变问号）"
  else
    ok "未使用不可显示符号 $glyph"
  fi
done

# 与 openssl 对齐的算法参数：任一改动都会导致云端解不开
for pat in "Rfc2898DeriveBytes" "200000" "HashAlgorithmName]::SHA256" "Salted__" \
           "Aes]::Create()" "CipherMode]::CBC" "PaddingMode]::PKCS7" "GetBytes(48)"; do
  emit_lines | grep -q -- "$pat" && ok "含 $pat" || bad "缺少 $pat"
done

# 无 BOM 写出：Set-Content -Encoding UTF8 会带 BOM，BOM 不是合法 JSON
grep -q "Write-TextNoBom" "$JOINPS" && grep -q 'UTF8Encoding($false)' "$JOINPS" \
  && ok "JSON 明文一律无 BOM 写出" || bad "JSON 写出方式可能带 BOM"
emit_lines | grep -q "Set-Content" && bad "用了 Set-Content（PS 5.1 会写 BOM）" \
  || ok "未误用 Set-Content"

# 参数面与 join.sh 对齐
for p in "\$Name" "\$Notify" "\$Out" "\$CredFile" "\$Split" "\$Print" \
         "\$StatusOnly" "\$Offline" "\$SelfTest"; do
  grep -q -- "\[string\]${p}\|\[switch\]${p}" "$JOINPS" && ok "参数 ${p} 已声明" \
    || bad "参数 ${p} 未声明"
done

# 密钥只能经加密用掉，或（仅 -Split 模式）打印给本人
grep -q 'pass env:' "$JOINPS" && bad "join.ps1 里出现了 openssl 用法（Windows 上不该依赖它）" \
  || ok "不依赖 openssl 命令行（纯 .NET 实现）"

# ==============================================================================
PWSH="${WB_PWSH:-$(command -v pwsh 2>/dev/null || true)}"
if [ -z "$PWSH" ] || [ ! -x "$PWSH" ]; then
  echo "── 2) 端到端：跳过（本机没有 pwsh）──"
  note "静态断言已覆盖格式与参数；完整互操作验证请在装有 PowerShell 7 的机器上跑"
  note "  安装：brew install --cask powershell  或  WB_PWSH=/path/to/pwsh bash $0"
  echo
  printf '════ 结果：通过 %s 项，失败 %s 项，跳过 %s 项 ════\n' "$pass" "$fail" "$skip"
  [ "$fail" = "0" ] || exit 1
  exit 0
fi

echo "── 2) 端到端：PowerShell 版本与加密自检 ──"
PSVER="$("$PWSH" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>&1 | tr -d '\r' | tail -1)"
ok "pwsh 可用：$PSVER"
"$PWSH" -NoProfile -File "$JOINPS" -SelfTest >"$PROBE/selftest.log" 2>&1
[ "$?" = "0" ] && ok "自检退出码 0" || { bad "自检失败"; sed 's/^/    /' "$PROBE/selftest.log"; }
grep -q "往返一致" "$PROBE/selftest.log" && ok "加密→解密往返一致" || bad "自检没报往返一致"
grep -q "Salted__" "$PROBE/selftest.log" && ok "密文头为 Salted__（与 openssl -salt 同格式）" \
  || bad "自检没确认密文头"

# ==============================================================================
echo "── 3) 端到端：跑 join.ps1 产出分享文件 ──"
# ==============================================================================
FAKE_TOKEN="eyJhbGciOiJIUzI1NiJ9.fake-token-for-win-test.zzz"
FAKE_UID="05381c3b-8cc0-4ce0-ac74-69ca96730756"
HOOK="https://oapi.dingtalk.com/robot/send?access_token=WINSECRET"
printf '{"auth":{"accessToken":"%s","lastRefreshTime":1789695329435,"expiresAt":1794447328838},"account":{"uid":"%s"}}\n' \
  "$FAKE_TOKEN" "$FAKE_UID" >"$PROBE/cred.json"

# 桩：只有收到正确的 Authorization / X-User-Id 才返回 200，否则 401
# （这样「发对了请求头」这件事也被真正验证，而不是只看脚本自己怎么报）
start_stub() {
  local mode="$1"
  "$PYTHON" - "$PROBE/port" "$PROBE/stub_headers.txt" "$mode" \
            "$FAKE_TOKEN" "$FAKE_UID" >"$PROBE/stub.log" 2>&1 <<'PY' &
import http.server, socketserver, sys
port_file, hdr_file, mode, want_token, want_uid = sys.argv[1:6]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        auth = self.headers.get("Authorization", "")
        uid = self.headers.get("X-User-Id", "")
        with open(hdr_file, "a") as fh:
            fh.write(f"Authorization: {auth}\nX-User-Id: {uid}\n")
        ok = (auth == "Bearer " + want_token) and (uid == want_uid)
        code = 401 if mode == "401" else (200 if ok else 401)
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

STUB_URL="$(start_stub 200)"
WLOG="$PROBE/join_win.log"
WB_CRED_FILE="$PROBE/cred.json" "$PWSH" -NoProfile -File "$JOINPS" \
  -Name alice -Notify "$HOOK" -StatusUrl "$STUB_URL" \
  -Out "$PROBE/share_win.json" >"$WLOG" 2>&1
RC=$?
[ "$RC" = "0" ] && ok "join.ps1 退出码 0" || { bad "join.ps1 退出码 $RC"; sed 's/^/    /' "$WLOG"; }
grep -q "凭据校验通过" "$WLOG" && ok "调接口校验了凭据（HTTP 200）" || bad "没做凭据校验"
grep -q "WINSECRET\|$FAKE_TOKEN\|$FAKE_UID" "$WLOG" \
  && bad "屏幕输出里泄露了凭据或机器人地址" || ok "输出无凭据、无机器人令牌、无 uid"
grep -q "^Authorization: Bearer $FAKE_TOKEN$" "$PROBE/stub_headers.txt" 2>/dev/null \
  && ok "真的把 Authorization 头发对了" || bad "Authorization 头不对"
grep -qx "X-User-Id: $FAKE_UID" "$PROBE/stub_headers.txt" 2>/dev/null \
  && ok "真的把 X-User-Id 头发对了" || bad "X-User-Id 头不对"

[ -f "$PROBE/share_win.json" ] && ok "已生成分享文件" || bad "没生成分享文件"
# 无 BOM：BOM 不是合法 JSON，下游解析器不一定容忍
[ "$(head -c 3 "$PROBE/share_win.json" | od -An -tx1 | tr -d ' ')" != "efbbbf" ] \
  && ok "分享文件无 BOM" || bad "分享文件带 BOM（jq 能容忍，但 Python json.loads 会报错）"
jq -e '.enc_b64 and .key and .slug' "$PROBE/share_win.json" >/dev/null 2>&1 \
  && ok "分享文件是合法 JSON 且字段齐全" || bad "分享文件结构不对"
jq -r '.slug' "$PROBE/share_win.json" | grep -qx "alice" && ok "slug = alice" || bad "slug 不对"
jq -r '.key' "$PROBE/share_win.json" | grep -Eq '^[0-9a-f]{64}$' \
  && ok "密钥为 64 位小写十六进制（与 join.sh 一致）" || bad "密钥格式不对"
# jq -r 输出末尾自带一个换行，所以「值里没有内嵌换行」对应 wc -l == 1
[ "$(jq -r '.enc_b64' "$PROBE/share_win.json" | wc -l | tr -d ' ')" = "1" ] \
  && ok "密文是单行 base64（无折行，openssl -A 才能解）" || bad "密文含内嵌换行"
jq -r '.enc_b64' "$PROBE/share_win.json" | grep -Eq '^[A-Za-z0-9+/]+=*$' \
  && ok "密文是标准 base64（含 = 填充）" || bad "密文不是标准 base64"

# ==============================================================================
echo "── 4) 互操作：仓库主侧 openssl 能解开 PowerShell 产出的密文 ──"
# ==============================================================================
WINKEY="$(jq -r '.key' "$PROBE/share_win.json")"
jq -r '.enc_b64' "$PROBE/share_win.json" | openssl base64 -d -A >"$PROBE/win.enc" 2>/dev/null
DEC="$(export RT_KEY="$WINKEY"; openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -md sha256 -in "$PROBE/win.enc" -pass env:RT_KEY 2>/dev/null)"
DEC_RC=$?
[ "$DEC_RC" = "0" ] && ok "openssl 解密成功（跨实现互操作成立）" \
  || bad "openssl 解不开 PowerShell 产出的密文（rc=${DEC_RC}）"
printf '%s' "$DEC" | jq -e '.access_token and .uid' >/dev/null 2>&1 \
  && ok "解出的 JSON 含 access_token 与 uid" || bad "解出的内容缺字段"
[ "$(printf '%s' "$DEC" | jq -r '.access_token')" = "$FAKE_TOKEN" ] \
  && ok "access_token 与原文逐字节一致" || bad "access_token 不一致"
[ "$(printf '%s' "$DEC" | jq -r '.notify_webhook')" = "$HOOK" ] \
  && ok "通知地址原样带过来了" || bad "通知地址不一致"
[ "$(printf '%s' "$DEC" | jq -r '.schema')" = "2" ] && ok "schema=2（与 join.sh 同代）" \
  || bad "schema 不对"
[ "$(printf '%s' "$DEC" | jq -r '.synced_at_utc')" != "" ] \
  && ok "带上了同步时间戳" || bad "缺 synced_at_utc"

# ==============================================================================
echo "── 5) 仓库主侧 add-peer.sh 能正常导入（收尾闭环）──"
# ==============================================================================
mkdir -p "$PROBE/repo/local" "$PROBE/repo/state" "$PROBE/state"
cp "$REPO/local/join.sh" "$REPO/local/add-peer.sh" "$PROBE/repo/local/"
cp -r "$REPO/scripts" "$PROBE/repo/"
git -C "$PROBE/repo" init -q --initial-branch=main
git -C "$PROBE/repo" remote add origin git@github.com:SomeOwner/some-repo.git
git -C "$PROBE/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

ALOG="$PROBE/add_win.log"
WB_STATE_DIR="$PROBE/state" WB_STATUS_URL="$STUB_URL" \
  bash "$PROBE/repo/local/add-peer.sh" "$PROBE/share_win.json" --offline --no-push \
  >"$ALOG" 2>&1
RC=$?
[ "$RC" = "0" ] && ok "add-peer.sh 退出码 0" || { bad "add-peer.sh 退出码 $RC"; sed 's/^/    /' "$ALOG"; }
grep -q "解密验证通过" "$ALOG" && ok "导入前解密验证通过" || bad "解密验证没过"
[ -f "$PROBE/repo/state/peers/alice.enc" ] && ok "快照已落盘 state/peers/alice.enc" \
  || bad "快照没落盘"
cmp -s "$PROBE/win.enc" "$PROBE/repo/state/peers/alice.enc" \
  && ok "落盘的是原密文（未被改写）" || bad "落盘的密文与原件不一致"
grep -q "$WINKEY" "$ALOG" && bad "导入输出里打印了密钥明文！" || ok "导入输出不含密钥明文"

# ==============================================================================
echo "── 6) 边界：死凭据 / 账号标识归一化 / -StatusOnly / -Split ──"
# ==============================================================================
kill "$STUB_PID" 2>/dev/null; STUB_PID=""
rm -f "$PROBE/port"
STUB_URL_401="$(start_stub 401)"
WB_CRED_FILE="$PROBE/cred.json" "$PWSH" -NoProfile -File "$JOINPS" -Name alice \
  -StatusUrl "$STUB_URL_401" -Out "$PROBE/share401.json" >"$PROBE/w401.log" 2>&1
RC=$?
[ "$RC" != "0" ] && ok "凭据 401 时退出码非 0" || bad "死凭据居然成功了"
[ -f "$PROBE/share401.json" ] && bad "死凭据也生成了分享文件！" || ok "死凭据不生成分享文件"
grep -q "401" "$PROBE/w401.log" && ok "明确说明是 401" || bad "没说明原因"

kill "$STUB_PID" 2>/dev/null; STUB_PID=""
rm -f "$PROBE/port"
STUB_URL="$(start_stub 200)"

# 账号标识归一化：与 join.sh 的 tr 链等价（大小写/空格/非法字符）
WB_CRED_FILE="$PROBE/cred.json" "$PWSH" -NoProfile -File "$JOINPS" -Name 'AL Ice!' \
  -Offline -Out "$PROBE/share_norm.json" >"$PROBE/wnorm.log" 2>&1
[ "$(jq -r '.slug' "$PROBE/share_norm.json" 2>/dev/null)" = "al-ice" ] \
  && ok "账号标识归一化与 join.sh 一致（'AL Ice!' → al-ice）" \
  || bad "归一化结果不同：$(jq -r '.slug' "$PROBE/share_norm.json" 2>/dev/null)"

# 不给 -Name 时从 uid 派生（join.sh：去掉连字符后取前 6 位，前缀 u）
WB_CRED_FILE="$PROBE/cred.json" "$PWSH" -NoProfile -File "$JOINPS" \
  -Offline -Out "$PROBE/share_auto.json" >"$PROBE/wauto.log" 2>&1
[ "$(jq -r '.slug' "$PROBE/share_auto.json" 2>/dev/null)" = "u05381c" ] \
  && ok "不给 -Name 时按 uid 派生（→ u05381c）" \
  || bad "派生结果不同：$(jq -r '.slug' "$PROBE/share_auto.json" 2>/dev/null)"

# -StatusOnly：只校验、不产文件
rm -f "$PROBE/share_only.json"
WB_CRED_FILE="$PROBE/cred.json" "$PWSH" -NoProfile -File "$JOINPS" -StatusOnly \
  -StatusUrl "$STUB_URL" -Out "$PROBE/share_only.json" >"$PROBE/wonly.log" 2>&1
RC=$?
[ "$RC" = "0" ] && ok "-StatusOnly 退出码 0" || bad "-StatusOnly 退出码 ${RC}"
[ -f "$PROBE/share_only.json" ] && bad "-StatusOnly 竟然生成了文件" \
  || ok "-StatusOnly 不产出文件"
grep -q "仅校验模式" "$PROBE/wonly.log" && ok "说明了是仅校验模式" || bad "没说明模式"

# -Split：文件里只有密文，密钥只显示在屏幕
WB_CRED_FILE="$PROBE/cred.json" "$PWSH" -NoProfile -File "$JOINPS" -Name bob -Split \
  -StatusUrl "$STUB_URL" -Out "$PROBE/split.enc" >"$PROBE/wsplit.log" 2>&1
RC=$?
[ "$RC" = "0" ] && ok "-Split 退出码 0" || bad "-Split 退出码 $RC"
SPLIT_KEY="$(grep -oE '^ {6}[0-9a-f]{64}$' "$PROBE/wsplit.log" | tr -d ' ' | head -1)"
[ -n "$SPLIT_KEY" ] && ok "密钥已打印供另一渠道发送" || bad "没打印密钥"
grep -q '"key"' "$PROBE/split.enc" 2>/dev/null && bad "-Split 文件里竟然含密钥！" \
  || ok "-Split 文件里不含密钥"
# 用朋友那条渠道给的密钥，把密文导入（走 --key 路径）
SLOG="$PROBE/add_split.log"
WB_STATE_DIR="$PROBE/state" WB_STATUS_URL="$STUB_URL" \
  bash "$PROBE/repo/local/add-peer.sh" "$PROBE/split.enc" --as bob \
  --key "$SPLIT_KEY" --offline --no-push >"$SLOG" 2>&1
RC=$?
[ "$RC" = "0" ] && ok "-Split 密文可正常导入（--key 路径）" \
  || { bad "-Split 密文导入失败（rc=${RC}）"; sed 's/^/    /' "$SLOG"; }
[ -f "$PROBE/repo/state/peers/bob.enc" ] && ok "bob 快照已落盘" || bad "bob 快照没落盘"

# 找不到登录态时必须给出人话，而不是一堆堆栈
"$PWSH" -NoProfile -File "$JOINPS" -CredFile "$PROBE/does-not-exist.info" \
  -Offline -Out "$PROBE/never.json" >"$PROBE/wnocred.log" 2>&1
RC=$?
[ "$RC" != "0" ] && ok "登录态缺失时退出码非 0" || bad "登录态缺失竟然成功"
grep -q "读不到本机登录态" "$PROBE/wnocred.log" && ok "给出的是可读的中文提示" \
  || bad "没有可读提示"
grep -qi "At line\|CategoryInfo\|FullyQualifiedErrorId" "$PROBE/wnocred.log" \
  && bad "输出里有 PowerShell 堆栈（应给人话）" || ok "输出里没有原始堆栈"

# 登录态是坏 JSON 时同样要给人话
printf '{"auth": ' >"$PROBE/bad.json"
"$PWSH" -NoProfile -File "$JOINPS" -CredFile "$PROBE/bad.json" \
  -Offline -Out "$PROBE/never2.json" >"$PROBE/wbad.log" 2>&1
RC=$?
[ "$RC" != "0" ] && ok "坏 JSON 时退出码非 0" || bad "坏 JSON 竟然成功"
grep -q "不是合法 JSON" "$PROBE/wbad.log" && ok "坏 JSON 给出可读提示" || bad "坏 JSON 没给提示"

kill "$STUB_PID" 2>/dev/null; STUB_PID=""

echo
printf '════ 结果：通过 %s 项，失败 %s 项，跳过 %s 项 ════\n' "$pass" "$fail" "$skip"
[ "$fail" = "0" ] || exit 1
