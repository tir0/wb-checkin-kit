#!/bin/bash
# ==============================================================================
# 回归测试：工作流「记录运行结果」步骤在推送撞车时能否自愈
# ==============================================================================
#   bash tests/test_record_retry.sh
#
# 为什么需要这个测试
#   2026-09-20 线上真实发生过一次：签到成功，但 logs/runs.md 里没有当天记录。
#   原因是本机凭据同步器与工作流是两条独立写路径，会同时往 main 推：
#     · 同步器：state/credentials.enc（凭据轮换时触发）
#     · 工作流：logs/runs.md（每次运行后）
#   工作流那次的 push 被拒，而该步骤设了 continue-on-error，失败被静默吞掉，
#   于是「今天到底有没有自动跑」就查不到了。
#
# 这个测试怎么做的
#   不复制粘贴一份逻辑（那样测的是副本，不是产物），而是直接从
#   .github/workflows/wb-checkin.yml 里把该步骤的 run 块抽出来，在一个
#   本地裸仓库上制造「另一个写者抢先推送」的场景，检验重试是否真能自愈。
#
# 依赖：git、/usr/bin/ruby（macOS 自带，用于解析 YAML）
# ==============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WF="$REPO/.github/workflows/wb-checkin.yml"
PROBE="$(mktemp -d "${TMPDIR:-/tmp}/wb-retry-XXXXXX")"
trap 'rm -rf "$PROBE"' EXIT

pass=0; fail=0
ok()  { printf '  \xe2\x9c\x93 %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \xe2\x9c\x97 %s\n' "$1"; fail=$((fail+1)); }

[ -f "$WF" ] || { echo "找不到工作流文件：$WF"; exit 1; }

echo "── 1) 从工作流抽出「记录运行结果」步骤的 run 块 ──"
# 纯 ASCII 的 ruby 片段：按「最后一个步骤」定位，避免在源码里写中文
if ! /usr/bin/ruby -ryaml -e \
    'd=YAML.load_file(ARGV[0]); File.write(ARGV[1], d["jobs"]["checkin"]["steps"].last["run"])' \
    "$WF" "$PROBE/record.sh"; then
  echo "  抽取失败（ruby/YAML 解析问题）"; exit 1
fi
# 把 GitHub 表达式替换为固定值（等价于一次 schedule 触发的成功运行）。
# 必须用单引号：里面的 $ {{ }} 和 | 在双引号下会被 shell 提前解释。
sed -i '' \
  -e 's/\${{ github\.event_name }}/schedule/g' \
  -e 's/\${{ github\.event\.schedule || .-. }}/17 20 * * */g' \
  -e 's/\${{ steps\.checkin\.outcome || .not-run. }}/success/g' \
  "$PROBE/record.sh"

grep -q 'for i in 1 2 3 4 5' "$PROBE/record.sh" \
  && ok "抽出的脚本含推送重试循环" || bad "未找到重试循环"
[ "$(grep -c '\${{' "$PROBE/record.sh")" = "0" ] \
  && ok "GitHub 表达式已全部替换" || bad "仍有未替换的表达式"

echo "── 2) 搭一个模拟仓库 ──"
git init -q --bare --initial-branch=main "$PROBE/origin.git" || exit 1
git clone -q "$PROBE/origin.git" "$PROBE/work" 2>/dev/null
cd "$PROBE/work" || exit 1
git config user.name t; git config user.email t@t
mkdir -p logs
# 刻意用【旧的 6 列表头 + 一行旧数据】：既测抗撞车，也测表头升级时的行迁移
# （只换表头不补列，历史行会整体错位，渲染成图时列会串）。
printf '| 时间(UTC) | 北京时间 | 触发方式 | cron | 签到步骤 | 凭据快照 |\n|---|---|---|---|---|---|\n| 2026-09-20 05:58:29 | 2026-09-20 13:58 | schedule | 17 0 * * * | success | 2026-09-20T05:58:00Z |\n' \
  > logs/runs.md
git add -A && git commit -q -m init && git push -q -u origin main
# wb_peers.py 落下的多账号逐行结果（记录步骤读它）。
# 刻意放在提交【之后】：该文件在真实仓库里被 .gitignore 排除，属运行时产物，
# 这里要保持「未被跟踪」的初始状态，才能验证它不会被顺手提交。
printf 'alice\tsuccess\tchecked_in\t\t2026-09-22T00:00:00Z\nbob\tfailure\tauth_failed\t凭据已过期 3 天\t2026-09-22T00:00:00Z\n' \
  > logs/last_run.tsv
ok "初始仓库就绪（含旧表头与一行旧数据 + 两个账号的待记录结果）"

echo "── 3) 制造撞车：另一个写者先推了一个提交 ──"
cd "$PROBE" || exit 1
git clone -q "$PROBE/origin.git" "$PROBE/rival" 2>/dev/null
cd "$PROBE/rival" || exit 1
git config user.name r; git config user.email r@r
mkdir -p state
# 模拟同步器推凭据快照：改的是另一个文件，所以 rebase 不会冲突
echo "snapshot-$(date +%s)" > state/credentials.enc
git add -A && git commit -q -m "chore: 同步凭据快照 [skip ci]" && git push -q origin main
ok "竞争提交已推送（此时 work 落后远程 1 个提交）"

echo "── 4) 执行记录步骤（预期：首次被拒 → 重试后成功）──"
cd "$PROBE/work" || exit 1
export GITHUB_REF_NAME=main
: > "$PROBE/step_summary.md"
export GITHUB_STEP_SUMMARY="$PROBE/step_summary.md"
/bin/bash "$PROBE/record.sh" > "$PROBE/record.out" 2>&1
RC=$?
[ "$RC" = "0" ] && ok "记录步骤退出码 0" || bad "记录步骤退出码 ${RC}（期望 0）"
grep -q "次推送被拒" "$PROBE/record.out" \
  && ok "确实走进了「被拒 → 重试」分支" || bad "没触发重试分支（场景没造出来？）"
grep -q "运行记录已提交" "$PROBE/record.out" \
  && ok "重试后成功推上记录" || bad "重试后仍未成功"

echo "── 5) 校验最终结果 ──"
# 注意：本脚本开了 pipefail，`git log | grep -q` 会在 grep 提前退出时让
# git log 吃到 SIGPIPE（退出码 141），使管道整体判为失败 —— 且是时有时无的
# 假阴性。所以先把日志落文件再匹配。
has_commit() {
  git log --oneline origin/main >"$PROBE/log.txt" 2>&1
  grep -q -- "$1" "$PROBE/log.txt"
}

cd "$PROBE" || exit 1
git clone -q "$PROBE/origin.git" "$PROBE/verify" 2>/dev/null
cd "$PROBE/verify" || exit 1
has_commit "记录运行" && ok "远程已含「记录运行」提交" || bad "远程缺「记录运行」提交"
[ -f state/credentials.enc ] && ok "竞争提交未被 rebase 弄丢" || bad "竞争提交丢失"
LINES="$(grep -c '^| 2026-' logs/runs.md 2>/dev/null || echo 0)"
[ "$LINES" -ge 1 ] && ok "runs.md 已追加记录（${LINES} 条）" || bad "runs.md 未追加记录"
has_commit "同步凭据快照" && ok "两个写者的提交都在 main 上" || bad "历史被覆盖"

echo "── 5b) 多账号行与旧行迁移 ──"
head -1 logs/runs.md | grep -q "账号" \
  && ok "表头已含账号列" || bad "表头缺账号列"
# 8 列的行以 | 切分恰好是 10 个字段；不等于 10 就是错位
BADROWS="$(awk -F'|' '/^\| 2026-/ && NF!=10 {printf "%s ", NR}' logs/runs.md)"
[ -z "$BADROWS" ] && ok "所有数据行都是 8 列（无错位）" \
  || bad "这些行不是 8 列：${BADROWS}"
grep -q '^| 2026-09-20 05:58:29 | 2026-09-20 13:58 | - |' logs/runs.md \
  && ok "旧 6 列行被迁移补成「-」账号" || bad "旧行没被正确迁移"
grep -q '| self |'  logs/runs.md && ok "写入了 self 行（仓库主本人）" || bad "缺 self 行"
grep -q '| alice |' logs/runs.md && ok "写入了 alice 行" || bad "缺 alice 行"
grep -q '| bob |'   logs/runs.md && ok "写入了 bob 行"   || bad "缺 bob 行"
grep -q 'auth_failed' logs/runs.md \
  && ok "失败原因落进了说明列" || bad "说明列没写进去"
git ls-files logs/ | grep -q last_run.tsv \
  && bad "last_run.tsv 被误提交了（应只入库 runs.md）" \
  || ok "last_run.tsv 未入库（运行时产物）"

echo
printf '════ 结果：通过 %s 项，失败 %s 项 ════\n' "$pass" "$fail"
echo
echo "── 记录步骤实际输出 ──"
sed 's/^/  /' "$PROBE/record.out"
[ "$fail" = "0" ] || exit 1
