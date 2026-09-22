<#
==============================================================================
 加入一个已存在的签到仓库（他人账号侧 · Windows）
==============================================================================
 与 local/join.sh 做的事完全一致，只是换成 Windows 原生方式，且**不依赖
 openssl / jq / bash**：用 .NET 内置的 PBKDF2-SHA256 + AES-256-CBC，
 产出与 `openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -salt`
 逐字节同格式的密文（"Salted__" + 8 字节 salt + 密文）。

 你（朋友）不需要 GitHub 账号，也不需要装任何常驻程序：签到这个动作由仓库
 主人的云端任务完成，你只负责把「一次性的凭据副本」交给他。

 用法（在 PowerShell 里执行）：
   powershell -NoProfile -ExecutionPolicy Bypass -File .\join.ps1 -Name alice
   powershell -NoProfile -ExecutionPolicy Bypass -File .\join.ps1 -Name alice -Notify '钉钉/企微机器人地址'
   powershell -NoProfile -ExecutionPolicy Bypass -File .\join.ps1 -Name alice -Split     # 密文与密钥分开送
   powershell -NoProfile -ExecutionPolicy Bypass -File .\join.ps1 -Name alice -Print     # 额外打印一行可粘贴的分享码
   powershell -NoProfile -ExecutionPolicy Bypass -File .\join.ps1 -SelfTest              # 自检加密链路（不碰凭据）

 关于安全（务必读一眼）
   分享文件里同时装着「上了锁的箱子」（密文）和「钥匙」（密钥）。
   · 默认模式：一个文件发出去，最省事；请只发给你信任的仓库主人，
     发完把桌面上的文件删掉（对方收到后也用不着留着）。
   · -Split 模式：密文进文件、密钥只显示在屏幕上，你分两个渠道发
     （例如文件走微信、密钥走另一个渠道）。多一步，但任何一个渠道泄露
     都不足以解开凭据。

 有效期
   凭据是 JWT，实测 55 天失效；桌面端重新登录也可能顶掉旧凭据。
   届时重跑本脚本，把新的分享文件发回即可（旧文件不用删，覆盖即可）。
==============================================================================
#>
[CmdletBinding()]
param(
    [string]$Name = '',
    [string]$Notify = '',
    [string]$Out = '',
    [string]$CredFile = '',
    [string]$StatusUrl = '',
    [switch]$Split,
    [switch]$Print,
    [switch]$StatusOnly,
    [switch]$Offline,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ------------------------------------------------------------------ 输出小工具
# 注意：本脚本刻意只用 GBK 也有的符号（√ × · ！），不用 ✓ ✗ ⚠ ——
# 中文 Windows 的控制台默认代码页是 936，那些符号会显示成问号。
function Say([string]$msg) { Write-Host $msg }
function Ok([string]$msg) { Write-Host "[√] $msg" }
function Warn([string]$msg) { Write-Host "[!] $msg" }
function Fail([string]$msg) { Write-Host "[×] $msg" -ForegroundColor Red; exit 1 }

# 无 BOM 写出：PS 5.1 的 Set-Content -Encoding UTF8 会带 BOM，而 BOM 并不是
# 合法 JSON（RFC 8259 只是「允许解析器忽略」，不强制）。实测：jq 1.7 会跳过
# BOM，但 Python 的 json.loads 遇到 U+FEFF 直接报 Unexpected UTF-8 BOM，
# 而下游「仓库主侧」的解析器不受我们控制 —— 所以这里一律走 .NET 显式写字节，
# 产出纯净 UTF-8（无 BOM）。
function Write-TextNoBom([string]$Path, [string]$Text) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function Get-RandomBytes([int]$Count) {
    $buf = New-Object 'byte[]' $Count
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buf)
    return , $buf
}

function ConvertTo-HexLower([byte[]]$Bytes) {
    return (($Bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

# 逐层取属性；任一层缺失都返回 ''。
# 为什么不直接写 $cred.auth.accessToken：本脚本开了 StrictMode，访问不存在的
# 属性会抛 PropertyNotFoundException，朋友看到的会是一整段堆栈而不是人话。
function Get-Prop($Object, [string]$Path) {
    $cur = $Object
    foreach ($seg in $Path.Split('.')) {
        if ($null -eq $cur) { return '' }
        $prop = $cur.PSObject.Properties[$seg]
        if ($null -eq $prop) { return '' }
        $cur = $prop.Value
    }
    if ($null -eq $cur) { return '' }
    return [string]$cur
}

# 与 openssl 的 `-salt` 输出格式对齐：PBKDF2-HMAC-SHA256(pass, salt, 200000, 48)
# → 前 32 字节为 AES-256 key、后 16 字节为 IV；文件头 "Salted__" + salt。
function Protect-OpenSslCompatible {
    param(
        [Parameter(Mandatory = $true)][byte[]]$PlainBytes,
        [Parameter(Mandatory = $true)][string]$HexKey
    )
    $salt = Get-RandomBytes 8
    try {
        $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new(
            $HexKey, $salt, 200000, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    }
    catch {
        Fail @"
本机 .NET 不支持 PBKDF2-SHA256，无法产出与云端兼容的密文。
  要求：Windows 10 1809（.NET Framework 4.7.2）及以上。
  请先装好系统更新再重试；或改用 Git for Windows 自带 Git Bash 跑仓库里的 join.sh。
"@
    }
    $derived = $kdf.GetBytes(48)
    $kdf.Dispose()

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = [byte[]]$derived[0..31]
    $aes.IV = [byte[]]$derived[32..47]
    $enc = $aes.CreateEncryptor()
    $cipher = $enc.TransformFinalBlock($PlainBytes, 0, $PlainBytes.Length)
    $enc.Dispose()
    $aes.Dispose()

    $magic = [System.Text.Encoding]::ASCII.GetBytes('Salted__')
    $out = New-Object 'byte[]' ($magic.Length + $salt.Length + $cipher.Length)
    [Array]::Copy($magic, 0, $out, 0, $magic.Length)
    [Array]::Copy($salt, 0, $out, $magic.Length, $salt.Length)
    [Array]::Copy($cipher, 0, $out, $magic.Length + $salt.Length, $cipher.Length)
    return , $out
}

function Unprotect-OpenSslCompatible {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Blob,
        [Parameter(Mandatory = $true)][string]$HexKey
    )
    if ($Blob.Length -lt 32) { throw '密文太短' }
    $magic = [System.Text.Encoding]::ASCII.GetString($Blob, 0, 8)
    if ($magic -ne 'Salted__') { throw "文件头不是 Salted__（实际 $magic）" }
    $salt = $Blob[8..15]
    $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new(
        $HexKey, $salt, 200000, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $derived = $kdf.GetBytes(48)
    $kdf.Dispose()
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = [byte[]]$derived[0..31]
    $aes.IV = [byte[]]$derived[32..47]
    $dec = $aes.CreateDecryptor()
    $plain = $dec.TransformFinalBlock($Blob, 16, $Blob.Length - 16)
    $dec.Dispose()
    $aes.Dispose()
    return , $plain
}

# ------------------------------------------------------------------ 自检模式
if ($SelfTest) {
    Say '=== 加密链路自检（不读取任何凭据、不产出文件）==='
    Say ''
    $key = ConvertTo-HexLower (Get-RandomBytes 32)
    $sample = '{"schema":2,"peer_slug":"selftest","access_token":"x.y.z","uid":"00000000-0000-0000-0000-000000000000"}'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($sample)
    $blob = Protect-OpenSslCompatible -PlainBytes $bytes -HexKey $key
    $back = Unprotect-OpenSslCompatible -Blob $blob -HexKey $key
    $text = [System.Text.Encoding]::UTF8.GetString($back)

    if ($text -ne $sample) { Fail '往返解密结果与原文不一致 —— 加密实现有问题，请把这段输出发给仓库主。' }
    Ok '加密 → 解密往返一致（PBKDF2-SHA256 200000 次 / AES-256-CBC）'
    if ([System.Text.Encoding]::ASCII.GetString($blob, 0, 8) -ne 'Salted__') { Fail '文件头不是 Salted__' }
    Ok '密文头为 Salted__ + 8 字节 salt（与 openssl -salt 同格式）'
    $expect = 8 + 8 + $bytes.Length + (16 - ($bytes.Length % 16))
    if ($blob.Length -ne $expect) { Fail "长度不符：期望 $expect，实际 $($blob.Length)" }
    Ok "密文长度符合 PKCS7 填充预期（$($blob.Length) 字节）"

    Say ''
    Say '本机 PowerShell / .NET 可以正常产出与云端兼容的密文。'
    exit 0
}

# ------------------------------------------------------------------ 参数归一
$CRED_CANDIDATES = @()
if ($CredFile) { $CRED_CANDIDATES += $CredFile }
if ($env:WB_CRED_FILE) { $CRED_CANDIDATES += $env:WB_CRED_FILE }
foreach ($base in @($env:APPDATA, $env:LOCALAPPDATA)) {
    if ($base) {
        $CRED_CANDIDATES += (Join-Path $base 'CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info')
        $CRED_CANDIDATES += (Join-Path $base 'WorkBuddy\Data\Public\auth\workbuddy-desktop.info')
    }
}
if ($env:USERPROFILE) {
    $CRED_CANDIDATES += (Join-Path $env:USERPROFILE '.codebuddy\Data\Public\auth\workbuddy-desktop.info')
}

if (-not $StatusUrl) {
    $StatusUrl = if ($env:WB_STATUS_URL) { $env:WB_STATUS_URL }
    else { 'https://copilot.tencent.com/v2/billing/meter/checkin-activity-status' }
}

Say '=== 加入 WorkBuddy 自动签到（他人账号侧 · Windows）==='
Say ''

# ------------------------------------------------------------------ 1) 读凭据
function Find-CredFile {
    foreach ($p in $CRED_CANDIDATES) {
        if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return (Resolve-Path -LiteralPath $p).Path }
    }
    # 兜底：在 %APPDATA% / %LOCALAPPDATA% 下按文件名搜（路径可能随版本变化）
    foreach ($base in @($env:APPDATA, $env:LOCALAPPDATA)) {
        if (-not $base -or -not (Test-Path -LiteralPath $base)) { continue }
        $hit = Get-ChildItem -LiteralPath $base -Filter 'workbuddy-desktop.info' -Recurse -File `
            -Depth 6 -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return ''
}

$CredPath = Find-CredFile
if (-not $CredPath) {
    Fail @"
读不到本机登录态。已找过这些位置：
  $($CRED_CANDIDATES -join "`n  ")
  以及 %APPDATA% / %LOCALAPPDATA% 下的模糊搜索（6 层）
请先打开 WorkBuddy 桌面端并完成登录，再重跑本脚本。
若你的桌面端把登录态放在别处，可用 -CredFile '完整路径' 指定。
"@
}

try {
    $cred = Get-Content -LiteralPath $CredPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Fail "登录态文件不是合法 JSON：$CredPath`n（桌面端可能正在写入，稍等几秒重跑即可）"
}
if ($null -eq $cred) { Fail "登录态文件是空的：$CredPath`n请先打开 WorkBuddy 桌面端并完成登录。" }

$ACCESS_TOKEN = Get-Prop $cred 'auth.accessToken'
$WB_UID = Get-Prop $cred 'account.uid'
$EXPIRES_AT = Get-Prop $cred 'auth.expiresAt'
$ROTATED_AT = Get-Prop $cred 'auth.lastRefreshTime'

if ([string]::IsNullOrWhiteSpace($ACCESS_TOKEN)) { Fail '登录态里没有 accessToken，请重新登录桌面端。' }
if ([string]::IsNullOrWhiteSpace($WB_UID)) { Fail '登录态里没有 uid，请重新登录桌面端。' }
Ok '[1/4] 已读取本机登录态（不显示内容）'

# 账号标识：不给就用 uid 派生一个，仓库主那边可以用 --as 改名
if (-not $Name) {
    $digest = $WB_UID -replace '-', ''
    if ($digest.Length -gt 6) { $digest = $digest.Substring(0, 6) }
    $Name = 'u' + $digest
    Say "      未指定 -Name，自动取账号标识：$Name（仓库主可在导入时改名）"
}
else {
    $Name = $Name.ToLowerInvariant() -replace '\s', '-'
    $Name = ($Name -replace '[^a-z0-9_-]', '')
}
if (-not $Name) { Fail '账号标识为空，请用 -Name 指定（只能用 a-z 0-9 _ -，如 -Name alice）' }

# ------------------------------------------------------------------ 2) 验证凭据
# 为什么先验证：一个过期的凭据交出去，对方要等到云端跑失败才知道，
# 那时还得再找你一轮。这里花一次请求就能提前拦住。
if ($Offline) {
    Warn '[2/4] 已跳过凭据校验（-Offline）。仅用于离线演练，不要用它生成正式分享文件。'
}
else {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
    $code = 0
    try {
        $req = [System.Net.WebRequest]::Create($StatusUrl)
        $req.Method = 'POST'
        $req.Timeout = 15000
        $req.ContentType = 'application/json'
        $req.Accept = 'application/json'
        $req.Headers.Add('Authorization', "Bearer $ACCESS_TOKEN")
        $req.Headers.Add('X-User-Id', $WB_UID)
        $body = [System.Text.Encoding]::UTF8.GetBytes('{}')
        $req.ContentLength = $body.Length
        $rs = $req.GetRequestStream()
        $rs.Write($body, 0, $body.Length)
        $rs.Close()
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
    }
    catch [System.Net.WebException] {
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } else { $code = 0 }
    }
    catch { $code = 0 }

    if ($code -eq 401) {
        Fail '凭据已被服务端拒绝（HTTP 401）。请确认桌面端处于登录状态（必要时退出重登）后重跑。'
    }
    if ($code -ne 200) {
        Warn "凭据校验未返回 200（HTTP=$code，可能是网络问题）。"
        Say  '  网络恢复后建议重跑本脚本再验证一次；继续生成分享文件也可，但请留意云端首次运行结果。'
    }
    else {
        Ok '[2/4] 凭据校验通过（HTTP 200）'
    }
}

if ($StatusOnly) {
    Say '      仅校验模式，未生成分享文件。'
    exit 0
}

# ------------------------------------------------------------------ 3) 加密
$KEY = ConvertTo-HexLower (Get-RandomBytes 32)

$nowUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$plainObj = [ordered]@{
    schema              = 2
    peer_slug           = $Name
    access_token        = $ACCESS_TOKEN
    uid                 = $WB_UID
    notify_webhook      = [string]$Notify
    token_rotated_at_ms = $ROTATED_AT
    token_expires_at_ms = $EXPIRES_AT
    synced_at_utc       = $nowUtc
}
$plainJson = $plainObj | ConvertTo-Json -Compress
$encBytes = Protect-OpenSslCompatible -PlainBytes ([System.Text.Encoding]::UTF8.GetBytes($plainJson)) -HexKey $KEY
Ok '[3/4] 已加密（AES-256-CBC / PBKDF2 20 万次）'
Say '      密钥仅存在于本次生成结果中，不会写入本机任何配置'

# ------------------------------------------------------------------ 4) 产出分享文件
$encB64 = [Convert]::ToBase64String($encBytes)

$stamp = (Get-Date).ToString('yyyyMMdd')
if (-not $Out) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop) { $desktop = $env:USERPROFILE }
    $Out = Join-Path $desktop "wb-checkin-$Name-$stamp.json"
}
$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { Fail "输出目录不存在：$outDir" }

if ($Split) {
    # 只把密文落文件，密钥单独显示
    Write-TextNoBom -Path $Out -Text ($encB64 + "`n")
    Say ''
    Ok '[4/4] 已生成「密文文件」：'
    Say "      $Out"
    Say ''
    Say  '      密钥（另一条渠道单独发给仓库主，别和文件走同一个渠道）：'
    Say "      $KEY"
    Say ''
    Warn '这串密钥只显示这一次，复制好再关窗口（本机不留副本）。'
}
else {
    $shareObj = [ordered]@{
        v              = '1'
        slug           = $Name
        key            = $KEY
        enc_b64        = $encB64
        created_at_utc = $nowUtc
    }
    $shareJson = ($shareObj | ConvertTo-Json -Compress)
    Write-TextNoBom -Path $Out -Text ($shareJson + "`n")
    Say ''
    Ok '[4/4] 已生成分享文件：'
    Say "      $Out"
}

if ($Print -and -not $Split) {
    Say ''
    Say '      —— 分享码（不想传文件的话，把下面一整行发过去）——'
    $fileBytes = [System.IO.File]::ReadAllBytes($Out)
    Say ([Convert]::ToBase64String($fileBytes))
}

Say ''
Say '接下来'
Say '  1. 把上面这个文件发给仓库主人（微信传文件即可）。'
Say '  2. 他导入后会更新仓库 Secret，之后你的账号就会跟着他的云端任务自动签到。'
if ($Notify) {
    Say '  3. 通知：已配置你自己的机器人（签到回执会直接发给你）。'
}
else {
    Say '  3. 通知：未配置。想要每日回执，重跑本脚本并加 -Notify ''你的机器人地址''。'
}
Say ''
Say '什么时候要重跑'
Say '  凭据约 55 天后过期；桌面端重新登录也可能让旧凭据失效。'
Say '  出现两种情况之一，重跑本脚本并把新文件发回去即可：'
Say '    · 你自己没再收到签到回执；'
Say '    · 仓库主告诉你「该账号凭据已失效」。'
Say ''
Say '安全提醒'
Say '  文件里含你的凭据密文（默认模式还含密钥），等同于把钥匙和箱子一起寄出。'
Say '  只发给你信任的仓库主；发送后建议删除本机这份：'
Say "    Remove-Item -LiteralPath '$Out'"
