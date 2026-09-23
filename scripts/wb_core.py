#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
WorkBuddy「Buddy 加油站」签到 —— 核心逻辑（单一实现源）
=========================================================
本模块只做一件事：调接口完成签到。被两个薄入口复用，因此接口契约与业务
判定只在这里定义一次，契约变更只改本文件：

    scripts/wb_checkin.py    → 命令行 / GitHub Actions
    tencent-scf/index.py     → 腾讯云函数 SCF（定时触发器）

接口契约（从 WorkBuddy 桌面端实现中提取，已实测打通）
    端点    https://copilot.tencent.com
    查状态  POST /v2/billing/meter/checkin-activity-status   body: {}
    签到    POST /v2/billing/meter/daily-checkin             body: {}
    请求头  Accept: application/json
            Authorization: Bearer <accessToken>
            Content-Type: application/json
            X-User-Id: <uid>
    成功    HTTP 200 且响应体 code == 0
    幂等    code == 10001 表示「今天已签到」，不是失败

实测陷阱（务必遵守，都是踩过的）
    1. /v2/billing/meter/checkin-status 返回的是空壳：active、today_checked_in、
       total_credits 恒为 0/false。用它判断会误判为「未签到」而每天发一次
       无效请求。必须使用同目录下的 /v2/billing/meter/checkin-activity-status。
    2. 网关会用 HTTP 400/401 包裹业务响应体，只读 HTTP 状态码会误判，
       必须解析响应体里的 code。
    3. HTTP 401 的语义是「凭据被顶掉或已过期」，属于不可重试错误，不要重试。

凭据生命周期（2026-09-16 实测）
    accessToken  有效期 60 天（expiresIn = 5184000 秒）
    refreshToken 有效期 70 天（refreshExpiresIn = 6048000 秒）
    桌面端每次换发都会顶掉旧 token，因此 401 后重新提取一次即可。

    刻意不实现 OIDC 自动换发：刷新接口
    /open-apis/authen/v1/oidc/refresh_access_token 需要 WorkBuddy 自身的
    应用级凭据（app_access_token），那不属于用户凭据；且脚本与运行中的
    桌面端争抢同一个 refreshToken，有连带吊销登录态的风险。

可选通知（凭据失效时主动告知，不用自己去翻日志）
    设置环境变量 NOTIFY_WEBHOOK 即开启，无需改代码。按域名自动匹配消息格式：
        企业微信/钉钉群机器人  https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...
                              https://oapi.dingtalk.com/robot/send?access_token=...
        Server 酱              https://sctapi.ftqq.com/<SENDKEY>.send
        其他（Slack 等）        通用 JSON {"text": "..."}
    只在「需要人工介入」的四种情况发送：凭据失效 / 未配置凭据 / 签到失败 /
    网络异常。正常完成的（已签到 / 活动未开放）默认静默——否则每天一条通知
    就成骚扰了；想每天收一份回执（含连续天数与累计积分），再设
    NOTIFY_ON_SUCCESS=1。CLI 的 --status-only 是调试模式，永不触发通知。
    通知失败只写日志，绝不影响签到结果与退出码。

安全约定
    任何情况下都不打印、不回显、不落盘凭据内容；业务请求只发往 copilot.tencent.com
    （通知请求发往使用者自配置的 NOTIFY_WEBHOOK，内容为纯文本，不含凭据）。
"""

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

ENDPOINT = "https://copilot.tencent.com"
PATH_STATUS = "/v2/billing/meter/checkin-activity-status"
PATH_CHECKIN = "/v2/billing/meter/daily-checkin"

# 退出码约定：两个入口共用，云平台据此判断成功/失败
EXIT_OK = 0
EXIT_FAIL = 1
EXIT_NO_CREDENTIALS = 2

# 北京时间。刻意不用 timezone 环境变量，避免云函数默认 UTC 导致日志时间错位
CN_TZ = timezone(timedelta(hours=8))

# 本机登录态文件（仅 --local-auth 时使用；macOS / Windows 路径均覆盖）
LOCAL_AUTH_CANDIDATES = [
    os.path.expanduser(
        "~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info"
    ),
    os.path.expanduser("~/.codebuddy/auth/workbuddy-desktop.info"),
    os.path.join(
        os.environ.get("LOCALAPPDATA", ""),
        "CodeBuddyExtension", "Data", "Public", "auth", "workbuddy-desktop.info",
    ),
]


def now_cn() -> str:
    return datetime.now(CN_TZ).strftime("%Y-%m-%d %H:%M:%S")


def make_logger(emit=None):
    """统一的带北京时间戳的日志函数。云函数里 print 会直接进日志。"""
    if emit is None:
        def emit(msg):
            print(msg, flush=True)

    def _log(msg: str) -> None:
        emit(f"[{now_cn()}] {msg}")

    return _log


def _dig(obj, *keys):
    cur = obj
    for k in keys:
        if isinstance(cur, dict) and k in cur:
            cur = cur[k]
        else:
            return None
    return cur


def load_local_auth(log=None):
    """从本机登录态文件读取 (accessToken, uid)。仅返回，绝不打印内容。"""
    log = log or make_logger()
    for path in LOCAL_AUTH_CANDIDATES:
        if not path or not os.path.isfile(path):
            continue
        try:
            with open(path, "r", encoding="utf-8") as fh:
                data = json.loads(fh.read())
        except (OSError, json.JSONDecodeError):
            continue

        token = (
            _dig(data, "auth", "accessToken")
            or _dig(data, "auth", "access_token")
            or data.get("accessToken")
            or data.get("access_token")
        )
        uid = (
            _dig(data, "account", "uid")
            or data.get("uid")
            or _dig(data, "account", "userId")
        )
        if token and uid:
            log(f"已从本机登录态文件读取凭据：{os.path.basename(path)}")
            return token, str(uid)
    return None, None


def _parse(raw: bytes):
    try:
        return json.loads(raw.decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001
        return {"_raw": raw.decode("utf-8", "replace")[:300]}


def request(path: str, token: str, uid: str, timeout: int = 15):
    """POST 请求。注意：网关可能用 HTTP 400/401 包裹业务响应，必须解析响应体。"""
    req = urllib.request.Request(ENDPOINT + path, data=b"{}", method="POST")
    req.add_header("Accept", "application/json")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("X-User-Id", uid)

    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, _parse(resp.read())
    except urllib.error.HTTPError as exc:
        # 关键点：HTTP 400/401 也可能带着业务响应体，必须读出来
        return exc.code, _parse(exc.read())


def with_retry(fn, retries: int = 1, log=None):
    log = log or make_logger()
    last = None
    for attempt in range(retries + 1):
        try:
            return fn()
        except Exception as exc:  # noqa: BLE001
            last = exc
            if attempt < retries:
                log(f"网络异常，1 秒后重试一次：{type(exc).__name__}")
                time.sleep(1)
    raise last  # type: ignore[misc]


# ---------------------------------------------------------------------------
# 可选通知：只在需要人工介入时发出
# ---------------------------------------------------------------------------
NOTIFY_WEBHOOK_ENV = "NOTIFY_WEBHOOK"
NOTIFY_ON_SUCCESS_ENV = "NOTIFY_ON_SUCCESS"
NOTIFY_TIMEOUT = 8

# 这几种结局说明「任务没能自己搞定」，值得打扰使用者一次。
# 与 NOTIFY_ON_SUCCESS 无关，一律推送。
ALERT_ACTIONS = ("auth_failed", "missing_credentials", "failed", "network_error")

# 每日回执（设 NOTIFY_ON_SUCCESS=1 后生效）只在这两种结局发：
#   checked_in —— 本次运行真的把签到做掉了，回执里的连续天数/积分才是新数据
#   inactive   —— 活动未开放，属于「自动化此刻做不了事」的状态，值得你知道
# 刻意排除 already_checked_in（今日已签到）：它是「已经报过的那一次」派生出的
# 同一份结论 —— 本工作流一天要跑 5 次（含喵喵旅行的领取窗口，见 wb-checkin.yml），
# 收进来就会把同一句话重复播报 4 遍。回执的价值在「我替你签上了」，
# 不在「我知道你已经签过了」。
# 同样刻意不含 status_only：那是本地调试模式，不该产生通知。
RECEIPT_ACTIONS = ("checked_in", "inactive")

_NOTIFY_TITLES = {
    "auth_failed": "凭据已失效",
    "missing_credentials": "未配置凭据",
    "failed": "签到失败",
    "network_error": "网络异常未完成",
    "checked_in": "签到成功",
    "already_checked_in": "今日已签到",
    "inactive": "活动当前未开放",
}

# 重新提取凭据的命令（只读取文件，不打印到任何日志）
_REEXTRACT_CMD = (
    "jq -r '.auth.accessToken, .account.uid' "
    '"$HOME/Library/Application Support/CodeBuddyExtension'
    '/Data/Public/auth/workbuddy-desktop.info"'
)


def _truthy(value) -> bool:
    return str(value or "").strip().lower() in ("1", "true", "yes", "on")


def _notify_kind(url: str) -> str:
    """按 webhook 域名自动匹配消息体格式，使用者不用记额外参数。"""
    host = urllib.parse.urlparse(url).netloc.lower()
    if "qyapi.weixin.qq.com" in host or "oapi.dingtalk.com" in host:
        return "wecom"        # 企业微信 / 钉钉群机器人（两者格式一致）
    if "sctapi.ftqq.com" in host:
        return "serverchan"   # Server 酱（表单提交）
    return "generic"          # 其他：通用 JSON {"text": ...}，Slack 等可直接收


def render_alert(exit_code, result) -> tuple:
    """把结果渲染成 (标题, 正文)。正文为纯文本，不含任何凭据。

    result 里可选带 account / peer 两个键（由多账号驱动 scripts/wb_peers.py 注入）：
    多账号场景下通知必须能一眼看出是哪一号出的问题，否则回执等于没回。
    单账号链路不传这两个键，渲染结果与从前逐字一致。
    """
    result = result or {}
    action = result.get("action") or "unknown"
    account = str(result.get("account") or "").strip()
    is_peer = bool(result.get("peer"))

    title = ("WorkBuddy 签到" + (f"｜{account}" if account else "")
             + "：" + _NOTIFY_TITLES.get(action, action))

    lines = [f"【{title}】", f"时间：{now_cn()}（北京时间）"]
    if account:
        lines.append(f"账号：{account}" + ("（他人账号）" if is_peer else ""))
    lines.append(f"退出码：{exit_code}")

    http_code = result.get("http")
    biz = result.get("code")
    if http_code is not None:
        lines.append(f"HTTP：{http_code}" + (f" / code={biz}" if biz is not None else ""))
    elif biz is not None:
        lines.append(f"业务码：{biz}")

    # 进度信息：成功回执时最有用（连续天数 / 本次积分 / 累计积分）
    progress = []
    if result.get("streak_days") is not None:
        progress.append(f"连续 {result['streak_days']} 天")
    credit = result.get("credit") if result.get("credit") is not None \
        else result.get("today_credit")
    if credit is not None:
        progress.append(f"本次 +{credit} 分")
    if result.get("total_credits") is not None:
        progress.append(f"累计 {result['total_credits']} 分")
    if progress:
        lines.append("进度：" + "｜".join(str(p) for p in progress))

    detail = result.get("detail")
    if detail:
        lines.append(f"详情：{str(detail)[:200]}")

    if action == "auth_failed":
        if is_peer:
            # 他人账号：仓库主无法自己修，必须由该账号的持有者在本机重做一份
            lines += [
                "影响：该账号本次未签到，仓库里那份快照已失效。",
                "常见原因：",
                " 1) 对方在本机重新登录了桌面端（新 token 顶掉旧的）",
                " 2) 已超过 accessToken 的有效期（JWT 实测 55 天）",
                "处理：请该账号的持有者重跑一次 local/join.sh，",
                "      把新生成的分享文件发回，再用 local/add-peer.sh 导入。",
            ]
        else:
            lines += [
                "影响：本次未签到，仓库里那份凭据快照已失效。",
                "常见原因：",
                " 1) 桌面端重新登录 / 凭据格式换代（sessionState 变化）",
                " 2) 已超过 accessToken 的有效期（JWT 实测 55 天）",
                "处理：",
                " 1) 确认 Mac 上 WorkBuddy 桌面端处于登录状态；",
                " 2) 同步器会在下一轮（≤30 分钟）自动推送新凭据，通常无需干预；",
                " 3) 若持续失败，在本机手动推一次：",
                "    bash ~/.wb-checkin/wb-sync-credentials.sh --force",
                "诊断（在本机执行，只读取文件、本身不写任何日志）：",
                f"    {_REEXTRACT_CMD}",
            ]
    elif action == "missing_credentials":
        if is_peer:
            lines.append(
                "处理：该账号的快照没解出凭据。检查仓库 Secret WB_PEER_KEYS 里"
                "是否包含该账号的密钥，以及 state/peers/ 下是否存在它的快照。")
        else:
            lines.append(
                "处理：仓库里没有可用的 state/credentials.enc。"
                "在本机执行 bash ~/.wb-checkin/wb-sync-credentials.sh --force 推送一份。")
    elif action == "network_error":
        lines.append("处理：多为偶发网络抖动，通常次日自愈；连续多日出现再排查。")
    elif action == "already_checked_in":
        lines.append("说明：今日已签到（可能由本次或先前一次完成），无需处理。"
                     "本条为每日回执。")
    elif action == "inactive":
        lines.append("说明：签到活动当前未开放（active=false），本次跳过。")
    elif action == "checked_in":
        lines.append("说明：签到成功，无需处理。")
    else:
        lines.append("处理：查看运行日志中的原始响应，必要时更新脚本。")

    return title, "\n".join(lines)


def _post_json(url, obj, timeout=NOTIFY_TIMEOUT):
    req = urllib.request.Request(
        url, data=json.dumps(obj, ensure_ascii=False).encode("utf-8"), method="POST"
    )
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read()


def _post_form(url, fields, timeout=NOTIFY_TIMEOUT):
    req = urllib.request.Request(
        url, data=urllib.parse.urlencode(fields).encode("utf-8"), method="POST"
    )
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read()


def _notify_delivered(body) -> tuple:
    """判断通知是否真的被渠道接收。返回 (是否成功, 说明)。

    HTTP 200 不等于投递成功：钉钉 / 企业微信在「关键词不匹配」「机器人被停用」
    这类情况下仍返回 200，只是正文里 errcode != 0。只看状态码会把失败报成成功
    —— 那正好是「静默失败」，与本项目最忌讳的失败模式同类。

    无法判定时（没有正文 / 非 JSON）按成功处理，避免误报。
    """
    text = (body or b"").decode("utf-8", "replace").strip()
    if not text:
        return True, ""
    try:
        data = json.loads(text)
    except (ValueError, TypeError):
        return True, ""
    if not isinstance(data, dict):
        return True, ""

    for key in ("errcode", "code"):
        if key in data:
            try:
                val = int(data[key])
            except (TypeError, ValueError):
                return True, ""
            if val != 0:
                msg = data.get("errmsg") or data.get("message") or ""
                return False, f"{key}={val} {msg}".strip()
            return True, ""
    return True, ""


def deliver(title: str, text: str, webhook=None, log=None) -> bool:
    """把一条已渲染好的通知按渠道格式发出去。返回是否真的送达。

    这是通知链路的**唯一发送实现**：渠道适配（企业微信/钉钉、Server 酱、
    通用 JSON）与「HTTP 200 却被渠道拒收」的判定都只此一处，
    签到（send_alert）与喵喵旅行（scripts/wb_travel.py）共用，避免两份漂移。

    刻意做成「永不抛异常、也永不改变退出码」：通知只是附加信息通道，
    它坏了不该让任务看起来失败，也不该掩盖真实结论。
    """
    log = log or make_logger()
    if webhook is None:
        webhook = os.environ.get(NOTIFY_WEBHOOK_ENV, "")
    webhook = (webhook or "").strip()
    if not webhook:
        return False

    if urllib.parse.urlparse(webhook).scheme not in ("http", "https"):
        log("通知未发送：NOTIFY_WEBHOOK 必须是 http(s) 地址。")
        return False

    kind = _notify_kind(webhook)

    def _send():
        if kind == "wecom":
            return _post_json(webhook, {"msgtype": "text", "text": {"content": text}})
        if kind == "serverchan":
            return _post_form(webhook, {"title": title, "desp": text})
        return _post_json(webhook, {"text": text})

    try:
        code, body = with_retry(_send, retries=1, log=log)
    except Exception as exc:  # noqa: BLE001
        log(f"通知发送失败（不影响签到结果）：{type(exc).__name__}")
        return False

    snippet = (body or b"").decode("utf-8", "replace")[:200]
    delivered, why = _notify_delivered(body)
    if not delivered:
        # 渠道收了 HTTP 200 却拒收了内容（钉钉：关键词不匹配 / 机器人被停用）。
        # 这里不能报成功，否则又是一个「看起来正常、实际没送达」的静默失败。
        log(f"通知被渠道拒收（{kind}，HTTP {code}）：{why}｜原文 {snippet}")
        return False
    log(f"通知已发送（{kind}，HTTP {code}）：{snippet}")
    return True


def send_alert(exit_code, result, webhook=None, log=None) -> bool:
    """按需发送通知。返回是否真的发出去了。

    只负责判断「该不该发」并渲染正文；实际发送交给 deliver()。
    刻意做成「永不抛异常、也永不改变退出码」：通知只是附加信息通道，
    它坏了不该让签到任务看起来失败，也不该掩盖真实结果。
    """
    log = log or make_logger()
    if webhook is None:
        webhook = os.environ.get(NOTIFY_WEBHOOK_ENV, "")
    webhook = (webhook or "").strip()
    if not webhook:
        return False

    action = (result or {}).get("action")
    if action in ALERT_ACTIONS:
        pass  # 需要人工介入，无论开关如何都要推送
    elif action in RECEIPT_ACTIONS and _truthy(os.environ.get(NOTIFY_ON_SUCCESS_ENV)):
        pass  # 真有进展（本次签到完成 / 活动状态变化）+ 已开启每日回执
    else:
        return False

    title, text = render_alert(exit_code, result)
    return deliver(title, text, webhook=webhook, log=log)


def checkin(token: str, uid: str, status_only: bool = False, log=None, notify=None):
    """执行「查状态 → 必要时签到」。

    返回 (exit_code, result)：
        exit_code  0 成功或今日已签到 · 1 失败 · 2 缺少凭据
        result     结构化结果，便于云函数直接作为返回值；
                   其中不含任何凭据内容。

    notify：可选的通知回调，签名 (exit_code, result) -> bool。
            默认走 send_alert（读 NOTIFY_WEBHOOK 环境变量，未配置即静默）。
    """
    log = log or make_logger()
    notify = send_alert if notify is None else notify

    def finish(code, res):
        """唯一的退出收口：通知只在这里发出，新增退出路径不会漏掉通知。"""
        try:
            notify(code, res)
        except Exception as exc:  # noqa: BLE001
            # 通知是附加通道，它出问题不能影响签到本身的结论
            log(f"通知处理异常（已忽略）：{type(exc).__name__}")
        return code, res

    if not token or not uid:
        log("结果：缺少凭据。请设置 WB_ACCESS_TOKEN / WB_UID。")
        return finish(EXIT_NO_CREDENTIALS, {"ok": False, "action": "missing_credentials"})

    # ---------- 1) 查询状态 ----------
    try:
        http_code, payload = with_retry(
            lambda: request(PATH_STATUS, token, uid), log=log
        )
    except Exception as exc:  # noqa: BLE001
        log(f"结果：查询签到状态失败（网络层）：{type(exc).__name__}")
        return finish(EXIT_FAIL, {"ok": False, "action": "network_error",
                                  "detail": type(exc).__name__})

    biz = payload.get("code")
    log(f"状态查询：HTTP {http_code} / code={biz}")

    if http_code == 401 or biz in (401, 1103, 10002):
        log("结果：鉴权失败，凭据已失效。")
        log("      原因通常有两种：")
        log("      ① 桌面端做过 token 换发或重新登录 —— 新 token 会顶掉旧的；")
        log("      ② accessToken 已过期（有效期 60 天）。")
        log("      处理：重新提取 accessToken / uid 并更新环境变量 / Secrets。")
        return finish(EXIT_FAIL, {"ok": False, "action": "auth_failed",
                                  "http": http_code, "code": biz})

    data = payload.get("data") or {}
    checked = data.get("today_checked_in")
    active = data.get("active")

    log(f"活动：{data.get('activity_name') or '（无）'}（第 {data.get('season')} 期）"
        f"｜周期 {data.get('start_time') or '?'} ~ {data.get('end_time') or '?'}")
    log(f"今日已签到：{checked}；连续天数：{data.get('streak_days')}；"
        f"今日积分：{data.get('today_credit')}；累计：{data.get('total_credits')}")

    result = {
        "ok": True,
        "action": "none",
        "activity": data.get("activity_name"),
        "season": data.get("season"),
        "active": active,
        "today_checked_in": checked,
        "streak_days": data.get("streak_days"),
        "today_credit": data.get("today_credit"),
        "total_credits": data.get("total_credits"),
    }

    if status_only:
        log("结果：仅查询模式，已结束。")
        result["action"] = "status_only"
        return finish(EXIT_OK, result)

    if checked is True:
        log("结果：今日已签到，无需重复操作。")
        result["action"] = "already_checked_in"
        return finish(EXIT_OK, result)

    if active is False:
        log("结果：签到活动当前未开放（active=false），本次跳过。")
        result["action"] = "inactive"
        return finish(EXIT_OK, result)

    # ---------- 2) 执行签到 ----------
    try:
        http_code, payload = with_retry(
            lambda: request(PATH_CHECKIN, token, uid), log=log
        )
    except Exception as exc:  # noqa: BLE001
        log(f"结果：签到请求失败（网络层）：{type(exc).__name__}")
        result.update({"ok": False, "action": "network_error",
                       "detail": type(exc).__name__})
        return finish(EXIT_FAIL, result)

    biz = payload.get("code")
    data = payload.get("data") or {}
    log(f"签到响应：HTTP {http_code} / code={biz} / msg={payload.get('msg')}")

    if biz == 0:
        result.update({
            "action": "checked_in",
            "streak_days": data.get("streak_days", result.get("streak_days")),
            "credit": data.get("credit"),
        })
        log(f"结果：签到成功 ✅ 连续 {result['streak_days']} 天，"
            f"本次 +{result['credit']} 积分")
        return finish(EXIT_OK, result)

    if biz == 10001:
        result.update({"action": "already_checked_in"})
        log("结果：今日已签到（幂等返回），无需处理。")
        return finish(EXIT_OK, result)

    result.update({"ok": False, "action": "failed", "code": biz,
                   "detail": json.dumps(payload, ensure_ascii=False)[:400]})
    log(f"结果：签到失败，业务码 {biz}。原始响应："
        f"{json.dumps(payload, ensure_ascii=False)[:400]}")
    return finish(EXIT_FAIL, result)
