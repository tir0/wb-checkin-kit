#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""通知能力的回归测试（无需 pytest，直接 python3 运行）
================================================================
    python3 tests/test_notify.py

覆盖三类关注点：
  1. 该发的发、不该发的静默 —— 逐分支断言，防止以后改逻辑时通知失效
  2. 安全 —— 推送内容与请求体绝不含凭据明文
  3. 健壮 —— 通知通道故障时不污染退出码

依赖本机登录态文件才能跑的用例（真实凭据相关）会在缺失时自动跳过，
其余用例只需要能访问 copilot.tencent.com。
"""
import http.server
import json
import os
import sys
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(REPO, "scripts"))

# 会话注入的代理会拦掉本地 mock webhook，也会干扰真实接口，先清干净
for _k in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
           "http_proxy", "https_proxy", "all_proxy"):
    os.environ.pop(_k, None)

import wb_core  # noqa: E402

# 用一个必然无效的 token 触发 401，这样鉴权类用例不依赖任何真实凭据
BAD_TOK, BAD_UID = "invalid-probe-token", "00000000-0000-0000-0000-000000000000"

RECV = []


class Mock(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        RECV.append({"ctype": self.headers.get("Content-Type"),
                     "body": self.rfile.read(n).decode("utf-8", "replace")})
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"errcode":0,"errmsg":"ok"}')

    def log_message(self, *a):
        pass


def load_creds():
    """返回本机 (accessToken, uid)，没有则 (None, None)。"""
    for p in wb_core.LOCAL_AUTH_CANDIDATES:
        if p and os.path.isfile(p):
            try:
                d = json.load(open(p, encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            tok = (d.get("auth") or {}).get("accessToken")
            uid = (d.get("account") or {}).get("uid")
            # 凭据文件的形态会随桌面端升级变化：2026-09-23 起桌面端启用了静态
            # 加密，accessToken 从明文 JWT 变成了 {"$wbEncrypted":1,"envelope":...}
            # 封套对象。此时没有可读的明文 token，等价于「本机没有登录态」，
            # 应当让依赖真实凭据的用例走跳过分支 —— 而不是把 dict 塞给
            # 后续的字符串操作，让测试以 TypeError 的方式炸掉。
            if isinstance(tok, str) and uid:
                return tok, str(uid)
    return None, None


RESULTS = []


def check(label, cond, extra=""):
    RESULTS.append(bool(cond))
    print(f"  {'✓' if cond else '✗'} {label}{(' — ' + extra) if extra else ''}")


def run(tok, uid, expect_exit, expect_notify, extra_env=None, hook=None, status_only=False):
    RECV.clear()
    os.environ["NOTIFY_WEBHOOK"] = hook or ""
    os.environ.pop("NOTIFY_ON_SUCCESS", None)
    for k, v in (extra_env or {}).items():
        os.environ[k] = v
    code, res = wb_core.checkin(tok, uid, status_only=status_only, log=lambda m: None)
    return code, res, len(RECV) > 0


def main():
    srv = http.server.HTTPServer(("127.0.0.1", 0), Mock)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    hook = f"http://127.0.0.1:{srv.server_port}/"

    tok, uid = load_creds()
    have_creds = bool(tok and uid)

    print("\n[1] 该发 / 不该发")
    code, _, sent = run("", "", 2, True, hook=hook)
    check(f"缺凭据 exit={code} 且已推送", code == 2 and sent)

    code, res, sent = run(BAD_TOK, BAD_UID, 1, True, hook=hook)
    check(f"鉴权失败 exit={code} 且已推送", code == 1 and sent, res.get("action", ""))

    if have_creds:
        code, _, sent = run(tok, uid, 0, False, hook=hook)
        check(f"正常完成 exit={code} 且默认静默", code == 0 and not sent)

        # 真实链路上「该不该有回执」由本次的 action 决定，而 action 又取决于
        # 今天是否已经签过 —— 所以这里不做固定预期，只断言两者一致：
        # 本次签上了（checked_in）→ 有回执；今天早已签过（already_checked_in）→ 静默。
        code, res, sent = run(tok, uid, 0, None, hook=hook,
                              extra_env={"NOTIFY_ON_SUCCESS": "1"})
        act = res.get("action", "")
        check(f"回执与本次结局一致（{act}）",
              code == 0 and sent == (act in ("checked_in", "inactive")), act)

        code, res, sent = run(tok, uid, 0, False, hook=hook,
                              extra_env={"NOTIFY_ON_SUCCESS": "1"}, status_only=True)
        check("status_only 调试模式永不推送",
              code == 0 and not sent, res.get("action", ""))
    else:
        print("  · 跳过 3 项：需要本机登录态文件")

    # ── 回执策略：只有「本次真的签上了」才发 ──────────────────────────────
    # 合成 result 直接测这一层判定，不依赖真实接口当天返回什么。
    # 背景：工作流一天跑 5 次（含喵喵旅行的领取窗口），若把「今日已签到」
    # 也算作成功回执，同一句话会重复播报 4 遍。
    print("\n[1b] 回执策略：已签到不重复播报")

    def receipt(action, on_success):
        RECV.clear()
        if on_success is None:
            os.environ.pop("NOTIFY_ON_SUCCESS", None)
        else:
            os.environ["NOTIFY_ON_SUCCESS"] = on_success
        sent = wb_core.send_alert(0, {"action": action}, webhook=hook,
                                  log=lambda m: None)
        return sent, len(RECV) > 0

    s, got = receipt("checked_in", "1")
    check("本次签到成功 + 开回执 → 推一条", s and got)
    s, got = receipt("already_checked_in", "1")
    check("今日已签到 + 开回执 → 静默（不重复播报）", not s and not got)
    s, got = receipt("inactive", "1")
    check("活动未开放 + 开回执 → 照推（这个状态需要你知道）", s and got)
    s, got = receipt("checked_in", None)
    check("本次签到成功 + 未开回执 → 静默", not s and not got)
    s, got = receipt("already_checked_in", None)
    check("今日已签到 + 未开回执 → 静默", not s and not got)
    s, got = receipt("auth_failed", None)
    check("需要人工介入时无视开关，一律推", s and got)
    os.environ.pop("NOTIFY_ON_SUCCESS", None)

    # 未配置 webhook 时应当完全静默（零侵入）
    code, _, sent = run("", "", 2, False, hook="")
    check("未配置 NOTIFY_WEBHOOK 时完全静默", code == 2 and not sent)

    print("\n[2] 安全：不泄露凭据")
    RECV.clear()
    os.environ["NOTIFY_WEBHOOK"] = hook
    wb_core.checkin(BAD_TOK, BAD_UID, log=lambda m: None)
    body = RECV[0]["body"] if RECV else ""
    leak = [s for s in (BAD_TOK, BAD_UID, tok or "", uid or "") if s and s in body]
    check("推送体不含凭据明文", not leak, str(leak) if leak else "")
    check("推送体含可执行的恢复指引", "jq -r" in body)

    print("\n[3] 渠道与健壮性")
    for u, want in {
        "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=x": "wecom",
        "https://oapi.dingtalk.com/robot/send?access_token=x": "wecom",
        "https://sctapi.ftqq.com/SCT123.send": "serverchan",
        "https://hooks.slack.com/services/x": "generic",
    }.items():
        check(f"识别 {want:<10}", wb_core._notify_kind(u) == want)

    RECV.clear()
    check("拒绝非 http(s) 的 webhook",
          wb_core.send_alert(1, {"action": "auth_failed"}, webhook="ftp://x/y",
                             log=lambda m: None) is False and not RECV)

    code, _, _ = run("", "", 2, False, hook="http://127.0.0.1:1/")
    check("通知通道故障时退出码不受污染", code == 2)

    # fake transport：零网络核对各渠道请求体结构
    CAP = []

    class FakeResp:
        status = 200

        def read(self):
            return b'{"errcode":0}'

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def fake_urlopen(req, timeout=None):
        CAP.append((req.get_header("Content-type"), req.data.decode("utf-8")))
        return FakeResp()

    real = wb_core.urllib.request.urlopen
    wb_core.urllib.request.urlopen = fake_urlopen
    try:
        rg = {"ok": False, "action": "auth_failed", "http": 401, "code": 401}
        for u, label, ok in [
            ("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=K", "企业微信",
             lambda b: '"msgtype": "text"' in b and '"content"' in b),
            ("https://oapi.dingtalk.com/robot/send?access_token=K", "钉钉",
             lambda b: '"msgtype": "text"' in b and '"content"' in b),
            ("https://sctapi.ftqq.com/SCT1.send", "Server酱",
             lambda b: "title=" in b and "desp=" in b),
            ("https://hooks.slack.com/services/K", "通用",
             lambda b: b.startswith('{"text":')),
        ]:
            CAP.clear()
            wb_core.send_alert(1, rg, webhook=u, log=lambda m: None)
            body = CAP[0][1] if CAP else ""
            check(f"{label} 请求体结构", bool(body) and ok(body))
            check(f"{label} 请求体不含凭据", not any(
                s and s in body for s in (tok or "", uid or "", BAD_TOK, BAD_UID)))
    finally:
        wb_core.urllib.request.urlopen = real

    print("\n[4] 投递结果判定：HTTP 200 不等于送达")
    for body, want_ok, why in [
        (b'{"errcode":0,"errmsg":"ok"}', True, "钉钉/企业微信 成功"),
        (b'{"errcode":310000,"errmsg":"keywords not in content"}', False,
         "钉钉 关键词不匹配"),
        (b'{"errcode":300001,"errmsg":"robot not exist"}', False, "钉钉 机器人不存在"),
        (b'{"code":0,"message":"","data":{}}', True, "Server酱 成功"),
        (b'{"code":40001,"message":"bad key"}', False, "Server酱 失败"),
        (b'{"errcode":0}', True, "仅含成功码"),
        (b'', True, "空正文按成功处理（无法判定不误报）"),
        (b'ok', True, "非 JSON 正文按成功处理"),
    ]:
        got, _ = wb_core._notify_delivered(body)
        check(why, got is want_ok)

    # 端到端：渠道回 errcode != 0 时，send_alert 必须返回 False 而不是谎报成功
    class RejectResp:
        status = 200

        def read(self):
            return b'{"errcode":310000,"errmsg":"keywords not in content"}'

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    real_reject = wb_core.urllib.request.urlopen
    wb_core.urllib.request.urlopen = lambda req, timeout=None: RejectResp()
    try:
        got = wb_core.send_alert(
            1, {"action": "auth_failed"},
            webhook="https://oapi.dingtalk.com/robot/send?access_token=K",
            log=lambda m: None)
        check("渠道拒收时返回 False（不谎报成功）", got is False)
    finally:
        wb_core.urllib.request.urlopen = real_reject

    print("\n[5] 文案不得残留已废弃的架构（云函数时代）")
    _, body_auth = wb_core.render_alert(1, {"action": "auth_failed"})
    for stale in ("WB_ACCESS_TOKEN", "WB_UID", "函数配置", "云函数"):
        check(f"auth_failed 文案不含「{stale}」", stale not in body_auth)
    check("auth_failed 文案指向当前同步器",
          "wb-sync-credentials.sh" in body_auth)

    _, body_miss = wb_core.render_alert(2, {"action": "missing_credentials"})
    for stale in ("WB_ACCESS_TOKEN", "函数配置", "云函数"):
        check(f"missing_credentials 文案不含「{stale}」", stale not in body_miss)
    check("missing_credentials 文案指向当前同步器",
          "wb-sync-credentials.sh" in body_miss)

    srv.shutdown()

    total, ok_n = len(RESULTS), sum(RESULTS)
    print(f"\n{'=' * 46}\n通过 {ok_n}/{total} 项")
    return 0 if ok_n == total else 1


if __name__ == "__main__":
    sys.exit(main())
