<#
.SYNOPSIS
    将 FrostBlade.ps1 打包为单文件 exe。

.NOTES
    本版与上一版的关键差异（上一版"好像不正常"的根源排查结果）：
    1. [已修复] 上一版检测/安装的模块是 "PS2EXE.Core"（Fabien Tschanz 维护的年轻分支项目，
       GitHub 仅 26 星，最新 0.6.1）。它默认会按当前运行环境自动选择编译目标：在 PowerShell
       Core 下运行时会尝试走 .NET SDK 编译路径，产物是 .NET (Core) 运行时程序，这既需要
       本机装有 .NET SDK（多数只装了 Windows PowerShell 5.1 的机器上并没有），产物也不保证
       在 Win7 上能跑——跟 FrostBlade 明确要覆盖 Win7~11 的目标直接冲突。已改回业界标准的
       "ps2exe" 模块（Markus Scholtes 维护，当前 1.0.18，零依赖，用 .NET Framework 自带的
       csc.exe 编译，产物是传统 .NET Framework 程序，Win7~11 全覆盖，多年生产验证）。
    2. [已移除] 上一版还检测了一个 "ConvertTo-Exe" 命令作为备选——核实过，这个命令不存在于
       任何 ps2exe 相关模块，是网上某些 SEO 文章编造的语法。之前那部分是永远不会被命中的
       死代码，白白增加复杂度，一并删除。
    3. [已改进] 安装模块前显式将 PSGallery 设为受信任源，避免全新机器上第一次安装时因为
       "未知的存储库" 交互确认卡住无人值守场景。
    4. [已改进] 明确加上 -STA（FrostBlade 用 WinForms，单线程单元模型更稳妥）和 -x64
       （与 FrostBlade 里 SHFILEOPSTRUCT 的 x64 Pack=1 修复对应，避免误编译成 x86 目标）。
    5. [有意不加] 没有加 -requireAdmin。FrostBlade 自身已经有一套"检测当前是否管理员、
       非管理员则自举重启提权"的逻辑；-requireAdmin 会在 exe 清单里写死"必须管理员运行"，
       跟脚本自己的判断逻辑重复，且行为上不完全等价（清单方式是启动即弹 UAC，脚本自己的
       方式可以先做一些非提权前置判断再决定要不要提权）。如果你确认不需要这层自由度，
       可以自行加上 -requireAdmin 让 Windows 自动弹 UAC、可以去掉脚本里那段自举重启代码。
#>

# 1. 切换到脚本所在目录
#    [已改进] 优先用 $PSScriptRoot（PowerShell 3.0+ 恒定可用、不受调用方式影响），
#    $MyInvocation.MyCommand.Path 在某些调用方式下（比如整段脚本被当字符串传给
#    -Command 执行）会取不到值，仅作为兜底。
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ($ScriptDir) { Set-Location $ScriptDir }

Write-Host "当前目录: $(Get-Location)" -ForegroundColor Cyan

# 2. 确保执行策略（仅当前进程，不影响系统级设置）
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# 3. 定义输入输出文件
$InputFile  = "FrostBlade_V1.0.ps1"
$OutputFile = "FrostBlade_V1.0.exe"
$IconFile   = "frostblade.ico"

if (-not (Test-Path -LiteralPath $InputFile)) {
    Write-Error "找不到 $InputFile（当前目录: $(Get-Location)）"
    exit 1
}

# 4. 安装/加载打包模块：统一使用标准 "ps2exe" 模块
$Module = "ps2exe"
if (-not (Get-Module -ListAvailable -Name $Module)) {
    Write-Host "安装 $Module ..." -ForegroundColor Yellow
    try {
        # 全新机器上 PSGallery 可能还未被标记为受信任源，Install-Module 会弹交互确认，
        # 无人值守场景下会卡住；这里显式信任一次（只影响 PSGallery 这一个源）。
        $galleryReg = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
        if ($galleryReg -and $galleryReg.InstallationPolicy -ne "Trusted") {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
        }
    } catch {
        Write-Host "设置 PSGallery 信任状态失败（不影响后续流程，若安装卡住请手动确认）: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    Install-Module -Name $Module -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
}
Import-Module $Module -Force -ErrorAction Stop
Write-Host "已加载 $Module" -ForegroundColor Green

# 5. 确认打包命令存在（ps2exe 模块导出的命令固定是 Invoke-ps2exe，别名 ps2exe）
if (-not (Get-Command -Name "Invoke-ps2exe" -ErrorAction SilentlyContinue)) {
    Write-Error "找不到 Invoke-ps2exe 命令。请检查 $Module 模块是否正确安装（Get-Module -ListAvailable -Name $Module 确认版本）。"
    exit 1
}

# 6. 构建参数
#    以下参数名均对照 ps2exe 模块实际支持的参数核实过（Get-Help Invoke-ps2exe -Full 可自行复核）。
$Params = @{
    inputFile  = $InputFile
    outputFile = $OutputFile
    title      = "霜刃 FrostBlade"
    version    = "1.0.0.2"
    company    = "Lya.Wong"
    product    = "FrostBlade 磁盘清理工具"
    copyright  = "Copyright©2026"
    noConsole  = $true   # FrostBlade 是 WinForms 图形界面工具，不需要控制台窗口
    x64        = $true   # 对应 FrostBlade 里 SHFILEOPSTRUCT 的 x64 Pack=1 修复，固定编译为 64 位
    STA        = $true   # WinForms 要求单线程单元模型，显式声明避免依赖默认值
    Verbose    = $true   # 编译失败时能看到 csc.exe 的详细报错，便于定位问题
}

if (Test-Path -LiteralPath $IconFile) {
    $Params.iconFile = $IconFile
    Write-Host "使用图标: $IconFile" -ForegroundColor Cyan
} else {
    Write-Host "未找到图标文件 $IconFile，将使用默认图标（不影响功能）" -ForegroundColor Yellow
}

# 7. 执行打包
try {
    Write-Host "`n开始打包，请稍候..." -ForegroundColor Cyan
    Invoke-ps2exe @Params -ErrorAction Stop
    if (Test-Path -LiteralPath $OutputFile) {
        Write-Host "`n打包成功！生成文件: $OutputFile" -ForegroundColor Green
        $fileSize = (Get-Item -LiteralPath $OutputFile).Length / 1MB
        Write-Host "文件大小: $([math]::Round($fileSize, 2)) MB" -ForegroundColor Gray
    } else {
        Write-Error "打包命令执行完毕，但未生成目标文件。请检查上方 Verbose 输出中的编译错误。"
        exit 1
    }
} catch {
    Write-Error "打包失败: $($_.Exception.Message)"
    Write-Host "请仔细阅读上方的 Verbose 输出，以定位编译错误。" -ForegroundColor Yellow
    exit 1
}
