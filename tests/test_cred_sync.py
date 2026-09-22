#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""凭据同步链路的回归测试（无需 pytest，直接 python3 运行）
================================================================
    python3 tests/test_cred_sync.py

这套架构有一个单点风险：本机同步器「加密」与云端工作流「解密」必须用
完全相同的 openssl 参数。任何一侧被改动而另一侧没跟上，就会在云端
静默解密失败。本测试因此做三件事：

  1. 断言两侧源码里的 openssl 参数串一致（防漂移）
  2. 真的做一次 加密 → 解密 往返，校验逐字节一致
  3. 校验错误密钥会被拒绝、密文中不含明文
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
COURIER = os.path.join(REPO, "local", "wb-sync-credentials.sh")
WORKFLOW = os.path.join(REPO, ".github", "workflows", "wb-checkin.yml")
CORE = os.path.join(REPO, "scripts", "wb_core.py")

# 两侧必须一致的核心参数
REQUIRED_SUBSTRINGS = ["-aes-256-cbc", "-pbkdf2", "-iter 200000", "-md sha256"]
FLAG_TOKENS = ["-aes-256-cbc", "-pbkdf2", "-iter", "200000", "-md", "sha256"]

RESULTS = []


def check(label, cond, extra=""):
    RESULTS.append(bool(cond))
    print(f"  {'✓' if cond else '✗'} {label}{(' — ' + extra) if extra else ''}")


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def openssl_available():
    return shutil.which("openssl") is not None


def main():
    print("\n[1] 加密参数在两侧一致（防漂移）")
    courier_src = read(COURIER)
    workflow_src = read(WORKFLOW)
    core_src = read(CORE)

    for flag in REQUIRED_SUBSTRINGS:
        check(f"同步器包含 {flag}", flag in courier_src)
        check(f"工作流包含 {flag}", flag in workflow_src)

    # 抽出各自 openssl enc 那一行的参数并归一化（去掉 -d / -salt 这类不参与
    # 算法选择的开关），确保两侧用的是同一套算法与迭代次数。
    def flags_of(src):
        m = re.search(r"openssl enc\s+((?:-d\s+)?(?:--?[a-z0-9-]+(?:[ =][^\s\\]+)?\s+)+)", src)
        if not m:
            return None
        parts = m.group(1).split()
        return sorted(p for p in parts if p not in ("-d", "-salt"))

    f_enc = flags_of(courier_src)
    f_dec = flags_of(workflow_src)
    check("两侧参数集合一致", f_enc is not None and f_enc == f_dec,
          f"enc={f_enc} dec={f_dec}")

    print("\n[2] 真实往返：加密 → 解密")
    if not openssl_available():
        print("  · 跳过：本机没有 openssl")
    else:
        with tempfile.TemporaryDirectory() as tmp:
            key = os.path.join(tmp, "key")
            subprocess.run(["openssl", "rand", "-hex", "32"],
                           stdout=open(key, "w"), check=True)
            os.chmod(key, 0o600)

            payload = {
                "schema": 1,
                "access_token": "fake-token-roundtrip-" + "x" * 40,
                "uid": "05381c3b-8cc0-4ce0-ac74-69ca96730756",
                "token_rotated_at_ms": "1789695329435",
                "token_expires_at_ms": "1794447328838",
                "synced_at_utc": "2026-09-18T01:50:00Z",
            }
            plain = os.path.join(tmp, "plain.json")
            enc = os.path.join(tmp, "credentials.enc")
            out = os.path.join(tmp, "out.json")
            with open(plain, "w", encoding="utf-8") as fh:
                json.dump(payload, fh, ensure_ascii=False)

            subprocess.run(
                ["openssl", "enc"] + FLAG_TOKENS
                + ["-salt", "-in", plain, "-out", enc, "-pass", f"file:{key}"],
                check=True)
            check("加密成功产出密文", os.path.getsize(enc) > 0)
            check("密文中不含明文 token",
                  payload["access_token"].encode() not in open(enc, "rb").read())

            env = dict(os.environ, RT_KEY=open(key).read().strip())
            subprocess.run(
                ["openssl", "enc", "-d"] + FLAG_TOKENS
                + ["-in", enc, "-pass", "env:RT_KEY"],
                stdout=open(out, "w"), check=True, env=env)

            check("解密后逐字节一致",
                  open(plain, "rb").read() == open(out, "rb").read())
            check("解出的 uid 正确",
                  json.load(open(out, encoding="utf-8"))["uid"] == payload["uid"])

            wrong = os.path.join(tmp, "wrongkey")
            subprocess.run(["openssl", "rand", "-hex", "32"],
                           stdout=open(wrong, "w"), check=True)
            bad = subprocess.run(
                ["openssl", "enc", "-d"] + FLAG_TOKENS
                + ["-in", enc, "-pass", f"file:{wrong}"],
                capture_output=True, env=dict(os.environ))
            check("错误密钥被拒绝", bad.returncode != 0)

    print("\n[3] 凭据摘要脚本")
    summariser = os.path.join(REPO, "scripts", "cred_summary.py")
    with tempfile.TemporaryDirectory() as tmp:
        p = os.path.join(tmp, "cred.json")
        with open(p, "w", encoding="utf-8") as fh:
            json.dump({"access_token": "secret-token-abc", "uid": "u-1",
                       "token_rotated_at_ms": "1789695329435",
                       "token_expires_at_ms": "1794447328838",
                       "synced_at_utc": "2026-09-18T01:50:00Z"}, fh)
        r = subprocess.run([sys.executable, summariser, p],
                           capture_output=True, text=True)
        check("渲染成功", r.returncode == 0, r.stderr.strip()[:80])
        check("输出不含 token", "secret-token-abc" not in r.stdout)
        check("输出含换发时间",
              re.search(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", r.stdout) is not None)

    print("\n[4] 同步器的安全约定与平台约束")
    check("不打印凭据（无 echo $ACCESS_TOKEN）",
          not re.search(r'echo\s+"?\$ACCESS_TOKEN', courier_src))
    check("日志文件权限收紧（chmod 700 状态目录）", "chmod 700" in courier_src)
    check("推送前会清理注入的代理", "unset HTTP_PROXY" in courier_src)
    check("凭据被服务端拒绝时不推送（401 分支）", '"401"' in courier_src)
    check("解密步骤显式注册脱敏", "::add-mask::" in workflow_src)

    # macOS TCC 会拦掉 launchd 对 ~/Documents 的访问，同步器必须用
    # ~/.wb-checkin 下的独立工作副本，且不能 cd 进 ~/Documents 里的仓库。
    check("使用独立工作副本而非 ~/Documents 仓库",
          'WORK_DIR="$STATE_DIR/repo"' in courier_src
          and 'git -C "$WORK_DIR"' in courier_src
          and not re.search(r"^\s*cd\s+.*Documents", courier_src, re.M))
    check("launchd 环境显式补 PATH（不含 Homebrew）",
          'export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"' in courier_src)
    check("自检脚本与同步器用同一套 openssl 参数",
          "-iter 200000" in read(
              os.path.join(REPO, "local", "install.sh")))

    # 真实踩过的坑：$VAR 后紧跟中文全角字符会被 bash 当成变量名的一部分，
    # 触发「unbound variable」。所有脚本必须用 ${VAR} 包起来。
    risky = []
    for rel in ("local/wb-sync-credentials.sh", "local/install.sh",
                "local/join.sh", "local/add-peer.sh"):
        src = read(os.path.join(REPO, rel))
        risky += [f"{rel}:${m.group(1)}{m.group(2)}"
                  for m in re.finditer(r"(?<!\{)\$([A-Za-z_][A-Za-z0-9_]*)([^\x00-\x7f])", src)]
    check("无 $VAR 紧贴全角字符的写法", not risky, str(risky) if risky else "")

    # 真实踩过的坑（2026-09-22）：grep 的 "\|" 交替并不是 POSIX BRE 的一部分。
    # GNU grep 与 macOS 的 BSD grep 恰好都认，但精简实现（例如 WorkBuddy 沙箱里
    # 注入的 toybox grep）不认 —— 不认时不只是「应命中」的断言会凭空失败，更糟的是
    # 「不得命中」的安全断言（如「输出里没有凭据 / 没有原始堆栈」）会静默变成永远
    # 通过，给出假安全。统一改用 grep -q -e A -e B 这种 POSIX 多模式写法。
    altern = []
    # 扫目录而不是列固定文件名：以后新增脚本自动被纳入，不用回来改测试
    scan_targets = [".github/workflows/wb-checkin.yml"]
    for sub, exts in (("local", (".sh", ".ps1")), ("tests", (".sh",))):
        d = os.path.join(REPO, sub)
        if os.path.isdir(d):
            scan_targets += [os.path.join(sub, f)
                             for f in sorted(os.listdir(d)) if f.endswith(exts)]
    for rel in scan_targets:
        p = os.path.join(REPO, rel)
        if not os.path.isfile(p):
            continue
        if re.search(r"grep[^\n]*\\\|", read(p)):
            altern.append(rel)
    check("grep 未使用 \\| 交替（改用 POSIX 的 -e 多模式）",
          not altern, str(sorted(set(altern))) if altern else "")

    # 真实踩过的坑（2026-09-20）：远端快照的哈希用 `jq -r '"\(a)\n\(b)"'`
    # 直接接 shasum，jq 会补一个尾部换行；而本地用 printf '%s\n%s'（无尾部
    # 换行）。两者永不相等 → 每轮都误判「未同步」而重复推送。
    # 现在两侧必须都用同一套 printf 公式。
    print("\n[5] 同步判据与静默失败防护")
    check("远端哈希与本地哈希用同一套拼接公式",
          courier_src.count("printf '%s\\n%s'") >= 3,
          f"出现 {courier_src.count(chr(39) + '%s' + chr(92) + 'n%s' + chr(39))} 次（期望 >=3）")
    check("不再出现旧的有害写法 jq -r 直接接 shasum",
          r'"\(.access_token)\n\(.uid)"' not in courier_src)

    # 陈旧 index.lock 会让 reset/add 静默失败，导致脚本误判「无变化」
    # 却把新指纹写进 last.sha256，从此永久停更。必须显式兜底清理。
    check("有陈旧 index.lock 兜底清理", "LOCK_MAX_AGE" in courier_src
          and "index.lock" in courier_src)
    check("锁看起来在用时不删（跳过重试）", "疑似正在使用" in courier_src)
    check("git add 失败即退出、不更新指纹",
          re.search(r'if ! git -C "\$WORK_DIR" add', courier_src) is not None)
    check("对齐远端失败即退出（2026-09-21 起由 reset --hard 改为 checkout -f -B）",
          re.search(r'if ! git -C "\$WORK_DIR" checkout -q -f -B', courier_src) is not None)
    check("推送全败时不写指纹（保证下轮重试）", "指纹未更新" in courier_src)

    # 2026-09-20 实测：签到成功但 logs/runs.md 没有当天记录 —— 本机同步器
    # 的提交与工作流的提交撞车，push 被拒，而该步骤 continue-on-error
    # 把失败静默吞掉。现在必须有重试 + 可见的 ::error::。
    print("\n[6] 运行记录步骤的抗撞车能力")
    record_step = workflow_src.split("记录运行结果")[-1]
    check("记录步骤有推送重试循环",
          re.search(r"for i in 1 2 3 4 5", record_step) is not None)
    check("重试时先 fetch + rebase", "git rebase" in record_step
          and "git fetch" in record_step)
    check("最终失败会打 ::error:: 注解（不再静默）",
          "::error::" in record_step)
    check("推送失败会打 ::warning:: 便于在 Actions 页面看见",
          "::warning::" in record_step)

    # 凭据快照曾经占仓库总提交量的 66%（清理前 52/78），且今晨 2 分钟内推了 3 次。
    # token 实测 55 天有效、旧快照不因换发失效，所以高频推送纯属堆积。节流是为了
    # 别再复现 —— 若日后被误删，这条会拦住。行为验证见 tests/test_sync_throttle.sh。
    print("\n[7] 推送节流（2026-09-21）")
    check("同步器含节流常量", "MIN_PUSH_INTERVAL" in courier_src)
    check("节流基准时刻只在推送成功后写入",
          re.search(r'date \+%s >"\$THROTTLE_FILE"', courier_src) is not None)
    check("支持 --force 绕过节流", "--force" in courier_src)
    check("远端没有快照时不节流（否则云端永远空着）",
          re.search(r'\[ -n "\$REMOTE_HASH" \] && \[ -f "\$THROTTLE_FILE" \]',
                    courier_src) is not None)
    check("节流判据同时检查窗口与基准有效性",
          "SECS_SINCE" in courier_src and "LAST_PUSH_AT" in courier_src)
    check("未知参数明确报错而不是静默忽略", "exit 64" in courier_src)

    # 2026-09-21 踩到：重试循环里的 git rebase 一旦冲突，会把工作副本永久留在
    # rebase 中途（main 漂到 ahead 68、HEAD 变 detached），之后每轮都失败。
    # 修复方式：不用 rebase，改为「清状态 + checkout -f -B 硬对齐 + 重新提交」。
    # 行为验证见 tests/test_sync_throttle.sh 的 [H] 用例。
    print("\n[7b] git 状态自愈（2026-09-21）")
    check("不再调用 git rebase", not re.search(r"git -C \"\$WORK_DIR\" rebase", courier_src))
    check("会清理 rebase/merge 残留状态目录", "rebase-merge" in courier_src)
    check("用 checkout -f -B 硬对齐（修 detached 与分支漂移）",
          "checkout -q -f -B" in courier_src)
    check("预检与重试两条路径都清理状态",
          courier_src.count("rebase-merge") >= 2)

    # 「今天签没签」过去只能自己来问，就是因为通知一直空转（从未配过）。
    # 2026-09-21 调整：地址不再依赖「用户记得去 GitHub 建 Secret」，改为随
    # 已有的加密快照下发（配置源单一，改地址在本机改完即生效）。
    print("\n[8] 通知接入（2026-09-21）")
    checkin_step = workflow_src.split("执行签到")[-1].split("记录运行结果")[0]
    decrypt_step = workflow_src.split("解出最新凭据")[-1].split("执行签到")[0]
    check("解密步骤从快照里取通知地址", "notify_webhook" in decrypt_step)
    check("地址写入 GITHUB_ENV 且注册了掩码",
          "NOTIFY_WEBHOOK=" in decrypt_step and "::add-mask::" in decrypt_step)
    check("Secret 仍可覆盖（兼容旧部署 / 临时排障）",
          "secrets.WB_NOTIFY_WEBHOOK" in workflow_src)
    check("签到步骤不再声明 NOTIFY_WEBHOOK（步骤级 env 优先级更高，"
          "未设 Secret 时会用空值把快照里的地址清掉）",
          re.search(r"(?m)^\s+NOTIFY_WEBHOOK:", checkin_step) is None)
    check("开启每日回执（NOTIFY_ON_SUCCESS）",
          "NOTIFY_ON_SUCCESS" in checkin_step)
    check("同步器把通知地址纳入加密载荷",
          "notify_webhook:$w" in courier_src)
    check("只改地址也能立刻生效（不被节流挡住）",
          "NEW_CFG_HASH" in courier_src and "REMOTE_CFG_HASH" in courier_src)
    check("同步器任何日志都不写通知地址明文",
          all("$NOTIFY_WEBHOOK" not in line
              for line in re.findall(r'log\s+"([^"]*)"', courier_src)))
    check("通知文案指向当前架构，不再提 WB_ACCESS_TOKEN / 函数配置",
          "函数配置" not in core_src and "更新到环境变量" not in core_src)
    check("钉钉 errcode 非 0 时不会被误报为已发送",
          "_notify_delivered" in core_src and "被渠道拒收" in core_src)

    # 多账号（2026-09-22）刻意做成「纯增量」：单账号那条链路一个字没改，
    # 朋友的账号挂在同一个私有仓库里跑。以下几条钉住这个设计边界 ——
    # 一旦有人把两条链路搅在一起（共用变量名 / 互相阻塞），这里会拦下来。
    print("\n[9] 多账号与单账号链路的边界")
    peers_step = workflow_src.split("多账号签到")[-1].split("记录运行结果")[0]
    check("多账号步骤 if: always()（两条链路互不拖累）",
          "if: always()" in peers_step)
    check("多账号步骤用独立的通知兜底变量名"
          "（否则会踩「步骤级 env 覆盖 GITHUB_ENV」那个坑，把单账号地址清成空）",
          "WB_PEER_NOTIFY_FALLBACK" in peers_step
          and re.search(r"(?m)^\s+NOTIFY_WEBHOOK:", peers_step) is None)
    check("单账号解密步骤保持原样（升级不影响既有部署）",
          "解出最新凭据" in workflow_src
          and "state/credentials.enc" in workflow_src
          and "secrets.WB_TOKEN_KEY" in workflow_src)
    check("多账号不碰单账号的 Secret（各自独立）",
          "WB_TOKEN_KEY" not in peers_step)
    check("记录步骤按账号逐行写入（读多账号驱动的 TSV）",
          "last_run.tsv" in record_step)
    check("记录步骤会把旧 6 列行迁移成 8 列（否则历史行整体错位）",
          "NF==8" in record_step and "账号" in record_step)
    check("多账号驱动的 openssl 参数与同步器一致（防止一侧漂移）",
          all(flag in read(os.path.join(REPO, "scripts", "wb_peers.py"))
              for flag in ("-iter", "200000", "-md", "sha256")))

    total, ok_n = len(RESULTS), sum(RESULTS)
    print(f"\n{'=' * 46}\n通过 {ok_n}/{total} 项")
    return 0 if ok_n == total else 1


if __name__ == "__main__":
    sys.exit(main())
