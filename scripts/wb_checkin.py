#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
WorkBuddy「Buddy 加油站」每日自动签到 —— 命令行入口
=====================================================
核心逻辑（接口契约、业务判定、凭据生命周期）全部在 wb_core.py，
与腾讯云函数入口 tencent-scf/index.py 共用同一份实现，此处只做参数解析。

用法：
    export WB_ACCESS_TOKEN='xxx'
    export WB_UID='yyy'
    python3 wb_checkin.py                  # 查状态，必要时签到
    python3 wb_checkin.py --status-only    # 只查状态
    python3 wb_checkin.py --local-auth     # 从本机登录态文件读凭据（一次性提取）

退出码：0 成功或今日已签到 · 1 失败 · 2 缺少凭据

可选通知：设置 NOTIFY_WEBHOOK（企业微信/钉钉群机器人或 Server 酱地址）后，
只在「凭据失效 / 未配置凭据 / 签到失败 / 网络异常」时推送；
再加 NOTIFY_ON_SUCCESS=1 可每天收一份回执（含连续天数与累计积分）。
--status-only 是调试模式，不会触发通知。

设计目标：不依赖本机、不经过任何大模型，因此运行成本恒为 0。
"""

import argparse
import os
import sys

from wb_core import (  # noqa: I001
    EXIT_NO_CREDENTIALS,
    checkin,
    load_local_auth,
    make_logger,
)


def main() -> int:
    ap = argparse.ArgumentParser(description="WorkBuddy 每日自动签到")
    ap.add_argument("--token", help="accessToken（也可用环境变量 WB_ACCESS_TOKEN）")
    ap.add_argument("--uid", help="用户 uid（也可用环境变量 WB_UID）")
    ap.add_argument("--local-auth", action="store_true", help="从本机登录态文件读取凭据")
    ap.add_argument("--status-only", action="store_true", help="只查询状态，不执行签到")
    args = ap.parse_args()

    log = make_logger()

    token = args.token or os.environ.get("WB_ACCESS_TOKEN", "").strip()
    uid = (args.uid or os.environ.get("WB_UID", "")).strip()

    if (not token or not uid) and args.local_auth:
        token, uid = load_local_auth(log=log)

    if not token or not uid:
        log("结果：缺少凭据。请设置环境变量 WB_ACCESS_TOKEN / WB_UID，"
            "或加 --local-auth 从本机读取。")
        return EXIT_NO_CREDENTIALS

    exit_code, _ = checkin(token, uid, status_only=args.status_only, log=log)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
