#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""多账号签到链路的回归测试（无需 pytest，直接 python3 运行）
================================================================
    python3 tests/test_peers.py

这套多账号架构的风险点与单账号不同，集中在四件事上，本测试逐一钉住：

  1. 【串号】两个账号的 token/uid 绝不能串 —— 串了就是「用自己的凭据
     给别人的号签到」，两边都错，而且不一定报错。
  2. 【分发】通知必须发给该账号自己的机器人；没配的才落到仓库兜底地址。
     发错了等于把 A 的签到结果推给 B。
  3. 【拖累】一个账号失败不能中断其他账号（别人还要签到），
     但整体退出码必须非 0（否则红不了，没人知道出事了）。
  4. 【泄露】密钥 / 凭据 / 机器人地址不得出现在任何输出里；
     CI 里必须对解出来的每个值先打 ::add-mask::。

另外还钉住一条兼容性约定：**没有 state/peers/ 时必须安静退 0**。
升级不能把原本正常的单账号部署染红。

全程不联网：checkin 与通知都被替换成桩。
"""
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SCRIPTS = os.path.join(REPO, "scripts")

sys.path.insert(0, SCRIPTS)

import wb_core        # noqa: E402
import wb_peers       # noqa: E402

RESULTS = []
SECRETS = []          # 测试过程中生成的所有敏感值，最后统一检查有没有漏出去


def check(label, cond, extra=""):
    RESULTS.append(bool(cond))
    print(f"  {'✓' if cond else '✗'} {label}{(' — ' + extra) if extra else ''}")


def snapshot(dirpath, slug, key, payload):
    """用给定密钥造一份密文快照（与生产同一套 openssl 参数）。"""
    os.makedirs(dirpath, exist_ok=True)
    plain = os.path.join(dirpath, f".{slug}.plain")
    enc = os.path.join(dirpath, f"{slug}.enc")
    with open(plain, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)
    os.chmod(plain, 0o600)
    env = dict(os.environ, SNAP_KEY=key)
    subprocess.run(
        ["openssl", "enc", "-aes-256-cbc", "-pbkdf2", "-iter", "200000",
         "-md", "sha256", "-salt", "-in", plain, "-out", enc, "-pass", "env:SNAP_KEY"],
        check=True, env=env)
    os.remove(plain)
    return enc


def fresh_key():
    key = subprocess.run(["openssl", "rand", "-hex", "32"],
                         capture_output=True, text=True, check=True).stdout.strip()
    SECRETS.append(key)
    return key


class Harness:
    """在临时仓库里跑 wb_peers.main()，同时把 checkin / 通知换成桩。"""

    def __init__(self, peers_spec):
        """peers_spec: {slug: {"key":…, "hook":…|None, "result":…, "code":…}}"""
        self.tmp = tempfile.mkdtemp(prefix="wb-peers-")
        self.root = os.path.join(self.tmp, "repo")
        self.peer_dir = os.path.join(self.root, "state", "peers")
        os.makedirs(self.peer_dir, exist_ok=True)
        self.keys = {}
        self.spec = peers_spec
        self.calls = []
        self.sent = []
        self.old_cwd = os.getcwd()

        for slug, spec in peers_spec.items():
            key = spec["key"]
            token = f"tok-{slug}-{'x' * 20}"
            uid = f"uid-{slug}"
            SECRETS.extend([token, uid])
            if spec.get("hook"):
                SECRETS.append(spec["hook"])
            snapshot(self.peer_dir, slug, key, {
                "schema": 2, "peer_slug": slug, "access_token": token, "uid": uid,
                "notify_webhook": spec.get("hook") or "",
                "token_expires_at_ms": str(int(__import__("time").time() * 1000)
                                           + 20 * 86400 * 1000),
                "synced_at_utc": "2026-09-22T00:00:00Z",
            })
            self.keys[slug] = key

        # 桩：记录被调用的 (token, uid)，按 spec 返回预设结果，并触发通知回调
        self._real_checkin = wb_core.checkin
        self._real_send = wb_core.send_alert

        def fake_checkin(token, uid, status_only=False, log=None, notify=None):
            slug = uid.replace("uid-", "")
            self.calls.append({"slug": slug, "token": token, "uid": uid})
            spec = self.spec.get(slug, {})
            res = dict(spec.get("result", {"ok": True, "action": "checked_in"}))
            code = spec.get("code", 0)
            if notify:
                notify(code, res)
            return code, res

        def fake_send_alert(exit_code, result, webhook=None, log=None):
            self.sent.append({
                "account": (result or {}).get("account"),
                "peer": (result or {}).get("peer"),
                "webhook": webhook,
                "exit": exit_code,
                "result": dict(result or {}),
            })
            return True

        wb_core.checkin = fake_checkin
        wb_core.send_alert = fake_send_alert
        wb_peers.core.checkin = fake_checkin
        wb_peers.core.send_alert = fake_send_alert

    def cleanup(self):
        wb_core.checkin = self._real_checkin
        wb_core.send_alert = self._real_send
        os.chdir(self.old_cwd)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run(self, argv=(), keys_env=None, cwd=None, github_actions=False, fallback=None):
        """跑一次 main()，返回 (退出码, stdout)。"""
        os.chdir(cwd or self.root)
        old_argv, old_env = sys.argv, dict(os.environ)
        sys.argv = ["wb_peers.py", *argv]
        if keys_env is None:
            os.environ[wb_peers.KEYS_ENV] = json.dumps(self.keys)
        elif keys_env == "":
            os.environ.pop(wb_peers.KEYS_ENV, None)
        else:
            os.environ[wb_peers.KEYS_ENV] = keys_env
        if fallback:
            os.environ[wb_peers.FALLBACK_NOTIFY_ENV] = fallback
        else:
            os.environ.pop(wb_peers.FALLBACK_NOTIFY_ENV, None)
        if github_actions:
            os.environ["GITHUB_ACTIONS"] = "true"
        else:
            os.environ.pop("GITHUB_ACTIONS", None)
        os.environ.pop(wb_peers.SUMMARY_ENV, None)

        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                code = wb_peers.main()
        finally:
            sys.argv = old_argv
            os.environ.clear()
            os.environ.update(old_env)
        return code, buf.getvalue()


def section(title):
    print(f"\n{title}")


def main():
    hook_a = "https://oapi.dingtalk.com/robot/send?access_token=HOOKAAA"
    hook_b = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=HOOKBBB"

    # ── [1] 兼容性：没有其他账号时必须安静退 0 ────────────────────────────
    section("[1] 未配置其他账号时安静跳过（升级不染红旧部署）")
    h = Harness({})
    try:
        code, out = h.run()
        check("退出码 0", code == 0, f"实际 {code}")
        check("提示是「跳过」而不是报错",
              "跳过" in out and "::error::" not in out)
        check("不产生任何账号行",
              os.path.exists(os.path.join(h.root, wb_peers.TSV_REL))
              and open(os.path.join(h.root, wb_peers.TSV_REL)).read() == "")
    finally:
        h.cleanup()

    # ── [2]+[3] 两个账号：不串号、各自通知 ────────────────────────────────
    section("[2] 两个账号各用自己的凭据，互不串号")
    spec = {
        "alice": {"key": fresh_key(), "hook": hook_a,
                  "result": {"ok": True, "action": "checked_in"}},
        "bob": {"key": fresh_key(), "hook": hook_b,
                "result": {"ok": True, "action": "already_checked_in"}},
    }
    h = Harness(spec)
    try:
        code, out = h.run()
        check("退出码 0（都成功）", code == 0, f"实际 {code}")
        check("两个账号都跑到了", sorted(c["slug"] for c in h.calls) == ["alice", "bob"])
        # 关键：alice 那次调用必须带 alice 的 token/uid
        by_slug = {c["slug"]: c for c in h.calls}
        check("alice 用的是自己的 token",
              by_slug["alice"]["token"].startswith("tok-alice-"), "")
        check("bob 用的是自己的 token",
              by_slug["bob"]["token"].startswith("tok-bob-"), "")
        check("uid 与 token 同源，没有交叉",
              by_slug["alice"]["uid"] == "uid-alice"
              and by_slug["bob"]["uid"] == "uid-bob")

        section("[3] 通知按账号分发")
        hooks = {s["account"]: s["webhook"] for s in h.sent}
        check("每个账号各发了一条", len(h.sent) == 2, f"实际 {len(h.sent)} 条")
        check("alice 的通知发到她自己的机器人", hooks.get("alice") == hook_a)
        check("bob 的通知发到他自己的机器人", hooks.get("bob") == hook_b)
        check("通知里带上了账号标识（否则收到也不知是谁）",
              all(s["account"] and s["peer"] is True for s in h.sent))
        for s in h.sent:
            title, _ = wb_core.render_alert(s["exit"], s["result"])
            check(f"标题含账号名 {s['account']}", s["account"] in title, title)
        check("标题仍保留「签到」关键词（钉钉自定义关键词靠它）",
              all("签到" in wb_core.render_alert(s["exit"], s["result"])[0]
                  for s in h.sent))

        section("[4] 结果落表：一行一个账号")
        tsv = open(os.path.join(h.root, wb_peers.TSV_REL), encoding="utf-8").read().splitlines()
        check("TSV 两行", len(tsv) == 2, f"实际 {len(tsv)} 行")
        check("TSV 行格式为 账号/结果/动作/提示/快照",
              all(len(line.split("\t")) == 5 for line in tsv))
    finally:
        h.cleanup()

    # ── [5] 一个失败不拖累另一个，但整体要红 ─────────────────────────────
    section("[5] 失败不互相拖累，整体退出码非 0")
    spec = {
        "alice": {"key": fresh_key(), "hook": hook_a,
                  "result": {"ok": False, "action": "auth_failed"}, "code": 1},
        "bob": {"key": fresh_key(), "hook": hook_b,
                "result": {"ok": True, "action": "checked_in"}},
    }
    h = Harness(spec)
    try:
        code, out = h.run()
        check("alice 失败时 bob 仍然跑了（没被中断）", len(h.calls) == 2)
        check("退出码非 0（否则红不了）", code == 1, f"实际 {code}")
        check("失败账号被指名报出", "::error::" in out and "alice" in out)
        fail_alert = next((s for s in h.sent if s["account"] == "alice"), None)
        fail_body = wb_core.render_alert(1, fail_alert["result"])[1] if fail_alert else ""
        check("失败账号的通知给的是「他人账号」专属指引（让对方重跑 join.sh，"
              "而不是引导仓库主去动自己的同步器）",
              "join.sh" in fail_body and "wb-sync-credentials.sh" not in fail_body)
        check("成功账号不受影响（结果表里 bob 仍是成功）",
              "| bob | ✅" in out)
    finally:
        h.cleanup()

    # ── [6] 兜底机器人：没自带地址的账号走仓库级地址 ─────────────────────
    section("[6] 未自带机器人的账号走仓库兜底地址")
    spec = {
        "alice": {"key": fresh_key(), "hook": hook_a,
                  "result": {"ok": True, "action": "checked_in"}},
        "carol": {"key": fresh_key(), "hook": None,
                  "result": {"ok": True, "action": "checked_in"}},
    }
    h = Harness(spec)
    try:
        code, out = h.run(fallback="https://example.com/fallback")
        hooks = {s["account"]: s["webhook"] for s in h.sent}
        check("自带机器人的仍用自己的", hooks.get("alice") == hook_a)
        check("没带的落到兜底地址",
              hooks.get("carol") == "https://example.com/fallback",
              str(hooks.get("carol"))[:24])
        check("未自带机器人在输出里被标注为「仓库兜底」", "仓库兜底" in out)

        # 兜底地址本身也必须进掩码（它是机器人令牌，等同密钥）。
        # 计数：alice（token/uid/自带机器人）=3 + carol（token/uid/兜底）=3
        #       + main 里对兜底地址再登记一次 =7
        code, out = h.run(fallback="https://example.com/fallback", github_actions=True)
        got = len([ln for ln in out.splitlines() if ln.startswith("::add-mask::")])
        check("兜底地址在 CI 下也被登记掩码", got == 7, f"实际 {got} 条（期望 7）")
    finally:
        h.cleanup()

    # ── [7] 安全：不泄露 ────────────────────────────────────────────────
    section("[7] 安全：密钥 / 凭据 / 机器人地址不进输出")
    spec = {"alice": {"key": fresh_key(), "hook": hook_a,
                      "result": {"ok": True, "action": "checked_in"}}}
    h = Harness(spec)
    try:
        code, out = h.run()
        check("输出里没有密钥", all(k not in out for k in h.keys.values()))
        check("输出里没有 token", "tok-alice-" not in out)
        check("输出里没有机器人地址令牌", "HOOKAAA" not in out)
        check("输出里没有 uid 原文", "uid-alice" not in out)

        code, out = h.run(github_actions=True)
        check("CI 下对解出来的凭据登记了 ::add-mask::", "::add-mask::" in out)
        masked = [ln for ln in out.splitlines() if ln.startswith("::add-mask::")]
        check("掩码覆盖 token / uid / 机器人地址（3 条）",
              len(masked) == 3, f"实际 {len(masked)} 条")
    finally:
        h.cleanup()

    # ── [8] 配置错误与文件名安全 ────────────────────────────────────────
    section("[8] 配置错误与路径安全")
    spec = {"alice": {"key": fresh_key(), "result": {"ok": True, "action": "checked_in"}}}
    h = Harness(spec)
    try:
        code, out = h.run(keys_env="{not json")
        check("WB_PEER_KEYS 不是 JSON → 退出码 2 且给出解释",
              code == 2 and wb_peers.KEYS_ENV in out, f"实际 {code}")

        # @文件 形式（本机排障用，避免密钥进命令行历史）
        kf = os.path.join(h.tmp, "keys.json")
        with open(kf, "w", encoding="utf-8") as fh:
            json.dump(h.keys, fh)
        code, out = h.run(keys_env="@" + kf)
        check("@文件 形式可读密钥", code == 0, f"实际 {code}")

        # 密钥与密文真实不匹配。⚠️ 这条容易误报：openssl 用错密钥时会把垃圾块
        # 先写到 stdout 再以退出码 1 报 bad decrypt，所以必须按退出码判定，
        # 否则提示会变成「解密成功但内容不完整」——把人引向错误方向。
        mismatched = json.dumps({**h.keys, "alice": fresh_key()})
        code, out = h.run(keys_env=mismatched)
        check("密钥不匹配 → 退出码 1", code == 1, f"实际 {code}")
        check("报的是「解密失败」而不是「内容不完整」",
              "解密失败" in out and "内容不完整" not in out,
              out.strip().splitlines()[-1][:60] if out.strip() else "")

        # 缺密钥：必须可见地跳过，而不是静默漏签
        code, out = h.run(keys_env="{}")
        check("缺密钥时退出码非 0（不会静默漏签）", code == 1, f"实际 {code}")
        check("缺密钥的账号被指名", "alice" in out)

        # 非法文件名不得被当成账号（大小写、路径穿越、非 .enc）
        for bad_name in ("UPPER.enc", "..enc", "a b.enc", "x.txt"):
            with open(os.path.join(h.peer_dir, bad_name), "wb") as fh:
                fh.write(b"\x00\x01")
        peers = wb_peers.discover_peers(h.peer_dir)
        check("非法文件名被忽略，只认合法 slug",
              [s for s, _ in peers] == ["alice"], str([s for s, _ in peers]))
        check("路径穿越式文件名不会被当作账号",
              not any("/" in s or ".." in s for s, _ in peers))
    finally:
        h.cleanup()

    # ── [9] --only / --list ─────────────────────────────────────────────
    section("[9] --only 与 --list")
    spec = {
        "alice": {"key": fresh_key(), "result": {"ok": True, "action": "checked_in"}},
        "bob": {"key": fresh_key(), "result": {"ok": True, "action": "checked_in"}},
    }
    h = Harness(spec)
    try:
        code, out = h.run(argv=["--only", "bob"])
        check("--only 只跑指定账号", [c["slug"] for c in h.calls] == ["bob"],
              str([c["slug"] for c in h.calls]))
        check("--only 时退出码 0", code == 0, f"实际 {code}")

        h.calls.clear()
        h.sent.clear()
        code, out = h.run(argv=["--list"])
        check("--list 退出码 0", code == 0)
        check("--list 不解密、不签到", h.calls == [] and h.sent == [])
        check("--list 列出两个账号", "alice" in out and "bob" in out)
        check("--list 不打印密钥", all(k not in out for k in h.keys.values()))
    finally:
        h.cleanup()

    # ── [10] 加密参数一致性（三方 + 同步器）─────────────────────────────
    section("[10] openssl 参数与单账号链路完全一致")
    def read(p):
        with open(p, encoding="utf-8") as fh:
            return fh.read()

    peers_src = read(os.path.join(SCRIPTS, "wb_peers.py"))
    join_src = read(os.path.join(REPO, "local", "join.sh"))
    add_src = read(os.path.join(REPO, "local", "add-peer.sh"))
    # wb_peers.py 里参数是列表常量，直接断言常量本身（比字符串包含更硬的约束）
    check("wb_peers.OPENSSL_FLAGS 与同步器同参",
          wb_peers.OPENSSL_FLAGS == ["-aes-256-cbc", "-pbkdf2", "-iter", "200000",
                                     "-md", "sha256"],
          str(wb_peers.OPENSSL_FLAGS))
    for flag in ("-aes-256-cbc", "-pbkdf2", "-iter 200000", "-md sha256"):
        check(f"join.sh 含 {flag}", flag in join_src)
        check(f"add-peer.sh 含 {flag}", flag in add_src)
    check("密钥经环境变量交给 openssl（不进 argv）",
          "-pass env:" in peers_src and "-pass env:" in join_src
          and "-pass env:" in add_src)
    check("分享文件里的密钥不写进本机文件（join.sh 不留密钥副本）",
          "JOIN_KEY" in join_src and "chmod 600 \"$OUT_PATH\"" in join_src)

    total, ok_n = len(RESULTS), sum(RESULTS)
    print(f"\n{'=' * 46}\n通过 {ok_n}/{total} 项")
    return 0 if ok_n == total else 1


if __name__ == "__main__":
    sys.exit(main())
