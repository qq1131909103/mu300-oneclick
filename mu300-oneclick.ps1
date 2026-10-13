#Requires -Version 5.1
<#
    MU300 / U30 Air 一键刷入 Linux —— 中文引导启动器

    这个脚本本身不刷机：它检查环境、找 adb、确认设备状态，
    然后调用上游官方安装器 dikeckaan/mu300-linux 的 install.ps1 完成真正的工作。

    设计原则：任何一步卡住，都要明确告诉用户「现在该做什么」，绝不静默等待。

    用法：
        一键刷入.cmd                  # 交互式（推荐）
        一键刷入.cmd -CheckOnly       # 只看设备状态，不刷
        一键刷入.cmd -Auto            # 尽量少提问（仍需在官方安装器里输入 INSTALL）
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,     # 只做环境与设备自检，不启动安装器
    [switch]$Auto,          # 自动回答可以安全默认的问题
    [string]$Work = ''      # 上游仓库解压到哪里；空 = 本脚本同级目录下的 mu300-linux
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$OutputEncoding = [Text.Encoding]::UTF8

$Script:Top = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Script:LogFile = Join-Path $Script:Top ("一键刷入-日志-{0:yyyyMMdd-HHmmss}.txt" -f (Get-Date))
$Script:StepNo = 0
$Script:StepTotal = 6
$Script:RepoZip = 'https://github.com/dikeckaan/mu300-linux/archive/refs/heads/main.zip'
$Script:AdbUrl = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'
$Script:UpstreamRepo = 'dikeckaan/mu300-linux'

# ---------------------------------------------------------------- 输出

function Write-Log([string]$text) {
    try { Add-Content -LiteralPath $Script:LogFile -Value ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $text) -Encoding UTF8 } catch { }
}

function Line { param([string]$c = '') ; Write-Host $c ; Write-Log $c }

function Title([string]$text) {
    $Script:StepNo++
    Line ''
    Line ('=' * 64)
    $head = "[{0}/{1}] {2}" -f $Script:StepNo, $Script:StepTotal, $text
    Write-Host $head -ForegroundColor Cyan
    Line ('=' * 64)
    Write-Log $head
}

function Ok([string]$text)   { Write-Host "  ✓ $text" -ForegroundColor Green ; Write-Log "OK  $text" }
function Warn([string]$t)    { Write-Host "  ! $t" -ForegroundColor Yellow ; Write-Log "WARN $t" }
function Info([string]$text) { Write-Host "  · $text" -ForegroundColor Gray ; Write-Log "    $text" }

# 卡住时的统一提示块：说清「发生了什么」「现在该做什么」「做完怎么继续」
function Stuck {
    param(
        [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory)][string[]]$DoThis,
        [string[]]$OrElse,
        [switch]$Brief
    )
    if ($Brief) {
        Line ''
        Write-Host "  还是卡在：$What" -ForegroundColor Red
        Write-Host "    -> $($DoThis[0])" -ForegroundColor Yellow
        Write-Log "STUCK(brief): $What"
        Line ''
        return
    }
    Line ''
    Write-Host ('-' * 64) -ForegroundColor Red
    Write-Host "  卡住了：$What" -ForegroundColor Red
    Write-Host ('-' * 64) -ForegroundColor Red
    Write-Log "STUCK: $What"
    Line ''
    Write-Host '  请这样做：' -ForegroundColor Yellow
    $i = 0
    foreach ($s in $DoThis) { $i++; Write-Host "    $i) $s" -ForegroundColor Yellow ; Write-Log "   $i) $s" }
    if ($OrElse) {
        Line ''
        Write-Host '  如果还是不行：' -ForegroundColor DarkYellow
        foreach ($s in $OrElse) { Write-Host "    - $s" -ForegroundColor DarkYellow ; Write-Log "   - $s" }
    }
    Line ''
    Info "完整日志：$Script:LogFile"
    Line ''
}

function Pause-ForUser([string]$message = '处理完后按回车继续（输入 q 再回车 = 放弃退出）') {
    Write-Host ''
    Write-Host "  $message " -NoNewline -ForegroundColor Yellow
    $a = Read-Host
    if ($a -and $a.Trim().ToLower() -in @('q', 'quit', 'exit')) { Line '  已取消。'; exit 130 }
    return $a
}

# ---------------------------------------------------------------- 环境

function Test-Internet {
    try {
        $r = Invoke-WebRequest -Uri 'https://github.com' -Method Head -TimeoutSec 12 -UseBasicParsing
        return ($r.StatusCode -ge 200)
    } catch { return $false }
}

function Find-Adb {
    # 1) PATH
    $cmd = Get-Command adb -CommandType Application -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # 2) 常见位置 + 本仓库同级
    $dirs = @(
        $Script:Top,
        (Join-Path $Script:Top 'platform-tools'),
        (Join-Path (Get-Location).Path 'platform-tools')
    )
    if ($env:LOCALAPPDATA) { $dirs += (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools') }
    if ($env:USERPROFILE) {
        $dirs += @(
            (Join-Path $env:USERPROFILE 'platform-tools'),
            (Join-Path $env:USERPROFILE 'Downloads\platform-tools'),
            (Join-Path $env:USERPROFILE 'Desktop\platform-tools')
        )
    }
    $dirs += @('C:\platform-tools', 'C:\adb', 'C:\Android\platform-tools')
    foreach ($d in $dirs) {
        if ($d -and (Test-Path (Join-Path $d 'adb.exe'))) { return (Join-Path $d 'adb.exe') }
    }
    return $null
}

function Install-Adb {
    $dest = Join-Path $Script:Top 'platform-tools'
    $zip  = Join-Path $Script:Top 'platform-tools.zip'
    Info "从 Google 下载 Android Platform Tools（约 10 MB）…"
    try {
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Script:AdbUrl -OutFile $zip -TimeoutSec 300 -UseBasicParsing
        Info '下载完成，正在解压…'
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue }
        Expand-Archive -LiteralPath $zip -DestinationPath $Script:Top -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        $adb = Join-Path $dest 'adb.exe'
        if (Test-Path $adb) { Ok "adb 已装好：$adb" ; return $adb }
        return $null
    } catch {
        Warn "自动下载失败：$($_.Exception.Message)"
        return $null
    }
}

# ---------------------------------------------------------------- 设备

# 原生程序往 stderr 写的普通信息（adb 的 "daemon not running" 之类）在
# $ErrorActionPreference='Stop' 下会被 PowerShell 5.1 当成终止性错误抛出。
# 所有 adb 调用都走这里，临时把偏好降回 Continue。
function Invoke-Adb {
    param(
        [Parameter(Mandatory)][string]$Adb,
        [Parameter(Mandatory)][string[]]$AdbArgs
    )
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Adb @AdbArgs 2>&1
        $code = $LASTEXITCODE
        return [pscustomobject]@{ Output = @($out) ; ExitCode = $code }
    } finally {
        $ErrorActionPreference = $old
    }
}

function Get-AdbDevices {
    param([string]$Adb)
    $res = Invoke-Adb -Adb $Adb -AdbArgs @('devices')
    $out = $res.Output
    $list = @()
    foreach ($l in $out) {
        if ($l -match '^(\S+)\s+(device|unauthorized|offline|recovery|sideload)\s*$') {
            $list += [pscustomobject]@{ Serial = $Matches[1] ; State = $Matches[2] }
        }
    }
    return $list
}

function Test-LinuxRunning {
    foreach ($ip in @('192.168.78.1', '192.168.77.1')) {
        if (Test-NetConnection -ComputerName $ip -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue) {
            return $ip
        }
    }
    return $null
}

# ---------------------------------------------------------------- 上游仓库

function Get-Upstream {
    param([string]$Adb)

    if ($Work) { $target = $Work } else { $target = Join-Path $Script:Top 'mu300-linux' }

    $installPs1 = Join-Path $target 'install.ps1'
    if (Test-Path $installPs1) {
        Ok "官方安装器已存在：$installPs1"
        return $target
    }

    Info '首次运行，正在从 GitHub 获取官方安装器…'

    # 优先 git clone（之后能自更新）
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue
    if ($git) {
        try {
            Info "git clone https://github.com/$Script:UpstreamRepo …"
            & $git.Source clone --depth 1 "https://github.com/$Script:UpstreamRepo.git" $target 2>&1 | ForEach-Object { Write-Log $_ }
            if (Test-Path $installPs1) { Ok 'clone 完成' ; return $target }
        } catch { Warn "git clone 失败：$($_.Exception.Message)" }
    }

    # 退回 zip 下载
    $zip = Join-Path $Script:Top 'mu300-linux.zip'
    try {
        $ProgressPreference = 'SilentlyContinue'
        Info '正在下载 zip 包（约 5 MB）…'
        Invoke-WebRequest -Uri $Script:RepoZip -OutFile $zip -TimeoutSec 300 -UseBasicParsing
        $tmp = Join-Path $Script:Top '_unzip'
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
        if ($inner) {
            if (Test-Path $target) { Remove-Item $target -Recurse -Force -ErrorAction SilentlyContinue }
            Move-Item $inner.FullName $target
        }
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $installPs1) { Ok '下载并解压完成' ; return $target }
    } catch {
        Warn "zip 下载失败：$($_.Exception.Message)"
    }

    return $null
}

# ---------------------------------------------------------------- 主流程

Clear-Host
Write-Host ''
Write-Host '  ╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '  ║        MU300 / U30 Air  一键刷入 Linux                       ║' -ForegroundColor Cyan
Write-Host '  ║        OpenWrt 或 Ubuntu —— 中文引导                          ║' -ForegroundColor Cyan
Write-Host '  ╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
Line ''
Info "日志文件：$Script:LogFile"
Info "上游项目：https://github.com/$Script:UpstreamRepo"
Line ''
Warn '刷机有风险。请确认设备已 root 并解锁，且已用 USB 连接电脑。'
Line ''
Line '  准备好了就按回车开始（输入 q 再回车 = 退出）'
Write-Host '  > ' -NoNewline
$go = Read-Host
if ($go -and $go.Trim().ToLower() -in @('q', 'quit', 'exit')) { Line '  已退出。'; exit 0 }

# ---- 1 电脑环境
Title '检查电脑环境'
$psv = $PSVersionTable.PSVersion
Ok "PowerShell $psv"
$isAdmin = $false
try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
if ($isAdmin) { Info '以管理员身份运行（不必要，但没坏处）' } else { Info '普通权限运行（足够，无需管理员）' }

$net = Test-Internet
if ($net) { Ok '能访问 GitHub' }
else {
    Warn '连不上 GitHub'
    Stuck -What '电脑无法访问 github.com（安装器需要它下载镜像）' -DoThis @(
        '检查电脑的网络是否正常（浏览器能打开 github.com 吗？）',
        '如果用了代理/加速器，确认它是全局模式，或让 PowerShell 走代理',
        '公司网络/校园网可能屏蔽 GitHub，换手机热点试试'
    ) -OrElse @(
        '设置镜像源后重试：$env:MU300_RELEASE_URL="你的镜像"; .\一键刷入.cmd',
        '如果设备上已经有 Linux，也可以在设备上直接执行 mu300-update apply（不需要电脑）'
    )
    Pause-ForUser '网络恢复后按回车继续（q = 退出）' | Out-Null
}

# ---- 2 adb
Title '检查 adb（Android 调试工具）'
$adb = Find-Adb
if (-not $adb) {
    Warn '没找到 adb，尝试自动下载…'
    $adb = Install-Adb
}
if (-not $adb) {
    Stuck -What '电脑上没有 adb，自动下载也失败了' -DoThis @(
        '手机浏览器或电脑打开 https://developer.android.com/tools/releases/platform-tools',
        '下载 Windows 版，解压得到 platform-tools 文件夹',
        "把整个 platform-tools 文件夹放到这里：$Script:Top",
        '确认文件夹里有 adb.exe，然后重新双击 一键刷入.cmd'
    ) -OrElse @(
        '如果你会用 winget：winget install Google.PlatformTools',
        '如果已经装过 Android Studio，把它的 platform-tools 目录加进 PATH 也行'
    )
    Pause-ForUser '放好 platform-tools 后按回车重试（q = 退出）' | Out-Null
    $adb = Find-Adb
    if (-not $adb) { Line ''; Write-Host '  还是没找到 adb，退出。' -ForegroundColor Red ; exit 1 }
}
Ok "adb：$adb"
$ver = (Invoke-Adb -Adb $adb -AdbArgs @('version')).Output | Select-Object -First 1
Info $ver
$env:PATH = "$(Split-Path -Parent $adb);$env:PATH"

# ---- 3 设备连接
Title '检查设备连接'
$devices = Get-AdbDevices -Adb $adb
$attempt = 1
while ($devices.Count -eq 0 -and $attempt -le 3) {
    Warn "没有检测到设备（第 $attempt 次）"
    Stuck -Brief:($attempt -gt 1) -What '电脑通过 adb 看不到任何设备' -DoThis @(
        '换一根 USB 数据线——很多线只能充电不能传数据，这是最常见的原因',
        '换一个 USB 口，台式机优先插机箱背面的口',
        '看设备屏幕：是否弹出「允许 USB 调试？」→ 勾选「一律允许」并点确定',
        '设备上开启调试：设置 → 关于手机 → 连点「版本号」7 次 → 开发者选项 → 打开「USB 调试」',
        '把设备从电脑上拔下，等 5 秒再插上'
    ) -OrElse @(
        '重启设备再试',
        '在设备上执行 adb tcpip 5555（需要在设备上有终端），然后 adb connect 设备IP:5555',
        'Windows 设备管理器里看有没有带感叹号的 Android 设备，有就装驱动'
    )
    Pause-ForUser '处理好后按回车重新检测（q = 退出）' | Out-Null
    $devices = Get-AdbDevices -Adb $adb
    $attempt++
}
if ($devices.Count -eq 0) { Line ''; Write-Host '  始终没有设备，退出。' -ForegroundColor Red ; exit 1 }

$bad = $devices | Where-Object { $_.State -ne 'device' }
if ($bad) {
    foreach ($b in $bad) { Warn "设备 $($b.Serial) 状态是 $($b.State)" }
    if ($bad.State -contains 'unauthorized') {
        Stuck -What '设备未授权 adb 调试' -DoThis @(
            '看设备屏幕，应该有一个「允许 USB 调试吗？」的弹窗',
            '勾选「一律允许使用这台计算机进行调试」，然后点「允许」',
            '如果没看到弹窗：拔插一次数据线，或重启设备',
            '如果之前误点了「拒绝」：设备上 开发者选项 → 撤销 USB 调试授权，然后重新插'
        )
    } elseif ($bad.State -contains 'offline') {
        Stuck -What '设备处于 offline 状态' -DoThis @(
            '在电脑上执行：adb kill-server 然后 adb start-server',
            '拔插一次数据线',
            '重启设备'
        )
    } else {
        Stuck -What "设备状态异常（$($bad.State -join ', ')）" -DoThis @(
            '确认设备当前启动的是正常 Android，不是 recovery 模式',
            '重启设备再试'
        )
    }
    Pause-ForUser '处理好后按回车继续（q = 退出）' | Out-Null
    $devices = Get-AdbDevices -Adb $adb
    if (-not ($devices | Where-Object { $_.State -eq 'device' })) { Line ''; Write-Host '  设备仍不可用，退出。' -ForegroundColor Red ; exit 1 }
}
$serial = ($devices | Where-Object { $_.State -eq 'device' } | Select-Object -First 1).Serial
Ok "设备已连接：$serial"
$env:ANDROID_SERIAL = $serial

if ($devices.Count -gt 1) {
    Warn "检测到多台设备，将使用第一台：$serial"
    Info '如果不对，请拔掉其他设备后重跑，或设置环境变量 ANDROID_SERIAL 指定序列号'
}

# ---- 4 设备状态
Title '检查设备状态'
$model = ''
try { $model = ((Invoke-Adb -Adb $adb -AdbArgs @('-s', $serial, 'shell', 'getprop', 'ro.product.model')).Output | Out-String).Trim() } catch { }
$androidVer = ''
try { $androidVer = ((Invoke-Adb -Adb $adb -AdbArgs @('-s', $serial, 'shell', 'getprop', 'ro.build.version.release')).Output | Out-String).Trim() } catch { }
if ($model) { Info "型号：$model" }
if ($androidVer) { Info "Android 版本：$androidVer" }

# root 检查
$suOk = $false
try {
    $suOut = ((Invoke-Adb -Adb $adb -AdbArgs @('-s', $serial, 'shell', 'su -c id')).Output | Out-String)
    $suOk = ($suOut -match 'uid=0')
} catch { }
if ($suOk) { Ok '设备已 root（su 可用）' }
else {
    Warn 'su 不可用——设备可能没有 root'
    Stuck -What '设备似乎没有 root 权限' -DoThis @(
        '这个项目要求设备已经 root 并且解锁（能启动修改过的 Android boot 镜像）',
        '看设备上是否有 Magisk / KernelSU 之类的 root 管理器，打开并确认已授权',
        '在设备上执行 su，看是否弹出授权请求，选「允许」',
        '如果是全新设备从没 root 过：先去 root，这不在本项目范围内'
    ) -OrElse @(
        '有些设备需要在开发者选项里额外打开「OEM 解锁」和「USB 调试（安全设置）」',
        '确认你用的是原装线，部分第三方线会干扰 adb shell'
    )
    $c = Pause-ForUser '继续刷入可能失败。按回车仍要继续，输入 q 退出' 
    if ($c -and $c.Trim().ToLower() -in @('q', 'quit')) { Line '  已退出。'; exit 0 }
}

# Linux 正在运行？
$linuxIp = Test-LinuxRunning
if ($linuxIp) {
    Warn "设备当前运行的是 Linux（$linuxIp 有 SSH 响应）"
    Stuck -What '设备当前在 Linux 系统下，安装器需要它在 Android 下' -DoThis @(
        '官方安装器会问你「是否现在重启到 Android」，选 是 即可（需要设备的 Linux 密码）',
        '如果自动切换失败，手动切：用 SSH 连上设备后执行  mu300-next-boot android && reboot',
        "SSH 命令：ssh root@$linuxIp   （F50/MU300 则是 root@192.168.77.1）",
        '设备重启回 Android 后，重新双击 一键刷入.cmd'
    ) -OrElse @(
        '如果忘了 Linux 密码：设备开机约 10 秒后拔线，反复 5 次，设备会自己回退到 Android'
    )
    Pause-ForUser '设备回到 Android 后再按回车（q = 退出，先手动切）' | Out-Null
}

Ok '设备状态检查完成'

# ---- 5 获取并运行官方安装器
Title '获取官方安装器'
$repo = Get-Upstream -Adb $adb
if (-not $repo) {
    Stuck -What '无法获取官方安装器（GitHub 克隆和 zip 下载都失败了）' -DoThis @(
        '确认能打开 https://github.com/dikeckaan/mu300-linux',
        '手动下载：打开上面网址 → Code → Download ZIP → 解压',
        "把解压出的文件夹改名为 mu300-linux，放到这里：$Script:Top",
        '然后重新双击 一键刷入.cmd（脚本会自动认出来并跳过下载）'
    ) -OrElse @(
        '用代理后重试',
        'git clone https://github.com/dikeckaan/mu300-linux.git'
    )
    Pause-ForUser '准备好后按回车重试（q = 退出）' | Out-Null
    $repo = Get-Upstream -Adb $adb
    if (-not $repo) { Line ''; Write-Host '  仍无法获取，退出。' -ForegroundColor Red ; exit 1 }
}
$installPs1 = Join-Path $repo 'install.ps1'
Ok "官方安装器：$installPs1"

if ($CheckOnly) {
    Line ''
    Ok '仅自检模式：环境与设备都没问题，未启动安装。'
    Info '去掉 -CheckOnly 即可开始真实刷入。'
    Line ''
    exit 0
}

Title '启动官方安装器（从这里开始真正刷入）'
Line ''
Write-Host '  接下来是官方安装器的中文问答界面。' -ForegroundColor White
Write-Host '  提示：' -ForegroundColor White
Write-Host '    · 不确定选什么就一路回车（用作者推荐的默认值）' -ForegroundColor Gray
Write-Host '    · 装系统时推荐选 OpenWrt（带中文网页面板）' -ForegroundColor Gray
Write-Host '    · 内核推荐选 7.2' -ForegroundColor Gray
Write-Host '    · 最后会要求你手动输入大写 INSTALL 才会真的开始写盘' -ForegroundColor Yellow
Write-Host '    · 中途想放弃：Ctrl+C，此时还没写盘的话没有任何影响' -ForegroundColor Gray
Line ''
Write-Host '  按回车启动官方安装器…' -NoNewline
Read-Host | Out-Null

$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installPs1, '-Lang', 'zh')
Write-Log "运行：powershell $($argList -join ' ')"
Line ''
Line ('  执行：powershell ' + ($argList -join ' ')) 
Line ''

$exit = 0
try {
    & powershell @argList
    $exit = $LASTEXITCODE
} catch {
    $exit = 1
    Warn "安装器抛出异常：$($_.Exception.Message)"
}

# ---- 6 结果
Line ''
Line ('=' * 64)
if ($exit -eq 0) {
    Write-Host '  安装器正常结束' -ForegroundColor Green
    Line ('=' * 64)
    Line ''
    Write-Host '  接下来：' -ForegroundColor Cyan
    Write-Host '    1) 等约 1 分钟，设备会自行启动 Linux' -ForegroundColor White
    Write-Host '    2) 在插着设备的这台电脑上连接：' -ForegroundColor White
    Write-Host '         U30 Air ：ssh root@192.168.78.1   （或浏览器打开 http://192.168.78.1）' -ForegroundColor Gray
    Write-Host '         F50/MU300：ssh root@192.168.77.1  （或浏览器打开 http://192.168.77.1）' -ForegroundColor Gray
    Write-Host '       密码就是你刚才设置的那个' -ForegroundColor Gray
    Write-Host '    3) 设备自己会开 Wi-Fi 热点，名称密码是从 Android 拷过来的' -ForegroundColor White
    Line ''
    Write-Host '  设备没反应？' -ForegroundColor Yellow
    Write-Host '    · 等两分钟，再拔插一次 USB' -ForegroundColor Gray
    Write-Host '    · 连续 5 次启动失败设备会自动回退到 Android，不会变砖' -ForegroundColor Gray
    Write-Host '    · 收集日志：在官方安装器目录下执行 tools/collect-logs.sh' -ForegroundColor Gray
    Write-Host '    · 想还原：uninstall.cmd' -ForegroundColor Gray
} else {
    Write-Host "  安装器退出码：$exit（未完成或出错）" -ForegroundColor Red
    Line ('=' * 64)
    Line ''
    Write-Host '  常见的收尾办法：' -ForegroundColor Yellow
    Write-Host '    · 直接重新双击 一键刷入.cmd —— 支持断点续传，已下载的不会重下' -ForegroundColor Gray
    Write-Host '    · 如果是网络中断：挂代理，或设 MU300_RELEASE_URL 指向镜像' -ForegroundColor Gray
    Write-Host '    · 如果提示空间不足（32GB 版）：需要缩小 userdata，会清空 Android 数据，先备份' -ForegroundColor Gray
    Write-Host '    · 如果设备当前在 Linux 下：先 mu300-next-boot android && reboot' -ForegroundColor Gray
    Write-Host '    · 看官方故障排查：https://github.com/dikeckaan/mu300-linux#common-problems' -ForegroundColor Gray
}
Line ''
Info "本次日志：$Script:LogFile"
Line ''
Write-Host '  按回车关闭窗口…' -NoNewline
Read-Host | Out-Null
exit $exit
