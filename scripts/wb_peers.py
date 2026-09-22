#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
多账号签到驱动（一个私有仓库里替多个账号签到）
=====================================================
只做一件事：把 state/peers/ 下的多份加密凭据逐个解开、逐个签到、按人通知。

与既有单账号链路的关系（刻意解耦，互不影响）
    scripts/wb_checkin.py + state/credentials.enc   ← 仓库主本人，链路一个字没改
    scripts/wb_peers.py   + state/peers/<slug>.enc  ← 其他账号（本文件）
    两者在同一个 workflow 里各跑一步，谁出问题都不影响对方。
    state/peers/ 为空时本脚本直接退 0（不报错、不变红），因此
    未启用多账号的旧部署行为与升级前完全一致。

为什么每个账号一把独立密钥
    所有密钥都由仓库主持有（它们必须进仓库 Secret，云端才解得开），但
    「一人一钥」让任何一个账号的密钥泄露都不会连累其他人 —— 拿到某个
    friend 的分享文件，只能解开他自己的那一份快照。

分享文件里有什么（由 local/join.sh 生成，local/add-peer.sh 导入）
    slug            账号标识（文件名 state/peers/<slug>.enc，同时也是通知前缀）
    key             该账号的 AES-256-CBC 密钥（openssl rand -hex 32）
    enc             用该 key 加密后的凭据密文
    hook（可选）     该账号自己的通知机器人地址；留空则用仓库级兜底地址

安全约定（与主链路一致）
    · 任何情况下都不打印 accessToken / uid / 密钥 / 通知地址明文
      （CI 里对解出来的每个值都先打 ::add-mask:: 再使用）
    · 密钥只经环境变量传给 openssl（-pass env:），不落盘
    · 只读必要字段，密文解出后立即丢弃，不做任何持久化

退出码：0 全部成功（含「无其他账号」）· 1 有账号失败 · 2 配置有问题
用法：
    python3 scripts/wb_peers.py                 # 全部账号
    python3 scripts/wb_peers.py --only alice    # 只跑某个账号（排障）
    python3 scripts/wb_peers.py --list          # 只列出账号与密钥齐备情况，不解密
    python3 scripts/wb_peers.py --status-only   # 只查状态不签到（调试）
"""

import argparse
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import wb_core as core  # noqa: E402

# ── 约定 ────────────────────────────────────────────────────────────────────
PEER_DIR_REL = os.path.join("state", "peers")
KEYS_ENV = "WB_PEER_KEYS"                     # JSON: {"slug": "<64位hex>"}
FALLBACK_NOTIFY_ENV = "WB_PEER_NOTIFY_FALLBACK"  # 未自带机器人的账号用它
SUMMARY_ENV = "GITHUB_STEP_SUMMARY"
TSV_REL = os.path.join("logs", "last_run.tsv")   # 给工作流「记录结果」步骤读
KEY_ENV_NAME = "WB_PEER_KEY_CUR"                 # 密钥只经 env 交给 openssl

# 与 local/wb-sync-credentials.sh、tests/test_cred_sync.py 必须完全一致
OPENSSL_FLAGS = ["-aes-256-cbc", "-pbkdf2", "-iter", "200000", "-md", "sha256"]

SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
KEY_RE = re.compile(r"^[0-9a-fA-F]{32,128}$")
EXPIRY_WARN_DAYS = 7


def ci_mask(value: str) -> None:
    """在 GitHub Actions 里登记脱敏，确保该值永远不会出现在日志里。

    必须在「任何可能打印它的动作之前」调用 —— 这是主链路踩过的顺序坑，
    所以这里统一放在解密后第一件事。
    """
    if value and os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"::add-mask::{value}", flush=True)


def note(msg: str) -> None:
    print(msg, flush=True)


def append_summary(md: str) -> None:
    path = os.environ.get(SUMMARY_ENV, "")
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(md)
    except OSError:
        pass


def load_keys() -> tuple:
    """读取 WB_PEER_KEYS。返回 (keys, 错误说明)。

    CI 里是一段 JSON；本机排障时可以直接指向密钥登记簿，省得把密钥
    粘到命令行里（那样会进 shell 历史）：
        WB_PEER_KEYS=@~/.wb-checkin/peer-keys.json python3 scripts/wb_peers.py --list
    """
    raw = (os.environ.get(KEYS_ENV) or "").strip()
    if not raw:
        return {}, ""
    if raw.startswith("@"):
        path = os.path.expanduser(raw[1:])
        try:
            with open(path, "r", encoding="utf-8") as fh:
                raw = fh.read()
        except OSError as exc:
            return {}, f"{KEYS_ENV} 指向的密钥文件读不到：{exc}"
    try:
        data = json.loads(raw)
    except ValueError:
        return {}, f"Secret {KEYS_ENV} 不是合法 JSON（应形如 {{\"alice\":\"<hex>\"}}）"
    if not isinstance(data, dict):
        return {}, f"Secret {KEYS_ENV} 应是对象：{{\"账号\": \"密钥\"}}"
    bad = [k for k, v in data.items() if not KEY_RE.match(str(v or ""))]
    if bad:
        return {}, f"Secret {KEYS_ENV} 里这些账号的密钥格式不对：{', '.join(sorted(bad))}"
    return {str(k): str(v) for k, v in data.items()}, ""


def discover_peers(peer_dir: str) -> list:
    """返回 [(slug, 密文路径)]，按 slug 排序，保证每次运行顺序一致。"""
    if not os.path.isdir(peer_dir):
        return []
    out = []
    for name in sorted(os.listdir(peer_dir)):
        if not name.endswith(".enc"):
            continue
        slug = name[:-4]
        if not SLUG_RE.match(slug):
            note(f"跳过文件名不合规的快照：{name}（slug 只允许小写字母/数字/下划线/连字符）")
            continue
        out.append((slug, os.path.join(peer_dir, name)))
    return out


def decrypt(path: str, key: str) -> tuple:
    """用 openssl 解密。返回 (dict 或 None, 失败原因)。密钥只走环境变量。"""
    env = dict(os.environ, **{KEY_ENV_NAME: key})
    try:
        proc = subprocess.run(
            ["openssl", "enc", "-d"] + OPENSSL_FLAGS + ["-in", path, "-pass", f"env:{KEY_ENV_NAME}"],
            capture_output=True, env=env, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, f"openssl 调用失败：{type(exc).__name__}"
    if proc.returncode != 0:
        tail = (proc.stderr or b"").decode("utf-8", "replace").strip().splitlines()
        return None, f"解密失败（密钥不匹配或密文损坏）：{tail[-1] if tail else 'openssl 无输出'}"
    try:
        data = json.loads(proc.stdout.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None, "解密结果不是合法 JSON"
    if not data.get("access_token") or not data.get("uid"):
        return None, "密文内容不完整（缺少 access_token 或 uid）"
    return data, ""


def expiry_hint(plain: dict):
    """按 token 的 exp 给出「还剩几天」的提示。

    为什么值得单独算：JWT 实测 55 天失效，而每个账号的凭据是各自在本机
    重新生成分享文件的。过期前主动提醒，比等到某天签到静默失败友好得多。
    """
    raw = str(plain.get("token_expires_at_ms") or "").strip()
    if not raw.isdigit():
        return "", None
    import time
    days = (int(raw) / 1000 - time.time()) / 86400
    if days < 0:
        return f"凭据已过期 {abs(days):.0f} 天", days
    if days <= EXPIRY_WARN_DAYS:
        return f"凭据 {days:.0f} 天后过期，建议提醒对方重跑 local/join.sh", days
    return "", days


def run_peer(slug: str, enc_path: str, key: str, fallback_hook: str,
             checkin_fn=None, status_only: bool = False) -> dict:
    """跑一个账号。返回结构化结果（不含任何凭据内容）。"""
    checkin_fn = checkin_fn or core.checkin
    log = core.make_logger(emit=lambda m, s=slug: print(f"[{s}] {m}", flush=True))

    result = {"slug": slug, "ok": False, "action": "config_error", "exit": 2,
              "notify_sent": False, "snapshot": "-", "hint": ""}

    if not key:
        log(f"结果：{KEYS_ENV} 里没有该账号的密钥，跳过。"
            f"（把 local/add-peer.sh 打印的 JSON 整体更新到仓库 Secret）")
        result["hint"] = "缺少密钥"
        return result

    plain, why = decrypt(enc_path, key)
    if plain is None:
        log(f"结果：{why}")
        result["hint"] = why
        return result

    token = plain["access_token"]
    uid = str(plain["uid"])
    hook = (plain.get("notify_webhook") or "").strip() or fallback_hook
    # 顺序不能改：先登记脱敏，再让任何值参与日志/请求
    ci_mask(token)
    ci_mask(uid)
    ci_mask(hook)

    hint, days_left = expiry_hint(plain)
    result["snapshot"] = str(plain.get("synced_at_utc") or "-")
    result["hint"] = hint
    if hint:
        log(f"提醒：{hint}")

    hook_src = ("快照自带" if (plain.get("notify_webhook") or "").strip()
                else ("仓库兜底" if hook else "未配置"))
    log(f"通知渠道：{hook_src}｜凭据快照：{result['snapshot']}")

    def _notify(code, res):
        """把「哪个账号」带进通知正文与标题 —— 多账号下没有这个前缀，
        收到消息的人根本不知道是哪一号出问题了。"""
        payload = dict(res or {})
        payload["account"] = slug
        payload["peer"] = True
        sent = core.send_alert(code, payload, webhook=hook, log=log)
        result["notify_sent"] = bool(sent)
        return sent

    try:
        code, res = checkin_fn(token, uid, status_only=status_only, log=log, notify=_notify)
    finally:
        # 密文解出来的明文用完即弃，不留任何副本
        token = uid = None
        plain = None

    res = res or {}
    result.update({
        "ok": bool(res.get("ok")) and code == 0,
        "action": res.get("action") or "unknown",
        "exit": code,
        "streak": res.get("streak_days"),
        "credit": res.get("credit") if res.get("credit") is not None else res.get("today_credit"),
        "total": res.get("total_credits"),
    })

    # wb_core 里的处理建议是给「本人账号」写的（重新提取凭据 / 更新环境变量），
    # 对他人账号不适用 —— 这里补一句这个账号真正能做的动作。
    if result["action"] in ("auth_failed", "missing_credentials"):
        log(f"处理：请让 {slug} 的持有者重跑一次 local/join.sh，把新的分享文件发回，"
            f"再用 local/add-peer.sh 导入（仓库主自己修不了他人账号的凭据）。")
    return result


def write_tsv(rows: list, path: str) -> None:
    """把结果落成 TSV，供工作流的「记录运行结果」步骤逐行追加到 logs/runs.md。"""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            for r in rows:
                fh.write("\t".join([
                    r["slug"],
                    "success" if r["ok"] else "failure",
                    str(r["action"]),
                    r["hint"].replace("\t", " "),
                    str(r["snapshot"]),
                ]) + "\n")
    except OSError as exc:
        note(f"⚠ 无法写入 {path}（不影响签到结果）：{exc}")


def render_summary(rows: list) -> str:
    lines = [
        "",
        "### 多账号签到",
        "",
        "| 账号 | 结果 | 说明 | 通知 | 凭据快照 |",
        "|---|---|---|---|---|",
    ]
    for r in rows:
        mark = "✅" if r["ok"] else "❌"
        extra = r["hint"] or "-"
        lines.append(f"| {r['slug']} | {mark} {r['action']} | {extra} | "
                     f"{'已发送' if r['notify_sent'] else '未发送'} | {r['snapshot']} |")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description="多账号 WorkBuddy 签到")
    ap.add_argument("--only", action="append", default=[],
                    help="只跑指定账号（可重复；排障用）")
    ap.add_argument("--list", action="store_true", help="只列出账号与密钥齐备情况")
    ap.add_argument("--status-only", action="store_true", help="只查状态，不签到")
    args = ap.parse_args()

    peer_dir = os.path.join(os.getcwd(), PEER_DIR_REL)
    keys, keys_err = load_keys()
    peers = discover_peers(peer_dir)

    if args.list:
        if not peers:
            note(f"未发现账号快照（{PEER_DIR_REL} 为空）")
            return 0
        note(f"{PEER_DIR_REL} 下共 {len(peers)} 个账号：")
        for slug, _ in peers:
            note(f"  · {slug:<20} 密钥：{'已登记' if slug in keys else '缺失'}")
        if keys_err:
            note(f"  ⚠ {keys_err}")
        return 0

    # 没有其他账号是「合法状态」而不是错误：单账号部署就长这样，
    # 这里必须安静退 0，否则会平白把一次正常调度染红。
    if not peers:
        note(f"未配置其他账号（{PEER_DIR_REL} 为空），跳过。")
        write_tsv([], os.path.join(os.getcwd(), TSV_REL))
        append_summary("\n### 多账号签到\n\n未配置其他账号，跳过。\n")
        return 0

    if keys_err:
        note(f"::error::{keys_err}")
        return 2

    todo = [(s, p) for s, p in peers if not args.only or s in args.only]
    missing = [s for s, _ in todo if s not in keys]
    if missing:
        note(f"⚠ 这些账号缺少密钥，将被跳过：{', '.join(missing)}")

    fallback_hook = (os.environ.get(FALLBACK_NOTIFY_ENV) or "").strip()
    if fallback_hook:
        ci_mask(fallback_hook)

    note(f"本次处理 {len(todo)} 个账号：{', '.join(s for s, _ in todo)}")
    rows = []
    for slug, path in todo:
        note(f"── 账号 {slug} ──")
        rows.append(run_peer(slug, path, keys.get(slug, ""), fallback_hook,
                             status_only=args.status_only))
        note("")

    summary = render_summary(rows)
    note(summary)
    append_summary(summary)
    write_tsv(rows, os.path.join(os.getcwd(), TSV_REL))

    failed = [r["slug"] for r in rows if not r["ok"]]
    if failed:
        # 明确标注是谁的问题，且不让失败的账号掩盖成功的账号（都已跑完）
        note(f"::error::以下账号本次未成功：{', '.join(failed)}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
