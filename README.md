# wb-checkin

WorkBuddy「Buddy 加油站」每日自动签到。**完全跑在 GitHub 云端**，不依赖你的电脑
（关机、断网、出差都不影响），也不经过任何大模型 —— token / 积分消耗恒为 0。

> **这个仓库可以安全公开**：它只包含脚本与文档，**不含任何凭据**。
> 加密后的凭据快照只会出现在**使用者自己的私有仓库**里。

---

## 你是哪一种情况？

| 你的情况 | 走哪条路 | 大概多少步 |
|---|---|---|
| 有朋友在跑这套，想让他捎带你一个 | **A. 只要拿到 `join` 脚本** | 3 步，不用 GitHub 账号 |
| 想给自己也装一整套 | **B. 用 Template 建自己的私有仓库** | 1 次安装脚本 |

### A. 只是要加入（不需要 GitHub 账号）

你只需要拿到一个脚本、跑一次、把生成的文件发回给那位朋友。**不需要注册 GitHub、
不需要装常驻软件、跟你的电脑开不开机无关。**

| 你的系统 | 拿这个文件 | 怎么跑 |
|---|---|---|
| Windows | `local/join.ps1` | 见 [`local/发给朋友-怎么加入.md`](local/发给朋友-怎么加入.md) |
| macOS / Linux | `local/join.sh` | `bash join.sh --name 你的昵称 --notify '你的机器人地址'` |

取文件的两种方式（任选）：

```powershell
# 方式一（Windows，一条命令；需要能访问 raw.githubusercontent.com）
irm https://raw.githubusercontent.com/tir0/wb-checkin-kit/main/local/join.ps1 -OutFile join.ps1
```

```bash
# 方式二（macOS / Linux；或直接用浏览器打开仓库页面点「Download raw file」）
curl -LO https://raw.githubusercontent.com/tir0/wb-checkin-kit/main/local/join.sh
```

> 拿不到 raw 链接也没关系：在 GitHub 网页上打开这个文件 → 右上角 **Raw** →
> 全选复制 → 存成本地文件，效果一样。

跑完你会得到一个 `wb-checkin-<昵称>-<日期>.json`，发给朋友即完成。里面装的是
**用你自己专属密钥加密过的凭据**，不是明文账号密码。

### B. 给自己装一整套

1. 点本仓库右上角 **Use this template → Create a new repository**
2. **Visibility 一定选 Private**，仓库名随意，比如 `wb-checkin`
3. 在你自己的 Mac 上：

```bash
git clone git@github.com:<你的用户名>/<你起的仓库名>.git && cd <你起的仓库名>
bash local/install.sh --notify 'https://oapi.dingtalk.com/robot/send?access_token=...'
```

`--notify` 可省略。装完按脚本提示，去**你自己那个仓库**的 Settings 新建 Secret
`WB_TOKEN_KEY`（密钥脚本已复制到剪贴板），保存即可。

> 建好 Secret 之前，Actions 里会有一次红色运行 —— 那是正常的：任务会在
> 「解出最新凭据」那步明确告诉你缺哪个 Secret。仓库里还没有凭据快照时，
> 「记录运行结果」步骤会整体跳过，不会往仓库里写无意义的提交。

> ⚠️ **你的仓库必须是私有的。** 工作流需要仓库里存一份「加密后的凭据快照」
> （`state/credentials.enc`）。它本身不可解密，但一旦公开就会永久留在 git 历史里、
> 收不回来 —— 哪天密钥泄露就等于凭据泄露。这也是这个仓库（你现在看的这个）
> 刻意**只放代码、不放任何快照**的原因。

> 建议顺手改一下 `.github/workflows/wb-checkin.yml` 里的 cron 时间，别和别人的部署
> 都挤在同一分钟（例如把 `17 1 * * *` 改成 `23 3 * * *`，UTC 时间）。

**依赖**：macOS、`jq`（新版系统自带 `/usr/bin/jq`，旧版 `brew install jq`）、
Homebrew `openssl`、`git`、`curl`；GitHub 用 **SSH** remote（用 PAT 推
`.github/workflows/` 会因缺 `workflow` scope 被拒）。

---

## 架构

```
Mac（本机同步器，launchd 常驻）
  读 ~/Library/.../workbuddy-desktop.info 里最新的 accessToken
  → AES-256-CBC 加密 → 推到你的私有仓库 state/credentials.enc
                                  │
GitHub Actions（每天 3 个时点，UTC 硬编码）│
  解密（密钥来自仓库 Secret WB_TOKEN_KEY）
  → 调签到接口 → 按需发通知 → 结果追加进 logs/runs.md
```

**为什么必须有本机这一环**：`accessToken` 是 JWT，实测 55 天失效；桌面端重新登录也会
顶掉旧的。所以不能「复制一次、长期不管」，必须有个环节持续把新凭据同步上去。
（实测：日常换发*不会*吊销旧 token，跨越 3.3 天的 8 份历史快照全都仍返回 200，
因此同步器带推送节流，默认 20 小时最多推一次。）

---

## 一、单账号：给自己装

```bash
git clone <你的仓库> && cd <你的仓库>
bash local/install.sh --notify 'https://oapi.dingtalk.com/robot/send?access_token=...'
```

脚本会：生成密钥并复制到剪贴板 → 加解密自检 → 装 launchd 任务 → 克隆独立工作副本
→ 立刻同步一次并核对退出码。收尾时它会**按你的 remote 自动推导**出设置页地址，提示你：

> 到 `…/settings/secrets/actions` 新建 Secret `WB_TOKEN_KEY`，直接粘贴。

装完不用管了。验证：Actions 页面点一次 **Run workflow**，或看 `logs/runs.md`。

---

## 二、多账号：帮朋友一起签

朋友**不需要 GitHub 账号、不需要 SSH、不需要装同步器**，只需要：

1. 在自己机器上登录 WorkBuddy 桌面端；
2. 跑一条命令（即上面「A. 只是要加入」），把一个分享文件发给你。

### 朋友侧（一次操作）

```bash
bash local/join.sh --name alice --notify 'https://oapi.dingtalk.com/robot/send?access_token=...'
# 不想配通知也行；想更稳妥（密文与密钥分开送）加 --split
```

脚本先调接口**验证凭据可用**（401 直接拒绝，不会让你白等），再用**这个账号专属的密钥**
加密，产出 `~/Desktop/wb-checkin-alice-<日期>.json`，把它发给你即可。

也可以把 [`local/发给朋友-怎么加入.md`](local/发给朋友-怎么加入.md) 整份转发给他 ——
那份文档是给「朋友」看的，含 Windows 图文步骤与常见报错对照。

#### Windows 朋友

同一个脚本的 Windows 版本：**`local/join.ps1`**。单文件、自包含，朋友**不需要**
git / GitHub / WSL / openssl / jq —— 用系统自带的 PowerShell + .NET 完成同样的事
（PBKDF2-SHA256 200000 次 + AES-256-CBC，产出与 `openssl enc -salt` 逐字节同格式的密文）。

把 `local/join.ps1` 单独发给他，他在 **PowerShell** 里执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\join.ps1 -Name alice
# 或一步到位，顺带配好自己的机器人：
powershell -NoProfile -ExecutionPolicy Bypass -File .\join.ps1 -Name alice -Notify 'https://oapi.dingtalk.com/robot/send?access_token=...'
```

产出 `桌面\wb-checkin-alice-<日期>.json`，发回给你，后续导入流程与 macOS **完全相同**
（照旧 `bash local/add-peer.sh <文件>`）。

| 参数 | 作用 |
|---|---|
| `-Name alice` | 账号标识（不填则用 uid 自动派生，你导入时可 `--as` 改名） |
| `-Notify '<机器人地址>'` | 该账号自己的通知机器人；不填则落到仓库兜底地址 |
| `-Split` | 密文进文件、密钥只显示在屏幕，两者分渠道发 |
| `-Print` | 额外打印一行可直接粘贴的分享码（= base64 整份文件） |
| `-StatusOnly` | 只校验凭据、不产出文件（排障用） |
| `-CredFile '<路径>'` | 手动指定登录态文件（默认自动探测，见下） |
| `-SelfTest` | 加密链路自检，不读凭据、不产文件（排障用） |

**登录态位置**：默认按顺序探测 `%APPDATA%\CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info`
等几个候选路径，都不存在时会在 `%APPDATA%` / `%LOCALAPPDATA%` 下按文件名模糊搜索（6 层，取最新）。
实在找不到就用 `-CredFile '完整路径'` 指定。

**两个 Windows 特有的坑，脚本已处理**：

- 脚本文件本身**带 UTF-8 BOM** —— PowerShell 5.1 对无 BOM 的 UTF-8 按系统代码页（中文系统 GBK）
  解码，中文提示会全变乱码。
- 产出的 JSON **一律无 BOM** 写出（`Set-Content -Encoding UTF8` 会加 BOM）—— BOM 不是合法 JSON，
  实测 jq 1.7 会跳过它、但 Python `json.loads` 直接报 `Unexpected UTF-8 BOM`，而下游解析器不受我们控制。
- 提示文案只用 GBK 也有的符号（`√ × · ！`），不用 `✓ ✗ ⚠`（中文控制台会显示成问号）。

### 仓库主侧（一次操作）

```bash
bash local/add-peer.sh ~/Downloads/wb-checkin-alice-20260922.json
```

脚本会：校验结构（防路径穿越）→ 先解密验证（密钥不符就拒绝）→ 再调接口验证凭据
可用 → 落盘 `state/peers/alice.enc` → 把完整密钥 JSON 放进剪贴板 → 提交并推送。
然后到仓库 Settings 更新 Secret **`WB_PEER_KEYS`**，粘贴（内容已在剪贴板）→ 保存。

之后每天云端会逐账号签到，`logs/runs.md` 一行一个账号：

```
| 时间(UTC) | 北京时间 | 账号 | 触发方式 | cron | 结果 | 说明 | 凭据快照 |
| 2026-09-22 05:58:29 | 2026-09-22 13:58 | self  | schedule | 17 4 * * * | success | checked_in | 2026-09-22T00:00:00Z |
| 2026-09-22 05:58:29 | 2026-09-22 13:58 | alice | schedule | 17 4 * * * | success | already_checked_in | 2026-09-22T00:00:00Z |
```

常用命令：

```bash
bash local/add-peer.sh --list            # 看已导入账号、密钥齐备情况、凭据剩余天数
bash local/add-peer.sh --remove alice    # 移除账号（记得同步更新 Secret）
python3 scripts/wb_peers.py --list       # 同上，直接看云端视角
```

### 通知怎么走

| 场景 | 行为 |
|---|---|
| 账号自带机器人（join.sh 里给了 `--notify`） | 回执**直接发给本人**，标题形如 `【WorkBuddy 签到｜alice：签到成功】` |
| 账号没带机器人 | 落到仓库级 `WB_NOTIFY_WEBHOOK`（即「大家都用同一个机器人」） |
| 谁都没配 | 完全静默，签到照常（不影响结果） |

一个账号失败**不会**中断其他账号，但整体退出码非 0（会红），且通知里会指名是哪个账号。

每日回执（`NOTIFY_ON_SUCCESS=1`）只在**本次运行真的签上了**时发一条；今天若早已签到
完成，不会再催一遍 —— 定时任务一天跑 5 次，只有真正签上的那一条带新信息。

---

## 三、维护

| 症状 | 处理 |
|---|---|
| 一天只收到一条回执，后面几次运行没动静 | 符合预期：只有真正签上的那次才发回执，已签到不重复播报 |
| 自己没再收到回执 / 记录里出现 `auth_failed` | 本机同步器一般会自动恢复；必要时 `bash ~/.wb-checkin/wb-sync-credentials.sh --force` |
| 某个朋友的账号 `auth_failed` | 让**他**重跑 `local/join.sh`（Windows 是 `join.ps1`），把新分享文件发回来，你再 `add-peer.sh` 导入 |
| 朋友是 Windows，跑脚本报错 | 先让他跑 `-SelfTest`（自检，不碰凭据）；再检查 `-ExecutionPolicy Bypass` 是否带上、文件是否被「解除锁定」 |
| 新增/移除账号后不生效 | 忘了更新 Secret `WB_PEER_KEYS`（缺密钥的账号会被明确跳过，不会静默漏签） |
| 改了 `local/` 下的脚本 | 重跑 `bash local/install.sh` —— launchd 跑的是 `~/.wb-checkin/` 下的副本 |
| 本地仓库没跟上云端提交 | 本机工作副本不会自动跟随（launchd 无权访问 `~/Documents`），自己 `git pull` |

---

## 四、安全边界

- 仓库里**只有密文**（`state/credentials.enc`、`state/peers/*.enc`），AES-256-CBC +
  PBKDF2 20 万次，无密钥不可解。
- **一人一钥**：每个朋友的快照用各自密钥加密，密钥集中放在 Secret `WB_PEER_KEYS`。
  某一份分享文件泄露，也只能解开他自己那一份。
- 密钥与凭据**永不打印**：脚本只经环境变量把密钥交给 openssl（`-pass env:`），
  CI 里对解出来的每个值先登记 `::add-mask::` 再使用。
- 分享文件默认同时含密文与密钥（最省事）；要更稳妥就用 `--split`，让两者走不同渠道。
- 通知地址（机器人令牌）随密文一起下发，因此**不必**在 GitHub 上手工建 Secret，
  改地址也只需改本机配置。

---

## 五、测试

```bash
python3 tests/test_cred_sync.py    # 加解密参数防漂移 + 往返 + 安全约定 + 两链路边界
python3 tests/test_peers.py        # 多账号：不串号 / 通知分发 / 失败不拖累 / 不泄露
python3 tests/test_notify.py       # 通知渲染与渠道适配
bash    tests/test_peer_join.sh    # 「朋友加入 → 仓库主导入」全链路（含本地桩）
bash    tests/test_peer_join_win.sh# 同上，Windows 侧（互操作 + 中文 Windows 兼容性）
bash    tests/test_record_retry.sh # 运行记录抗撞车 + 旧表头行迁移
bash    tests/test_sync_throttle.sh# 同步器节流与 git 状态自愈
python3 tests/test_travel.py       # 喵喵旅行：幂等 / 状态机 / 竞态 / 通知策略 / 工作流接线
```

`tests/test_record_retry.sh` 直接从工作流里抽出「记录运行结果」步骤来跑 ——
所以改那段 bash 后，必须先跑它。

`tests/test_travel.py` 的后半段是**静态断言**（工作流里的喵喵步骤、cron 数量、
不重复声明 NOTIFY_WEBHOOK、记录步骤读 travel.tsv）—— 改那段接线后必须重跑。

`tests/test_peer_join_win.sh` 的静态部分**永远执行**（BOM、GBK 无法显示的符号、
与 openssl 对齐的算法参数、参数面）；端到端部分需要 PowerShell：本机没有 `pwsh`
时会**明确打印「跳过」**并列出安装命令，不会假装通过：

```bash
brew install --cask powershell                       # macOS
WB_PWSH=/path/to/pwsh bash tests/test_peer_join_win.sh   # 指定别的可执行文件
```

---

## 六、目录

```
.github/workflows/wb-checkin.yml   云端：解密 → 签到 → 多账号 → 喵喵旅行 → 记录
scripts/wb_core.py                 核心逻辑（接口契约、判定、通知渲染，单一实现源）
scripts/wb_checkin.py              单账号入口
scripts/wb_peers.py                多账号驱动（每人一把密钥，逐个签到、分头发通知）
scripts/wb_travel.py               喵喵旅行（幂等自检：该领就领、该派就派）
local/install.sh                   本机安装（launchd + 密钥 + 配置）
local/wb-sync-credentials.sh       本机凭据同步器（加密上传，带节流与锁兜底）
local/join.sh                      他人账号侧：产出发给仓库主的分享文件（macOS/Linux）
local/join.ps1                     同上，Windows 版（自包含，仅需系统自带 PowerShell）
local/发给朋友-怎么加入.md           可直接转发给朋友的操作说明（含 Windows 图文步骤）
local/add-peer.sh                  仓库主侧：导入分享文件、维护密钥登记簿
state/                             加密凭据快照（入库；无密钥不可解）
logs/runs.md                       逐账号运行记录（工作流自动追加）
```

---

## 七、附：派喵喵去旅行

工作流里还挂了一个增长中心的小活动：每天可以把 Buddy（猫猫）派去一个地点旅行，
随机 1~4 小时后到达，到达可领 5~10 积分，**每天限一次**。属于顺带跑的功能，
不想要的话把工作流里的「喵喵旅行」步骤和 `scripts/wb_travel.py` 删掉即可，
签到链路不受影响。

自动化方式是**幂等自检**，不是「派完 sleep 四小时」：

| 运行时的状态 | 动作 |
|---|---|
| `arrived`（已到达） | 领取奖励 |
| `idle` 且今天还没派 | 随机挑个地点派出去 |
| `traveling`（在路上） | 什么都不做，等下一次运行来领 |
| `idle` 且今天已派过 | 什么都不做 |

所以只需多两个 cron 时点（16:17 / 20:17 北京）—— 上午那次把猫派出去，
之后任意一次运行时若已到达就自动领取。每次运行都是安全的：
重复跑不会重复领、也不会重复派。

凭据与签到**同源**：同一个 accessToken 在 `www.workbuddy.cn` 与
`copilot.tencent.com` 两边都能用，因此**不需要任何新的 Secret**。

```bash
python3 scripts/wb_travel.py --status-only   # 看一眼状态（只读，不影响活动）
python3 scripts/wb_travel.py                 # 手动跑一次完整自检
```

通知也只共用同一个机器人：只在「领取成功」和「需要人工介入」时推送。

---

## 不做什么

- 不采集、不上传任何与签到无关的数据；
- 不绕过任何验证码 / 风控；接口失败就如实报失败（通知里会写明是「渠道拒收」
  还是「凭据失效」）；
- 不依赖大模型 —— 整条链路就是一次 HTTP 请求加一次 JSON 读写。

---

## 许可

MIT License，署名 tir0 —— 详见 [LICENSE](LICENSE)。可自由使用、修改、再分发，
保留版权声明即可。
