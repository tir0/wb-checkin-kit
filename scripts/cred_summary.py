#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把解密出来的凭据元数据渲染成 Markdown 表格，用于 Actions 运行摘要。

只输出时间与状态，**不输出任何凭据内容**。
用法：python3 scripts/cred_summary.py /path/to/cred.json
"""
import datetime
import json
import sys


def fmt_ms(value):
    """毫秒时间戳 → 可读时间；无法解析时返回「未知」。"""
    try:
        v = int(value)
    except (TypeError, ValueError):
        return "未知"
    if v <= 0:
        return "未知"
    return datetime.datetime.fromtimestamp(v / 1000).strftime("%Y-%m-%d %H:%M:%S")


def main(argv):
    if len(argv) < 2:
        print("用法：cred_summary.py <cred.json>", file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8") as fh:
        data = json.load(fh)

    synced = data.get("synced_at_utc") or "未知"
    rotated = fmt_ms(data.get("token_rotated_at_ms"))
    expires = fmt_ms(data.get("token_expires_at_ms"))

    print("### 凭据新鲜度")
    print()
    print("| 项 | 值 |")
    print("|---|---|")
    print(f"| 本机同步快照时间 | {synced} |")
    print(f"| 桌面端换发 token 时间 | {rotated} |")
    print(f"| accessToken 到期时间 | {expires} |")
    print()
    print("> 快照时间越旧，说明本机同步器越久没跑；若长期不变而 Signin 又报 401，"
          "先检查 Mac 上的 `~/.wb-checkin/sync.log`。")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
