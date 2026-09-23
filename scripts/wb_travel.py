#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
WorkBuddy「派喵喵去旅行」自动化
================================

玩法：每天可以派 Buddy（猫猫）去一个地点旅行，随机 1~4 小时后到达，
到达即可领取 5~10 积分，每天限一次。

本脚本是**幂等自检**：每次运行都先看状态，再决定要不要动作 ——

    state=arrived                      → 领取奖励
    state=idle 且今天还没派             → 派出去（默认随机挑地点）
    state=traveling                    → 什么都不做（等下次运行来领）
    state=idle 且今天已派过（已领完）    → 什么都不做

因此把它挂到任何频率的定时任务上都不会重复领取、也不会重复派出；
「派出 → 1~4 小时后领取」靠多次运行自然闭环，不需要长驻进程。

接口契约（2026-09-22 从 web 端 bundle 逆向 + 实测确认）：

    GET  /activity/growth/buddy/travel/config    地点表（每地点 1~4h、5~10 分）
    GET  /activity/growth/buddy/travel/status    状态机，含 daily_limit_reached
    POST /activity/growth/buddy/travel/depart    {"location_id": n}  派出
    POST /activity/growth/buddy/travel/claim     {}                 领取

鉴权与签到同源：同一个 accessToken 直接可用（Authorization: Bearer + X-User-Id），
所以复用仓库里已有的凭据快照，**不需要任何新的 Secret**。

用法：
    export WB_ACCESS_TOKEN='xxx'
    export WB_UID='yyy'
    python3 wb_travel.py                   # 自检：该领就领，该派就派
    python3 wb_travel.py --status-only      # 只看状态（调试，永不触发通知）
    python3 wb_travel.py --location-id 4    # 指定地点（默认随机）
    python3 wb_travel.py --local-auth       # 从本机登录态文件读凭据

退出码：0 正常（含「今天已经完成」「正在旅行中」）· 1 需要处理 · 2 缺少凭据

通知（可选）：读 NOTIFY_WEBHOOK，与签到共用同一个渠道地址、同一套渠道适配。
默认只在「领取成功 / 凭据失效 / 需要人工处理」时推送，日常的「已派出 / 旅行中 /
今天已完成」完全静默，不会变成每日骚扰。
"""

import argparse
import json
import os
import random
import sys
import urllib.error
import urllib.request

from wb_core import (  # noqa: I001
    EXIT_FAIL,
    EXIT_NO_CREDENTIALS,
    EXIT_OK,
    NOTIFY_WEBHOOK_ENV,
    deliver,
    load_local_auth,
    make_logger,
    now_cn,
    with_retry,
)

# 活动接口在 www.workbuddy.cn（增长中心 H5 的同源网关），与签到的
# copilot.tencent.com 不是同一个域名 —— 同一个 token 两边都能用。
ENDPOINT = "https://www.workbuddy.cn"
PATH_CONFIG = "/activity/growth/buddy/travel/config"
PATH_STATUS = "/activity/growth/buddy/travel/status"
PATH_DEPART = "/activity/growth/buddy/travel/depart"
PATH_CLAIM = "/activity/growth/buddy/travel/claim"

# 本次结果落成的 TSV，供工作流「记录运行结果」步骤逐行追加到 logs/runs.md。
# 与多账号驱动用同一套列格式，因此那个步骤无需为喵喵单独写分支。
TSV_REL = os.path.join("logs", "travel.tsv")

# 需要人工介入的结局：无论通知开关如何都要推送
ALERT_ACTIONS = (
    "auth_failed",
    "missing_credentials",
    "no_buddy",
    "failed",
    "network_error",
)

# 正常结局：默认静默。「claimed」刻意不在这里 —— 领取是每天唯一一次的正反馈，
# 单独放行（见 send_travel_alert）。
QUIET_ACTIONS = ("departed", "traveling", "today_done", "not_ready", "status_only")

_TITLES = {
    "claimed": "领取成功",
    "departed": "已出门旅行",
    "traveling": "旅行中",
    "today_done": "今天已完成",
    "not_ready": "还没到，稍后再领",
    "no_buddy": "还没有 Buddy",
    "auth_failed": "凭据已失效",
    "missing_credentials": "未配置凭据",
    "failed": "执行失败",
    "network_error": "网络异常未完成",
    "status_only": "仅查询",
}


def _parse(raw: bytes):
    try:
        return json.loads(raw.decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001
        return {"_raw": raw.decode("utf-8", "replace")[:300]}


def api(method: str, path: str, token: str, uid: str, body=None, timeout: int = 15):
    """请求活动接口。返回 (http_code, payload)。

    注意网关会用自己的 HTML 页面回 401（不是 JSON），所以调用方判断鉴权失败
    必须看 http_code，不能只看响应体里的 code。
    """
    data = None
    if method != "GET":
        data = json.dumps(
            body if body is not None else {}, ensure_ascii=False
        ).encode("utf-8")

    req = urllib.request.Request(ENDPOINT + path, data=data, method=method)
    req.add_header("Accept", "application/json")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("X-User-Id", uid)
    # 网页端会带这个头区分 web / 小程序，服务端据此返回不同形态的数据。
    req.add_header("X-Client-Platform", "web")

    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, _parse(resp.read())
    except urllib.error.HTTPError as exc:
        return exc.code, _parse(exc.read())


def _is_auth_error(http_code, biz) -> bool:
    # 1103 / 10002 是签到链路上见过的令牌类业务码，保持一致以便统一排障
    return http_code == 401 or biz in (401, 1103, 10002)


def _pick_location(locations, wanted=None, log=None):
    """选一个旅行地点。返回 (location, 错误说明)。"""
    if wanted is not None:
        for loc in locations or []:
            try:
                if int(loc.get("id", -1)) == int(wanted):
                    return loc, ""
            except (TypeError, ValueError):
                continue
        return None, f"指定的地点 id={wanted} 不在活动地点表里"
    if not locations:
        return None, "活动地点表为空（活动可能未开放）"
    return random.choice(locations), ""


def _fmt_eta(seconds) -> str:
    try:
        seconds = int(seconds)
    except (TypeError, ValueError):
        return "未知"
    if seconds <= 0:
        return "已到达"
    minutes = seconds // 60
    if minutes < 60:
        return f"约 {minutes} 分钟"
    return f"约 {minutes // 60} 小时 {minutes % 60} 分钟"


def render_travel_alert(exit_code, result) -> tuple:
    """渲染通知正文。纯文本，不含任何凭据。"""
    result = result or {}
    action = result.get("action") or "unknown"
    title = "WorkBuddy 喵喵旅行：" + _TITLES.get(action, action)

    lines = [f"【{title}】", f"时间：{now_cn()}（北京时间）", f"退出码：{exit_code}"]

    if result.get("http") is not None:
        biz = result.get("code")
        lines.append(f"HTTP：{result['http']}"
                     + (f" / code={biz}" if biz is not None else ""))
    elif result.get("code") is not None:
        lines.append(f"业务码：{result['code']}")

    location = result.get("location")
    if location:
        lines.append(f"地点：{location}")
    if result.get("reward_credit") is not None:
        lines.append(f"本次积分：+{result['reward_credit']}")

    eta = result.get("eta")
    if eta:
        lines.append(f"预计到达：{eta}")

    letter = result.get("letter")
    if letter:
        first = str(letter).strip().splitlines()
        lines.append(f"Buddy 来信：{first[0][:120] if first else ''}")

    if action == "claimed":
        lines.append("说明：奖励已到账，无需处理。")
    elif action == "departed":
        lines.append("说明：已派出，1~4 小时后由下一次运行自动领取。")
    elif action == "traveling":
        lines.append("说明：猫猫还在路上，下一次运行会自动尝试领取。")
    elif action == "today_done":
        lines.append("说明：今天的旅行已完成（每天限一次），无需处理。")
    elif action == "not_ready":
        lines.append("说明：服务端状态刚变化（还没到可领取），下次运行会重试。")
    elif action == "no_buddy":
        lines += [
            "影响：本次没有派出，因为账号里还没有 Buddy。",
            "处理：先到活动页领取一只 Buddy ——",
            "      https://www.workbuddy.cn/profile/growth-center",
        ]
    elif action == "auth_failed":
        lines += [
            "影响：本次未旅行，仓库里那份凭据快照已失效。",
            "处理：确认 Mac 上桌面端处于登录状态，同步器会在下一轮自动补上新凭据；",
            "      也可手动推一次：bash ~/.wb-checkin/wb-sync-credentials.sh --force",
        ]
    elif action == "missing_credentials":
        lines.append(
            "处理：仓库里没有可用的凭据快照。在本机执行 "
            "bash ~/.wb-checkin/wb-sync-credentials.sh --force 推送一份。")
    elif action == "network_error":
        lines.append("处理：多为偶发网络抖动，下次运行通常自愈。")
    else:
        detail = result.get("detail")
        if detail:
            lines.append(f"详情：{str(detail)[:200]}")
        lines.append("处理：查看运行日志中的原始响应，必要时更新脚本。")

    return title, "\n".join(lines)


def send_travel_alert(exit_code, result, webhook=None, log=None) -> bool:
    """按需推送喵喵旅行的通知。返回是否真的发出去了。

    发送实现复用 wb_core.deliver（与签到同一条通道、同一套拒收判定）。
    """
    log = log or make_logger()
    if webhook is None:
        webhook = os.environ.get(NOTIFY_WEBHOOK_ENV, "")
    webhook = (webhook or "").strip()
    if not webhook:
        return False

    action = (result or {}).get("action")
    if action == "claimed":
        pass  # 每天唯一一次的正反馈，用户明确要收
    elif action in ALERT_ACTIONS:
        pass  # 需要人工介入
    else:
        return False  # departed / traveling / today_done … 静默

    title, text = render_travel_alert(exit_code, result)
    return deliver(title, text, webhook=webhook, log=log)


def write_tsv(result, path=None) -> None:
    """把本次结果落成一行 TSV，供工作流「记录运行结果」步骤读取。

    列格式与多账号驱动一致（账号 / 结果 / 动作 / 说明 / 凭据快照），
    所以记录步骤不用为喵喵单写分支。
    """
    path = path or TSV_REL
    result = result or {}
    # 说明列：优先用排障信息（detail），否则拼「地点｜积分｜预计到达」里有的部分。
    # 刻意避开「reward_credit=0 也拼出 +0分」这种噪声。
    parts = []
    if result.get("location"):
        parts.append(str(result["location"]))
    if result.get("action") == "claimed" and result.get("reward_credit"):
        parts.append(f"+{result['reward_credit']}分")
    if result.get("eta"):
        parts.append(str(result["eta"]))
    hint = result.get("detail") or "｜".join(parts) or "-"
    row = [
        "喵喵旅行",
        "success" if result.get("ok") else "failure",
        str(result.get("action") or "unknown"),
        str(hint).replace("\t", " ").replace("\n", " ")[:80],
        os.environ.get("WB_CRED_SNAPSHOT", "-") or "-",
    ]
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\t".join(row) + "\n")
    except OSError:
        pass  # 落盘失败不影响任务结论


def run(token: str, uid: str, status_only: bool = False, location_id=None,
        log=None, notify=None):
    """执行「查状态 → 该领就领 / 该派就派」。

    返回 (exit_code, result)：exit_code 0 正常 · 1 需要处理 · 2 缺少凭据。
    result 为结构化结果，不含任何凭据内容。
    """
    log = log or make_logger()
    notify = send_travel_alert if notify is None else notify

    def finish(code, res):
        """唯一的退出收口：通知只在这里发，新增退出路径不会漏发。"""
        try:
            notify(code, res)
        except Exception as exc:  # noqa: BLE001
            log(f"通知处理异常（已忽略）：{type(exc).__name__}")
        return code, res

    if not token or not uid:
        log("结果：缺少凭据。请设置 WB_ACCESS_TOKEN / WB_UID。")
        return finish(EXIT_NO_CREDENTIALS,
                      {"ok": False, "action": "missing_credentials"})

    # ---------- 1) 查状态 ----------
    try:
        http_code, payload = with_retry(
            lambda: api("GET", PATH_STATUS, token, uid), log=log)
    except Exception as exc:  # noqa: BLE001
        log(f"结果：查询旅行状态失败（网络层）：{type(exc).__name__}")
        return finish(EXIT_FAIL, {"ok": False, "action": "network_error",
                                  "detail": type(exc).__name__})

    biz = payload.get("code")
    log(f"状态查询：HTTP {http_code} / code={biz}")

    if _is_auth_error(http_code, biz):
        log("结果：鉴权失败，凭据已失效。")
        return finish(EXIT_FAIL, {"ok": False, "action": "auth_failed",
                                  "http": http_code, "code": biz})

    if biz != 0:
        detail = json.dumps(payload, ensure_ascii=False)[:300]
        log(f"结果：状态查询未成功，业务码 {biz}。原始响应：{detail}")
        return finish(EXIT_FAIL, {"ok": False, "action": "failed",
                                  "http": http_code, "code": biz, "detail": detail})

    data = payload.get("data") or {}
    state = data.get("state") or "idle"
    daily = bool(data.get("daily_limit_reached"))
    loc_obj = data.get("location") if isinstance(data.get("location"), dict) else None
    loc_name = (loc_obj or {}).get("name")

    result = {
        "ok": True,
        "action": "none",
        "state": state,
        "location": loc_name,
        "record_id": data.get("record_id"),
        "buddy_id": data.get("buddy_id"),
        "depart_at": data.get("depart_at"),
        "arrive_at": data.get("arrive_at"),
        "server_now": data.get("server_now"),
        "reward_credit": data.get("reward_credit"),
        "daily_limit_reached": daily,
    }

    if state == "traveling":
        eta = _fmt_eta((data.get("arrive_at") or 0) - (data.get("server_now") or 0))
        result["eta"] = eta
        log(f"当前：旅行中 → {loc_name or '（地点未知）'}，预计到达 {eta}")
    elif state == "arrived":
        log(f"当前：已到达，可领取 → {loc_name or '（地点未知）'}")
    else:
        log(f"当前：未出门（今天{'已' if daily else '还'}派过）")

    if status_only:
        log("结果：仅查询模式，已结束。")
        result["action"] = "status_only"
        return finish(EXIT_OK, result)

    # ---------- 2) 已到达 → 领取 ----------
    if state == "arrived":
        try:
            http_code, payload = api("POST", PATH_CLAIM, token, uid, {})
        except Exception as exc:  # noqa: BLE001
            log(f"结果：领取请求失败（网络层）：{type(exc).__name__}")
            result.update({"ok": False, "action": "network_error",
                           "detail": type(exc).__name__})
            return finish(EXIT_FAIL, result)

        biz = payload.get("code")
        msg = str(payload.get("msg") or "")
        claim = payload.get("data") or {}
        log(f"领取响应：HTTP {http_code} / code={biz} / msg={msg}")

        if _is_auth_error(http_code, biz):
            result.update({"ok": False, "action": "auth_failed",
                           "http": http_code, "code": biz})
            log("结果：鉴权失败，凭据已失效。")
            return finish(EXIT_FAIL, result)

        if biz == 0:
            letter = claim.get("letter")
            result.update({
                "action": "claimed",
                "reward_credit": claim.get("reward_credit", result.get("reward_credit")),
                "letter": (letter or {}).get("text") if isinstance(letter, dict) else None,
            })
            log(f"结果：领取成功 ✅ 本次 +{result['reward_credit']} 积分")
            return finish(EXIT_OK, result)

        if "not arrived yet" in msg or "no unclaimed travel" in msg:
            # 与状态查询之间的竞态：状态刚变（例如刚好被别的端领走），不算失败
            result.update({"action": "not_ready", "detail": msg})
            log(f"结果：暂无可领取的旅行（{msg}），下次运行重试。")
            return finish(EXIT_OK, result)

        detail = json.dumps(payload, ensure_ascii=False)[:300]
        result.update({"ok": False, "action": "failed", "http": http_code,
                       "code": biz, "detail": detail})
        log(f"结果：领取失败，业务码 {biz}。原始响应：{detail}")
        return finish(EXIT_FAIL, result)

    # ---------- 3) 正在旅行 → 什么都不做 ----------
    if state == "traveling":
        result["action"] = "traveling"
        log("结果：猫猫还在路上，本次不做任何操作（等下一次运行来领）。")
        return finish(EXIT_OK, result)

    # ---------- 4) 未出门且今天已派过 → 今日完成 ----------
    if daily:
        result["action"] = "today_done"
        log("结果：今天已经派过（每天限一次），本次不做任何操作。")
        return finish(EXIT_OK, result)

    # ---------- 5) 未出门 → 派出去 ----------
    try:
        http_code, payload = with_retry(
            lambda: api("GET", PATH_CONFIG, token, uid), log=log)
    except Exception as exc:  # noqa: BLE001
        log(f"结果：读取地点表失败（网络层）：{type(exc).__name__}")
        result.update({"ok": False, "action": "network_error",
                       "detail": type(exc).__name__})
        return finish(EXIT_FAIL, result)

    if _is_auth_error(http_code, payload.get("code")):
        result.update({"ok": False, "action": "auth_failed",
                       "http": http_code, "code": payload.get("code")})
        log("结果：鉴权失败，凭据已失效。")
        return finish(EXIT_FAIL, result)

    locations = (payload.get("data") or {}).get("locations") or []
    loc, why = _pick_location(locations, location_id, log=log)
    if loc is None:
        result.update({"ok": False, "action": "failed", "detail": why})
        log(f"结果：{why}")
        return finish(EXIT_FAIL, result)

    result["location"] = loc.get("name")
    log(f"派出：{loc.get('name')}（id={loc.get('id')}，"
        f"随机 {loc.get('duration_hours_min')}~{loc.get('duration_hours_max')} 小时，"
        f"奖励 {loc.get('reward_credit_min')}~{loc.get('reward_credit_max')} 分）")

    try:
        http_code, payload = api("POST", PATH_DEPART, token, uid,
                                 {"location_id": loc.get("id")})
    except Exception as exc:  # noqa: BLE001
        log(f"结果：派出请求失败（网络层）：{type(exc).__name__}")
        result.update({"ok": False, "action": "network_error",
                       "detail": type(exc).__name__})
        return finish(EXIT_FAIL, result)

    biz = payload.get("code")
    msg = str(payload.get("msg") or "")
    dep = payload.get("data") or {}
    log(f"派出响应：HTTP {http_code} / code={biz} / msg={msg}")

    if _is_auth_error(http_code, biz):
        result.update({"ok": False, "action": "auth_failed",
                       "http": http_code, "code": biz})
        log("结果：鉴权失败，凭据已失效。")
        return finish(EXIT_FAIL, result)

    if biz == 0:
        arrive_at = dep.get("arrive_at") or result.get("arrive_at")
        server_now = dep.get("server_now") or result.get("server_now")
        result.update({
            "action": "departed",
            "state": dep.get("state") or "traveling",
            "arrive_at": arrive_at,
            "eta": _fmt_eta((arrive_at or 0) - (server_now or 0)),
        })
        log(f"结果：已派出 ✅ 预计 {result['eta']} 后到达，"
            f"届时由下一次运行自动领取。")
        return finish(EXIT_OK, result)

    # 幂等 / 竞态：都视为「本次不需要动作」，不算失败
    if http_code == 429 or "daily limit" in msg:
        result.update({"action": "today_done", "detail": msg})
        log("结果：今天已经派过（服务端返回每日上限），本次不做任何操作。")
        return finish(EXIT_OK, result)

    if "already traveling" in msg:
        result.update({"action": "traveling", "detail": msg})
        log("结果：猫猫已经在路上了，本次不做任何操作。")
        return finish(EXIT_OK, result)

    if "no active buddy" in msg:
        result.update({"ok": False, "action": "no_buddy", "http": http_code,
                       "code": biz, "detail": msg})
        log("结果：账号里还没有 Buddy，需要先到活动页领取一只。")
        return finish(EXIT_FAIL, result)

    if "location not available" in msg:
        result.update({"ok": False, "action": "failed", "http": http_code,
                       "code": biz, "detail": f"地点不可用：{msg}"})
        log(f"结果：该地点暂时不可用（{msg}）。换一个地点或稍后重试。")
        return finish(EXIT_FAIL, result)

    detail = json.dumps(payload, ensure_ascii=False)[:300]
    result.update({"ok": False, "action": "failed", "http": http_code,
                   "code": biz, "detail": detail})
    log(f"结果：派出失败，业务码 {biz}。原始响应：{detail}")
    return finish(EXIT_FAIL, result)


def main() -> int:
    ap = argparse.ArgumentParser(description="WorkBuddy 派喵喵去旅行")
    ap.add_argument("--token", help="accessToken（也可用环境变量 WB_ACCESS_TOKEN）")
    ap.add_argument("--uid", help="用户 uid（也可用环境变量 WB_UID）")
    ap.add_argument("--local-auth", action="store_true", help="从本机登录态文件读取凭据")
    ap.add_argument("--status-only", action="store_true",
                    help="只查询状态，不派出也不领取（调试用，不触发通知）")
    ap.add_argument("--location-id", type=int,
                    help="指定旅行地点 id（默认随机挑一个）")
    args = ap.parse_args()

    log = make_logger()

    token = (args.token or os.environ.get("WB_ACCESS_TOKEN", "")).strip()
    uid = (args.uid or os.environ.get("WB_UID", "")).strip()

    if (not token or not uid) and args.local_auth:
        token, uid = load_local_auth(log=log)

    if not token or not uid:
        log("结果：缺少凭据。请设置环境变量 WB_ACCESS_TOKEN / WB_UID，"
            "或加 --local-auth 从本机读取。")
        return EXIT_NO_CREDENTIALS

    exit_code, result = run(token, uid, status_only=args.status_only,
                            location_id=args.location_id, log=log)
    # 调试模式不落盘：status_only 只是本地看状态，写进 TSV 会污染运行记录
    if not args.status_only:
        write_tsv(result)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
