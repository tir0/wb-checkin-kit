#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""「派喵喵去旅行」自动化链路的回归测试（无需 pytest）
=======================================================
    python3 tests/test_travel.py

喵喵旅行与签到共用同一份凭据快照，但**风险点完全不同**，本测试逐一钉住：

  1. 【幂等】脚本被挂在任意频率的定时任务上，重复运行绝不能重复派出、
     也不能重复领取 —— 这是「靠多次运行闭环」这个方案成立的前提。
  2. 【状态机】idle / traveling / arrived × daily_limit_reached 的每个组合
     都必须走到正确分支，退出码符合约定（0 正常 / 1 需处理 / 2 缺凭据）。
  3. 【竞态】claim 撞上「还没到 / 已被领走」、depart 撞上「今日已派 /
     已在路上」都不是失败 —— 那是服务端状态刚变，判成失败会制造假告警。
  4. 【保密】token / uid 不得出现在日志或通知正文里。
  5. 【通知】只在「领取成功 / 需人工介入」时推送；日常的已派出 / 旅行中 /
     今天已完成必须静默，否则每天一条变骚扰。

全程不联网：wb_travel.api 被替换成桩，逐请求断言。
"""
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SCRIPTS = os.path.join(REPO, "scripts")

sys.path.insert(0, SCRIPTS)

import wb_travel    # noqa: E402

RESULTS = []
TOKEN = "eyJfake.token.value"      # 故意用带点号的假串，便于断言「没漏出去」
UIDV = "1234567890abcdefghijklmnopqrstuvwxyz"

SERVER_NOW = 1790068881            # 2026-09-22 17:21:21 CST

S = wb_travel.PATH_STATUS
C = wb_travel.PATH_CONFIG
D = wb_travel.PATH_DEPART
CL = wb_travel.PATH_CLAIM


def check(label, cond, extra=""):
    RESULTS.append(bool(cond))
    print(f"  {'✓' if cond else '✗'} {label}{(' — ' + extra) if extra else ''}")


def section(title):
    print(f"\n── {title} " + "─" * max(2, 44 - len(title)))


# ── 桩 ──────────────────────────────────────────────────────────────────────
def status_payload(state="idle", daily=False, **over):
    data = {
        "state": state, "buddy_id": 88, "record_id": 7926707, "location": None,
        "depart_at": 0, "arrive_at": 0, "server_now": SERVER_NOW,
        "letter": None, "use_deeplink": "", "daily_limit_reached": daily,
        "duration_hours": 0, "reward_credit": 0,
    }
    data.update(over)
    return {"code": 0, "msg": "OK", "data": data}


def config_payload(locations=None):
    if locations is None:
        locations = [
            {"id": i, "name": n, "duration_hours_min": 1, "duration_hours_max": 4,
             "reward_credit_min": 5, "reward_credit_max": 10}
            for i, n in enumerate(["咖啡馆", "商场店铺", "健身房", "古镇客栈"], 1)
        ]
    return {"code": 0, "msg": "OK",
            "data": {"locations": locations, "server_now": SERVER_NOW}}


def run_case(responses, token=TOKEN, uid=UIDV, **kw):
    """跑一次 run()，返回 (exit_code, result, 请求列表, 日志, 通知列表)。"""
    calls, logs, notes = [], [], []

    def fake_api(method, path, tok, uidv, body=None, timeout=15):
        calls.append((method, path, body))
        key = (method, path)
        if key not in responses:
            raise AssertionError(f"未预期的请求：{key}")
        value = responses[key]
        if isinstance(value, Exception):
            raise value
        return value

    orig = wb_travel.api
    wb_travel.api = fake_api
    try:
        code, res = wb_travel.run(
            token, uid,
            log=lambda m: logs.append(m),
            notify=lambda c, r: notes.append((c, r)),
            **kw,
        )
    finally:
        wb_travel.api = orig
    return code, res, calls, logs, notes


def notify_decision(action, exit_code=0, **extra):
    """只测「该不该发」：把 deliver 换掉，看它有没有被调用。"""
    captured = []
    orig = wb_travel.deliver

    def fake_deliver(title, text, webhook=None, log=None):
        captured.append((title, text))
        return True

    payload = {"action": action}
    payload.update(extra)

    wb_travel.deliver = fake_deliver
    try:
        sent = wb_travel.send_travel_alert(
            exit_code, payload,
            webhook="https://oapi.dingtalk.com/robot/send?access_token=x",
            log=lambda m: None)
    finally:
        wb_travel.deliver = orig
    return sent, captured


def main():
    # ── [1] 接口契约（防止逆向结论漂移）────────────────────────────────
    section("[1] 接口契约")
    check("端点与实测一致", wb_travel.ENDPOINT == "https://www.workbuddy.cn",
          wb_travel.ENDPOINT)
    for label, got, want in (
        ("status", S, "/activity/growth/buddy/travel/status"),
        ("config", C, "/activity/growth/buddy/travel/config"),
        ("depart", D, "/activity/growth/buddy/travel/depart"),
        ("claim", CL, "/activity/growth/buddy/travel/claim"),
    ):
        check(f"{label} 路径", got == want, got)

    # ── [2] 状态机四分支 ────────────────────────────────────────────────
    section("[2] 状态机 idle / traveling / arrived")

    code, res, calls, _, _ = run_case({
        ("GET", S): (200, status_payload("idle", False)),
        ("GET", C): (200, config_payload()),
        ("POST", D): (200, {"code": 0, "msg": "OK",
                            "data": {"state": "traveling", "location_id": 1,
                                     "depart_at": SERVER_NOW,
                                     "arrive_at": SERVER_NOW + 7200,
                                     "server_now": SERVER_NOW}}),
    })
    paths = [c[1] for c in calls]
    check("idle+今天没派 → status → config → depart", paths == [S, C, D], str(paths))
    check("退出码 0", code == 0, str(code))
    check("action=departed", res.get("action") == "departed", str(res.get("action")))
    check("派出带了合法的 location_id",
          calls[2][2] and calls[2][2].get("location_id") in (1, 2, 3, 4),
          str(calls[2][2]))
    check("eta 由 arrive_at-server_now 算出",
          res.get("eta") == "约 2 小时 0 分钟", str(res.get("eta")))

    code, res, calls, _, _ = run_case({
        ("GET", S): (200, status_payload("traveling", False,
                                         arrive_at=SERVER_NOW + 3600,
                                         location={"id": 1, "name": "咖啡馆"})),
    })
    check("traveling → 不派也不领（只发一次请求）", len(calls) == 1, str(len(calls)))
    check("traveling → 退出码 0 且 action/eta 正确",
          code == 0 and res.get("action") == "traveling"
          and res.get("eta") == "约 1 小时 0 分钟", str(res.get("eta")))

    code, res, calls, _, _ = run_case({
        ("GET", S): (200, status_payload("arrived", False,
                                         location={"id": 3, "name": "健身房"},
                                         arrive_at=SERVER_NOW - 60)),
        ("POST", CL): (200, {"code": 0, "msg": "OK",
                             "data": {"reward_credit": 8,
                                      "letter": {"id": 2,
                                                 "text": "亲爱的铲屎官：\n今天去了健身房。"},
                                      "use_deeplink": ""}}),
    })
    check("arrived → 只额外调 claim", [c[1] for c in calls] == [S, CL],
          str([c[1] for c in calls]))
    check("arrived → 退出码 0 且 action=claimed",
          code == 0 and res.get("action") == "claimed", str(res.get("action")))
    check("积分被带进结果", res.get("reward_credit") == 8, str(res.get("reward_credit")))
    check("信件正文被带进结果（供通知使用）",
          "健身房" in (res.get("letter") or ""), str(res.get("letter"))[:40])

    code, res, calls, _, _ = run_case({("GET", S): (200, status_payload("idle", True))})
    check("idle+今天已派 → 不请求 config/depart（只查询）",
          len(calls) == 1, str([c[1] for c in calls]))
    check("idle+今天已派 → action=today_done 且退出码 0",
          res.get("action") == "today_done" and code == 0, str(res.get("action")))

    # ── [3] 幂等：定时任务可以任意频繁运行 ──────────────────────────────
    section("[3] 幂等（反复运行不重复动作）")

    _, r1, _, _, _ = run_case({
        ("GET", S): (200, status_payload("idle", False)),
        ("GET", C): (200, config_payload()),
        ("POST", D): (200, {"code": 0, "msg": "OK", "data": {"state": "traveling"}}),
    })
    _, r2, c2, _, _ = run_case({("GET", S): (200, status_payload("idle", True))})
    _, r3, c3, _, _ = run_case({("GET", S): (200, status_payload("idle", True))})

    check("第一次：派出", r1.get("action") == "departed", str(r1.get("action")))
    check("第二次：不再派出（无 depart 请求）",
          D not in [c[1] for c in c2], str([c[1] for c in c2]))
    check("第三次（已领完）：today_done 且不重复领取",
          r3.get("action") == "today_done" and CL not in [c[1] for c in c3],
          str(r3.get("action")))

    # ── [4] 竞态与幂等错误：不得制造假告警 ──────────────────────────────
    section("[4] 竞态与幂等错误（不得制造假告警）")

    code, res, _, _, _ = run_case({
        ("GET", S): (200, status_payload("arrived", False)),
        ("POST", CL): (200, {"code": 40001, "msg": "not arrived yet"}),
    })
    check("claim 遇 not arrived yet → 退出码 0 且 not_ready",
          code == 0 and res.get("action") == "not_ready", str(res.get("action")))

    code, res, _, _, _ = run_case({
        ("GET", S): (200, status_payload("arrived", False)),
        ("POST", CL): (200, {"code": 40002, "msg": "no unclaimed travel"}),
    })
    check("claim 遇 no unclaimed travel → 退出码 0 且 not_ready",
          code == 0 and res.get("action") == "not_ready", str(res.get("action")))

    code, res, _, _, _ = run_case({
        ("GET", S): (200, status_payload("idle", False)),
        ("GET", C): (200, config_payload()),
        ("POST", D): (429, {"code": 429, "msg": "daily limit reached"}),
    })
    check("depart 遇 429/daily limit → 退出码 0 且 today_done",
          code == 0 and res.get("action") == "today_done", str(res.get("action")))

    code, res, _, _, _ = run_case({
        ("GET", S): (200, status_payload("idle", False)),
        ("GET", C): (200, config_payload()),
        ("POST", D): (200, {"code": 40003, "msg": "already traveling"}),
    })
    check("depart 遇 already traveling → 退出码 0 且 traveling",
          code == 0 and res.get("action") == "traveling", str(res.get("action")))

    # ── [5] 失败路径 ────────────────────────────────────────────────────
    section("[5] 失败路径（必须红、且要能人工处理）")

    code, res, _, _, _ = run_case({("GET", S): (401, {"_raw": "401 Authorization Required"})})
    check("状态查询 401（网关回 HTML）→ auth_failed 且退出码 1",
          code == 1 and res.get("action") == "auth_failed", str(res.get("action")))

    code, res, _, _, _ = run_case({
        ("GET", S): (200, status_payload("idle", False)),
        ("GET", C): (200, config_payload()),
        ("POST", D): (200, {"code": 40004, "msg": "no active buddy"}),
    })
    check("没有 Buddy → no_buddy 且退出码 1",
          code == 1 and res.get("action") == "no_buddy", str(res.get("action")))

    code, res, _, _, _ = run_case({
        ("GET", S): (200, status_payload("idle", False)),
        ("GET", C): (200, config_payload()),
        ("POST", D): (200, {"code": 40005, "msg": "location not available"}),
    })
    check("地点不可用 → failed 且退出码 1",
          code == 1 and res.get("action") == "failed", str(res.get("action")))

    code, res, calls, logs, _ = run_case({("GET", S): OSError("boom")})
    n_status = len([c for c in calls if c[1] == S])
    check("网络异常 → network_error 且退出码 1",
          code == 1 and res.get("action") == "network_error", str(res.get("action")))
    check("网络异常时 status 被重试一次（共 2 次）", n_status == 2, str(n_status))
    check("网络异常有日志", any("重试" in m for m in logs), str(logs[:1]))

    code, res, _, _, _ = run_case({
        ("GET", S): (200, status_payload("idle", False)),
        ("GET", C): (200, config_payload(locations=[])),
    })
    check("地点表为空 → failed 且退出码 1",
          code == 1 and res.get("action") == "failed", str(res.get("action")))

    code, res, _, _, _ = run_case({})
    check("响应完全缺失时不会静默成功（退出码非 0）", code != 0, str(code))

    # ── [6] 指定地点 ────────────────────────────────────────────────────
    section("[6] 地点选择")

    _, res, calls, _, _ = run_case({
        ("GET", S): (200, status_payload("idle", False)),
        ("GET", C): (200, config_payload()),
        ("POST", D): (200, {"code": 0, "msg": "OK", "data": {"state": "traveling"}}),
    }, location_id=4)
    check("指定 location_id 被原样使用",
          calls[-1][2].get("location_id") == 4, str(calls[-1][2]))

    code, res, _, _, _ = run_case({
        ("GET", S): (200, status_payload("idle", False)),
        ("GET", C): (200, config_payload()),
    }, location_id=99)
    check("指定不存在的地点 → failed 且退出码 1",
          code == 1 and res.get("action") == "failed", str(res.get("action")))

    # 默认随机：多次运行必须总落在合法集合内
    picked = set()
    for _ in range(30):
        _, _, cs, _, _ = run_case({
            ("GET", S): (200, status_payload("idle", False)),
            ("GET", C): (200, config_payload()),
            ("POST", D): (200, {"code": 0, "msg": "OK", "data": {"state": "traveling"}}),
        })
        picked.add(cs[-1][2].get("location_id"))
    check("默认随机且取值合法", picked.issubset({1, 2, 3, 4}) and picked,
          str(sorted(picked)))

    # ── [7] 缺凭据 ──────────────────────────────────────────────────────
    section("[7] 缺凭据（退出码 2，与签到约定一致）")

    code, res, calls, _, _ = run_case({}, token="", uid="")
    check("缺 token → 退出码 2", code == 2, str(code))
    check("缺 token → action=missing_credentials",
          res.get("action") == "missing_credentials", str(res.get("action")))
    check("缺凭据时一个请求都不发", calls == [], str(calls))

    # ── [8] 通知策略 ────────────────────────────────────────────────────
    section("[8] 通知：领取成功与失败必推，日常静默")

    for action, want in (("claimed", True), ("failed", True),
                         ("auth_failed", True), ("no_buddy", True),
                         ("network_error", True), ("missing_credentials", True),
                         ("departed", False), ("traveling", False),
                         ("today_done", False), ("not_ready", False),
                         ("status_only", False)):
        sent, captured = notify_decision(action)
        check(f"{action} → {'推送' if want else '静默'}",
              sent == want and bool(captured) == want,
              f"sent={sent} captured={len(captured)}")

    _, captured = notify_decision("claimed", reward_credit=8, location="古镇客栈",
                                  letter="亲爱的铲屎官：\n今天路过四家咖啡馆。")
    title, text = captured[0]
    check("通知标题含「喵喵旅行」", "喵喵旅行" in title, title)
    check("通知正文含积分增量", "+8" in text, text.splitlines()[-2][:40])
    check("通知正文含地点", "古镇客栈" in text)
    check("Buddy 来信只取首行（避免长信刷屏）",
          "今天路过四家咖啡馆。" not in text and "亲爱的铲屎官" in text)

    _, captured = notify_decision("no_buddy")
    check("没有 Buddy 的通知给出处理办法（附活动页地址）",
          "growth-center" in captured[0][1])

    # ── [9] 保密：token / uid 不得外泄 ──────────────────────────────────
    section("[9] 保密（日志与通知里绝不能出现凭据）")

    code, res, _, logs, _ = run_case({
        ("GET", S): (200, status_payload("arrived", False)),
        ("POST", CL): (200, {"code": 0, "msg": "OK",
                             "data": {"reward_credit": 5, "letter": {"text": "hi"}}}),
    })
    note_title, note_text = wb_travel.render_travel_alert(code, res)
    blob = "\n".join(logs) + note_title + note_text
    check("日志与通知不含 token", TOKEN not in blob)
    check("日志与通知不含 uid", UIDV not in blob)

    _, text_fail = wb_travel.render_travel_alert(
        1, {"action": "failed", "detail": "code=500 boom"})
    check("失败通知带 detail 便于排障", "code=500 boom" in text_fail)

    # ── [10] 结果落盘 ───────────────────────────────────────────────────
    section("[10] 结果落盘 TSV（供工作流记录步骤读取）")

    with tempfile.TemporaryDirectory() as td:
        p = os.path.join(td, "travel.tsv")
        wb_travel.write_tsv({"ok": True, "action": "claimed", "reward_credit": 9,
                             "location": "古镇客栈"}, path=p)
        with open(p, encoding="utf-8") as fh:
            row = fh.read().rstrip("\n").split("\t")
        check("TSV 为 5 列（与多账号驱动同格式）", len(row) == 5, str(len(row)))
        check("第 1 列是「喵喵旅行」", row[0] == "喵喵旅行", row[0])
        check("第 3 列是 action", row[2] == "claimed", row[2])
        check("说明里带地点与积分", "古镇客栈" in row[3] and "+9分" in row[3], row[3])

        wb_travel.write_tsv({"ok": False, "action": "failed", "detail": "x"}, path=p)
        with open(p, encoding="utf-8") as fh:
            lines = fh.read().rstrip("\n").splitlines()
        check("失败行记为 failure", lines[0].split("\t")[1] == "failure",
              lines[0].split("\t")[1])
        check("覆盖写（只保留本次一行）", len(lines) == 1, str(len(lines)))

        wb_travel.write_tsv({"ok": True, "action": "today_done",
                             "reward_credit": 0}, path=p)
        with open(p, encoding="utf-8") as fh:
            row3 = fh.read().rstrip("\n").split("\t")
        check("reward_credit=0 时不拼出「+0分」噪声",
              "+0分" not in row3[3], row3[3])
        check("无内容可说明时用 -", row3[3] == "-", row3[3])

    # ── [11] 静态断言：工作流接线 ───────────────────────────────────────
    section("[11] GitHub Actions 接线")

    wf = os.path.join(REPO, ".github", "workflows", "wb-checkin.yml")
    with open(wf, encoding="utf-8") as fh:
        yml = fh.read()

    check("工作流调用了 wb_travel.py", "scripts/wb_travel.py" in yml)
    check("喵喵步骤存在", "name: 喵喵旅行" in yml)
    check("喵喵步骤用 if: always()（不被签到失败拖累）",
          yml.count("if: always()") >= 3, str(yml.count("if: always()")))
    crons = [ln for ln in yml.splitlines() if ln.strip().startswith("- cron:")]
    check("cron 时点已扩容（≥5 个，覆盖 1~4h 后的领取窗口）",
          len(crons) >= 5, str(len(crons)))

    travel_step = yml.split("name: 喵喵旅行", 1)[-1].split("- name: 记录运行结果", 1)[0]
    check("喵喵步骤没有重复声明 NOTIFY_WEBHOOK（会覆盖 GITHUB_ENV 里的值）",
          re.search(r"(?m)^\s+NOTIFY_WEBHOOK:", travel_step) is None)
    check("喵喵步骤带 set -o pipefail（否则 tee 会吞掉退出码）",
          "set -o pipefail" in travel_step)
    check("记录步骤会读 logs/travel.tsv", "logs/travel.tsv" in yml)

    # ── [12] 通知实现只有一份 ───────────────────────────────────────────
    section("[12] 通知实现不重复（防止两份漂移）")

    with open(os.path.join(SCRIPTS, "wb_core.py"), encoding="utf-8") as fh:
        core_src = fh.read()
    with open(os.path.join(SCRIPTS, "wb_travel.py"), encoding="utf-8") as fh:
        travel_src = fh.read()

    check("wb_core 暴露了通用发送层 deliver()", "def deliver(" in core_src)
    check("send_alert 复用 deliver（不再自己拼渠道请求）",
          "return deliver(title, text" in core_src)
    check("渠道适配只在 wb_core 实现一份（wb_travel 不自己 POST webhook）",
          "msgtype" not in travel_src and "sctapi" not in travel_src)
    check("仍保留被渠道拒收的判定（静态测试项，勿删）",
          "_notify_delivered" in core_src and "被渠道拒收" in core_src)
    check("wb_travel 通过 wb_core 的 deliver 发通知",
          "from wb_core import" in travel_src and "    deliver," in travel_src)
    check("--status-only 调试模式不落盘（不污染运行记录）",
          "if not args.status_only:" in travel_src)
    check("POST（depart/claim）不被 with_retry 包裹（副作用不能重放）",
          re.search(r'with_retry\(\s*\n?\s*lambda: api\("POST"', travel_src) is None)
    check("只有两个 GET（status/config）带自动重试",
          travel_src.count("with_retry(") == 2, str(travel_src.count("with_retry(")))

    total, ok_n = len(RESULTS), sum(RESULTS)
    print(f"\n{'=' * 46}\n通过 {ok_n}/{total} 项")
    return 0 if ok_n == total else 1


if __name__ == "__main__":
    sys.exit(main())
