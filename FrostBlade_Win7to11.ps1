<#
.SYNOPSIS
    霜刃·垃圾清理工具 FrostBlade v1.0  定位：面向个人电脑用户的轻量级磁盘清理工具。清理项含较多启发式判断与不可逆操作，不建议在企业/生产环境中批量部署或无人值守运行，请自行评估风险后使用。
#>
param(
    [switch]$Silent = $false,
    # 以下参数仅在 -Silent 下生效，默认值均与 GUI 未勾选时的行为保持一致：
    [switch]$CreateRestorePoint = $false,   # 清理前自动创建系统还原点
    [switch]$ClosePrograms = $false,        # 清理前自动关闭占用进程
    [int]$RecycleBinMonths = 0,             # 回收站清理范围：0=全部清空；N(>0)=仅清理N个月前删除的项目
    [string]$LogFile = $null                # 运行日志追加写入到该文件，便于配合计划任务排查
)

# =====================================================================
# 0. 权限提升与全局配置
# =====================================================================
$ConfirmPreference = 'None'
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------
# 顶层异常兜底 (trap)：捕获主线程未被 try/catch 处理的终止性错误，避免用户看到裸露的报错栈。
# 命中后尽量落盘运行日志；静默模式打印错误并以退出码 1 退出，交互模式弹出统一风格的错误框。
# 注意：Runspace($ScanScriptBlock/$CleanScriptBlock) 内部异常已在各自 try/catch 中处理，
#       不会传导到这里；GUI 事件回调异常由下方 Application.ThreadException 单独兜底。
# ---------------------------------------------------------------------
function Save-FrostBladeCrashLog([string]$ErrorMessage, [string]$ScriptLine) {
    # 落盘动作本身也套一层 try，避免"想保存崩溃日志"这个动作自己又抛异常、把兜底逻辑也搞崩。
    try {
        $crashLines = New-Object System.Collections.Generic.List[string]
        [void]$crashLines.Add("霜刃 FrostBlade 崩溃日志")
        [void]$crashLines.Add("时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        [void]$crashLines.Add("错误: $ErrorMessage (脚本行号: $ScriptLine)")
        [void]$crashLines.Add("----- 运行日志（如有） -----")
        if ($Global:SyncHash -and $Global:SyncHash.FullLogHistory -and $Global:SyncHash.FullLogHistory.Count -gt 0) {
            foreach ($l in $Global:SyncHash.FullLogHistory) { [void]$crashLines.Add($l) }
        } else {
            [void]$crashLines.Add("(崩溃发生时尚未产生运行日志，或日志系统本身还未初始化)")
        }
        $crashPath = Join-Path $env:TEMP ("FrostBlade_崩溃日志_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt")
        [System.IO.File]::WriteAllLines($crashPath, $crashLines)
        return $crashPath
    } catch {
        return $null
    }
}

trap {
    $errMsg  = $_.Exception.Message
    $errLine = $_.InvocationInfo.ScriptLineNumber
    $crashPath = Save-FrostBladeCrashLog -ErrorMessage $errMsg -ScriptLine $errLine

    if ($Silent) {
        Write-Host "[FrostBlade][致命错误] $errMsg (行 $errLine)" -ForegroundColor Red
        if ($crashPath) { Write-Host "[FrostBlade] 已保存崩溃日志: $crashPath" -ForegroundColor Yellow }
        exit 1
    } else {
        try {
            $msg = "程序运行时发生未处理的错误，已尽量保存运行日志方便排查。`r`n`r`n错误信息: $errMsg`r`n(脚本行号: $errLine)"
            if ($crashPath) { $msg += "`r`n`r`n崩溃日志已保存到:`r`n$crashPath" }
            [System.Windows.Forms.MessageBox]::Show($msg, "霜刃 FrostBlade - 发生错误", "OK", "Error") | Out-Null
        } catch { }
        exit 1
    }
    break
}

# ---------------------------------------------------------------------
# WinForms 相关程序集需要在"提权/线程模型判断"之前就加载好：这样无论是下面的提权
# 失败提示框，还是 trap 里的崩溃提示框，才能保证在 Windows PowerShell 5.1 和
# PowerShell 7.x 下都稳定弹出（Windows PowerShell 对部分 GAC 程序集有隐式解析，
# 但 PowerShell 7 / .NET 没有这个机制，必须显式 Add-Type 才能让两边行为一致）。
# ---------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

# WinForms 事件回调异常兜底：按钮点击等消息循环回调不在 trap 覆盖范围内，需用
# ThreadException 机制接住，否则异常会被吞掉或导致界面卡死。须在 ShowDialog()/Run() 之前设置。
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($senderObj, $threadExArgs)
    $exMsg = $threadExArgs.Exception.Message
    $crashPath = Save-FrostBladeCrashLog -ErrorMessage $exMsg -ScriptLine "GUI事件回调(非主线程序号)"
    $msg = "界面操作时发生了一个未处理的错误，已尽量保存运行日志。`r`n`r`n错误信息: $exMsg"
    if ($crashPath) { $msg += "`r`n`r`n崩溃日志已保存到:`r`n$crashPath" }
    try { [System.Windows.Forms.MessageBox]::Show($msg, "霜刃 FrostBlade - 界面发生错误", "OK", "Error") | Out-Null } catch { }
})

# ---------------------------------------------------------------------
# 自举重启：管理员提权 + 必要时的 STA 线程模型修复
#
# 注意：以下分支按"当前宿主进程类型"（是不是 powershell.exe/pwsh.exe）区分，
# 不按操作系统版本区分——因为触发下面这些坑的根因跟 Windows 版本无关，跟"脚本是被
# 脚本引擎直接解释执行，还是已经被打包成独立 exe 后运行"这件事有关，Win7~11 都可能
# 遇到同一类问题，也都受益于同一套修复，不需要（也不应该）写 if(Win11) 这种分支。
#
# 旧版直接写死：
#   Start-Process powershell.exe -ArgumentList "... -File `"$scriptPath`"" -Verb RunAs
# 在某些环境下会被 ShellExecuteEx 报"参数错误"(Win32 错误 87)，常见成因：
#   1) "powershell.exe" 是裸文件名，交给系统按 PATH 搜索；一旦 PATH 缺失/异常就找不到目标；
#   2) $MyInvocation.MyCommand.Definition 在某些非"直接执行 .ps1 文件"的调用方式下(比如
#      脚本内容被当字符串通过管道/Invoke-Expression 执行)会退化成整段脚本源码而不是文件
#      路径，一旦真取到源码，塞进 -File 参数会把提权命令行拼成一坨畸形的超长字符串；
#   3) 在 Windows 11 上如果是用 PowerShell 7 (pwsh.exe) 启动的，硬编码 "powershell.exe"
#      会把提权后的进程错误地切回 Windows PowerShell 5.1，而不是保持在 pwsh 7。
# 这里改为：用当前进程的真实映像路径作为重启目标、用 $PSCommandPath 取脚本自身路径
# (PowerShell 3.0+ 专用变量，恒定返回文件路径，绝不会退化成源码文本)，提权前做路径有效性
# 检查，整个重启过程套 try/catch——即使失败也只弹出清晰指引，不再让脚本抛裸异常崩溃退出。
# ---------------------------------------------------------------------
function Get-FrostBladeHostExePath {
    # 优先取当前进程的真实可执行文件路径：无论是 powershell.exe 还是 pwsh.exe，
    # 也无论是否在 PATH 里，都能精确拿到，彻底绕开 ShellExecuteEx 的文件名搜索逻辑。
    try {
        $p = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p)) { return $p }
    } catch { }
    $exeName = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "powershell.exe" }
    try {
        $fallback = Join-Path $PSHOME $exeName
        if (Test-Path -LiteralPath $fallback) { return $fallback }
    } catch { }
    return $exeName
}

# 脚本自身路径：优先用 PS3.0+ 的 $PSCommandPath（恒定是路径，不会退化成源码文本），
# 拿不到时再依次退回旧的两种取法兜底。
$scriptPath = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($scriptPath)) { $scriptPath = $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($scriptPath)) { $scriptPath = $MyInvocation.MyCommand.Definition }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# PowerShell 7 (pwsh) 在部分宿主(如 VSCode 集成终端)下默认线程模型是 MTA，而 WinForms 必须
# 跑在 STA 下才能正常弹窗/使用剪贴板等功能；Windows PowerShell 5.1 恒为 STA，无需处理。
$needSTA = ($PSVersionTable.PSEdition -eq "Core") -and ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA)

if ((-not $isAdmin) -or $needSTA) {
    if ($Silent) {
        if (-not $isAdmin) { Write-Error "静默模式需要管理员权限。"; exit 1 }
        # 静默模式通常由已提权的计划任务/命令行调用，且不涉及界面交互，STA 与否不影响，此处不强制处理。
    } else {
        # ---------------------------------------------------------------
        # 关键修复：区分"当前是被 powershell.exe/pwsh.exe 解释执行的裸 .ps1"
        # 还是"当前就是一个打包好的独立 exe（如 ps2exe 编译产物）"。
        # 打包后的 exe 自身就是可执行宿主，不需要也不能再拼 "-File 脚本路径"
        # 这种参数——那是喂给 powershell.exe/pwsh.exe 解析脚本文件用的语法，
        # 独立 exe 根本不认识它，ShellExecuteEx 会报 Win32 错误 87（参数错误）。
        # 同时，独立 exe 场景下 $PSCommandPath 也经常是 $null 或指向临时解包
        # 路径而不是真正落地的 exe 文件，此前的 pathUsable 校验会因此提前失败，
        # 弹出"未能获取到脚本文件的有效完整路径"的提示——这正是打包后的现象。
        # ---------------------------------------------------------------
        $hostExe = Get-FrostBladeHostExePath
        $hostExeName = [System.IO.Path]::GetFileName($hostExe)
        $isScriptEngineHost = ($hostExeName -ieq "powershell.exe") -or ($hostExeName -ieq "pwsh.exe")

        if (-not $isScriptEngineHost) {
            # ------ 独立打包 exe 场景：直接把 exe 自己拉起来即可，不拼 -File 参数 ------
            try {
                if (-not $isAdmin) {
                    Start-Process -FilePath $hostExe -Verb RunAs -ErrorAction Stop
                } else {
                    Start-Process -FilePath $hostExe -ErrorAction Stop
                }
            } catch {
                $failMsg = "自动以管理员身份重启失败：$($_.Exception.Message)`r`n`r`n请手动关闭当前窗口，右键本程序，选择「以管理员身份运行」。"
                try { [System.Windows.Forms.MessageBox]::Show($failMsg, "霜刃 FrostBlade - 重启失败", "OK", "Error") | Out-Null } catch { Write-Host $failMsg }
                exit 1
            }
            exit
        }

        # ------ 裸 .ps1 由 powershell.exe/pwsh.exe 解释执行的场景：走原有 -File 重启逻辑 ------
        $pathUsable = (-not [string]::IsNullOrWhiteSpace($scriptPath)) -and (Test-Path -LiteralPath $scriptPath) -and ($scriptPath.Length -lt 1000)
        if (-not $pathUsable) {
            $warnMsg = "未能获取到脚本文件的有效完整路径，无法自动以管理员身份重启。`r`n`r`n请手动关闭当前窗口，右键本脚本文件，选择「以管理员身份运行」。"
            try { [System.Windows.Forms.MessageBox]::Show($warnMsg, "霜刃 FrostBlade - 需要管理员权限", "OK", "Warning") | Out-Null } catch { Write-Host $warnMsg }
            exit 1
        }
        try {
            $argParts = New-Object System.Collections.Generic.List[string]
            [void]$argParts.Add("-NoProfile")
            [void]$argParts.Add("-ExecutionPolicy Bypass")
            if ($needSTA) { [void]$argParts.Add("-STA") }
            [void]$argParts.Add("-File `"$scriptPath`"")
            $argStr = $argParts -join " "
            if (-not $isAdmin) {
                Start-Process -FilePath $hostExe -ArgumentList $argStr -Verb RunAs -ErrorAction Stop
            } else {
                # 已具备管理员权限，只是线程模型不对：同权限重启即可，不需要再弹一次 UAC。
                Start-Process -FilePath $hostExe -ArgumentList $argStr -ErrorAction Stop
            }
        } catch {
            $failMsg = "自动重启失败：$($_.Exception.Message)`r`n`r`n请手动关闭当前窗口，右键本脚本文件，选择「以管理员身份运行」。"
            try { [System.Windows.Forms.MessageBox]::Show($failMsg, "霜刃 FrostBlade - 重启失败", "OK", "Error") | Out-Null } catch { Write-Host $failMsg }
            exit 1
        }
        exit
    }
}

# =====================================================================
# 1. WinAPI 原生接口封装 (C# Add-Type，常驻内存，底层提速/抗权限报错)
#    提供：MoveFileEx(计划重启删除) / SHEmptyRecycleBin / SHQueryRecycleBin / 高速递归测目录大小
# =====================================================================
$Win32APICode = @"
using System;
using System.IO;
using System.Runtime.InteropServices;
public class FrostBladeWinAPI_v1 {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);
    
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SHEmptyRecycleBin(IntPtr hwnd, string pszRootPath, int dwFlags);

    public static long GetDirectorySizeFast(string folderPath) {
        long size = 0;
        try {
            DirectoryInfo di = new DirectoryInfo(folderPath);
            if (!di.Exists) return 0;
            try { foreach (FileInfo fi in di.GetFiles()) { size += fi.Length; } } catch { }
            try { foreach (DirectoryInfo subDi in di.GetDirectories()) { size += GetDirectorySizeFast(subDi.FullName); } } catch { }
        } catch { } 
        return size;
    }
    // --- 回收站大小查询 ---
[StructLayout(LayoutKind.Sequential)]
public struct SHQUERYRBINFO {
    public int cbSize;
    public long i64Size;
    public long i64NumItems;
}

[DllImport("shell32.dll", CharSet = CharSet.Unicode)]
public static extern int SHQueryRecycleBin(string pszRootPath, ref SHQUERYRBINFO pSHQueryRBInfo);

public static long GetRecycleBinTotalSize(string driveRoot) {
    SHQUERYRBINFO info = new SHQUERYRBINFO();
    info.cbSize = Marshal.SizeOf(info);
    int hr = SHQueryRecycleBin(driveRoot, ref info);
    return (hr == 0) ? info.i64Size : 0;
}

// --- 回收站"选择性清理"用的逐项静默强删（Remove-Item 失败时的兜底路径）---
// 只删除已在回收站里的项目，故不带 FOF_ALLOWUNDO（否则等于"再扔回收站一次"，删了等于没删）。
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto, Pack = 1)]
public struct SHFILEOPSTRUCT {
    public IntPtr hwnd;
    public int wFunc;
    public string pFrom;
    public string pTo;
    public short fFlags;
    public bool fAnyOperationsAborted;
    public IntPtr hNameMappings;
    public string lpszProgressTitle;
}

[DllImport("shell32.dll", CharSet = CharSet.Auto)]
public static extern int SHFileOperation(ref SHFILEOPSTRUCT FileOp);

const int FO_DELETE = 3;
const short FOF_SILENT = 4;             // 不显示进度条 UI
const short FOF_NOCONFIRMATION = 16;    // 不弹确认框（避免 -Silent/后台线程卡在等用户点是）
const short FOF_NOERRORUI = 1024;       // 出错不弹错误提示框

public static int SHFileOperationDeleteSilent(string path) {
    SHFILEOPSTRUCT fileOp = new SHFILEOPSTRUCT();
    fileOp.wFunc = FO_DELETE;
    // pFrom 必须是双重 null 结尾的字符串（哪怕只删一项也不例外），这是 SHFileOperation 的固定要求
    fileOp.pFrom = path + '\0' + '\0';
    fileOp.fFlags = (short)(FOF_SILENT | FOF_NOCONFIRMATION | FOF_NOERRORUI);
    return SHFileOperation(ref fileOp);
}
}
"@

if (-not ("FrostBladeWinAPI_v1" -as [type])) {
    Add-Type -TypeDefinition $Win32APICode -Language CSharp -ErrorAction Stop
}


# =====================================================================
# 2. 清理规则库与进程映射表 (纯数据，无逻辑；新增一条软件规则只需要改这里)
# =====================================================================
$Global:BuiltInRules = @{
    "SoftwareRules" = @(
        # --- 核心社交与办公 ---
        @{ ID="WeChat"; Paths=@("*\AppData\Roaming\Tencent\WeChat\XPlugin\Plugins\*\Cache", "*\Documents\WeChat Files\*\FileStorage\Cache", "*\Documents\WeChat Files\*\FileStorage\Temp", "*\Documents\xwechat_files\*\FileStorage\Cache", "*\Documents\xwechat_files\*\FileStorage\Temp") },
        @{ ID="TencentQQ"; Paths=@("*\AppData\Roaming\Tencent\QQ\Temp", "*\AppData\Roaming\Tencent\QQ\CrashDump", "*\AppData\Roaming\Tencent\QQ\*\AppData\file\cache") },
        @{ ID="TencentQQNT"; Paths=@("*\AppData\Roaming\Tencent\QQNT\Cache", "*\AppData\Roaming\Tencent\QQNT\Logs", "*\AppData\Roaming\Tencent\QQNT\historylog", "*\AppData\Local\Tencent\QQNT\Cache") },
        @{ ID="DingTalk"; Paths=@("*\AppData\Roaming\DingTalk\*\Cache", "*\AppData\Roaming\DingTalk\*\cef_cache") },
        @{ ID="WXWork"; Paths=@("*\Documents\WXWork\*\Cache", "*\Documents\WXWork\*\Temp") },
        @{ ID="Feishu"; Paths=@("*\AppData\Local\Feishu\*\Cache", "*\AppData\Local\Feishu\*\Code Cache") },
        @{ ID="TencentMeeting"; Paths=@("*\AppData\Local\Tencent\WeMeet\Cache", "*\AppData\Local\Tencent\WeMeet\Log") },
        @{ ID="MSTeamsClassic"; Paths=@("*\AppData\Roaming\Microsoft\Teams\Cache", "*\AppData\Roaming\Microsoft\Teams\Code Cache", "*\AppData\Roaming\Microsoft\Teams\GPUCache", "*\AppData\Roaming\Microsoft\Teams\blob_storage", "*\AppData\Roaming\Microsoft\Teams\Service Worker\CacheStorage") },
        @{ ID="MSTeamsNew"; Paths=@("*\AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Cache", "*\AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\Cache") },
        @{ ID="Slack"; Paths=@("*\AppData\Roaming\Slack\Cache", "*\AppData\Roaming\Slack\Code Cache", "*\AppData\Roaming\Slack\GPUCache", "*\AppData\Roaming\Slack\Service Worker\CacheStorage") },
        @{ ID="Zoom"; Paths=@("*\AppData\Roaming\Zoom\data\Cache", "*\AppData\Roaming\Zoom\logs") },
        @{ ID="iQiyi"; Paths=@("*\AppData\Local\IQIYI Video\LStyle\Cache", "*\AppData\Roaming\IQIYI Video\LStyle\Dump") },
        @{ ID="Bilibili"; Paths=@("*\AppData\Roaming\bilibili\Cache", "*\AppData\Roaming\bilibili\cef_cache", "*\AppData\Roaming\bilibili\logs") },
        @{ ID="TencentVideo"; Paths=@("*\AppData\Local\Tencent\TencentVideo\Download", "*\AppData\Local\Tencent\QQLive\*\Cache") },
        @{ ID="Youku"; Paths=@("*\AppData\Roaming\Youku\*\Cache", "*\AppData\Roaming\Youku\*\cef_cache", "*\AppData\Local\Youku\*\Cache") },
        @{ ID="Tudou"; Paths=@("*\AppData\Roaming\Tudou\*\Cache", "*\AppData\Roaming\Tudou\*\cef_cache") },
        @{ ID="NetEaseMusic"; Paths=@("*\AppData\Local\Netease\CloudMusic\Cache", "*\AppData\Local\Netease\CloudMusic\webdata\file\cache") },
        @{ ID="KuGou"; Paths=@("*\AppData\Roaming\Kugou*\Cache", "*\AppData\Roaming\Kugou*\Temp", "*\AppData\Roaming\Kugou*\cef_cache", "*\AppData\Local\Kugou*\Cache") },
        @{ ID="Kuwo"; Paths=@("*\AppData\Roaming\Kuwo*\Cache", "*\AppData\Roaming\Kuwo*\Temp", "*\AppData\Roaming\Kuwo*\cef_cache", "*\AppData\Local\Kuwo*\Cache") },
        @{ ID="Spotify"; Paths=@("*\AppData\Local\Spotify\Browser\Cache", "*\AppData\Local\Spotify\Storage") },
        @{ ID="Thunder"; Paths=@("C:\Users\Public\Thunder Network\*\Cache", "*\AppData\LocalLow\Thunder Network\*\Cache") },
        @{ ID="BaiduNetdisk"; Paths=@("*\AppData\Roaming\baidu\BaiduNetdisk\Cache", "*\AppData\Roaming\baidu\BaiduNetdisk\Crashpad\reports", "*\AppData\Roaming\baidu\BaiduNetdisk\logs") },
        @{ ID="Steam"; Paths=@("*\AppData\Local\Steam\htmlcache\Cache", "*\AppData\Local\Steam\htmlcache\Code Cache") },
        @{ ID="VSCode"; Paths=@("*\AppData\Roaming\Code\Cache", "*\AppData\Roaming\Code\CachedData", "*\AppData\Roaming\Code\Code Cache") },
        @{ ID="Discord"; Paths=@("*\AppData\Roaming\discord\Cache", "*\AppData\Roaming\discord\Code Cache") },
        @{ ID="WPS"; Paths=@("*\AppData\Local\Kingsoft\WPS Office\*\cache", "*\AppData\Roaming\kingsoft\wps\addons\cef\cache") }
    )
    "WeChatMediaPaths" = @(
        "*\Documents\WeChat Files\*\FileStorage\Video", "*\Documents\WeChat Files\*\FileStorage\Image", "*\Documents\WeChat Files\*\FileStorage\File", "*\Documents\WeChat Files\*\FileStorage\MsgAttach",
        "*\Documents\xwechat_files\*\FileStorage\Video", "*\Documents\xwechat_files\*\FileStorage\Image", "*\Documents\xwechat_files\*\FileStorage\File", "*\Documents\xwechat_files\*\FileStorage\MsgAttach"
    )
}

# --- 「清理前自动关闭占用进程」映射表：默认不启用，仅在对应扫描项被勾选清理时生效 ---
$Global:ProcessCloseMap = @{
    "BrowserCache"  = @("chrome", "msedge", "firefox", "opera", "opera_gx", "brave", "vivaldi",
                         "360se", "360chrome", "QQBrowser", "SogouExplorer", "Maxthon", "HuaweiBrowser")
    "SoftwareCache" = @("WeChat", "Weixin", "QQ", "TIM", "QQNT", "DingTalk", "WXWork", "Feishu",
                         "WeMeet", "Teams", "ms-teams", "Slack", "Zoom", "IQIYI", "bilibili", "QQLive",
                         "YoukuDesktop", "Tudou", "cloudmusic", "KuGou", "KuGou8", "Kuwo", "Spotify",
                         "Thunder", "baiduNetdisk", "Steam", "Code", "Discord", "wpsoffice", "wps", "et", "wpp")
    "WeChatMedia"   = @("WeChat", "Weixin", "WXWork")
}


# =====================================================================
# 3. 扫描清单与线程安全通信对象 (ScanItems / SyncHash)
# =====================================================================
$Global:ScanItems = @{
    # --- 第一梯队：安全必清 (零风险·自动重建·官方推荐默认勾选) ---
    "SystemTemp"         = @{ Name = "系统临时文件 (Temp/Prefetch)";          Checked = $true;  Size = 0; Paths = @() }
    "UserTemp"           = @{ Name = "用户临时文件";                          Checked = $true;  Size = 0; Paths = @() }
    "WinUpdate"          = @{ Name = "Windows Update 下载缓存";               Checked = $true;  Size = 0; Paths = @() }
    "DeliveryOpt"        = @{ Name = "传递优化缓存 (DeliveryOpt)";            Checked = $true;  Size = 0; Paths = @("$env:windir\SoftwareDistribution\DeliveryOptimization") }
    "BrowserCache"       = @{ Name = "浏览器缓存 (Chrome/Edge等)";            Checked = $true;  Size = 0; Paths = @() }
    "ThumbCache"         = @{ Name = "缩略图与图标缓存";                      Checked = $true;  Size = 0; Paths = @() }
    "D3DSCache"          = @{ Name = "显卡/DirectX 着色器缓存 (全用户,含N/A/Intel)"; Checked = $true;  Size = 0; Paths = @() }
    "FontCache"          = @{ Name = "系统字体缓存";                          Checked = $true;  Size = 0; Paths = @("$env:windir\ServiceProfiles\LocalService\AppData\Local\FontCache") }
    "MemoryDumps"        = @{ Name = "内存转储与崩溃缓存 (CrashDumps)";       Checked = $true;  Size = 0; Paths = @() }
    "DriverCache"        = @{ Name = "显卡驱动安装残留";                      Checked = $true;  Size = 0; Paths = @() }
    "AdobeCache"         = @{ Name = "Adobe 媒体与安装缓存";                  Checked = $true;  Size = 0; Paths = @() }
    "UWPAppCache"        = @{ Name = "Windows 应用临时文件 (UWP)";            Checked = $true;  Size = 0; Paths = @() }
    "SoftwareCache"      = @{ Name = "常用软件运行时缓存 (规则库)";           Checked = $true;  Size = 0; Paths = @() }
    "RecycleBin"         = @{ Name = "回收站 (所有用户)";                     Checked = $true;  Size = 0; Paths = @() }

    # --- 第二梯队：安全可选 (风险低，但作用场景较窄或有轻微副作用，按需勾选) ---
    "RegUninstall"       = @{ Name = "注册表失效卸载项清理";                  Checked = $true;  Size = 0; Paths = @() }
    "Prefetch"           = @{ Name = "系统预读取文件 (Prefetch)";             Checked = $false; Size = 0; Paths = @("$env:windir\Prefetch") }
    "WinDiagLogs"        = @{ Name = "Windows 系统诊断日志 (Windows\Logs，含CBS/DISM/更新日志，故障排查可能需要保留)"; Checked = $false; Size = 0; Paths = @() }
    "WERFiles"           = @{ Name = "Windows 错误报告存档 (WER)";            Checked = $false; Size = 0; Paths = @("$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue") }
    "PrintSpool"         = @{ Name = "打印机后台池队列";                      Checked = $false; Size = 0; Paths = @("$env:windir\System32\spool\PRINTERS") }
    "SearchIndex"        = @{ Name = "Windows 搜索索引文件";                  Checked = $false; Size = 0; Paths = @("$env:ProgramData\Microsoft\Search\Data\Applications\Windows") }
    "AspTemp"            = @{ Name = "ASP.NET 临时编译文件";                  Checked = $false; Size = 0; Paths = @("$env:windir\Microsoft.NET\Framework\v4.0.30319\Temporary ASP.NET Files", "$env:windir\Microsoft.NET\Framework64\v4.0.30319\Temporary ASP.NET Files", "$env:windir\Microsoft.NET\Framework\v2.0.50727\Temporary ASP.NET Files", "$env:windir\Microsoft.NET\Framework64\v2.0.50727\Temporary ASP.NET Files") }
    "WindowsUpgradeLogs" = @{ Name = "系统更新隐藏缓存 (~BT/~WS)";            Checked = $false; Size = 0; Paths = @("$env:SystemDrive\`$WINDOWS.~BT", "$env:SystemDrive\`$Windows.~WS") }
    "WinSxSClean"        = @{ Name = "WinSxS 组件存储清理 (DISM /StartComponentCleanup)"; Checked = $false; Size = 0; Paths = @() }

    # --- 第三梯队：高危项 (按"影响可逆程度→是否波及用户个人数据→是否不可逆"递增排列，需谨慎勾选) ---
    "CompactOS"          = @{ Name = "Compact OS 系统压缩 (省 2-4GB，可逆·可用下方按钮还原，机械硬盘慎用)"; Checked = $false; Size = 0; Paths = @() }
    "HibernateFile"      = @{ Name = "休眠文件 hiberfil.sys (关闭后失去快速启动/休眠功能)"; Checked = $false; Size = 0; Paths = @() }
    "EventLogs"          = @{ Name = "Windows 事件日志 (清空·wevtutil·磁盘空间变化极小)"; Checked = $false; Size = 0; Paths = @() }
    "ResidualAppDirs"      = @{ Name = "已卸载软件残留目录 (智能识别·启发式·可能误判绿色软件)"; Checked = $false; Size = 0; Paths = @() }
    "EmptyFolders"       = @{ Name = "深度空壳收割 (高危需谨慎)";              Checked = $false; Size = 0; Paths = @() }
    "QQChatImages"       = @{ Name = "QQ 聊天图片/自定义头像 (Image/CustomFace，用户可见聊天内容，非纯缓存)"; Checked = $false; Size = 0; Paths = @() }
    "WeChatMedia"        = @{ Name = "微信媒体文件 (深度排查 - 高危)";        Checked = $false; Size = 0; Paths = @() }
    "WindowsOld"         = @{ Name = "旧版系统备份 (Windows.old)";            Checked = $false; Size = 0; Paths = @("$env:SystemDrive\Windows.old") }
    "VSSShadow"          = @{ Name = "系统还原点与卷影复制 (高危)";           Checked = $false; Size = 0; Paths = @() }
    "WinSxSResetBase"    = @{ Name = "WinSxS 深度压缩 /ResetBase (高危·不可逆·清后无法回滚更新)"; Checked = $false; Size = 0; Paths = @() }
}

# Stale：$true 表示"该项尚未在勾选状态下被完整扫描过一次"。防止用户扫描完成后才勾选某项、
# 未重新扫描就直接清理导致 Paths 为空、静默跳过却让用户误以为已处理。勾选框变更（Add_CheckedChanged）
# 会置为 Stale，只有该项在勾选状态下跑完一次扫描才会被扫描引擎清掉。
foreach ($k in $Global:ScanItems.Keys) { $Global:ScanItems[$k].Stale = $true }

# 顺序按"必要性从高到低、风险从低到高"排列，与上方 ScanItems 三梯队定义一致，
# 使 GUI 勾选框列表自上而下呈现"越靠上越该清、越靠下越要谨慎"。
$KeyList = @(
    # 第一梯队：安全必清
    "SystemTemp", "UserTemp", "WinUpdate", "DeliveryOpt", "BrowserCache", "ThumbCache", "D3DSCache",
    "FontCache", "MemoryDumps", "DriverCache", "AdobeCache", "UWPAppCache", "SoftwareCache", "RecycleBin",
    # 第二梯队：安全可选
    "RegUninstall", "Prefetch", "WinDiagLogs", "WERFiles", "PrintSpool", "SearchIndex", "AspTemp",
    "WindowsUpgradeLogs", "WinSxSClean",
    # 第三梯队：高危项（谨慎程度递增）
    "CompactOS", "HibernateFile", "EventLogs", "ResidualAppDirs", "EmptyFolders",
    "QQChatImages", "WeChatMedia", "WindowsOld", "VSSShadow", "WinSxSResetBase"
)

# 高危/需人工复核项统一清单：红色标记 + "全选"跳过 + 是否需要清理前预览确认，三处共用，避免各处硬编码不同步。
$Global:HighRiskKeys = @("WeChatMedia", "QQChatImages", "VSSShadow", "WindowsOld", "EmptyFolders", "EventLogs",
                          "WinSxSResetBase", "HibernateFile", "CompactOS", "ResidualAppDirs")
# 删除前需逐项勾选预览确认的项（启发式判定、误判代价较高）
$Global:PreviewRequiredKeys = @("ResidualAppDirs", "RegUninstall")

$Global:SyncHash = [hashtable]::Synchronized(@{})
$Global:SyncHash.LogQueue = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$Global:SyncHash.FullLogHistory = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$Global:SyncHash.Progress = 0
$Global:SyncHash.IsRunning = $false
$Global:SyncHash.CancelRequested = $false
$Global:SyncHash.ScanItems = $Global:ScanItems
$Global:SyncHash.SystemDrive = $env:SystemDrive
$Global:SyncHash.BuiltInRules = $Global:BuiltInRules
# 残留目录逐项详情（路径+大小+最后写入时间），供清理前预览界面使用（ScanItems.Paths 仅为字符串数组，不带大小）
$Global:SyncHash.ResidualDetails = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
# 注册表失效卸载项详情（显示名/注册表路径/安装路径），供清理前预览界面使用：
# InstallLocation 为空、或路径暂时不可达（如 USB/网络驱动器离线）都可能被误判为"失效"，需用户逐项确认。
$Global:SyncHash.RegUninstallDetails = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
# "自动创建还原点"与"VSSShadow清理"冲突时，用户选择"仅本次跳过卷影清理"会置为 $true；
# 不修改 ScanItems.VSSShadow.Checked 本身，避免影响下次运行的勾选状态。
$Global:SyncHash.SkipVSSThisRun = $false
# 回收站清理范围：0=全部清空（默认，向后兼容）；N(>0)=仅清理 N 个月前删除的项目
$Global:SyncHash.RecycleBinMonths = 0

function Get-FixedDriveLetters {
    # 主线程版三轨降级（$ScanScriptBlock 内部还有一份给独立 Runspace 用的同款函数，互不共享，必须各定义一份）
    $list = New-Object System.Collections.Generic.List[string]
    try {
        if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
            Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop | ForEach-Object { [void]$list.Add($_.DeviceID) }
        } else {
            Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop | ForEach-Object { [void]$list.Add($_.DeviceID) }
        }
    } catch {
        try {
            [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq "Fixed" -and $_.IsReady } | ForEach-Object { [void]$list.Add($_.Name.TrimEnd('\')) }
        } catch { }
    }
    return @($list | Select-Object -Unique)
}


# =====================================================================
# 4. 大文件扫描引擎 (独立功能：全盘按体积扫描，命中后由用户手动勾选删除，不在常规清理项里)
# =====================================================================
$Global:LFSync = [hashtable]::Synchronized(@{})
$Global:LFSync.IsRunning = $false
$Global:LFSync.CancelRequested = $false
$Global:LFSync.StatusMsg = ""
$Global:LFSync.Results = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

$LargeFileScanBlock = {
    param($Sync, $MinSizeBytes, $ExcludeSystemDirs, $Drives)

    $Sync.Results.Clear()
    $Sync.IsRunning = $true
    $Sync.CancelRequested = $false
    $scanned = 0

    # [安全] 默认跳过系统关键目录
    $excludePrefixes = New-Object System.Collections.Generic.List[string]
    if ($ExcludeSystemDirs) {
        # 防御：检查 SystemRoot 是否为空
        if ([string]::IsNullOrEmpty($env:SystemRoot)) {
            Write-Warning "SystemRoot 环境变量为空，系统目录排除无效。"
        } else {
            [void]$excludePrefixes.Add($env:SystemRoot.ToUpper())
        }
        foreach ($drv in $Drives) {
            [void]$excludePrefixes.Add(("$drv\SYSTEM VOLUME INFORMATION").ToUpper())
            [void]$excludePrefixes.Add(("$drv\$RECYCLE.BIN").ToUpper())
        }
        # 输出调试信息（可视作状态更新）
        $Sync.StatusMsg = "排除前缀: $($excludePrefixes -join ', ')"
    }

    foreach ($root in $Drives) {
        if ($Sync.CancelRequested) { break }
        # 使用显式栈做深度优先遍历，兼容 PS2.0 (使用 GetFileSystemEntries)
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push("$root\")
        while ($stack.Count -gt 0) {
            if ($Sync.CancelRequested) { break }
            $dir = $stack.Pop()
            $dirUpper = $dir.ToUpper()
            $skip = $false
            foreach ($ex in $excludePrefixes) {
                if ($dirUpper.StartsWith($ex)) { $skip = $true; break }
            }
            if ($skip) { continue }
            try {
                # 使用 GetFileSystemEntries 兼容 .NET 3.5
                foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($dir)) {
                    try {
                        $attr = [System.IO.File]::GetAttributes($entry)
                        # 跳过重分析点（符号链接/挂载点/OneDrive占位符等）
                        if ($attr -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                        if ($attr -band [System.IO.FileAttributes]::Directory) {
                            [void]$stack.Push($entry)
                        } else {
                            $len = (New-Object System.IO.FileInfo($entry)).Length
                            $scanned++
                            if ($len -ge $MinSizeBytes) {
                                [void]$Sync.Results.Add(@{ Path = $entry; Size = $len })
                            }
                            if (($scanned % 3000) -eq 0) {
                                $Sync.StatusMsg = "已扫描 $scanned 个文件，命中 $($Sync.Results.Count) 个大文件... 当前: $dir"
                            }
                        }
                    } catch { }
                }
            } catch { }
        }
    }

    $Sync.StatusMsg = if ($Sync.CancelRequested) { "扫描已取消，目前已找到 $($Sync.Results.Count) 个大文件。" } else { "扫描完成！共找到 $($Sync.Results.Count) 个大文件。" }
    $Sync.IsRunning = $false
}


# =====================================================================
# 5. 异步后台扫描引擎 (ScriptBlock，运行于独立 Runspace)
#    遍历第 3 节中勾选的扫描项，计算体积、收集路径，写入 SyncHash。
#    注意：Runspace 不继承父作用域函数表，Get-FixedDriveLetters 在本文件中共有两份独立副本
#    （主线程版见第 3 节 334 行；本 Runspace 内的版本见下方，供本脚本块内所有小节共用，
#    包括空文件夹扫描等小节——它们与本函数同处一个 Runspace 作用域，无需再各自定义一份）。
#    修复其 bug 时两处都要同步。
# =====================================================================
$ScanScriptBlock = {
    param($Sync)

    function Write-AsyncLog([string]$msg) {
        $timestamp = Get-Date -Format "HH:mm:ss"
        $line = "[$timestamp] $msg"
        [void]$Sync.LogQueue.Add($line)
        [void]$Sync.FullLogHistory.Add($line)
    }
    function Get-FolderSize([string]$p) { return [FrostBladeWinAPI_v1]::GetDirectorySizeFast($p) }
    function Get-FixedDriveLetters {
        # 三轨降级获取固定磁盘列表
        $list = New-Object System.Collections.Generic.List[string]
        try {
            if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
                Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop | ForEach-Object { [void]$list.Add($_.DeviceID) }
            } else {
                Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop | ForEach-Object { [void]$list.Add($_.DeviceID) }
            }
        } catch {
            try {
                [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq "Fixed" -and $_.IsReady } | ForEach-Object { [void]$list.Add($_.Name.TrimEnd('\')) }
            } catch { }
        }
        return @($list | Select-Object -Unique)
    }

    Write-AsyncLog ">>> 后台深度扫描引擎启动 (Zero I/O) <<<"
    $Sync.Progress = 2

    # 本轮扫描开始时，把当前勾选状态的项统一清掉 Stale 标记，即使结果为 0（如浏览器缓存本就是空的）
    # 也能与"从未扫描过"区分开——后者会在点击"执行深度清理"时被拦下提醒。
    [System.Threading.Monitor]::Enter($Sync)
    try {
        foreach ($k in $Sync.ScanItems.Keys) {
            if ($Sync.ScanItems[$k].Checked) { $Sync.ScanItems[$k].Stale = $false }
        }
    } finally { [System.Threading.Monitor]::Exit($Sync) }

    $usersRoot = "$($Sync.SystemDrive)\Users"
    # 过滤掉非真实用户档案目录：Public/Default/Default User 是系统模板/公共目录，不含真实用户的
    # AppData 缓存；"All Users" 在新版 Windows 下是指向 $env:ProgramData 的联接点(Junction)，不过滤的话
    # 会把 ProgramData 错当成"某个用户目录"重复拼一遍路径去探测，属于无意义的重复 Test-Path。
    # -notcontains 是 PowerShell 1.0/2.0 就有的运算符（区别于 PS3.0+ 才有的 -notin），沿用与全文
    # 一致的 PS2.0 兼容写法。外层套 @() 是必须的：Where-Object 管道只筛出 0/1 个结果时 PowerShell 会
    # 自动"拆包"成单个字符串而不是数组，届时下方 $userDirs[0] 会变成对字符串取第 1 个字符，
    # 而不是取第 1 个用户目录路径，导致 3.1/3.2 节里"绝对路径只在第一个用户目录下处理一次"的
    # 去重逻辑失效（会给每个用户目录重复扫描一遍系统级绝对路径）。@() 强制结果始终是数组，避免这个坑。
    $excludedUserDirNames = @("Public", "Default", "Default User", "All Users")
    if (Test-Path -LiteralPath $usersRoot) {
        $userDirs = @([System.IO.Directory]::GetDirectories($usersRoot) | Where-Object {
            $dirName = [System.IO.Path]::GetFileName($_)
            $isJunction = $false
            try { $isJunction = ([System.IO.File]::GetAttributes($_) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } catch { }
            (-not $isJunction) -and ($excludedUserDirNames -notcontains $dirName)
        })
    } else {
        # 正常 Windows 系统上 Users 目录必然存在；这里兜底是为了防止极少数非常规部署（用户目录被
        # 迁移、SystemDrive 判断有误等）导致 GetDirectories 抛出未捕获异常、扫描 Runspace 提前终止——
        # 那样会使 $Sync.IsRunning 永远停留在 $true（复位语句在脚本最末尾，走不到），GUI 侧表现为
        # 卡在"扫描中"且没有任何报错提示，比直接报错更难排查。这里改为跳过按用户扫描的项目、
        # 记录一行日志，让其余与用户目录无关的项（各盘 WinSxS、回收站等）能继续正常扫描完成。
        Write-AsyncLog "  -> [警告] 未找到用户目录 $usersRoot，本次跳过所有按用户扫描的项目（浏览器缓存/微信缓存等）"
        $userDirs = @()
    }
    
    [System.Threading.Monitor]::Enter($Sync)
    try {
        $staticPaths = @("DeliveryOpt", "FontCache", "Prefetch", "AspTemp", "PrintSpool", "SearchIndex", "WindowsOld", "WindowsUpgradeLogs")
        foreach ($k in $Sync.ScanItems.Keys) {
            $Sync.ScanItems[$k].Size = 0
            if ($staticPaths -contains $k) { continue } 
            $Sync.ScanItems[$k].Paths = @()
        }
        $Sync.ResidualDetails.Clear()
        $Sync.RegUninstallDetails.Clear()
    } finally { [System.Threading.Monitor]::Exit($Sync) }

    # --- 1. 系统与用户临时 ---
    if ($Sync.ScanItems["SystemTemp"].Checked -or $Sync.ScanItems["UserTemp"].Checked) {
        Write-AsyncLog "[扫描] 系统与用户临时文件..."
        [System.Threading.Monitor]::Enter($Sync)
        try {
            if ($Sync.ScanItems["SystemTemp"].Checked) {
                $Sync.ScanItems["SystemTemp"].Paths = @("$env:SystemRoot\Temp")
                $Sync.ScanItems["SystemTemp"].Size = Get-FolderSize $Sync.ScanItems["SystemTemp"].Paths[0]
            }
            if ($Sync.ScanItems["UserTemp"].Checked) {
                $userTempPaths = New-Object System.Collections.Generic.List[string]
                [void]$userTempPaths.Add($env:TEMP)
                foreach ($d in $userDirs) {
                    $tp = "$d\AppData\Local\Temp"
                    if (Test-Path $tp) { [void]$userTempPaths.Add($tp) }
                }
                $Sync.ScanItems["UserTemp"].Paths = $userTempPaths | Select-Object -Unique
                [long]$uSize = 0; foreach ($p in $Sync.ScanItems["UserTemp"].Paths) { $uSize += Get-FolderSize $p }
                $Sync.ScanItems["UserTemp"].Size = $uSize
            }
        } finally { [System.Threading.Monitor]::Exit($Sync) }
    }
    $Sync.Progress = 15

    # --- 2. 浏览器缓存 ---
    if ($Sync.ScanItems["BrowserCache"].Checked) {
        Write-AsyncLog "[扫描] 多用户浏览器缓存..."
        $browserPaths = New-Object System.Collections.Generic.List[string]
        $browserDefs = @(
            @{Dir="Google\Chrome\User Data"; Cache="Cache\Cache_Data"; Code="Code Cache"; Roaming=$false},
            @{Dir="Microsoft\Edge\User Data"; Cache="Cache\Cache_Data"; Code="Code Cache"; Roaming=$false},
            @{Dir="Opera Software\Opera Stable"; Cache="Cache\Cache_Data"; Code="Code Cache"; Roaming=$true},
            @{Dir="Opera Software\Opera GX Stable"; Cache="Cache\Cache_Data"; Code="Code Cache"; Roaming=$true},
            @{Dir="BraveSoftware\Brave-Browser\User Data"; Cache="Cache\Cache_Data"; Code="Code Cache"; Roaming=$false},
            @{Dir="Vivaldi\User Data"; Cache="Cache\Cache_Data"; Code="Code Cache"; Roaming=$false},
            @{Dir="360Chrome\Chrome\User Data"; Cache="Cache\Cache_Data"; Code="Code Cache"; Roaming=$false},
            @{Dir="360se6\User Data"; Cache="Cache\Cache_Data"; Code="Code Cache"; Roaming=$true},
            @{Dir="Tencent\QQBrowser\User Data"; Cache="Cache\Cache_Data"; Code="Code Cache"; Roaming=$false},
            @{Dir="SogouExplorer\User Data"; Cache="Cache\Cache_Data"; Code="Code Cache"; Roaming=$false},
            @{Dir="Sogou\SogouExplorer\User Data"; Cache="Cache\Cache_Data"; Code="Code Cache"; Roaming=$false},
            @{Dir="Maxthon\User Data"; Cache="Cache\Cache_Data"; Code="Code Cache"; Roaming=$false},
            @{Dir="Huawei\HuaweiBrowser\User Data"; Cache="Cache\Cache_Data"; Code="Code Cache"; Roaming=$false},
            @{Dir="Mozilla\Firefox\Profiles"; Cache="cache2"; Code=""; Roaming=$true}
        )
        foreach ($userDir in $userDirs) {
            if ($Sync.CancelRequested) { break }
            $local = "$userDir\AppData\Local"; $roaming = "$userDir\AppData\Roaming"
            foreach ($b in $browserDefs) {
                $basePath = if ($b.Roaming) { $roaming } else { $local }
                $dataDir = "$basePath\$($b.Dir)"
                if (-not (Test-Path $dataDir)) { continue }
                if ($b.Dir -like "Mozilla*") {
                    foreach ($pd in [System.IO.Directory]::GetDirectories($dataDir)) { 
                        [void]$browserPaths.Add("$pd\cache2"); [void]$browserPaths.Add("$pd\storage\default"); [void]$browserPaths.Add("$pd\thumbnails") 
                    }
                } else {
                    [void]$browserPaths.Add("$dataDir\Default\$($b.Cache)"); [void]$browserPaths.Add("$dataDir\Default\$($b.Code)")
                    [void]$browserPaths.Add("$dataDir\Default\GPUCache"); [void]$browserPaths.Add("$dataDir\Default\Service Worker\CacheStorage")
                    Get-ChildItem -LiteralPath $dataDir -Force -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer -and $_.Name -match "Profile " } | ForEach-Object {
                        [void]$browserPaths.Add("$($_.FullName)\$($b.Cache)"); [void]$browserPaths.Add("$($_.FullName)\$($b.Code)")
                        [void]$browserPaths.Add("$($_.FullName)\GPUCache"); [void]$browserPaths.Add("$($_.FullName)\Service Worker\CacheStorage")
                    }
                }
            }
            $inetCache = "$local\Microsoft\Windows\INetCache"
            if (Test-Path $inetCache) { [void]$browserPaths.Add($inetCache) }
        }
        [System.Threading.Monitor]::Enter($Sync)
        try {
            $Sync.ScanItems["BrowserCache"].Paths = $browserPaths | Where-Object { Test-Path $_ } | Select-Object -Unique
            [long]$bSize = 0; foreach ($p in $Sync.ScanItems["BrowserCache"].Paths) { $bSize += Get-FolderSize $p }
            $Sync.ScanItems["BrowserCache"].Size = $bSize
        } finally { [System.Threading.Monitor]::Exit($Sync) }
    }
    $Sync.Progress = 30

    # --- 3. 内置规则/软件缓存 (融合微信/QQ/钉钉动态雷达) ---
    if ($Sync.ScanItems["SoftwareCache"].Checked) {
        Write-AsyncLog "[扫描] 应用内部缓存规则分析与动态雷达探测..."
        $softPathsList = New-Object System.Collections.Generic.List[string]

        # ==== 微信缓存路径动态发现（三轨：注册表 + 配置文件 + 全盘物理探测）====
        $wxCacheBaseDirs = New-Object System.Collections.Generic.List[string]
        [void]$wxCacheBaseDirs.Add("*\Documents\WeChat Files")
        [void]$wxCacheBaseDirs.Add("*\Documents\xwechat_files")
        try {
            Get-ChildItem "Registry::HKEY_USERS" -ErrorAction SilentlyContinue |
              Where-Object { $_.PSChildName -match "^S-1-5-21-\d+-\d+-\d+-\d+$" } | ForEach-Object {
                $wxReg2 = "Registry::HKEY_USERS\$($_.PSChildName)\Software\Tencent\WeChat"
                if (Test-Path -LiteralPath $wxReg2 -ErrorAction SilentlyContinue) {
                    $wxPath2 = (Get-ItemProperty $wxReg2 -Name "FileSavePath" -ErrorAction SilentlyContinue).FileSavePath
                    if ($wxPath2 -and $wxPath2 -ne "MyDocument:" -and $wxPath2 -match "^[a-zA-Z]:\\") {
                        [void]$wxCacheBaseDirs.Add(($wxPath2.TrimEnd('\') + "\WeChat Files"))
                        [void]$wxCacheBaseDirs.Add(($wxPath2.TrimEnd('\') + "\xwechat_files"))
                    }
                }
            }
        } catch { }
        foreach ($userDir in $userDirs) {
            $wxCfg = "$userDir\AppData\Roaming\Tencent\WeChat\All Users\config"
            if (Test-Path -LiteralPath $wxCfg) {
                try {
                    Get-ChildItem -LiteralPath $wxCfg -Filter "*.ini" -ErrorAction SilentlyContinue | ForEach-Object {
                        Get-Content $_.FullName -ErrorAction SilentlyContinue | ForEach-Object {
                            if ($_ -match "(?i)^.*?=([a-zA-Z]:\\[^\*\|\<\>\?]+)$") {
                                $v2 = $Matches[1].Trim().TrimEnd('\')
                                if ($v2 -notmatch "WeChat Files$" -and $v2 -notmatch "xwechat_files$") {
                                    [void]$wxCacheBaseDirs.Add("$v2\WeChat Files")
                                    [void]$wxCacheBaseDirs.Add("$v2\xwechat_files")
                                } else { [void]$wxCacheBaseDirs.Add($v2) }
                            }
                        }
                    }
                } catch { }
            }
        }
        try {
            Get-FixedDriveLetters | ForEach-Object {
                $drv2 = $_
                @("$drv2\WeChat Files","$drv2\xwechat_files","$drv2\WeChat\WeChat Files","$drv2\WeChat\xwechat_files") |
                    Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { [void]$wxCacheBaseDirs.Add($_) }
                # [PS2.0兼容] -Directory 开关参数是 PowerShell 3.0+ 才有的，PS2.0 不支持；
                # 改用 PSIsContainer 属性过滤，这是自 V1 起就存在的写法，效果完全等价。
                Get-ChildItem -LiteralPath "$drv2\" -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer } | ForEach-Object {
                    @("$($_.FullName)\WeChat Files","$($_.FullName)\xwechat_files") |
                        Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { [void]$wxCacheBaseDirs.Add($_) }
                }
            }
        } catch { }
        $finalWxCacheBaseDirs = @($wxCacheBaseDirs) | Select-Object -Unique
        foreach ($b2 in $finalWxCacheBaseDirs) { Write-AsyncLog "  -> [微信缓存雷达] 基准路径: $b2" }
        # ==== 微信动态发现结束 ====

        $qqBasePaths = New-Object System.Collections.Generic.List[string]
        $dingBasePaths = New-Object System.Collections.Generic.List[string]
        [void]$qqBasePaths.Add("*\Documents\Tencent Files")
        [void]$qqBasePaths.Add("*\AppData\Roaming\Tencent\QQ")
        [void]$dingBasePaths.Add("*\AppData\Roaming\DingTalk")
        try {
            Get-ChildItem "Registry::HKEY_USERS" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match "^S-1-5-21-\d+-\d+-\d+-\d+$" } | ForEach-Object {
                $sid = $_.PSChildName
                $qqReg = "Registry::HKEY_USERS\$sid\Software\Tencent\QQ2009"
                if (Test-Path -LiteralPath $qqReg -ErrorAction SilentlyContinue) {
                    $qqPath = (Get-ItemProperty $qqReg -Name "SavePath" -ErrorAction SilentlyContinue).SavePath
                    if ($qqPath -and $qqPath -match "^[a-zA-Z]:\\") { [void]$qqBasePaths.Add($qqPath.TrimEnd('\')) }
                }
                $dingReg = "Registry::HKEY_USERS\$sid\Software\DingTalk"
                if (Test-Path -LiteralPath $dingReg -ErrorAction SilentlyContinue) {
                    $dingPath = (Get-ItemProperty $dingReg -Name "DataPath" -ErrorAction SilentlyContinue).DataPath
                    if ($dingPath -and $dingPath -match "^[a-zA-Z]:\\") { [void]$dingBasePaths.Add($dingPath.TrimEnd('\')) }
                }
            }
        } catch { }
        try {
            Get-FixedDriveLetters | Where-Object { $_ -ne $Sync.SystemDrive } | ForEach-Object {
                @("$_\Tencent Files","$_\QQ\Tencent Files") | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { [void]$qqBasePaths.Add($_) }
            }
        } catch { }
        $finalQQBasePaths   = @($qqBasePaths)   | Select-Object -Unique
        $finalDingBasePaths = @($dingBasePaths)  | Select-Object -Unique

        # 拦截规则并进行动态路径注入
        foreach ($r in $Sync.BuiltInRules.SoftwareRules) {
            if ($r.ID -eq "WeChat") {
                # 使用动态发现的基准目录，展开到每个账号目录下的缓存子路径
                foreach ($base in $finalWxCacheBaseDirs) {
                    $resolvedBase = $null
                    if ($base -match "^[a-zA-Z]:\\") {
                        if (Test-Path -LiteralPath $base) { $resolvedBase = $base }
                    } else {
                        # 相对模式（*\Documents\WeChat Files），针对每个用户目录展开
                        foreach ($ud in $userDirs) {
                            $expanded = $base -replace "^\*", $ud
                            if (Test-Path -LiteralPath $expanded) { $resolvedBase = $expanded; break }
                        }
                    }
                    if (-not $resolvedBase) { continue }
                    $accDirs = @()
                    try { $accDirs = @(Get-ChildItem -LiteralPath $resolvedBase -ErrorAction Stop | Where-Object { $_.PSIsContainer }) } catch { }
                    foreach ($acc in $accDirs) {
                        @("FileStorage\Cache","FileStorage\Temp","cache","temp") |
                            ForEach-Object { [void]$softPathsList.Add((Join-Path $acc.FullName $_)) }
                    }
                }
                Write-AsyncLog "  -> [微信缓存雷达] 注入动态缓存路径（基于 $($finalWxCacheBaseDirs.Count) 个根目录）"
            } elseif ($r.ID -eq "TencentQQ") {
                foreach ($base in $finalQQBasePaths) {
                    [void]$softPathsList.Add("$base\Temp"); [void]$softPathsList.Add("$base\CrashDump")
                    [void]$softPathsList.Add("$base\*\AppData\file\cache")
                    # "$base\*\Image"、"$base\*\CustomFace" 是聊天图片/自定义头像，属于用户可见内容，
                    # 不是纯技术缓存，不混入默认开启的"常用软件运行时缓存"，已拆分为独立的 QQChatImages 项（见 3.1）。
                }
                Write-AsyncLog "  -> [QQ雷达] 注入 $($finalQQBasePaths.Count) 个动态基准路径"
            } elseif ($r.ID -eq "DingTalk") {
                foreach ($base in $finalDingBasePaths) {
                    [void]$softPathsList.Add("$base\*\Cache"); [void]$softPathsList.Add("$base\*\cef_cache")
                }
                Write-AsyncLog "  -> [钉钉雷达] 注入 $($finalDingBasePaths.Count) 个动态基准路径"
            } else {
                foreach ($p in $r.Paths) { [void]$softPathsList.Add($p) }
            }
        }

        $finalSoftPaths = New-Object System.Collections.Generic.List[string]
        foreach ($userDir in $userDirs) {
            foreach ($sp in $softPathsList) {
                $isAbsolute = $sp -match "^[a-zA-Z]:\\"
                if ($isAbsolute -and $userDir -ne $userDirs[0]) { continue }
                $searchPattern = if ($isAbsolute) { $sp } else { $sp -replace "^\*", $userDir }
                Get-ChildItem -Path $searchPattern -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer } | ForEach-Object { [void]$finalSoftPaths.Add($_.FullName) }
            }
        }
        [System.Threading.Monitor]::Enter($Sync)
        try {
            $Sync.ScanItems["SoftwareCache"].Paths = $finalSoftPaths | Select-Object -Unique
            [long]$sSize = 0; foreach ($p in $Sync.ScanItems["SoftwareCache"].Paths) { $sSize += Get-FolderSize $p }
            $Sync.ScanItems["SoftwareCache"].Size = $sSize
        } finally { [System.Threading.Monitor]::Exit($Sync) }
    }

    # --- 3.1 QQ 聊天图片/自定义头像（从"软件缓存"中拆分出来，默认关闭，需要单独确认）---
    # 说明：QQ 的 Image/CustomFace 目录存放的是聊天中收发过的图片、以及自定义头像展示缓存，
    # 属于用户可见的聊天内容，不是纯技术缓存（不像 Temp/CrashDump 那样删了不影响任何可感知的东西），
    # 因此单独拆成一项。此处独立重新探测 QQ 基准路径，不依赖 SoftwareCache 是否勾选，两个开关互不影响。
    if ($Sync.ScanItems["QQChatImages"].Checked) {
        Write-AsyncLog "[扫描] QQ 聊天图片/自定义头像缓存（用户可见内容，请谨慎）..."
        $qqImgBasePaths = New-Object System.Collections.Generic.List[string]
        [void]$qqImgBasePaths.Add("*\Documents\Tencent Files")
        [void]$qqImgBasePaths.Add("*\AppData\Roaming\Tencent\QQ")
        try {
            Get-ChildItem "Registry::HKEY_USERS" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match "^S-1-5-21-\d+-\d+-\d+-\d+$" } | ForEach-Object {
                $qqReg2 = "Registry::HKEY_USERS\$($_.PSChildName)\Software\Tencent\QQ2009"
                if (Test-Path -LiteralPath $qqReg2 -ErrorAction SilentlyContinue) {
                    $qqPath2 = (Get-ItemProperty $qqReg2 -Name "SavePath" -ErrorAction SilentlyContinue).SavePath
                    if ($qqPath2 -and $qqPath2 -match "^[a-zA-Z]:\\") { [void]$qqImgBasePaths.Add($qqPath2.TrimEnd('\')) }
                }
            }
        } catch { }
        try {
            Get-FixedDriveLetters | Where-Object { $_ -ne $Sync.SystemDrive } | ForEach-Object {
                @("$_\Tencent Files","$_\QQ\Tencent Files") | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { [void]$qqImgBasePaths.Add($_) }
            }
        } catch { }
        $finalQQImgBasePaths = @($qqImgBasePaths) | Select-Object -Unique

        $qqImgPathsList = New-Object System.Collections.Generic.List[string]
        foreach ($base in $finalQQImgBasePaths) {
            [void]$qqImgPathsList.Add("$base\*\Image"); [void]$qqImgPathsList.Add("$base\*\CustomFace")
        }
        $finalQQImgPaths = New-Object System.Collections.Generic.List[string]
        foreach ($userDir in $userDirs) {
            foreach ($sp in $qqImgPathsList) {
                $isAbsolute = $sp -match "^[a-zA-Z]:\\"
                if ($isAbsolute -and $userDir -ne $userDirs[0]) { continue }
                $searchPattern = if ($isAbsolute) { $sp } else { $sp -replace "^\*", $userDir }
                Get-ChildItem -Path $searchPattern -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer } | ForEach-Object { [void]$finalQQImgPaths.Add($_.FullName) }
            }
        }
        [System.Threading.Monitor]::Enter($Sync)
        try {
            $Sync.ScanItems["QQChatImages"].Paths = $finalQQImgPaths | Select-Object -Unique
            [long]$qSize = 0; foreach ($p in $Sync.ScanItems["QQChatImages"].Paths) { $qSize += Get-FolderSize $p }
            $Sync.ScanItems["QQChatImages"].Size = $qSize
        } finally { [System.Threading.Monitor]::Exit($Sync) }
    }

    # --- 3.2 微信媒体深度文件（终极通用版）---
    if ($Sync.ScanItems["WeChatMedia"].Checked) {
        Write-AsyncLog "[探测] 启动微信媒体通用雷达..."
        $wxRootCandidates = New-Object System.Collections.Generic.List[string]

        # 1. 文档路径（自动获取，兼容中英文 Documents 目录名）
        $myDocsPaths = @()
        try { $myDocsPaths += [Environment]::GetFolderPath("MyDocuments") } catch { }
        foreach ($d in $userDirs) {
            @("$d\Documents","$d\文档","$d\My Documents") | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { $myDocsPaths += $_ }
        }
        foreach ($p in ($myDocsPaths | Select-Object -Unique)) {
            [void]$wxRootCandidates.Add((Join-Path $p "WeChat Files"))
            [void]$wxRootCandidates.Add((Join-Path $p "xwechat_files"))
        }

        # 2. 注册表（含子键遍历，覆盖多账号场景）
        try {
            Get-ChildItem "Registry::HKEY_USERS" | Where-Object { $_.PSChildName -match "^S-1-5-21-\d+-\d+-\d+-\d+$" } | ForEach-Object {
                $wxRegRoot = "Registry::$($_.Name)\Software\Tencent\WeChat"
                if (Test-Path $wxRegRoot) {
                    $val = (Get-ItemProperty $wxRegRoot -Name FileSavePath -ErrorAction SilentlyContinue).FileSavePath
                    if ($val -and $val -ne "MyDocument:" -and $val -match "^[a-zA-Z]:\\") { [void]$wxRootCandidates.Add($val.TrimEnd('\')) }
                    Get-ChildItem $wxRegRoot -ErrorAction SilentlyContinue | ForEach-Object {
                        $sub = (Get-ItemProperty $_.PSPath -Name FileSavePath -ErrorAction SilentlyContinue).FileSavePath
                        if ($sub -and $sub -ne "MyDocument:" -and $sub -match "^[a-zA-Z]:\\") { [void]$wxRootCandidates.Add($sub.TrimEnd('\')) }
                    }
                }
            }
        } catch { }

        # 3. 配置文件（All Users\config\*.ini）
        foreach ($d in $userDirs) {
            $cfg = Join-Path $d "AppData\Roaming\Tencent\WeChat\All Users\config"
            if (Test-Path $cfg) {
                Get-ChildItem $cfg -Filter "*.ini" -ErrorAction SilentlyContinue | Get-Content |
                    Where-Object { $_ -match "([a-zA-Z]:\\[^\*\|\<\>\?]+)" } |
                    ForEach-Object { [void]$wxRootCandidates.Add($Matches[1].Trim().TrimEnd('\')) }
            }
        }

        # 4. 全盘物理搜索（深度 2 层，覆盖任意自定义存储位置）
        try {
            Get-FixedDriveLetters | ForEach-Object {
                $drv = $_
                @("$drv\WeChat Files","$drv\xwechat_files","$drv\WeChat\WeChat Files","$drv\WeChat\xwechat_files") |
                    Where-Object { Test-Path $_ } | ForEach-Object { [void]$wxRootCandidates.Add($_) }
                # [PS2.0兼容] Get-ChildItem -Recurse -Depth 是 PowerShell 5.0+ 才新增的参数组合，
                # -Directory 则是 3.0+ 才有，PS2.0 环境下两个都不存在，会直接报"找不到参数"的错误。
                # 这里手动展开两层（等价于原来的 -Depth 2），并用 PSIsContainer 代替 -Directory 过滤目录。
                $wxLevel1Dirs = $null
                try { $wxLevel1Dirs = @(Get-ChildItem -LiteralPath "$drv\" -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer }) } catch { $wxLevel1Dirs = @() }
                foreach ($wxL1 in $wxLevel1Dirs) {
                    if ($wxL1.Name -eq "WeChat Files" -or $wxL1.Name -eq "xwechat_files") { [void]$wxRootCandidates.Add($wxL1.FullName) }
                    $wxLevel2Dirs = $null
                    try { $wxLevel2Dirs = @(Get-ChildItem -LiteralPath $wxL1.FullName -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer }) } catch { $wxLevel2Dirs = @() }
                    foreach ($wxL2 in $wxLevel2Dirs) {
                        if ($wxL2.Name -eq "WeChat Files" -or $wxL2.Name -eq "xwechat_files") { [void]$wxRootCandidates.Add($wxL2.FullName) }
                    }
                }
            }
        } catch { }

        # 去重 + 解析符号链接为真实路径
        $wxRoots = @($wxRootCandidates | Select-Object -Unique | ForEach-Object {
            try { (Get-Item $_ -Force -ErrorAction Stop).FullName } catch { }
        } | Select-Object -Unique)
        Write-AsyncLog "  -> 微信根目录: $($wxRoots -join '; ')"

        # 逐账号目录扫描，匹配典型媒体子目录结构
        $wxMediaPaths = New-Object System.Collections.Generic.List[string]
        $subDirPatterns = @("FileStorage\Video","FileStorage\Image","FileStorage\File","FileStorage\MsgAttach","msg\video","msg\file","msg\attach")
        foreach ($root in $wxRoots) {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            foreach ($acc in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer })) {
                foreach ($sub in $subDirPatterns) {
                    $full = Join-Path $acc.FullName $sub
                    if (Test-Path -LiteralPath $full) { [void]$wxMediaPaths.Add($full) }
                }
            }
        }

        $final = @($wxMediaPaths | Select-Object -Unique)
        [System.Threading.Monitor]::Enter($Sync)
        try {
            $Sync.ScanItems["WeChatMedia"].Paths = $final
            $Sync.ScanItems["WeChatMedia"].Size  = 0
            foreach ($p in $final) { $Sync.ScanItems["WeChatMedia"].Size += Get-FolderSize $p }
        } finally { [System.Threading.Monitor]::Exit($Sync) }
        Write-AsyncLog ("  -> [微信统计] 共捕获 {0} 个媒体目录，总大小 {1:N2} MB" -f $final.Count, ($Sync.ScanItems["WeChatMedia"].Size/1MB))
    }

    # --- 4. 注册表失效项 ---
    if ($Sync.ScanItems["RegUninstall"].Checked) {
        Write-AsyncLog "[扫描] 注册表失效卸载项追踪..."
        $regPaths = @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*")
        $invalidRegs = New-Object System.Collections.Generic.List[string]
        foreach ($reg in $regPaths) {
            if ($Sync.CancelRequested) { break }
            Get-ItemProperty $reg -ErrorAction SilentlyContinue | Where-Object { $null -ne $_.UninstallString -and $null -ne $_.InstallLocation } | ForEach-Object {
                $ipath = $_.InstallLocation.Trim('"').Trim("'")
                if (-not [string]::IsNullOrEmpty($ipath) -and -not (Test-Path $ipath)) {
                    [void]$invalidRegs.Add($_.PSPath)
                    $dispName = if ($_.DisplayName) { $_.DisplayName } else { "(无显示名称)" }
                    Write-AsyncLog "  -> 发现失效项: $dispName"
                    [void]$Sync.RegUninstallDetails.Add(@{ PSPath = $_.PSPath; DisplayName = $dispName; InstallLocation = $ipath })
                }
            }
        }
        [System.Threading.Monitor]::Enter($Sync)
        try {
            $Sync.ScanItems["RegUninstall"].Paths = $invalidRegs; $Sync.ScanItems["RegUninstall"].Size = 0
        } finally { [System.Threading.Monitor]::Exit($Sync) }
    }

    # --- 5. 已卸载软件残留目录（残留目录）智能识别 ---
    if ($Sync.ScanItems["ResidualAppDirs"].Checked) {
        Write-AsyncLog "[扫描] 已卸载软件残留目录（残留目录）识别中（多维度误判过滤）..."

        # ── Step 1: 多源收集「当前仍存在的软件」路径证据 ─────────────────────────────
        $knownPaths = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

        # 1a. 标准 Uninstall 注册表（三处，补充 DisplayIcon 字段）
        $regScanPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        foreach ($rp in $regScanPaths) {
            Get-ItemProperty $rp -ErrorAction SilentlyContinue | ForEach-Object {
                foreach ($prop in @("InstallLocation","InstallDir","InstallPath","DisplayIcon")) {
                    $val = $_.$prop
                    if ($val -and $val.Trim() -ne "") {
                        $val = ($val -split ',')[0].Trim().Trim('"') # DisplayIcon 含 ,0 后缀
                        if ($val -match '\.[a-zA-Z]{2,4}$') { $val = [System.IO.Path]::GetDirectoryName($val) }
                        if ($val -and $val.Length -gt 3) { [void]$knownPaths.Add($val.TrimEnd('\')) }
                    }
                }
            }
        }

        # 1b. App Paths（每个 .exe 单独注册；绿色软件常见注册方式）
        foreach ($apRoot in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\*",
                              "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\App Paths\*")) {
            Get-ItemProperty $apRoot -ErrorAction SilentlyContinue | ForEach-Object {
                $exePath = $_."(default)"
                if ($exePath -and $exePath.Trim() -ne "") {
                    $exePath = $exePath.Trim().Trim('"')
                    $dir = [System.IO.Path]::GetDirectoryName($exePath)
                    if ($dir -and $dir.Length -gt 3) { [void]$knownPaths.Add($dir.TrimEnd('\')) }
                }
            }
        }

        # 1c. Windows 服务 ImagePath（服务型程序无 InstallLocation）
        try {
            Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\*" -ErrorAction SilentlyContinue | ForEach-Object {
                $img = $_.ImagePath
                if ($img -and $img.Trim() -ne "") {
                    $img = ($img -replace '^"([^"]+)".*','$1' -replace "^([^ ]+).*",'$1').Trim('"').Trim()
                    if ($img -match "^[a-zA-Z]:\\" -and $img -notmatch "^[a-zA-Z]:\\[Ww]indows\\") {
                        $dir = [System.IO.Path]::GetDirectoryName($img)
                        if ($dir -and $dir.Length -gt 3) { [void]$knownPaths.Add($dir.TrimEnd('\')) }
                    }
                }
            }
        } catch { }

        # 1d. 开始菜单快捷方式目标（最可靠：用户看得见的软件基本都在这里）
        $WshShell = $null
        try {
            $WshShell = New-Object -ComObject WScript.Shell
            @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
              "$env:ProgramData\Microsoft\Windows\Start Menu\Programs") | Where-Object { Test-Path $_ } | ForEach-Object {
                Get-ChildItem -Path $_ -Filter "*.lnk" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                    try {
                        $lnk = $WshShell.CreateShortcut($_.FullName)
                        $target = $lnk.TargetPath
                        if ($target -and $target -match "^[a-zA-Z]:\\") {
                            $dir = [System.IO.Path]::GetDirectoryName($target)
                            if ($dir -and $dir.Length -gt 3) { [void]$knownPaths.Add($dir.TrimEnd('\')) }
                        }
                    } catch { }
                }
            }
        } catch { } finally {
            if ($WshShell) { try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($WshShell) | Out-Null } catch { } }
        }

        # 1e. 正在运行的进程路径（绝对不能删）
        $runningDirs = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        try {
            Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $exe = $_.MainModule.FileName
                    if ($exe -and $exe -match "^[a-zA-Z]:\\") {
                        $dir = [System.IO.Path]::GetDirectoryName($exe)
                        if ($dir) {
                            [void]$runningDirs.Add($dir.TrimEnd('\'))
                            $parent = [System.IO.Path]::GetDirectoryName($dir)
                            if ($parent -and $parent.Length -gt 3) { [void]$knownPaths.Add($parent.TrimEnd('\')) }
                        }
                    }
                } catch { }
            }
        } catch { }
        Write-AsyncLog ("  -> [残留目录扫描] 已知路径证据 {0} 条（注册表+AppPaths+服务+快捷方式+进程）" -f $knownPaths.Count)

        # ── Step 2: 候选目录收集 ─────────────────────────────────────────────────────
        $scanRoots = New-Object System.Collections.Generic.List[string]
        foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:SystemDrive\Program Files", "$env:SystemDrive\Program Files (x86)")) {
            if (-not [string]::IsNullOrEmpty($pf) -and (Test-Path $pf)) { [void]$scanRoots.Add($pf) }
        }
        foreach ($ud in (Get-ChildItem -LiteralPath "$env:SystemDrive\Users" -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer } | Select-Object -ExpandProperty FullName)) {
            foreach ($sub in @("AppData\Roaming","AppData\Local","AppData\Local\Programs")) {
                $c = Join-Path $ud $sub
                if (Test-Path $c) { [void]$scanRoots.Add($c) }
            }
        }
        [void]$scanRoots.Add("$env:ProgramData")

        # 系统级永久排除名单
        $safeNames = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        @("Microsoft","Microsoft.NET","Windows","Common Files","Internet Explorer","WindowsPowerShell",
          "Windows Defender","Windows Security","Windows NT","WindowsApps","ModifiableWindowsApps",
          "Temp","Temporary Internet Files","Packages","Reference Assemblies",
          "Microsoft OneDrive","OneDrive","Google","Mozilla Firefox","Mozilla",
          "Git","Node.js","Python","Java","JRE","JDK","Oracle","Visual Studio Code") | ForEach-Object { [void]$safeNames.Add($_) }

        $residualDirs  = New-Object System.Collections.Generic.List[string]
        $residualTotal = [long]0
        # 90天内有文件写入 = 极可能仍在使用（绿化软件/破解软件都有活跃写入）
        $cutoffDate  = (Get-Date).AddDays(-90)
        # 同名目录跨路径交叉核对：activeNames 记录本次扫描中被判定为活跃/含卸载器/进程占用/已知安装路径的目录名；
        # pendingResiduals 暂存通过初筛但尚未与 activeNames 核对的候选残留目录（见 Step 4）。
        $activeNames    = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        $pendingResiduals = New-Object System.Collections.Generic.List[object]

        # ── Step 3: 逐目录多维判定 ───────────────────────────────────────────────────
        foreach ($root in $scanRoots) {
            if ($Sync.CancelRequested) { break }
            try {
                foreach ($dir in [System.IO.Directory]::GetDirectories($root)) {
                    $name = [System.IO.Path]::GetFileName($dir)
                    if ($safeNames.Contains($name)) { continue }

                    # 判断①：注册表/快捷方式/服务等任意已知路径包含或被包含于此目录
                    $isKnown = $false
                    foreach ($known in $knownPaths) {
                        # 双向匹配：known 以 dir\ 开头（dir 是父） 或 dir 以 known\ 开头（dir 是子）
                        if ($known.StartsWith($dir + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
                            $dir.StartsWith($known + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
                            [string]::Equals($known, $dir, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $isKnown = $true; break
                        }
                    }
                    if ($isKnown) { [void]$activeNames.Add($name); continue }

                    # 判断②：正在运行的进程来自此目录
                    $hasRunning = $false
                    foreach ($rd in $runningDirs) {
                        if ($rd.StartsWith($dir + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
                            [string]::Equals($rd, $dir, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $hasRunning = $true; break
                        }
                    }
                    if ($hasRunning) { Write-AsyncLog "  -> [跳过-进程运行中] $dir"; [void]$activeNames.Add($name); continue }

                    # 判断③④⑤：单次遍历——同时检测卸载程序、计算大小、获取最近写入时间
                    # 三个结果合并到一个 GetFiles 循环里，避免对同一目录重复遍历
                    $hasUninstaller = $false
                    $lastWrite      = [DateTime]::MinValue
                    $sz             = [long]0
                    try {
                        foreach ($f in [System.IO.Directory]::GetFiles($dir, "*", [System.IO.SearchOption]::AllDirectories)) {
                            try {
                                $fi = New-Object System.IO.FileInfo($f)
                                $sz += $fi.Length
                                $fw  = $fi.LastWriteTime
                                if ($fw -gt $lastWrite) { $lastWrite = $fw }
                                # 只在尚未确认有卸载器时才检查文件名（已确认则跳过，节省时间）
                                if (-not $hasUninstaller) {
                                    $n = $fi.Name.ToLower()
                                    if ($n -match "^unins|^uninstall|^uninst|setup|updater|patcher|launcher|update") {
                                        $hasUninstaller = $true
                                    }
                                }
                            } catch { }
                        }
                    } catch { }

                    if ($hasUninstaller) { Write-AsyncLog "  -> [跳过-含启动/卸载程序] $dir"; [void]$activeNames.Add($name); continue }
                    if ($lastWrite -gt $cutoffDate) {
                        Write-AsyncLog ("  -> [跳过-近期活跃({0:yyyy-MM-dd})] {1}" -f $lastWrite, $dir)
                        [void]$activeNames.Add($name)
                        continue
                    }

                    # 通过所有过滤器：此目录暂列为「疑似残留」候选，先不下结论、也不立即报告，
                    # 留到 Step 4 跟同名目录（例如 AppData\Roaming\Adobe 与 ProgramData\Adobe）做交叉核对之后再定案——
                    # 避免「同一款软件在别处已被判定为活跃，但这个目录自己 90 天内没写入」时被单独误判成残留目录。
                    if ($sz -gt 1MB) {
                        $lastWriteStr = if ($lastWrite -gt [DateTime]::MinValue) { $lastWrite.ToString("yyyy-MM-dd") } else { "未知" }
                        [void]$pendingResiduals.Add(@{ Path = $dir; Name = $name; Size = [long]$sz; LastWriteStr = $lastWriteStr })
                    }
                }
            } catch { }
        }

        # ── Step 4: 同名目录跨路径交叉核对 ───────────────────────────────────────────
        # 同一款软件常常在 AppData\Roaming、AppData\Local、ProgramData 下各留一个同名目录，
        # 但很多软件日常运行时只会持续写入其中一两处（比如聊天/内容类目录），另一处（例如
        # ProgramData 下存共享组件/授权信息的目录）可能几个月都不写入一次。如果只按单个目录
        # 自己的 mtime 判定，就会出现「软件明明还在用，但其中一个目录被单独判定成残留目录」的
        # 误报（例如 ProgramData\Adobe、ProgramData\Tencent）。这里用同名目录做兜底核对：
        # 只要同名目录在任意一个位置被判定为活跃/含卸载器/进程占用/已知安装路径，
        # 所有位置的同名目录都不再判定为残留目录。
        foreach ($cand in $pendingResiduals) {
            if ($activeNames.Contains($cand.Name)) {
                Write-AsyncLog ("  -> [跳过-同名目录在其他位置活跃(交叉核对)] {0}" -f $cand.Path)
                continue
            }
            [void]$residualDirs.Add($cand.Path)
            $residualTotal += $cand.Size
            Write-AsyncLog ("  -> 残留目录 [{0:N0} MB, 最后写入:{1}]: {2}" -f ($cand.Size/1MB), $cand.LastWriteStr, $cand.Path)
            [void]$Sync.ResidualDetails.Add(@{ Path = $cand.Path; Size = [long]$cand.Size; LastWrite = $cand.LastWriteStr })
        }

        [System.Threading.Monitor]::Enter($Sync)
        try {
            $Sync.ScanItems["ResidualAppDirs"].Paths = $residualDirs
            $Sync.ScanItems["ResidualAppDirs"].Size  = $residualTotal
        } finally { [System.Threading.Monitor]::Exit($Sync) }
        Write-AsyncLog ("[扫描完成] 残留目录共 {0} 个，合计 {1:N0} MB（已过滤近期活跃/含卸载器/进程占用/快捷方式匹配目录/同名目录交叉核对）" -f $residualDirs.Count, ($residualTotal/1MB))
    }

    # --- 6. 高危项体积探测：WinSxS / 休眠文件 / CompactOS ---
    # 6.1 WinSxS 组件存储大小预估（DISM /Online /Cleanup-Image /AnalyzeComponentStore）
    if ($Sync.ScanItems["WinSxSClean"].Checked -or $Sync.ScanItems["WinSxSResetBase"].Checked) {
        Write-AsyncLog "[扫描] WinSxS 组件存储分析（DISM AnalyzeComponentStore，可能需要 30-90 秒）..."
        $winsxsPath = "$env:windir\WinSxS"
        $winsxsSize = [long]0
        if (Test-Path $winsxsPath) {
            try {
                foreach ($f in [System.IO.Directory]::GetFiles($winsxsPath, "*", [System.IO.SearchOption]::AllDirectories)) {
                    try { $winsxsSize += (New-Object System.IO.FileInfo($f)).Length } catch { }
                }
            } catch { }
        }
        # DISM 分析获取"可回收"空间大小
        # 目标行（中英双语兼容）：
        #   "Disk Space Savings from cleanup          : 2.00 GB"
        #   "清理可节省的磁盘空间                     : 2.00 GB"
        $reclaimable = [long]0
        try {
            $dismOut = & dism.exe /Online /Cleanup-Image /AnalyzeComponentStore 2>&1
            $dismOut | ForEach-Object {
                Write-AsyncLog "  [DISM] $_"
                # 仅匹配"可节省 / Savings"行，避免误取总大小
                if ($_ -match "(?i)(disk\s*space\s*savings|节省的磁盘空间|可以通过清理|可回收|可節省)") {
                    if ($_ -match "(\d[\d,\.]+)\s*(GB|MB)") {
                        $num   = [double]($Matches[1] -replace ',','')
                        $bytes = if ($Matches[2] -eq "GB") { [long]($num * 1GB) } else { [long]($num * 1MB) }
                        if ($bytes -gt $reclaimable) { $reclaimable = $bytes }
                    }
                }
            }
        } catch { Write-AsyncLog "  [DISM] 分析命令执行失败（DISM 不可用或权限不足）" }

        # DISM 输出解析失败（正则未命中/命令超时/权限不足）时不用目录物理总大小（普遍 5-10GB+）顶替
        # "可回收空间"上报——两者是完全不同的量，会造成虚高误报。未能取得明确值时按 0 处理，日志注明"未知"。
        $reportSize = if ($reclaimable -gt 0) { $reclaimable } else { [long]0 }
        [System.Threading.Monitor]::Enter($Sync)
        try {
            $Sync.ScanItems["WinSxSClean"].Size     = $reportSize
            $Sync.ScanItems["WinSxSResetBase"].Size  = $reportSize
        } finally { [System.Threading.Monitor]::Exit($Sync) }
        if ($reclaimable -gt 0) {
            Write-AsyncLog ("[扫描完成] WinSxS 当前占用约 {0:N1} GB，可回收空间估算 {1:N1} GB" -f ($winsxsSize/1GB), ($reclaimable/1GB))
        } else {
            Write-AsyncLog ("[扫描完成] WinSxS 当前占用约 {0:N1} GB，但未能从 DISM 输出中解析出明确的可回收空间数值，本次按 0 处理（不代表没有可回收空间，只是无法确认，请勿以此总占用量作为参考）。" -f ($winsxsSize/1GB))
        }
    }

    # 6.2 休眠文件大小检测
    if ($Sync.ScanItems["HibernateFile"].Checked) {
        $hibPath = "$env:SystemDrive\hiberfil.sys"
        $hibSize = [long]0
        if (Test-Path $hibPath) {
            try { $hibSize = (Get-Item -LiteralPath $hibPath -Force -ErrorAction Stop).Length } catch { }
        }
        $Sync.ScanItems["HibernateFile"].Size  = $hibSize
        $Sync.ScanItems["HibernateFile"].Paths = if ($hibSize -gt 0) { @($hibPath) } else { @() }
        if ($hibSize -gt 0) {
            Write-AsyncLog ("[扫描] 休眠文件 hiberfil.sys：{0:N1} GB（关闭休眠后可释放）" -f ($hibSize/1GB))
        } else {
            Write-AsyncLog "[扫描] 未检测到休眠文件（休眠功能可能已关闭）"
        }
    }

    # 6.3 Compact OS 状态检测
    if ($Sync.ScanItems["CompactOS"].Checked) {
        # compact.exe /CompactOS:query 的英文回显不含 "compacted" 一词，故按"先排除否定短语、
        # 再匹配肯定短语"的顺序判定（"not in the Compact"优先排除，剩下命中"in the Compact state"才算已压缩），
        # 中文本地化文案同理兜底匹配。匹配不确定时保持 $false：/CompactOS:always 是幂等操作，
        # 误判成"尚未压缩"顶多重新核对一次，比漏掉真正需要压缩的系统更安全。
        $isCompacted = $false
        try {
            $compactOut = & compact.exe /CompactOS:query 2>&1
            $compactRaw = ($compactOut -join " ")
            if ($compactRaw -match "not in the Compact") { $isCompacted = $false }
            elseif ($compactRaw -match "in the Compact state") { $isCompacted = $true }
            elseif ($compactRaw -match "未.{0,6}压缩|不.{0,6}压缩状态|尚未压缩") { $isCompacted = $false }
            elseif ($compactRaw -match "压缩状态|已.{0,4}压缩") { $isCompacted = $true }
        } catch { }
        if ($isCompacted) {
            $Sync.ScanItems["CompactOS"].Size  = 0
            $Sync.ScanItems["CompactOS"].Paths = @()
            Write-AsyncLog "[扫描] Compact OS：系统已处于压缩状态，无需重复操作"
        } else {
            # 预估可节省空间：Windows 目录典型压缩率约 40%，粗估约 2-4 GB（仅供参考，samples 仅取 *.dll，
            # 实际压缩范围还包含 exe/sys/mui 等文件，与压缩算法也有关，真实数字可能有出入）
            $winDirSize = [long]0
            try {
                foreach ($f in [System.IO.Directory]::GetFiles($env:windir, "*.dll", [System.IO.SearchOption]::AllDirectories)) {
                    try { $winDirSize += (New-Object System.IO.FileInfo($f)).Length } catch { }
                    if ($winDirSize -gt 20GB) { break }  # 采样到 20 GB 足够估算，不需完整遍历
                }
            } catch { }
            $estimated = [long]($winDirSize * 0.35)
            $Sync.ScanItems["CompactOS"].Size  = $estimated
            $Sync.ScanItems["CompactOS"].Paths = @("CompactOS_Action")
            Write-AsyncLog ("[扫描] Compact OS：系统尚未压缩，预估可节省约 {0:N1} GB（估算值，仅供参考）" -f ($estimated/1GB))
        }
    }
    $Sync.Progress = 70

    # --- 7. 空文件夹收割（全盘递归扫描，增强版） ---
    if ($Sync.ScanItems["EmptyFolders"].Checked) {
        Write-AsyncLog "[扫描] 全盘递归空文件夹收割（增强版，实时日志）..."
        $emptyFolders    = New-Object System.Collections.Generic.List[string]
        # 用 ${env:ProgramFiles(x86)} 显式定界（普通 "$env:ProgramFiles(x86)" 在双引号字符串里
        # 会在左括号处截断，导致排除规则形同虚设），并逐项非空校验。
        $excludePrefixes = New-Object System.Collections.Generic.List[string]
        foreach ($ep in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
            if (-not [string]::IsNullOrEmpty($ep)) { [void]$excludePrefixes.Add($ep) }
        }
        [void]$excludePrefixes.Add("$env:SystemDrive\System Volume Information")
        [void]$excludePrefixes.Add("$env:SystemDrive\`$RECYCLE.BIN")
        $drives    = Get-FixedDriveLetters
        $totalDirs = 0
        foreach ($root in $drives) {
            if ($Sync.CancelRequested) { break }
            Write-AsyncLog "  -> 开始扫描驱动器: $root"
            $stack = New-Object System.Collections.Generic.Stack[string]
            $stack.Push("$root\")
            while ($stack.Count -gt 0) {
                if ($Sync.CancelRequested) { break }
                $dir      = $stack.Pop()
                $dirUpper = $dir.ToUpper()
                $skip = $false
                foreach ($ex in $excludePrefixes) {
                    if ($dirUpper.StartsWith($ex.ToUpper())) { $skip = $true; break }
                }
                if ($skip) { continue }
                try {
                    $entries = [System.IO.Directory]::GetFileSystemEntries($dir)
                } catch {
                    Write-AsyncLog "  -> [跳过] 无法访问: $dir"
                    continue
                }
                if ($entries.Count -eq 0) {
                    [void]$emptyFolders.Add($dir)
                } else {
                    foreach ($entry in $entries) {
                        if ([System.IO.Directory]::Exists($entry)) {
                            # 跳过重分析点（junction / symlink），避免误判或破坏软链接
                            try {
                                $attr = [System.IO.File]::GetAttributes($entry)
                                if ($attr -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                            } catch { continue }
                            [void]$stack.Push($entry)
                        }
                    }
                }
                $totalDirs++
                if ($totalDirs % 5000 -eq 0) {
                    Write-AsyncLog "  -> 已遍历 $totalDirs 个目录，发现 $($emptyFolders.Count) 个空文件夹，当前目录: $dir"
                }
            }
            Write-AsyncLog "  -> 驱动器 $root 扫描完成，累计发现 $($emptyFolders.Count) 个空文件夹"
        }
        [System.Threading.Monitor]::Enter($Sync)
        try {
            $Sync.ScanItems["EmptyFolders"].Paths = $emptyFolders | Select-Object -Unique
            $Sync.ScanItems["EmptyFolders"].Size  = 0
            Write-AsyncLog "  -> 全盘扫描结束，共发现 $($emptyFolders.Count) 个空文件夹（已排除系统关键目录）"
        } finally { [System.Threading.Monitor]::Exit($Sync) }
    }
    $Sync.Progress = 80

    # --- 8. 核心杂项与其他探测 ---
    Write-AsyncLog "[扫描] 核心杂项与系统环境探测..."

    [System.Threading.Monitor]::Enter($Sync)
    try {
        if ($Sync.ScanItems["DriverCache"].Checked) {
            # 覆盖面说明（已核实来源）：
            #   - SystemDrive\NVIDIA / \AMD / \INTEL：三大厂商驱动安装程序在系统盘根目录下的解压暂存目录，
            #     安装完成后即为纯粹残留，删除不影响已安装驱动和显卡功能（原有 NVIDIA/AMD 两项，新增 INTEL）。
            #   - NVIDIA Corporation\Downloader：当前版本驱动下载缓存（原有）。
            #   - NVIDIA Corporation\Installer2：历次驱动/组件安装包缓存，用于日后"驱动回滚"时重新拼装安装包，
            #     常年只增不减，体积可达数 GB；只清空其内容、不删除 Installer2 目录本身
            #     （与 SafeClean 只清空目录内容、不删除目录本身的行为天然吻合），删除内容不影响当前已装驱动，
            #     但会导致今后驱动异常时无法用"回滚到上一版本"，只能重新下载安装——是可接受的代价。
            #   - 未纳入 NVIDIA Corporation\NetService：该目录是遥测/日志文件，重启后由服务自动重建、
            #     持续被进程写入，清理收益有限且冲突概率更高，暂不作为默认必清项收录。
            $Sync.ScanItems["DriverCache"].Paths = @(
                "$env:SystemDrive\NVIDIA",
                "$env:SystemDrive\AMD",
                "$env:SystemDrive\INTEL",
                "$env:ProgramData\NVIDIA Corporation\Downloader",
                "$env:ProgramFiles\NVIDIA Corporation\Installer2"
            ) | Where-Object { Test-Path $_ }
        }
        if ($Sync.ScanItems["AdobeCache"].Checked) {
            $adobePaths = New-Object System.Collections.Generic.List[string]
            foreach ($d in $userDirs) { [void]$adobePaths.Add("$d\AppData\Roaming\Adobe\Common\Media Cache Files"); [void]$adobePaths.Add("$d\AppData\Roaming\Adobe\Common\Media Cache") }
            $Sync.ScanItems["AdobeCache"].Paths = $adobePaths | Where-Object { Test-Path $_ }
        }
        if ($Sync.ScanItems["UWPAppCache"].Checked) {
            $uwpPaths = New-Object System.Collections.Generic.List[string]
            foreach ($d in $userDirs) {
                $uwpBase = "$d\AppData\Local\Packages"
                if (Test-Path $uwpBase) { Get-ChildItem $uwpBase -Force -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer } | ForEach-Object { [void]$uwpPaths.Add("$($_.FullName)\AC\Temp") } }
            }
            $Sync.ScanItems["UWPAppCache"].Paths = $uwpPaths | Where-Object { Test-Path $_ }
        }
        if ($Sync.ScanItems["D3DSCache"].Checked) {
            $d3dPaths = New-Object System.Collections.Generic.List[string]
            foreach ($d in $userDirs) {
                [void]$d3dPaths.Add("$d\AppData\Local\D3DSCache")
                [void]$d3dPaths.Add("$d\AppData\Local\NVIDIA\DXCache")
                [void]$d3dPaths.Add("$d\AppData\Local\NVIDIA\GLCache")
                [void]$d3dPaths.Add("$d\AppData\Local\NVIDIA Corporation\NV_Cache")
                [void]$d3dPaths.Add("$d\AppData\Local\AMD\DxCache")
                [void]$d3dPaths.Add("$d\AppData\Local\AMD\DxcCache")
                [void]$d3dPaths.Add("$d\AppData\Local\AMD\VkCache")
                [void]$d3dPaths.Add("$d\AppData\Local\AMD\GLCache")
                [void]$d3dPaths.Add("$d\AppData\Local\Intel\ShaderCache")
            }
            [void]$d3dPaths.Add("$env:ProgramData\NVIDIA Corporation\NV_Cache")
            $Sync.ScanItems["D3DSCache"].Paths = $d3dPaths | Where-Object { Test-Path $_ }
        }
        if ($Sync.ScanItems["ThumbCache"].Checked) {
            $thumbPaths = New-Object System.Collections.Generic.List[string]
            foreach ($d in $userDirs) {
                $exp = "$d\AppData\Local\Microsoft\Windows\Explorer"
                if (Test-Path $exp) {
                    Get-ChildItem $exp -Filter "thumbcache_*.db" -ErrorAction SilentlyContinue | ForEach-Object { [void]$thumbPaths.Add($_.FullName) }
                    Get-ChildItem $exp -Filter "iconcache_*.db" -ErrorAction SilentlyContinue | ForEach-Object { [void]$thumbPaths.Add($_.FullName) }
                }
            }
            $Sync.ScanItems["ThumbCache"].Paths = $thumbPaths
        }
        if ($Sync.ScanItems["WinUpdate"].Checked) { $Sync.ScanItems["WinUpdate"].Paths = @("$env:SystemRoot\SoftwareDistribution\Download") }
        # Windows\Logs 装的是 CBS/DISM/WindowsUpdate 等诊断日志，与"崩溃转储"(MemoryDumps，默认勾选)不是一回事，
        # 混在一起容易在用户没意识到的情况下删掉有排障价值的日志，故拆成两个独立项。
        if ($Sync.ScanItems["MemoryDumps"].Checked) { $Sync.ScanItems["MemoryDumps"].Paths = @("$env:SystemRoot\MEMORY.DMP", "$env:SystemRoot\Minidump") | Where-Object { Test-Path $_ } }
        if ($Sync.ScanItems["WinDiagLogs"].Checked) { $Sync.ScanItems["WinDiagLogs"].Paths = @("$env:SystemRoot\Logs") | Where-Object { Test-Path $_ } }
        if ($Sync.ScanItems["EventLogs"].Checked) { $Sync.ScanItems["EventLogs"].Paths = @("$env:SystemRoot\System32\Winevt\Logs") | Where-Object { Test-Path $_ } }
        # [调整] RecycleBin 的扫描逻辑挪到本锁外面单独处理（见下方 finally 之后），原因见下方新代码块注释。
        if ($Sync.ScanItems["WERFiles"].Checked) {
            $werPaths = New-Object System.Collections.Generic.List[string]
            [void]$werPaths.Add("$env:ProgramData\Microsoft\Windows\WER\ReportArchive")
            [void]$werPaths.Add("$env:ProgramData\Microsoft\Windows\WER\ReportQueue")
            foreach ($d in $userDirs) {
                [void]$werPaths.Add("$d\AppData\Local\Microsoft\Windows\WER\ReportArchive")
                [void]$werPaths.Add("$d\AppData\Local\Microsoft\Windows\WER\ReportQueue")
            }
            $Sync.ScanItems["WERFiles"].Paths = $werPaths | Where-Object { Test-Path $_ }
        }
    } finally { [System.Threading.Monitor]::Exit($Sync) }

    # --- 回收站扫描：RecycleBinMonths<=0 走快速路径（SHQueryRecycleBin 直接测总量）；
    #     >0 时逐项枚举统计"删除时间早于 N 个月前"的大小。逐项枚举可能耗时较久，
    #     故放在上面共享 Monitor 锁之外，避免拖慢其它扫描项、影响 GUI 用锁读取进度时的响应。 ---
    if ($Sync.ScanItems["RecycleBin"].Checked) {
        Write-AsyncLog "[扫描] 回收站..."
        $rbPaths     = New-Object System.Collections.Generic.List[string]
        $totalRbSize = 0
        $rbMonths = 0
        try { $rbMonths = [int]$Sync.RecycleBinMonths } catch { $rbMonths = 0 }

        if ($rbMonths -le 0) {
            # 原有全量路径：只用 API 测总量，速度最快，对应"全部清空"
            foreach ($drv in (Get-FixedDriveLetters)) {
                $path = "$drv\`$Recycle.Bin"
                if (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue) {
                    [void]$rbPaths.Add($path)
                    $size = [FrostBladeWinAPI_v1]::GetRecycleBinTotalSize("$drv\")
                    $totalRbSize += $size
                    Write-AsyncLog "  -> 驱动器 $drv 回收站占用: $([math]::Round($size/1MB,2)) MB"
                }
            }
        } else {
            # 选择性路径：借助 Shell.Application 逐项枚举，只统计删除时间早于 $cutoff 的项目
            $cutoff = (Get-Date).AddMonths(-$rbMonths)
            $shell = $null; $rbFolder = $null
            try {
                $shell = New-Object -ComObject Shell.Application
                $rbFolder = $shell.Namespace(0xA)
                if ($rbFolder) {
                    foreach ($item in @($rbFolder.Items())) {
                        try {
                            if ($item.ModifyDate -and ([datetime]$item.ModifyDate) -lt $cutoff) {
                                $itemSize = 0
                                try { $itemSize = [long]$item.ExtendedProperty("Size") } catch { }
                                if ($itemSize -le 0 -and (Test-Path -LiteralPath $item.Path -ErrorAction SilentlyContinue)) {
                                    # 部分系统上文件夹项的 ExtendedProperty("Size") 取不到值，退化为文件系统递归测量兜底
                                    try { $itemSize = [FrostBladeWinAPI_v1]::GetDirectorySizeFast($item.Path) } catch { }
                                }
                                $totalRbSize += $itemSize
                                [void]$rbPaths.Add($item.Path)
                            }
                        } catch { }
                    }
                }
                Write-AsyncLog "  -> 回收站中 $rbMonths 个月前的项目占用: $([math]::Round($totalRbSize/1MB,2)) MB（共 $($rbPaths.Count) 项）"
            } catch {
                Write-AsyncLog "  -> [警告] 回收站按时间筛选扫描失败：$($_.Exception.Message)，本次按 0 处理，不影响其他清理项。"
            } finally {
                if ($rbFolder) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($rbFolder) }
                if ($shell) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
            }
        }

        [System.Threading.Monitor]::Enter($Sync)
        try {
            $Sync.ScanItems["RecycleBin"].Paths = $rbPaths | Select-Object -Unique
            $Sync.ScanItems["RecycleBin"].Size  = $totalRbSize
        } finally { [System.Threading.Monitor]::Exit($Sync) }
    }

    # RecycleBin 已在上方单独处理并精确赋值，不进此循环（GetDirectorySizeFast 无法穿透 $Recycle.Bin 权限保护，直接跑会返回 0 覆盖掉正确值）
    $miscKeys = @("DriverCache", "AdobeCache", "D3DSCache", "UWPAppCache", "ThumbCache", "WinUpdate", "MemoryDumps", "WinDiagLogs", "EventLogs",
                  "DeliveryOpt", "WindowsOld", "FontCache", "PrintSpool", "SearchIndex", "AspTemp",
                  "WindowsUpgradeLogs", "Prefetch", "WERFiles")
                  
    foreach ($k in $miscKeys) {
        if (-not $Sync.ScanItems[$k]) { continue }
        if ($k -eq "EventLogs" -and $Sync.ScanItems[$k].Checked) {
            Write-AsyncLog "  -> [注意] 事件日志文件清空后，物理文件可能不会立即缩小，实际释放空间可能少于扫描值。"
        }
        if (-not $Sync.ScanItems[$k].Checked) { continue }
        if ($Sync.CancelRequested) { break }
        [long]$sz = 0
        foreach ($p in $Sync.ScanItems[$k].Paths) {
            if (Test-Path -LiteralPath $p) {
                [long]$itemSize = 0
                if ((Get-Item -LiteralPath $p -ErrorAction SilentlyContinue).PSIsContainer) { $itemSize = Get-FolderSize $p } 
                else { $itemSize = (New-Object System.IO.FileInfo($p)).Length }
                $sz += $itemSize
                $mbSize = [math]::Round($itemSize / 1MB, 2)
                Write-AsyncLog "  -> [$($Sync.ScanItems[$k].Name)] 命中: $p (体积: $mbSize MB)"
            }
        }
        [System.Threading.Monitor]::Enter($Sync)
        try { $Sync.ScanItems[$k].Size = $sz } finally { [System.Threading.Monitor]::Exit($Sync) }
    }

    if ($Sync.ScanItems["VSSShadow"] -and $Sync.ScanItems["VSSShadow"].Checked) {
        Write-AsyncLog "  -> [系统还原点与卷影复制] 命中: 系统底层快照 (将通过 CIM/WMI 双轨清除)"
        [System.Threading.Monitor]::Enter($Sync)
        try { $Sync.ScanItems["VSSShadow"].Size = 0 } finally { [System.Threading.Monitor]::Exit($Sync) }
    }

    $Sync.Progress = 100
    if (-not $Sync.CancelRequested) { Write-AsyncLog "[SUCCESS] >>> 异步扫描分析完成！ <<<" }
    else { Write-AsyncLog "[中断] 扫描已被用户取消。" }
    
    $Sync.IsRunning = $false
}

# =====================================================================
# 6. 异步后台清理引擎 (ScriptBlock，运行于独立 Runspace)
#    SafeClean（robocopy 镜像清空 + 残留核查）、Remove-ItemRobust（MoveFileEx 计划重启删除兜底）、
#    按 ScanItems.Paths 执行真正的删除/takeown 提权等破坏性操作。
#    注意：这是全脚本风险最集中的模块，任何改动都应该优先复核，而不是顺手改。
# =====================================================================
$CleanScriptBlock = {
    param($Sync)
    
    function Write-AsyncLog([string]$msg) {
        $timestamp = Get-Date -Format "HH:mm:ss"
        $line = "[$timestamp] $msg"
        [void]$Sync.LogQueue.Add($line)
        [void]$Sync.FullLogHistory.Add($line)
    }

    Write-AsyncLog "[WARNING] >>> 后台深度清理引擎启动 <<<"
    $Sync.Progress = 5
    
    function SafeClean([string]$Path) {
        if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path) -or $Path.Length -le 3) { return }

        $itemInfo = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if ($null -eq $itemInfo) { return }

        # 目标本身是单个文件（例如 MEMORY.DMP），直接走单文件健壮删除
        if (-not $itemInfo.PSIsContainer) {
            $r = Remove-ItemRobust $Path
            if ($r -eq "scheduled") { Write-AsyncLog "  -> [占用-已计划重启删除] $Path" }
            elseif ($r -eq "failed") { Write-AsyncLog "  -> [占用/拦截] 无法删除: $Path" }
            return
        }

        # 第一轮：robocopy 镜像清空法（/XJ 跳过软链接与挂载点，避免误删外部目标；
        #          /MIR 对锁定文件只会跳过并继续处理其余文件，不会像管道删除那样整体中断；
        #          robocopy 原生支持远超 260 字符的深层路径，可兜底长路径删不掉的问题）
        if ($Global:FrostBladeRobocopyAvailable) {
            $emptyDir = Join-Path $env:TEMP ("FrostBladeEmpty_" + [guid]::NewGuid().ToString("N"))
            try {
                New-Item -ItemType Directory -Path $emptyDir -Force -ErrorAction SilentlyContinue | Out-Null
                $null = & robocopy.exe "`"$emptyDir`"" "`"$Path`"" /MIR /XJ /R:0 /W:0 /NFL /NDL /NJH /NJS /NP 2>$null
            } catch { }
            finally { try { Remove-Item -LiteralPath $emptyDir -Force -Recurse -ErrorAction SilentlyContinue } catch { } }
        }

        # 第二轮：手动栈式核查残留（跳过重分析点本身，不进入也不删除其指向的真实内容），
        #          逐项单独删除——不再因为某一个文件被占用就放弃同目录下的其它文件；
        #          仍删不掉的（被占用/锁定）转入 MoveFileEx 计划重启删除兜底。
        $remainFiles = New-Object System.Collections.Generic.List[string]
        $remainDirs  = New-Object System.Collections.Generic.List[string]
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($Path)
        while ($stack.Count -gt 0) {
            $cur = $stack.Pop()
            try {
                foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($cur)) {
                    try {
                        $attr = [System.IO.File]::GetAttributes($entry)
                        if ($attr -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                        if ($attr -band [System.IO.FileAttributes]::Directory) {
                            [void]$remainDirs.Add($entry)
                            [void]$stack.Push($entry)
                        } else {
                            [void]$remainFiles.Add($entry)
                        }
                    } catch { }
                }
            } catch { }
        }

        $deletedCount = 0; $scheduledCount = 0; $failedCount = 0
        foreach ($f in $remainFiles) {
            $r = Remove-ItemRobust $f
            switch ($r) { "deleted" { $deletedCount++ }; "scheduled" { $scheduledCount++ }; default { $failedCount++ } }
        }
        # 目录按路径长度倒序（先删最深层的子目录），尽量让父目录在子目录清空后也能被一并移除
        foreach ($d in ($remainDirs | Sort-Object { $_.Length } -Descending)) {
            if (-not (Test-Path -LiteralPath $d)) { continue }
            try { Remove-Item -LiteralPath $d -Force -ErrorAction Stop } catch { }
        }

        if ($scheduledCount -gt 0) { Write-AsyncLog "  -> [占用-已计划重启删除] $Path 下 $scheduledCount 个文件将在下次重启时自动清除" }
        if ($failedCount -gt 0)    { Write-AsyncLog "  -> [占用/拦截] $Path 下仍有 $failedCount 项无法处理" }
    }

    function Remove-ItemRobust([string]$FilePath) {
        # 返回 "deleted" / "scheduled"（已计划重启删除）/ "failed"
        try {
            Remove-Item -LiteralPath $FilePath -Force -ErrorAction Stop
            return "deleted"
        } catch {
            try {
                # MOVEFILE_DELAY_UNTIL_REBOOT = 4：登记到 PendingFileRenameOperations，下次重启时由系统自动删除
                $ok = [FrostBladeWinAPI_v1]::MoveFileEx($FilePath, $null, 4)
                if ($ok) { return "scheduled" } else { return "failed" }
            } catch { return "failed" }
        }
    }

    $Global:FrostBladeRobocopyAvailable = [bool](Get-Command robocopy.exe -ErrorAction SilentlyContinue)

    $totalKeys = $Sync.ScanItems.Keys.Count
    $step = 90 / $totalKeys
    $currProgress = 5

    foreach ($key in $Sync.ScanItems.Keys) {
        if ($Sync.CancelRequested) { break }
        $item = $Sync.ScanItems[$key]
        if ($item.Checked) {
            Write-AsyncLog "[清理] $($item.Name)..."
            if ($key -eq "RecycleBin") {
                $rbMonths = 0
                try { $rbMonths = [int]$Sync.RecycleBinMonths } catch { $rbMonths = 0 }
                if ($rbMonths -le 0) {
                    # 默认行为不变：整体清空，最快
                    [FrostBladeWinAPI_v1]::SHEmptyRecycleBin([IntPtr]::Zero, $null, 7) | Out-Null
                } else {
                    # 选择性清理：逐个删除扫描阶段圈定的项目，其余原样保留。双层兜底：优先 Remove-Item，
                    # 失败则退回 SHFileOperationDeleteSilent（带 FOF_SILENT|FOF_NOCONFIRMATION|FOF_NOERRORUI，
                    # 确保不弹出交互框卡住 -Silent 或后台清理线程）。
                    $rbFailCount = 0
                    foreach ($rp in $item.Paths) {
                        $removed = $false
                        try {
                            if (-not (Test-Path -LiteralPath $rp -ErrorAction SilentlyContinue)) {
                                $removed = $true
                            } else {
                                Remove-Item -LiteralPath $rp -Force -Recurse -ErrorAction Stop
                                $removed = $true
                            }
                        } catch {
                            try {
                                if ([FrostBladeWinAPI_v1]::SHFileOperationDeleteSilent($rp) -eq 0) { $removed = $true }
                            } catch { }
                        }
                        if (-not $removed) { $rbFailCount++ }
                    }
                    if ($rbFailCount -gt 0) { Write-AsyncLog "  -> [警告] 回收站选择性清理中有 $rbFailCount 项删除失败（可能仍被其他进程占用）。" }
                }
            } elseif ($key -eq "RegUninstall") {
                foreach ($p in $item.Paths) { 
                    try { Remove-Item -Path $p -Force -Recurse -Confirm:$false -ErrorAction Stop } 
                    catch { Write-AsyncLog "  -> [错误] 注册表项锁定: $($_.Exception.Message)" } 
                }
            } elseif ($key -eq "EmptyFolders" -or $key -eq "ThumbCache") {
                foreach ($p in $item.Paths) {
                    # ThumbCache 路径是具体 .db 文件，直接删；EmptyFolders 路径是目录，删除前二次确认为空
                    if ([System.IO.Directory]::Exists($p)) {
                        # 二次确认：扫描结束到执行清理之间目录状态可能已改变
                        try {
                            $stillEmpty = ([System.IO.Directory]::GetFileSystemEntries($p).Count -eq 0)
                        } catch { $stillEmpty = $false }
                        if (-not $stillEmpty) {
                            Write-AsyncLog "  -> [跳过] 目录已非空（状态已变化）: $p"
                            continue
                        }
                    }
                    # 故意不加 -Recurse：若目录非空则报错进入 catch，绝不会递归删除
                    $r = Remove-ItemRobust $p
                    if ($r -eq "scheduled") { Write-AsyncLog "  -> [占用-已计划重启删除] $p" }
                    elseif ($r -eq "failed") { Write-AsyncLog "  -> [占用/非空] 无法删除: $p" }
                }
            } elseif ($key -eq "EventLogs") {
                try {
                    $logNames = wevtutil el
                    foreach ($ln in $logNames) {
                        if ([string]::IsNullOrEmpty($ln) -or $ln.Trim().Length -eq 0) { continue }
                        try { wevtutil cl "$ln" 2>$null } catch { }
                    }
                } catch { Write-AsyncLog "  -> [跳过] 无法清空事件日志（权限不足）" }
            } elseif ($key -eq "VSSShadow") {
                if ($Sync.SkipVSSThisRun) {
                    Write-AsyncLog "  -> [跳过] 检测到本次已创建系统还原点，为避免自我销毁，本轮跳过卷影清理（下次运行不受影响）"
                    $currProgress += $step; $Sync.Progress = [int][math]::Min(98, [math]::Round($currProgress))
                    continue
                }
                $vssOk = $false
                try { 
                    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
                        $shadows = Get-CimInstance Win32_ShadowCopy -ErrorAction Stop
                        if ($shadows) { $shadows | ForEach-Object { Remove-CimInstance -InputObject $_ -ErrorAction Stop } }
                        $vssOk = $true
                    } else {
                        Get-WmiObject Win32_ShadowCopy -ErrorAction Stop | ForEach-Object { $_.Delete() | Out-Null }
                        $vssOk = $true
                    }
                } catch { Write-AsyncLog "  -> [CIM/WMI失败] 卷影清理转用 vssadmin 命令行兜底..." }
                if (-not $vssOk) {
                    try {
                        $vssOut = & vssadmin.exe delete shadows /all /quiet 2>&1
                        Write-AsyncLog "  -> [vssadmin兜底] 执行完成"
                    } catch { Write-AsyncLog "  -> [跳过] vssadmin 兜底同样失败（权限不足或服务未运行）" }
                }
            } elseif ($key -eq "WindowsOld" -or $key -eq "WindowsUpgradeLogs") {
                # Windows.old / $WINDOWS.~BT / $WINDOWS.~WS 内部分文件归属 TrustedInstaller，
                # 普通 Remove-Item 经常因权限不足只删掉一部分；先用 takeown/icacls 夺取所有权再清理。
                foreach ($p in $item.Paths) {
                    if (-not (Test-Path -LiteralPath $p)) { continue }
                    Write-AsyncLog "  -> [取所有权] 正在为 $p 授予删除权限（可能需要一些时间）..."
                    try {
                        & takeown.exe /F "$p" /R /D Y *> $null
                        & icacls.exe "$p" /grant "*S-1-5-32-544:F" /T /C /Q *> $null
                    } catch { Write-AsyncLog "  -> [警告] 取所有权过程出现异常: $($_.Exception.Message)" }
                    SafeClean $p
                    try {
                        if ((Test-Path -LiteralPath $p) -and ([System.IO.Directory]::GetFileSystemEntries($p).Count -eq 0)) {
                            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
                        }
                    } catch { }
                }
            } elseif ($key -eq "ResidualAppDirs") {
                # 应用残留残留目录：直接调用 SafeClean 逐个清理
                foreach ($p in $item.Paths) {
                    if (-not (Test-Path -LiteralPath $p)) { continue }
                    Write-AsyncLog "  -> [残留目录] 清理: $p"
                    SafeClean $p
                    try {
                        if ((Test-Path -LiteralPath $p) -and ([System.IO.Directory]::GetFileSystemEntries($p).Count -eq 0)) {
                            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
                        }
                    } catch { }
                }
            } elseif ($key -eq "WinSxSClean") {
                # DISM StartComponentCleanup：清理已被更新替代的旧版本组件，保留回滚能力
                Write-AsyncLog "  -> [DISM] 正在执行 /StartComponentCleanup（可能需要数分钟，请耐心等待）..."
                try {
                    $dismResult = & dism.exe /Online /Cleanup-Image /StartComponentCleanup 2>&1
                    $dismResult | ForEach-Object { Write-AsyncLog "  [DISM] $_" }
                    Write-AsyncLog "  -> [DISM] StartComponentCleanup 执行完毕"
                } catch {
                    Write-AsyncLog "  -> [DISM] 执行失败：$($_.Exception.Message)"
                }
            } elseif ($key -eq "WinSxSResetBase") {
                # DISM /ResetBase：彻底移除旧组件版本，释放最多空间，但不可逆——清理后无法卸载已安装的更新
                Write-AsyncLog "  -> [DISM] 正在执行 /StartComponentCleanup /ResetBase（不可逆操作，可能需要数分钟）..."
                try {
                    $dismResult = & dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1
                    $dismResult | ForEach-Object { Write-AsyncLog "  [DISM] $_" }
                    Write-AsyncLog "  -> [DISM] ResetBase 执行完毕（此后无法卸载已安装的系统更新）"
                } catch {
                    Write-AsyncLog "  -> [DISM] 执行失败：$($_.Exception.Message)"
                }
            } elseif ($key -eq "HibernateFile") {
                # powercfg /hibernate off：关闭休眠功能，系统自动删除 hiberfil.sys 并禁止重建
                Write-AsyncLog "  -> [powercfg] 正在关闭休眠功能并释放 hiberfil.sys..."
                try {
                    $pfOut = & powercfg.exe /hibernate off 2>&1
                    Start-Sleep -Milliseconds 1500
                    if (-not (Test-Path "$env:SystemDrive\hiberfil.sys")) {
                        Write-AsyncLog "  -> [powercfg] 休眠已关闭，hiberfil.sys 已删除"
                    } else {
                        Write-AsyncLog "  -> [powercfg] 命令已执行，文件可能需要重启后才会消失"
                    }
                } catch {
                    Write-AsyncLog "  -> [powercfg] 执行失败：$($_.Exception.Message)"
                }
            } elseif ($key -eq "CompactOS") {
                # compact /CompactOS:always：对系统文件启用 NTFS WofCompressed 压缩
                # 注意：SSD 上几乎没有性能损耗；HDD 上读写略有影响，脚本已在 UI 标红提醒
                Write-AsyncLog "  -> [compact] 正在执行 Compact OS 系统压缩（可能需要 5-20 分钟，请勿中断）..."
                try {
                    $compactOut = & compact.exe /CompactOS:always 2>&1
                    $compactOut | ForEach-Object { Write-AsyncLog "  [compact] $_" }
                    Write-AsyncLog "  -> [compact] Compact OS 压缩执行完毕"
                } catch {
                    Write-AsyncLog "  -> [compact] 执行失败：$($_.Exception.Message)"
                }
            } elseif ($key -eq "SearchIndex") {
                # Windows 搜索索引数据库在 WSearch 服务运行期间会被独占锁定，直接 SafeClean
                # 大概率悄悄失败或转入 MoveFileEx 延迟删除——用户看完成报告会以为已经清理，
                # 实际这块空间要等下次重启才真正释放。这里显式停服务再删，删完重新拉起服务。
                $svc = Get-Service -Name "WSearch" -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -eq "Running") {
                    Write-AsyncLog "  -> [服务] 正在停止 Windows Search 服务以释放索引文件锁定..."
                    try { Stop-Service -Name "WSearch" -Force -ErrorAction Stop; Start-Sleep -Milliseconds 800 }
                    catch { Write-AsyncLog "  -> [服务] 停止 WSearch 服务失败（可能权限不足），仍尝试直接删除: $($_.Exception.Message)" }
                }
                foreach ($p in $item.Paths) { SafeClean $p }
                if ($svc -and $svc.Status -eq "Running") {
                    try {
                        Start-Service -Name "WSearch" -ErrorAction Stop
                        Write-AsyncLog "  -> [服务] Windows Search 服务已重新启动（索引将在后台自动重建）"
                    } catch { Write-AsyncLog "  -> [服务] 重新启动 WSearch 服务失败，请手动启动该服务或重启电脑: $($_.Exception.Message)" }
                }
            } elseif ($key -eq "FontCache") {
                # 同理，字体缓存文件在 FontCache 服务运行期间也可能被占用。
                $fcSvc = Get-Service -Name "FontCache" -ErrorAction SilentlyContinue
                if ($fcSvc -and $fcSvc.Status -eq "Running") {
                    Write-AsyncLog "  -> [服务] 正在停止字体缓存服务以释放锁定..."
                    try { Stop-Service -Name "FontCache" -Force -ErrorAction Stop; Start-Sleep -Milliseconds 500 }
                    catch { Write-AsyncLog "  -> [服务] 停止 FontCache 服务失败，仍尝试直接删除: $($_.Exception.Message)" }
                }
                foreach ($p in $item.Paths) { SafeClean $p }
                if ($fcSvc -and $fcSvc.Status -eq "Running") {
                    try { Start-Service -Name "FontCache" -ErrorAction Stop }
                    catch { Write-AsyncLog "  -> [服务] 重新启动 FontCache 服务失败，字体缓存将在下次需要时自动重建: $($_.Exception.Message)" }
                }
            } else {
                foreach ($p in $item.Paths) { SafeClean $p }
            }
        }
        $currProgress += $step
        $Sync.Progress = [int][math]::Min(98, [math]::Round($currProgress))
    }

    $Sync.Progress = 100
    if (-not $Sync.CancelRequested) { Write-AsyncLog "[SUCCESS] >>> 深度清理完成！建议重启电脑 <<<" }
    else { Write-AsyncLog "[中断] 清理被用户取消。" }
    
    $Sync.IsRunning = $false
}

# Compact OS 还原脚本块：与 $CleanScriptBlock 相互独立，仅用于"取消系统压缩"这一单一操作，
# 复用相同的 Start-RunspaceJob + UITimer 机制，但不走 ScanItems 多项目遍历逻辑。
$CompactRevertScriptBlock = {
    param($Sync)
    function Write-AsyncLog([string]$msg) {
        $timestamp = Get-Date -Format "HH:mm:ss"
        $line = "[$timestamp] $msg"
        [void]$Sync.LogQueue.Add($line)
    }
    Write-AsyncLog "[WARNING] >>> 正在还原 Compact OS（取消系统压缩），请勿关闭窗口，可能需要几分钟 <<<"
    $Sync.Progress = 15
    try {
        $revertOut = & compact.exe /CompactOS:never 2>&1
        foreach ($line in $revertOut) { Write-AsyncLog "  [compact] $line" }
        $Sync.Progress = 90
        Write-AsyncLog "[SUCCESS] >>> Compact OS 已还原为未压缩状态。部分正在使用中的系统文件需重启后才能完全生效，建议重启电脑 <<<"
    } catch {
        Write-AsyncLog "[错误] 还原失败：$($_.Exception.Message)"
    }
    $Sync.Progress = 100
    $Sync.IsRunning = $false
}

# =====================================================================
# 7. 清理前置动作 (还原点 / 关闭占用进程)
#    从 GUI 按钮回调中提取为独立全局函数，不含任何 UI 交互，供 GUI 与 -Silent 共用同一套实现
#    ——GUI 侧负责弹窗确认，静默侧负责按参数决定是否调用。
# =====================================================================

function Get-PreCleanTargetProcessNames {
    # 根据当前 ScanItems 勾选状态，从 ProcessCloseMap 汇总出去重后的目标进程名列表
    # （只是"候选名单"，不代表这些进程当前正在运行）。GUI 确认弹窗与实际关闭动作共用这份名单，
    # 避免两处各写一份、后续漏改不同步。
    $targetNames = New-Object System.Collections.Generic.List[string]
    foreach ($mapKey in $Global:ProcessCloseMap.Keys) {
        if ($Global:SyncHash.ScanItems[$mapKey] -and $Global:SyncHash.ScanItems[$mapKey].Checked) {
            foreach ($pn in $Global:ProcessCloseMap[$mapKey]) { [void]$targetNames.Add($pn) }
        }
    }
    return @($targetNames | Select-Object -Unique)
}

function Invoke-PreCleanProcessTermination {
    # 按 Get-PreCleanTargetProcessNames 给出的名单，先礼后兵：CloseMainWindow() 优雅关闭，
    # 800ms 后仍存活的再 Stop-Process -Force。不包含任何弹窗/确认，调用方（GUI 或静默模式）
    # 自行决定是否需要在调用前征得用户同意。
    # 返回：实际检测到"正在运行"并尝试关闭过的进程名（去重）数组；无匹配或均未运行时返回空数组。
    $uniqueNames = Get-PreCleanTargetProcessNames
    if ($uniqueNames.Count -eq 0) { return @() }
    $runningProcs = Get-Process -Name $uniqueNames -ErrorAction SilentlyContinue
    if (-not $runningProcs) { return @() }
    $closedNames = @($runningProcs | Select-Object -ExpandProperty ProcessName -Unique)
    foreach ($p in $runningProcs) { try { [void]$p.CloseMainWindow() } catch { } }
    Start-Sleep -Milliseconds 800
    foreach ($p in (Get-Process -Name $uniqueNames -ErrorAction SilentlyContinue)) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
    Start-Sleep -Milliseconds 500
    return $closedNames
}

function Invoke-PreCleanRestorePoint {
    # 创建系统还原点，含 VSS 服务未启动时的兜底拉起逻辑。不包含任何弹窗，失败与否通过返回值告知调用方。
    # 返回 Hashtable: @{ Success = <bool>; Message = <string, 失败时为异常信息> }
    try {
        $srService = Get-Service -Name VSS -ErrorAction SilentlyContinue
        if ($srService -and $srService.Status -ne "Running") {
            Start-Service -Name VSS -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 800
        }
        Checkpoint-Computer -Description "霜刃 清理前自动备份 $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        return @{ Success = $true; Message = "" }
    } catch {
        return @{ Success = $false; Message = $_.Exception.Message }
    }
}

# =====================================================================
# 8. GUI 初始化与静默执行调度
#    WinForms 控件搭建、事件绑定、定时器轮询 SyncHash/LFSync 更新界面，调起第 4/5/6 节的 Runspace 任务。
# =====================================================================
if ($Silent) {
    # =====================================================================
    # 静默模式 (-Silent) 执行流：扫描 -> 哨兵校验 -> (可选)前置动作 -> 清理，无 UI 依赖。
    #
    # 用法示例：
    #   powershell -File FrostBlade.ps1 -Silent
    #   powershell -File FrostBlade.ps1 -Silent -CreateRestorePoint -ClosePrograms
    #   powershell -File FrostBlade.ps1 -Silent -RecycleBinMonths 6 -LogFile C:\Logs\frostblade.log
    #
    # 清理哪些项：沿用 $Global:ScanItems 各项的默认 Checked 状态（第 3 节），与 GUI 初始勾选一致
    # ——第一梯队(安全必清)默认开，第二/三梯队(可选/高危)默认关。如需静默清理覆盖高危项，
    # 需自行在文件顶部调整对应项的 Checked 值，不建议通过命令行参数临时打开，以免无人复核地重复执行。
    #
    # 退出码约定，供计划任务/自动化调用方判断执行结果：
    #   0 = 正常完成，且确实清理出了 > 0 的空间
    #   3 = 正常跑完，但未发现任何可清理内容（可能系统已很干净，也可能扫描异常，不算失败，
    #       但用不同于 0 的退出码告知调用方"这次没有实际效果"）
    #   1 = 运行时发生未处理异常（由文件顶部的 trap 兜底捕获并退出，不在这里设置）
    # =====================================================================

    function Write-SilentLog([string]$msg) {
        $timestamp = Get-Date -Format "HH:mm:ss"
        $line = "[$timestamp] $msg"
        Write-Host $line
        if ($LogFile) {
            # -LogFile 落盘失败（路径不可写、磁盘满等）不应中断清理流程，仅提示一次后续仅输出到控制台。
            try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop }
            catch {
                Write-Host "[$timestamp] [警告] 写入日志文件失败: $($_.Exception.Message)（后续仅输出到控制台）"
                $Script:LogFile = $null
            }
        }
    }

    function Invoke-SilentEngineJob([scriptblock]$ScriptBlock, [string]$JobName) {
        # 静默模式没有消息循环（不像 GUI 靠 ShowDialog 驱动 $UITimer 轮询 IsRunning/LogQueue），
        # 所以这里不能沿用 GUI 版 Start-RunspaceJob 的 BeginInvoke()+Timer 轮询方式（会直接卡死或立刻返回未完成的任务）。
        # 改为同步 Invoke()：跑完再一次性把 LogQueue 刷到控制台，语义上等价于"等这一步彻底跑完再进行下一步"。
        $Global:SyncHash.IsRunning = $true
        $Global:SyncHash.Progress = 0
        $Global:SyncHash.CancelRequested = $false

        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = "STA"
        $runspace.ThreadOptions = "ReuseThread"
        $runspace.Open()
        $runspace.SessionStateProxy.SetVariable("Sync", $Global:SyncHash)

        $ps = [powershell]::Create()
        $ps.Runspace = $runspace
        $ps.AddScript($ScriptBlock).AddArgument($Global:SyncHash) | Out-Null

        try {
            $ps.Invoke() | Out-Null
            if ($ps.Streams.Error.Count -gt 0) {
                foreach ($e in $ps.Streams.Error) { Write-SilentLog "[$JobName][运行时错误] $($e.Exception.Message)" }
            }
        } catch {
            Write-SilentLog "[$JobName][致命错误] $($_.Exception.Message)"
        } finally {
            while ($Global:SyncHash.LogQueue.Count -gt 0) {
                Write-SilentLog $Global:SyncHash.LogQueue[0]
                $Global:SyncHash.LogQueue.RemoveAt(0)
            }
            $ps.Dispose()
            $runspace.Close(); $runspace.Dispose()
            $Global:SyncHash.IsRunning = $false
        }
    }

    Write-SilentLog "[FrostBlade] 进入静默运行模式..."
    Write-SilentLog ("[FrostBlade] 前置动作：创建还原点={0}，关闭占用进程={1}（均需显式传参开启，默认与GUI未勾选状态一致）" -f $CreateRestorePoint.IsPresent, $ClosePrograms.IsPresent)
    $Global:SyncHash.RecycleBinMonths = $RecycleBinMonths
    if ($RecycleBinMonths -gt 0) { Write-SilentLog "[FrostBlade] 回收站清理范围：仅清理 $RecycleBinMonths 个月前删除的项目（默认是全部清空，此项由 -RecycleBinMonths 显式指定）。" }

    # 1. 扫描
    Write-SilentLog "[FrostBlade] 步骤 1/3：正在扫描..."
    Invoke-SilentEngineJob $ScanScriptBlock "扫描引擎"

    # 哨兵校验：记下扫描是否发现了可清理内容，避免"扫描其实什么都没扫到 -> 清理空跑一遍 -> 假成功"
    # 这种情况被调用方误判为正常；不阻止继续执行清理，只是最后用不同退出码告知调用方。
    [long]$preCleanTotal = 0
    foreach ($k in $Global:SyncHash.ScanItems.Keys) { if ($Global:SyncHash.ScanItems[$k].Checked) { $preCleanTotal += $Global:SyncHash.ScanItems[$k].Size } }
    if ($preCleanTotal -le 0) {
        Write-SilentLog "[FrostBlade] [提示] 本次扫描未发现任何可清理内容——可能是系统本来就很干净，也可能是扫描过程出现了异常（例如权限不足），脚本无法自动区分这两种情况，请留意上面的扫描日志确认。"
    }

    # 2. 前置动作（还原点 + 关闭占用进程），均为可选，默认不执行
    $Global:SyncHash.SkipVSSThisRun = $false
    if ($CreateRestorePoint) {
        if ($Global:SyncHash.ScanItems["VSSShadow"].Checked) {
            # 与 GUI 冲突检测弹窗给出的"推荐"选项保持同一结论：静默模式无法弹窗询问用户，
            # 默认选择"保护还原点"——本次运行自动跳过 VSSShadow 清理，避免刚创建的还原点
            # 马上被卷影清理一起删掉、白做保护（这里刻意不学 Gemini 补丁草稿里把该值设为 $false，
            # 那样等价于 GUI 弹窗里的"否/忽略警告"选项，会让还原点保护形同虚设）。
            $Global:SyncHash.SkipVSSThisRun = $true
            Write-SilentLog "[FrostBlade] 检测到 VSSShadow 清理项处于勾选状态，且已启用 -CreateRestorePoint：本次自动跳过 VSSShadow 清理以保留刚创建的还原点。"
        }
        Write-SilentLog "[FrostBlade] 步骤 2/3：正在创建系统还原点（可能需要 20-60 秒）..."
        $rpResult = Invoke-PreCleanRestorePoint
        if ($rpResult.Success) {
            Write-SilentLog "[FrostBlade] 还原点创建成功。"
        } else {
            Write-SilentLog "[FrostBlade] 还原点创建失败：$($rpResult.Message)（常见原因：C: 未开启系统保护，或 24 小时内已存在还原点）。继续执行清理。"
        }
    }
    if ($ClosePrograms) {
        Write-SilentLog "[FrostBlade] 正在关闭占用进程（如有，未保存的工作可能丢失）..."
        $closed = Invoke-PreCleanProcessTermination
        if ($closed.Count -gt 0) { Write-SilentLog "[FrostBlade] 已尝试关闭：$($closed -join ', ')" }
        else { Write-SilentLog "[FrostBlade] 未检测到需要关闭的目标进程。" }
    }

    # 3. 清理
    Write-SilentLog "[FrostBlade] 步骤 3/3：正在执行清理..."
    Invoke-SilentEngineJob $CleanScriptBlock "清理引擎"

    [long]$totalFreed = 0
    foreach ($k in $Global:ScanItems.Keys) { if ($Global:ScanItems[$k].Checked) { $totalFreed += $Global:ScanItems[$k].Size } }
    Write-SilentLog ("[FrostBlade] 静默清理执行完毕，预计释放约 {0:N2} GB。部分变更（休眠/Compact OS/组件存储等）需重启后完全生效。" -f ($totalFreed/1GB))

    if ($totalFreed -le 0) {
        Write-SilentLog "[FrostBlade] 退出码 3：本次运行没有产生实际清理效果（详见上方提示）。"
        exit 3
    }
    exit 0
} else {
    # --- UI 美化：统一的扁平按钮样式（去掉 Windows 默认的立体浮雕边框，加悬停反馈） ---
    function Get-FrostBladeShade([System.Drawing.Color]$Color, [double]$Factor) {
        [System.Drawing.Color]::FromArgb($Color.A, [int]($Color.R * $Factor), [int]($Color.G * $Factor), [int]($Color.B * $Factor))
    }
    function Set-FrostBladeButtonStyle {
        param([System.Windows.Forms.Button]$Btn, [System.Drawing.Color]$BackColor, [System.Drawing.Color]$ForeColor = [System.Drawing.Color]::White)
        $Btn.FlatStyle = "Flat"
        $Btn.Cursor = "Hand"
        $Btn.BackColor = $BackColor
        $Btn.ForeColor = $ForeColor
        $Btn.FlatAppearance.BorderSize = 1
        $Btn.FlatAppearance.BorderColor = Get-FrostBladeShade $BackColor 0.85
        $Btn.FlatAppearance.MouseOverBackColor = Get-FrostBladeShade $BackColor 0.92
        $Btn.FlatAppearance.MouseDownBackColor = Get-FrostBladeShade $BackColor 0.8
    }

    $MainForm = New-Object System.Windows.Forms.Form
    $MainForm.Text = "霜刃 FrostBlade v1.0"
    $MainForm.Size = New-Object System.Drawing.Size(900, 720)
    $MainForm.StartPosition = "CenterScreen"
    $MainForm.FormBorderStyle = "FixedSingle"
    $MainForm.MaximizeBox = $false
    $MainForm.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 248)

    $HeaderPanel = New-Object System.Windows.Forms.Panel; $HeaderPanel.Size = New-Object System.Drawing.Size(900, 70); $HeaderPanel.BackColor = [System.Drawing.Color]::FromArgb(43, 87, 154); $MainForm.Controls.Add($HeaderPanel)
    $HeaderAccent = New-Object System.Windows.Forms.Panel; $HeaderAccent.Location = New-Object System.Drawing.Point(0, 67); $HeaderAccent.Size = New-Object System.Drawing.Size(900, 3); $HeaderAccent.BackColor = [System.Drawing.Color]::FromArgb(90, 158, 232); $HeaderPanel.Controls.Add($HeaderAccent)
    $TitleLabel = New-Object System.Windows.Forms.Label; $TitleLabel.Font = New-Object System.Drawing.Font("微软雅黑", 14, [System.Drawing.FontStyle]::Bold); $TitleLabel.Text = "霜刃·垃圾清理工具 v1.0"; $TitleLabel.ForeColor = [System.Drawing.Color]::White; $TitleLabel.Location = New-Object System.Drawing.Point(20, 20); $TitleLabel.Size = New-Object System.Drawing.Size(550, 30); $HeaderPanel.Controls.Add($TitleLabel)
    $BigFileButton = New-Object System.Windows.Forms.Button; $BigFileButton.Text = "大文件扫描"; $BigFileButton.Font = New-Object System.Drawing.Font("微软雅黑", 9, [System.Drawing.FontStyle]::Bold); $BigFileButton.Location = New-Object System.Drawing.Point(710, 18); $BigFileButton.Size = New-Object System.Drawing.Size(160, 34); $HeaderPanel.Controls.Add($BigFileButton)
    Set-FrostBladeButtonStyle -Btn $BigFileButton -BackColor ([System.Drawing.Color]::FromArgb(74, 118, 179)) -ForeColor ([System.Drawing.Color]::White)


    $LeftPanel = New-Object System.Windows.Forms.Panel; $LeftPanel.Location = New-Object System.Drawing.Point(15, 85); $LeftPanel.Size = New-Object System.Drawing.Size(420, 520); $LeftPanel.BorderStyle = "FixedSingle"; $LeftPanel.BackColor = [System.Drawing.Color]::White; $MainForm.Controls.Add($LeftPanel)

    # $ToolbarPanel 承载"全选/取消"按钮与两个前置动作复选框，用不同底色 + 1px 分隔线
    # 与下方清理项列表区（$InnerPanel）区分开，纯视觉分区，不影响下方任何业务逻辑。
    $ToolbarPanel = New-Object System.Windows.Forms.Panel; $ToolbarPanel.Location = New-Object System.Drawing.Point(0, 0); $ToolbarPanel.Size = New-Object System.Drawing.Size(418, 96); $ToolbarPanel.BackColor = [System.Drawing.Color]::FromArgb(222, 232, 244); $LeftPanel.Controls.Add($ToolbarPanel)
    $ToolbarDivider = New-Object System.Windows.Forms.Panel; $ToolbarDivider.Location = New-Object System.Drawing.Point(0, 96); $ToolbarDivider.Size = New-Object System.Drawing.Size(418, 1); $ToolbarDivider.BackColor = [System.Drawing.Color]::FromArgb(190, 202, 218); $LeftPanel.Controls.Add($ToolbarDivider)

    $BtnAll = New-Object System.Windows.Forms.Button; $BtnAll.Text = "全选"; $BtnAll.Size = New-Object System.Drawing.Size(60,25); $BtnAll.Location = New-Object System.Drawing.Point(5,5); $ToolbarPanel.Controls.Add($BtnAll)
    Set-FrostBladeButtonStyle -Btn $BtnAll -BackColor ([System.Drawing.Color]::White) -ForeColor ([System.Drawing.Color]::FromArgb(43, 87, 154))
    $BtnNone = New-Object System.Windows.Forms.Button; $BtnNone.Text = "取消"; $BtnNone.Size = New-Object System.Drawing.Size(60,25); $BtnNone.Location = New-Object System.Drawing.Point(70,5); $ToolbarPanel.Controls.Add($BtnNone)
    Set-FrostBladeButtonStyle -Btn $BtnNone -BackColor ([System.Drawing.Color]::White) -ForeColor ([System.Drawing.Color]::FromArgb(43, 87, 154))
    $AutoCloseChk = New-Object System.Windows.Forms.CheckBox; $AutoCloseChk.Text = "清理前自动关闭占用进程(微信/QQ/浏览器等)"; $AutoCloseChk.Font = New-Object System.Drawing.Font("微软雅黑", 8); $AutoCloseChk.ForeColor = [System.Drawing.Color]::DarkSlateGray; $AutoCloseChk.BackColor = [System.Drawing.Color]::Transparent; $AutoCloseChk.Checked = $false; $AutoCloseChk.Location = New-Object System.Drawing.Point(5, 33); $AutoCloseChk.Size = New-Object System.Drawing.Size(405, 18); $ToolbarPanel.Controls.Add($AutoCloseChk)
    $RestorePointChk = New-Object System.Windows.Forms.CheckBox; $RestorePointChk.Text = "清理前自动创建系统还原点(仅保护系统设置/系统文件级操作)"; $RestorePointChk.Font = New-Object System.Drawing.Font("微软雅黑", 8); $RestorePointChk.ForeColor = [System.Drawing.Color]::DarkSlateGray; $RestorePointChk.BackColor = [System.Drawing.Color]::Transparent; $RestorePointChk.Checked = $false; $RestorePointChk.Location = New-Object System.Drawing.Point(5, 53); $RestorePointChk.Size = New-Object System.Drawing.Size(405, 18); $ToolbarPanel.Controls.Add($RestorePointChk)
    # 系统还原点自 Win8 起不再备份个人文件，只能保护系统文件/注册表/驱动等系统级变更，
    # 对微信媒体/浏览器缓存/残留目录等用户数据类清理项无法起到恢复作用，用 Tooltip 明确告知。
    $RPTip = New-Object System.Windows.Forms.ToolTip
    $RPTip.AutoPopDelay = 15000; $RPTip.InitialDelay = 300; $RPTip.ReshowDelay = 100
    $RPTip.SetToolTip($RestorePointChk, "系统还原点只能回滚系统设置/系统文件/注册表相关的变更（如 WinSxS 压缩、Compact OS、休眠开关等），`r`n不会恢复被清理掉的个人文件——微信媒体、浏览器缓存、残留目录等一旦删除，还原点无法找回，请务必单独确认。")

    # 回收站清理范围：默认"全部清空"；选其余选项后，清理项列表中"回收站"仅清理早于所选月数的内容。
    $RBScopeLabel = New-Object System.Windows.Forms.Label; $RBScopeLabel.Text = "回收站清理范围:"; $RBScopeLabel.Font = New-Object System.Drawing.Font("微软雅黑", 8); $RBScopeLabel.ForeColor = [System.Drawing.Color]::DarkSlateGray; $RBScopeLabel.BackColor = [System.Drawing.Color]::Transparent; $RBScopeLabel.Location = New-Object System.Drawing.Point(5, 75); $RBScopeLabel.Size = New-Object System.Drawing.Size(95, 18); $ToolbarPanel.Controls.Add($RBScopeLabel)
    $RBScopeCombo = New-Object System.Windows.Forms.ComboBox; $RBScopeCombo.DropDownStyle = "DropDownList"; $RBScopeCombo.Font = New-Object System.Drawing.Font("微软雅黑", 8); $RBScopeCombo.Location = New-Object System.Drawing.Point(100, 72); $RBScopeCombo.Size = New-Object System.Drawing.Size(160, 20); $ToolbarPanel.Controls.Add($RBScopeCombo)
    $RBScopeMonthsMap = @(0, 3, 6, 12)
    foreach ($t in @("全部清空(默认)", "仅清 3 个月前", "仅清 6 个月前", "仅清 12 个月前")) { [void]$RBScopeCombo.Items.Add($t) }
    $RBScopeCombo.SelectedIndex = 0
    $RBScopeCombo.Add_SelectedIndexChanged({
        $Global:SyncHash.RecycleBinMonths = $RBScopeMonthsMap[$RBScopeCombo.SelectedIndex]
        # 范围一变，之前扫描出来的"回收站"大小/项目清单就不再准确，标记 Stale 强制要求重新扫描后才能清理，
        # 跟勾选框改变时的处理方式保持一致。
        if ($Global:SyncHash.ScanItems["RecycleBin"]) { $Global:SyncHash.ScanItems["RecycleBin"].Stale = $true }
    })
    $RBScopeTip = New-Object System.Windows.Forms.ToolTip
    $RBScopeTip.AutoPopDelay = 15000; $RBScopeTip.InitialDelay = 300; $RBScopeTip.ReshowDelay = 100
    $RBScopeTip.SetToolTip($RBScopeCombo, "选择「全部清空」以外的选项时，只会删除回收站里删除时间早于所选月数的项目，其余保留；改动后需要重新扫描一次才能得到准确大小。")

    $InnerPanel = New-Object System.Windows.Forms.Panel; $InnerPanel.Location = New-Object System.Drawing.Point(0, 97); $InnerPanel.Size = New-Object System.Drawing.Size(420, 423); $InnerPanel.AutoScroll = $true; $InnerPanel.BackColor = [System.Drawing.Color]::White; $LeftPanel.Controls.Add($InnerPanel)

    $ControlsMap = @{}
    $YOffset = 0
    foreach ($Key in $KeyList) {
        $Item = $Global:SyncHash.ScanItems[$Key]
        $CheckBox = New-Object System.Windows.Forms.CheckBox; $CheckBox.Text = $Item.Name; $CheckBox.Font = New-Object System.Drawing.Font("微软雅黑", 9); $CheckBox.Checked = $Item.Checked; $CheckBox.Location = New-Object System.Drawing.Point(5, $YOffset); $CheckBox.Size = New-Object System.Drawing.Size(280, 20); $CheckBox.Tag = $Key
        
        if ($Global:HighRiskKeys -contains $Key) { $CheckBox.ForeColor = [System.Drawing.Color]::Red }
        
        $CheckBox.Add_CheckedChanged({
            $Global:SyncHash.ScanItems[$this.Tag].Checked = $this.Checked
            # 勾选动作本身就意味着"这个状态还没被扫描引擎验证过"，统一标记为待重新扫描；
            # 取消勾选则不用管 Stale——反正 CleanEngine 只处理 Checked=true 的项，未勾选的项本来就不会被清理。
            if ($this.Checked) { $Global:SyncHash.ScanItems[$this.Tag].Stale = $true }
        })
        $InnerPanel.Controls.Add($CheckBox)

        $SizeLabel = New-Object System.Windows.Forms.Label; $SizeLabel.Text = "0.00 MB"; $SizeLabel.Font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold); $SizeLabel.Location = New-Object System.Drawing.Point(285, $YOffset); $SizeLabel.Size = New-Object System.Drawing.Size(100, 20); $SizeLabel.TextAlign = "MiddleRight"
        $InnerPanel.Controls.Add($SizeLabel)
        $ControlsMap[$Key] = @{ CheckBox=$CheckBox; Label=$SizeLabel }
        $YOffset += 25

        if ($Key -eq "CompactOS") {
            # Compact OS 是可逆操作（compact.exe /CompactOS:never），独立加一个还原按钮直接跑
            # $CompactRevertScriptBlock，与勾选框/深度清理流程无关，不需要先勾选也不需要点"深度清理"。
            $RevertCompactBtn = New-Object System.Windows.Forms.Button
            $RevertCompactBtn.Text = "↩ 还原压缩(取消 Compact OS)"
            $RevertCompactBtn.Font = New-Object System.Drawing.Font("微软雅黑", 8)
            $RevertCompactBtn.Location = New-Object System.Drawing.Point(20, $YOffset)
            $RevertCompactBtn.Size = New-Object System.Drawing.Size(200, 22)
            $InnerPanel.Controls.Add($RevertCompactBtn)
            Set-FrostBladeButtonStyle -Btn $RevertCompactBtn -BackColor ([System.Drawing.Color]::FromArgb(120, 130, 200)) -ForeColor ([System.Drawing.Color]::White)
            $RevertCompactTip = New-Object System.Windows.Forms.ToolTip
            $RevertCompactTip.SetToolTip($RevertCompactBtn, "独立执行 compact.exe /CompactOS:never，把系统还原为压缩前的状态。`r`n可逆操作，不删除任何文件，可能需要几分钟，完成后建议重启电脑使更改完全生效。")
            $YOffset += 26
        }
    }

    $BtnAll.Add_Click({ foreach ($k in $KeyList) { if ($Global:HighRiskKeys -contains $k) { continue }; $ControlsMap[$k].CheckBox.Checked = $true } })
    $BtnNone.Add_Click({ foreach ($k in $KeyList) { $ControlsMap[$k].CheckBox.Checked = $false } })

    $LogBox = New-Object System.Windows.Forms.TextBox; $LogBox.Multiline = $true; $LogBox.ScrollBars = "Vertical"; $LogBox.ReadOnly = $true; $LogBox.BorderStyle = "FixedSingle"; $LogBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30); $LogBox.ForeColor = [System.Drawing.Color]::LimeGreen; $LogBox.Font = New-Object System.Drawing.Font("Consolas", 9.5); $LogBox.Location = New-Object System.Drawing.Point(445, 85); $LogBox.Size = New-Object System.Drawing.Size(425, 520); $LogBox.Text = "==================================================`r`n欢迎使用 霜刃 FrostBlade v1.0`r`n> 纯内存解析 (Zero I/O)`r`n> Runspace 内存防护池启动`r`n> CIM/WMI 双轨接口就绪`r`n==================================================`r`n[提示] 清理项含启发式判断与不可逆操作，建议清理前逐项核对红色高危项。"; $MainForm.Controls.Add($LogBox)
    
    $TotalLabel = New-Object System.Windows.Forms.Label; $TotalLabel.Text = "预计可释放: 0.00 GB"; $TotalLabel.Font = New-Object System.Drawing.Font("微软雅黑", 11, [System.Drawing.FontStyle]::Bold); $TotalLabel.ForeColor = [System.Drawing.Color]::FromArgb(43, 87, 154); $TotalLabel.Location = New-Object System.Drawing.Point(15, 612); $TotalLabel.Size = New-Object System.Drawing.Size(400, 25); $MainForm.Controls.Add($TotalLabel)
    $ProgressBar = New-Object System.Windows.Forms.ProgressBar; $ProgressBar.Location = New-Object System.Drawing.Point(15, 640); $ProgressBar.Size = New-Object System.Drawing.Size(420, 14); $MainForm.Controls.Add($ProgressBar)
    $StatusLabel = New-Object System.Windows.Forms.Label; $StatusLabel.Text = "就绪"; $StatusLabel.Font = New-Object System.Drawing.Font("微软雅黑", 8); $StatusLabel.ForeColor = [System.Drawing.Color]::Gray; $StatusLabel.Location = New-Object System.Drawing.Point(15, 657); $StatusLabel.Size = New-Object System.Drawing.Size(420, 16); $MainForm.Controls.Add($StatusLabel)

    $ScanButton = New-Object System.Windows.Forms.Button; $ScanButton.Text = "深度扫描分析"; $ScanButton.Font = New-Object System.Drawing.Font("微软雅黑", 10, [System.Drawing.FontStyle]::Bold); $ScanButton.Location = New-Object System.Drawing.Point(445, 615); $ScanButton.Size = New-Object System.Drawing.Size(140, 55); $MainForm.Controls.Add($ScanButton)
    Set-FrostBladeButtonStyle -Btn $ScanButton -BackColor ([System.Drawing.Color]::FromArgb(59, 130, 246)) -ForeColor ([System.Drawing.Color]::White)
    $CleanButton = New-Object System.Windows.Forms.Button; $CleanButton.Text = "执行深度清理"; $CleanButton.Font = New-Object System.Drawing.Font("微软雅黑", 10, [System.Drawing.FontStyle]::Bold); $CleanButton.Location = New-Object System.Drawing.Point(595, 615); $CleanButton.Size = New-Object System.Drawing.Size(140, 55); $CleanButton.Enabled = $false; $MainForm.Controls.Add($CleanButton)
    Set-FrostBladeButtonStyle -Btn $CleanButton -BackColor ([System.Drawing.Color]::FromArgb(220, 53, 69)) -ForeColor ([System.Drawing.Color]::White)
    $ExportButton = New-Object System.Windows.Forms.Button; $ExportButton.Text = "导出日志"; $ExportButton.Font = New-Object System.Drawing.Font("微软雅黑", 9, [System.Drawing.FontStyle]::Bold); $ExportButton.Location = New-Object System.Drawing.Point(745, 615); $ExportButton.Size = New-Object System.Drawing.Size(125, 55); $MainForm.Controls.Add($ExportButton)
    Set-FrostBladeButtonStyle -Btn $ExportButton -BackColor ([System.Drawing.Color]::FromArgb(233, 236, 239)) -ForeColor ([System.Drawing.Color]::FromArgb(73, 80, 87))

    function Refresh-GUI-Labels {
        [System.Threading.Monitor]::Enter($Global:SyncHash)
        try {
            [long]$TotalBytes = 0
            foreach ($Key in $KeyList) {
                $Bytes = $Global:SyncHash.ScanItems[$Key].Size
                $Label = $ControlsMap[$Key].Label
                if ($Global:SyncHash.ScanItems[$Key].Checked) { $TotalBytes += $Bytes }
                if ($Bytes -eq 0) { $Label.Text = "0.00 MB"; $Label.ForeColor = [System.Drawing.Color]::Gray }
                elseif ($Bytes -ge 1GB) { $Label.Text = "$([math]::Round($Bytes/1GB,2)) GB"; $Label.ForeColor = [System.Drawing.Color]::Red }
                else { $Label.Text = "$([math]::Round($Bytes/1MB,2)) MB"; $Label.ForeColor = [System.Drawing.Color]::DarkOrange }
            }
            $TotalLabel.Text = "预计可释放: $([math]::Round($TotalBytes/1GB,2)) GB"
        } finally { [System.Threading.Monitor]::Exit($Global:SyncHash) }
    }

    $UITimer = New-Object System.Windows.Forms.Timer
    $UITimer.Interval = 100 
    $UITimer.Add_Tick({
        [int]$targetVal = [math]::Round($Global:SyncHash.Progress)
        if ($targetVal -lt 0) { $targetVal = 0 }
        if ($targetVal -gt 100) { $targetVal = 100 }
        if ($ProgressBar.Value -ne $targetVal) { $ProgressBar.Value = $targetVal }
        
        while ($Global:SyncHash.LogQueue.Count -gt 0) {
            $LogBox.AppendText("`r`n" + $Global:SyncHash.LogQueue[0])
            $Global:SyncHash.LogQueue.RemoveAt(0)
            $LogBox.SelectionStart = $LogBox.TextLength; $LogBox.ScrollToCaret()
        }
        
        if (-not $Global:SyncHash.IsRunning) {
            $UITimer.Stop()
            $ProgressBar.Value = 100
            $StatusLabel.Text = "就绪"; $StatusLabel.ForeColor = [System.Drawing.Color]::Gray
            $ScanButton.Enabled = $true; $CleanButton.Enabled = $true; if ($null -ne $RevertCompactBtn) { $RevertCompactBtn.Enabled = $true }
            Refresh-GUI-Labels
            
            if ($null -ne $Global:SyncHash.ActivePS) { $Global:SyncHash.ActivePS.Dispose(); $Global:SyncHash.ActivePS = $null }
            if ($null -ne $Global:SyncHash.ActiveRS) { $Global:SyncHash.ActiveRS.Close(); $Global:SyncHash.ActiveRS.Dispose(); $Global:SyncHash.ActiveRS = $null }
            $Global:SyncHash.ActiveResult = $null
            [System.GC]::Collect()
        } elseif ($null -ne $Global:SyncHash.ActiveResult -and $Global:SyncHash.ActiveResult.IsCompleted) {
            # Runspace 已完成（包含异常崩溃退出），但 $Sync.IsRunning 未被重置为 $false
            $Global:SyncHash.IsRunning = $false
            $UITimer.Stop()
            $ProgressBar.Value = 0
            $StatusLabel.Text = "任务异常终止，已强制回收"; $StatusLabel.ForeColor = [System.Drawing.Color]::OrangeRed
            $ScanButton.Enabled = $true; $CleanButton.Enabled = $true; if ($null -ne $RevertCompactBtn) { $RevertCompactBtn.Enabled = $true }
            Refresh-GUI-Labels
            if ($null -ne $Global:SyncHash.ActivePS) { 
                try { $errs = $Global:SyncHash.ActivePS.Streams.Error; if ($errs.Count -gt 0) { $LogBox.AppendText("`r`n[!] 后台异常: $($errs[0].Exception.Message)") } } catch { }
                $Global:SyncHash.ActivePS.Dispose(); $Global:SyncHash.ActivePS = $null 
            }
            if ($null -ne $Global:SyncHash.ActiveRS) { $Global:SyncHash.ActiveRS.Close(); $Global:SyncHash.ActiveRS.Dispose(); $Global:SyncHash.ActiveRS = $null }
            $Global:SyncHash.ActiveResult = $null
            [System.GC]::Collect()
        }
    })

    function Start-RunspaceJob([scriptblock]$ScriptBlock) {
        $Global:SyncHash.IsRunning = $true
        $Global:SyncHash.Progress = 0
        $Global:SyncHash.CancelRequested = $false
        $UITimer.Start()

        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = "STA"
        $runspace.ThreadOptions = "ReuseThread"
        $runspace.Open()
        $runspace.SessionStateProxy.SetVariable("Sync", $Global:SyncHash)

        $ps = [powershell]::Create()
        $ps.Runspace = $runspace
        $ps.AddScript($ScriptBlock).AddArgument($Global:SyncHash) | Out-Null
        
        $Global:SyncHash.ActiveRS = $runspace
        $Global:SyncHash.ActivePS = $ps
        $Global:SyncHash.ActiveResult = $ps.BeginInvoke()
    }

    $ScanButton.Add_Click({
        $ScanButton.Enabled = $false; $CleanButton.Enabled = $false; if ($null -ne $RevertCompactBtn) { $RevertCompactBtn.Enabled = $false }
        Start-RunspaceJob $ScanScriptBlock
    })

    $RevertCompactBtn.Add_Click({
        if ($Global:SyncHash.IsRunning) { return }
        $rc = [System.Windows.Forms.MessageBox]::Show(
            "即将执行 compact.exe /CompactOS:never，将系统还原为压缩前的状态。`r`n此操作可逆、不会删除任何文件，但可能需要几分钟，且部分正在使用中的系统文件需重启后才能完全生效。是否继续？",
            "还原 Compact OS", "YesNo", "Question")
        if ($rc -ne "Yes") { return }
        $ScanButton.Enabled = $false; $CleanButton.Enabled = $false; $RevertCompactBtn.Enabled = $false
        Start-RunspaceJob $CompactRevertScriptBlock
    })

    function Show-ResidualPreview {
        # 残留目录清理属于启发式判定，误判代价高（可能命中未在注册表登记的绿色/便携软件）。
        # 在真正 SafeClean 之前，展示逐项路径/大小/最后写入时间供用户勾选确认；
        # 只影响本轮 ScanItems["ResidualAppDirs"].Paths，不改变主界面的勾选框状态。
        $details = @($Global:SyncHash.ResidualDetails)
        if ($details.Count -eq 0) { return }

        $RPForm = New-Object System.Windows.Forms.Form
        $RPForm.Text = "残留目录清理确认 - 启发式识别结果可能不准确，请逐项核对"
        $RPForm.Size = New-Object System.Drawing.Size(820, 560)
        $RPForm.StartPosition = "CenterParent"
        $RPForm.FormBorderStyle = "FixedDialog"
        $RPForm.MaximizeBox = $false; $RPForm.MinimizeBox = $false

        $HintLabel = New-Object System.Windows.Forms.Label
        $HintLabel.Text = "以下目录满足『未匹配到注册表/快捷方式/服务/进程证据 + 90天内无写入 + 无卸载器文件名』的启发式规则，`r`n被判定为疑似已卸载软件残留，但并非 100% 准确 —— 尤其可能误判长期不更新的便携版/绿色软件。`r`n请核对路径，不确定的请取消勾选后再删除。"
        $HintLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 0, 0)
        $HintLabel.Location = New-Object System.Drawing.Point(10, 10)
        $HintLabel.Size = New-Object System.Drawing.Size(790, 46)
        $RPForm.Controls.Add($HintLabel)

        $RPList = New-Object System.Windows.Forms.ListView
        $RPList.View = "Details"; $RPList.CheckBoxes = $true; $RPList.FullRowSelect = $true; $RPList.GridLines = $true
        $RPList.Location = New-Object System.Drawing.Point(10, 60); $RPList.Size = New-Object System.Drawing.Size(790, 395)
        [void]$RPList.Columns.Add("路径", 520)
        [void]$RPList.Columns.Add("大小", 100)
        [void]$RPList.Columns.Add("最后写入", 120)
        foreach ($d in ($details | Sort-Object { [long]$_.Size } -Descending)) {
            $li = New-Object System.Windows.Forms.ListViewItem($d.Path)
            [void]$li.SubItems.Add(("{0:N2} MB" -f ($d.Size / 1MB)))
            [void]$li.SubItems.Add($d.LastWrite)
            $li.Checked = $true
            $li.Tag = $d.Path
            [void]$RPList.Items.Add($li)
        }
        $RPForm.Controls.Add($RPList)

        $BtnPanel = New-Object System.Windows.Forms.Panel
        $BtnPanel.Location = New-Object System.Drawing.Point(10, 462); $BtnPanel.Size = New-Object System.Drawing.Size(790, 50)
        $RPForm.Controls.Add($BtnPanel)
        $RPSelAll = New-Object System.Windows.Forms.Button; $RPSelAll.Text = "全选"; $RPSelAll.Location = New-Object System.Drawing.Point(0, 10); $RPSelAll.Size = New-Object System.Drawing.Size(70, 30); $BtnPanel.Controls.Add($RPSelAll)
        $RPSelNone = New-Object System.Windows.Forms.Button; $RPSelNone.Text = "全不选"; $RPSelNone.Location = New-Object System.Drawing.Point(80, 10); $RPSelNone.Size = New-Object System.Drawing.Size(70, 30); $BtnPanel.Controls.Add($RPSelNone)
        $RPSelAll.Add_Click({ foreach ($it in $RPList.Items) { $it.Checked = $true } })
        $RPSelNone.Add_Click({ foreach ($it in $RPList.Items) { $it.Checked = $false } })

        $RPConfirm = New-Object System.Windows.Forms.Button
        $RPConfirm.Text = "确认删除勾选项"
        $RPConfirm.Location = New-Object System.Drawing.Point(560, 10); $RPConfirm.Size = New-Object System.Drawing.Size(120, 30)
        $RPConfirm.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $BtnPanel.Controls.Add($RPConfirm)
        Set-FrostBladeButtonStyle -Btn $RPConfirm -BackColor ([System.Drawing.Color]::FromArgb(220, 53, 69)) -ForeColor ([System.Drawing.Color]::White)
        $RPCancel = New-Object System.Windows.Forms.Button
        $RPCancel.Text = "跳过残留目录清理"; $RPCancel.Location = New-Object System.Drawing.Point(690, 10); $RPCancel.Size = New-Object System.Drawing.Size(110, 30)
        $RPCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $BtnPanel.Controls.Add($RPCancel)
        Set-FrostBladeButtonStyle -Btn $RPCancel -BackColor ([System.Drawing.Color]::FromArgb(233, 236, 239)) -ForeColor ([System.Drawing.Color]::FromArgb(73, 80, 87))
        $RPForm.AcceptButton = $RPConfirm
        $RPForm.CancelButton = $RPCancel

        $dr = $RPForm.ShowDialog($MainForm)
        if ($dr -ne [System.Windows.Forms.DialogResult]::OK) {
            # 用户取消：本轮跳过残留目录清理，不影响其它已勾选项继续执行
            $Global:SyncHash.ScanItems["ResidualAppDirs"].Paths = @()
            return
        }
        $confirmed = New-Object System.Collections.Generic.List[string]
        foreach ($it in $RPList.Items) { if ($it.Checked) { [void]$confirmed.Add([string]$it.Tag) } }
        $Global:SyncHash.ScanItems["ResidualAppDirs"].Paths = @($confirmed)
    }

    function Show-RegUninstallPreview {
        # RegUninstall 原来是"判定失效即删"，没有预览。InstallLocation 为空的记录本身已被过滤掉，
        # 但路径暂时不可达（比如安装在 USB/网络驱动器，当前恰好没插/没连）同样会被判定为"失效"，
        # 直接删掉这个卸载注册表项之后，即便原程序目录后续又出现，用户也无法再通过控制面板正常卸载它了。
        # 这里同样在真正 Remove-Item 之前给一次逐项确认的机会。
        $details = @($Global:SyncHash.RegUninstallDetails)
        if ($details.Count -eq 0) { return }

        $RUForm = New-Object System.Windows.Forms.Form
        $RUForm.Text = "注册表失效卸载项确认 - 路径暂时不可达也会被判定为失效，请逐项核对"
        $RUForm.Size = New-Object System.Drawing.Size(820, 560)
        $RUForm.StartPosition = "CenterParent"
        $RUForm.FormBorderStyle = "FixedDialog"
        $RUForm.MaximizeBox = $false; $RUForm.MinimizeBox = $false

        $RUHint = New-Object System.Windows.Forms.Label
        $RUHint.Text = "以下注册表卸载项记录的安装路径（InstallLocation）当前不存在，可能是软件确已卸载残留、`r`n也可能是安装在 USB/移动硬盘/网络驱动器等暂时不可达的位置。删除后将无法再通过控制面板卸载该软件。`r`n请核对安装路径，不确定的请取消勾选后再删除。"
        $RUHint.ForeColor = [System.Drawing.Color]::FromArgb(160, 0, 0)
        $RUHint.Location = New-Object System.Drawing.Point(10, 10)
        $RUHint.Size = New-Object System.Drawing.Size(790, 46)
        $RUForm.Controls.Add($RUHint)

        $RUList = New-Object System.Windows.Forms.ListView
        $RUList.View = "Details"; $RUList.CheckBoxes = $true; $RUList.FullRowSelect = $true; $RUList.GridLines = $true
        $RUList.Location = New-Object System.Drawing.Point(10, 60); $RUList.Size = New-Object System.Drawing.Size(790, 395)
        [void]$RUList.Columns.Add("显示名称", 260)
        [void]$RUList.Columns.Add("记录的安装路径", 380)
        foreach ($d in ($details | Sort-Object { $_.DisplayName })) {
            $li = New-Object System.Windows.Forms.ListViewItem($d.DisplayName)
            [void]$li.SubItems.Add($d.InstallLocation)
            $li.Checked = $true
            $li.Tag = $d.PSPath
            [void]$RUList.Items.Add($li)
        }
        $RUForm.Controls.Add($RUList)

        $RUBtnPanel = New-Object System.Windows.Forms.Panel
        $RUBtnPanel.Location = New-Object System.Drawing.Point(10, 462); $RUBtnPanel.Size = New-Object System.Drawing.Size(790, 50)
        $RUForm.Controls.Add($RUBtnPanel)
        $RUSelAll = New-Object System.Windows.Forms.Button; $RUSelAll.Text = "全选"; $RUSelAll.Location = New-Object System.Drawing.Point(0, 10); $RUSelAll.Size = New-Object System.Drawing.Size(70, 30); $RUBtnPanel.Controls.Add($RUSelAll)
        $RUSelNone = New-Object System.Windows.Forms.Button; $RUSelNone.Text = "全不选"; $RUSelNone.Location = New-Object System.Drawing.Point(80, 10); $RUSelNone.Size = New-Object System.Drawing.Size(70, 30); $RUBtnPanel.Controls.Add($RUSelNone)
        $RUSelAll.Add_Click({ foreach ($it in $RUList.Items) { $it.Checked = $true } })
        $RUSelNone.Add_Click({ foreach ($it in $RUList.Items) { $it.Checked = $false } })

        $RUConfirm = New-Object System.Windows.Forms.Button
        $RUConfirm.Text = "确认删除勾选项"
        $RUConfirm.Location = New-Object System.Drawing.Point(560, 10); $RUConfirm.Size = New-Object System.Drawing.Size(120, 30)
        $RUConfirm.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $RUBtnPanel.Controls.Add($RUConfirm)
        Set-FrostBladeButtonStyle -Btn $RUConfirm -BackColor ([System.Drawing.Color]::FromArgb(220, 53, 69)) -ForeColor ([System.Drawing.Color]::White)
        $RUCancel = New-Object System.Windows.Forms.Button
        $RUCancel.Text = "跳过本项清理"; $RUCancel.Location = New-Object System.Drawing.Point(690, 10); $RUCancel.Size = New-Object System.Drawing.Size(110, 30)
        $RUCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $RUBtnPanel.Controls.Add($RUCancel)
        Set-FrostBladeButtonStyle -Btn $RUCancel -BackColor ([System.Drawing.Color]::FromArgb(233, 236, 239)) -ForeColor ([System.Drawing.Color]::FromArgb(73, 80, 87))
        $RUForm.AcceptButton = $RUConfirm
        $RUForm.CancelButton = $RUCancel

        $dr2 = $RUForm.ShowDialog($MainForm)
        if ($dr2 -ne [System.Windows.Forms.DialogResult]::OK) {
            # 用户取消：本轮跳过注册表失效项清理，不影响其它已勾选项继续执行
            $Global:SyncHash.ScanItems["RegUninstall"].Paths = @()
            return
        }
        $confirmed2 = New-Object System.Collections.Generic.List[string]
        foreach ($it in $RUList.Items) { if ($it.Checked) { [void]$confirmed2.Add([string]$it.Tag) } }
        $Global:SyncHash.ScanItems["RegUninstall"].Paths = @($confirmed2)
    }

    $CleanButton.Add_Click({
        # --- 0.1 「所见即所得」校验：拦截"扫描完成后才勾选、还没重新扫描就点清理"的情况 ---
        # 这些项由于从未在勾选状态下被扫描引擎处理过，Paths 是空的，清理时只会静默跳过，
        # 用户却可能以为已经处理了——这里显式提醒并给出"取消去重新扫描"的机会。
        $staleNames = New-Object System.Collections.Generic.List[string]
        foreach ($k in $KeyList) {
            $it = $Global:SyncHash.ScanItems[$k]
            if ($it.Checked -and $it.Stale) { [void]$staleNames.Add($it.Name) }
        }
        if ($staleNames.Count -gt 0) {
            $staleMsg = "以下 $($staleNames.Count) 项是在最近一次扫描完成之后才勾选的，尚未被扫描引擎确认，本次点击「执行深度清理」不会处理它们（不会误删，但也不会释放空间）：`r`n`r`n" +
                        ("- " + ($staleNames -join "`r`n- ")) +
                        "`r`n`r`n建议：点击「否」取消，先重新点一次「深度扫描分析」，确认体积后再清理。`r`n如果只是想清理其它已扫描过的勾选项，可以点「是」继续。"
            $staleRes = [System.Windows.Forms.MessageBox]::Show($staleMsg, "存在未重新扫描的勾选项", "YesNo", "Warning")
            if ($staleRes -ne "Yes") { $StatusLabel.Text = "已取消，建议重新扫描"; $StatusLabel.ForeColor = [System.Drawing.Color]::Gray; return }
        }

        $res = [System.Windows.Forms.MessageBox]::Show("即将永久删除垃圾数据（高危选项被勾选时可能引发数据丢失或无法回滚），确定继续？","操作警告","YesNo","Warning")
        if ($res -eq "Yes") {
            $Global:SyncHash.SkipVSSThisRun = $false

            # --- 0.2 残留目录（启发式识别）清理前逐项预览确认 ---
            if ($Global:SyncHash.ScanItems["ResidualAppDirs"].Checked -and ($Global:PreviewRequiredKeys -contains "ResidualAppDirs")) {
                Show-ResidualPreview
            }

            # --- 0.3 注册表失效卸载项清理前逐项预览确认 ---
            if ($Global:SyncHash.ScanItems["RegUninstall"].Checked -and ($Global:PreviewRequiredKeys -contains "RegUninstall")) {
                Show-RegUninstallPreview
            }

            # --- 0.4 还原点与 VSSShadow(卷影清理) 冲突检测 ---
            # VSSShadow 会删除全部卷影副本，若晚于还原点创建执行会把刚创建的还原点一并销毁，需提醒用户选择。
            if ($RestorePointChk.Checked -and $Global:SyncHash.ScanItems["VSSShadow"].Checked) {
                $vssWarn = [System.Windows.Forms.MessageBox]::Show(
                    "检测到同时勾选了『清理前自动创建系统还原点』和『系统还原点与卷影复制(VSSShadow)』清理项：`r`n`r`n" +
                    "VSSShadow 清理会删除系统上的全部卷影副本，这会把本次刚创建的还原点一并销毁，等于白做了还原点保护。`r`n`r`n" +
                    "【是】= 本次跳过卷影清理，保留刚创建的还原点（推荐）`r`n【否】= 忽略警告，两者都执行（还原点不会起到保护作用）`r`n【取消】= 中止本次清理，返回调整勾选",
                    "还原点与卷影清理冲突", "YesNoCancel", "Warning")
                if ($vssWarn -eq "Cancel") { $StatusLabel.Text = "已取消"; $StatusLabel.ForeColor = [System.Drawing.Color]::Gray; return }
                elseif ($vssWarn -eq "Yes") { $Global:SyncHash.SkipVSSThisRun = $true }
            }

            # --- 1. 自动创建系统还原点（创建逻辑见全局函数 Invoke-PreCleanRestorePoint，供 GUI 与 -Silent 共用；这里只处理弹窗交互）---
            if ($RestorePointChk.Checked) {
                $StatusLabel.Text = "正在创建系统还原点，请稍候（可能需要 20-60 秒）..."
                $StatusLabel.ForeColor = [System.Drawing.Color]::DarkOrange
                [System.Windows.Forms.Application]::DoEvents()
                $rpResult = Invoke-PreCleanRestorePoint
                if (-not $rpResult.Success) {
                    # 常见原因：系统驱动器未启用还原保护、已被组策略禁用、24h 内已有还原点(Win10限频)
                    $skipAnyway = [System.Windows.Forms.MessageBox]::Show(
                        "创建系统还原点失败：`r`n$($rpResult.Message)`r`n`r`n常见原因：C: 驱动器未开启「系统保护」，或 24 小时内已存在还原点（Windows 10/11 限频策略）。`r`n`r`n是否忽略此问题、继续执行清理？",
                        "还原点创建失败", "YesNo", "Warning")
                    if ($skipAnyway -ne "Yes") { $StatusLabel.Text = "已取消"; $StatusLabel.ForeColor = [System.Drawing.Color]::Gray; return }
                } else {
                    $StatusLabel.Text = "还原点创建成功，开始清理..."
                    $StatusLabel.ForeColor = [System.Drawing.Color]::Green
                    [System.Windows.Forms.Application]::DoEvents()
                }
            }
            # --- 2. 清理前自动关闭占用进程（关闭逻辑见全局函数 Invoke-PreCleanProcessTermination，供 GUI 与 -Silent 共用；
            #     这里只处理"检测到哪些正在运行 -> 弹窗确认"交互，确认后才调用共用函数执行）---
            if ($AutoCloseChk.Checked) {
                $candidateNames = Get-PreCleanTargetProcessNames
                if ($candidateNames.Count -gt 0) {
                    $runningProcs = Get-Process -Name $candidateNames -ErrorAction SilentlyContinue
                    if ($runningProcs) {
                        $shownNames = ($runningProcs | Select-Object -ExpandProperty ProcessName -Unique) -join ", "
                        $confirm = [System.Windows.Forms.MessageBox]::Show("检测到以下程序正在运行：`r`n$shownNames`r`n`r`n为了让对应缓存清理得更彻底，需要先关闭它们（未保存的工作可能丢失）。是否继续关闭并清理？", "关闭占用进程确认", "YesNo", "Warning")
                        if ($confirm -eq "Yes") {
                            [void](Invoke-PreCleanProcessTermination)
                        }
                    }
                }
            }
            $ScanButton.Enabled = $false; $CleanButton.Enabled = $false; if ($null -ne $RevertCompactBtn) { $RevertCompactBtn.Enabled = $false }
            Start-RunspaceJob $CleanScriptBlock
        }
    })

    $ExportButton.Add_Click({
        $SaveDialog = New-Object System.Windows.Forms.SaveFileDialog
        $SaveDialog.Filter = "Log File|*.log"
        $SaveDialog.FileName = "FrostBlade_Diagnostic_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
        if ($SaveDialog.ShowDialog() -eq "OK") {
            [System.IO.File]::WriteAllLines($SaveDialog.FileName, $Global:SyncHash.FullLogHistory)
            [System.Windows.Forms.MessageBox]::Show("诊断日志导出成功！", "完成", "OK", "Information") | Out-Null
        }
    })

    function Format-LFSize([long]$bytes) {
        if ($bytes -ge 1GB) { return "$([math]::Round($bytes/1GB,2)) GB" }
        else { return "$([math]::Round($bytes/1MB,2)) MB" }
    }

    function Show-LargeFileScanner {
        $LFForm = New-Object System.Windows.Forms.Form
        $LFForm.Text = "大文件扫描 (支持全盘或单独盘符按体积查找，需手动勾选后删除)"
        $LFForm.Size = New-Object System.Drawing.Size(900, 600)
        $LFForm.StartPosition = "CenterScreen"
        $LFForm.FormBorderStyle = "FixedDialog"
        $LFForm.MaximizeBox = $false

        $TopPanel2 = New-Object System.Windows.Forms.Panel; $TopPanel2.Location = New-Object System.Drawing.Point(10,10); $TopPanel2.Size = New-Object System.Drawing.Size(850,30); $LFForm.Controls.Add($TopPanel2)
        $SizeLabel2 = New-Object System.Windows.Forms.Label; $SizeLabel2.Text = "最小文件大小:"; $SizeLabel2.Location = New-Object System.Drawing.Point(0,7); $SizeLabel2.Size = New-Object System.Drawing.Size(90,20); $TopPanel2.Controls.Add($SizeLabel2)
        $SizeCombo2 = New-Object System.Windows.Forms.ComboBox; $SizeCombo2.DropDownStyle = "DropDownList"; $SizeCombo2.Location = New-Object System.Drawing.Point(95,3); $SizeCombo2.Size = New-Object System.Drawing.Size(90,22); $TopPanel2.Controls.Add($SizeCombo2)
        $SizeOptions2 = @(
            @{Text="100 MB"; Bytes=[long]100MB}, @{Text="200 MB"; Bytes=[long]200MB}, @{Text="500 MB"; Bytes=[long]500MB},
            @{Text="1 GB";   Bytes=[long]1GB},   @{Text="2 GB";   Bytes=[long]2GB},   @{Text="5 GB";   Bytes=[long]5GB}
        )
        foreach ($o2 in $SizeOptions2) { [void]$SizeCombo2.Items.Add($o2.Text) }
        $SizeCombo2.SelectedIndex = 1

        # 盘符筛选：索引0固定为"全部固定磁盘"，之后追加各固定磁盘盘符，避免每次都要遍历全盘。
        $DriveLabel2 = New-Object System.Windows.Forms.Label; $DriveLabel2.Text = "扫描范围:"; $DriveLabel2.Location = New-Object System.Drawing.Point(195,7); $DriveLabel2.Size = New-Object System.Drawing.Size(65,20); $TopPanel2.Controls.Add($DriveLabel2)
        $DriveCombo2 = New-Object System.Windows.Forms.ComboBox; $DriveCombo2.DropDownStyle = "DropDownList"; $DriveCombo2.Location = New-Object System.Drawing.Point(262,3); $DriveCombo2.Size = New-Object System.Drawing.Size(145,22); $TopPanel2.Controls.Add($DriveCombo2)
        [void]$DriveCombo2.Items.Add("全部固定磁盘")
        $AllFixedDrives2 = Get-FixedDriveLetters
        foreach ($d2 in $AllFixedDrives2) {
            $driveText2 = $d2
            try {
                $di2 = New-Object System.IO.DriveInfo($d2 + "\")
                if ($di2.IsReady) { $driveText2 = "$d2  (共 $([math]::Round($di2.TotalSize/1GB,0)) GB)" }
            } catch { }
            [void]$DriveCombo2.Items.Add($driveText2)
        }
        $DriveCombo2.SelectedIndex = 0
        $DriveTip2 = New-Object System.Windows.Forms.ToolTip
        $DriveTip2.SetToolTip($DriveCombo2, "选择'全部固定磁盘'会遍历本机所有固定磁盘（原有行为）；`r`n选择某个具体盘符（如 D:）则只扫描该盘，速度更快，适合明确知道大文件在哪个盘的场景。")

        $ExcludeChk2 = New-Object System.Windows.Forms.CheckBox; $ExcludeChk2.Text = "排除系统关键目录(推荐保留勾选)"; $ExcludeChk2.Checked = $true; $ExcludeChk2.Location = New-Object System.Drawing.Point(415,5); $ExcludeChk2.Size = New-Object System.Drawing.Size(230,20); $TopPanel2.Controls.Add($ExcludeChk2)
        $ScanBtn2 = New-Object System.Windows.Forms.Button; $ScanBtn2.Text = "开始扫描"; $ScanBtn2.Location = New-Object System.Drawing.Point(655,0); $ScanBtn2.Size = New-Object System.Drawing.Size(90,28); $TopPanel2.Controls.Add($ScanBtn2)
        Set-FrostBladeButtonStyle -Btn $ScanBtn2 -BackColor ([System.Drawing.Color]::FromArgb(59, 130, 246)) -ForeColor ([System.Drawing.Color]::White)
        $CancelBtn2 = New-Object System.Windows.Forms.Button; $CancelBtn2.Text = "取消扫描"; $CancelBtn2.Location = New-Object System.Drawing.Point(750,0); $CancelBtn2.Size = New-Object System.Drawing.Size(90,28); $CancelBtn2.Enabled = $false; $TopPanel2.Controls.Add($CancelBtn2)
        Set-FrostBladeButtonStyle -Btn $CancelBtn2 -BackColor ([System.Drawing.Color]::FromArgb(233, 236, 239)) -ForeColor ([System.Drawing.Color]::FromArgb(73, 80, 87))

        $StatusLabel2 = New-Object System.Windows.Forms.Label; $StatusLabel2.Text = "就绪。"; $StatusLabel2.Location = New-Object System.Drawing.Point(10,45); $StatusLabel2.Size = New-Object System.Drawing.Size(850,20); $StatusLabel2.ForeColor = [System.Drawing.Color]::DimGray; $LFForm.Controls.Add($StatusLabel2)

        $ListView2 = New-Object System.Windows.Forms.ListView
        $ListView2.Location = New-Object System.Drawing.Point(10,70)
        $ListView2.Size = New-Object System.Drawing.Size(850,400)
        $ListView2.View = "Details"; $ListView2.CheckBoxes = $true; $ListView2.FullRowSelect = $true; $ListView2.GridLines = $true
        [void]$ListView2.Columns.Add("路径", 570)
        [void]$ListView2.Columns.Add("大小", 100)
        [void]$ListView2.Columns.Add("修改时间", 150)
        $LFForm.Controls.Add($ListView2)

        # --- 右键菜单：打开文件 / 打开所在文件夹并定位 / 复制完整路径 ---
        $LFContextMenu = New-Object System.Windows.Forms.ContextMenuStrip
        $LFMenuOpenFile   = New-Object System.Windows.Forms.ToolStripMenuItem; $LFMenuOpenFile.Text   = "打开文件"
        $LFMenuOpenFolder = New-Object System.Windows.Forms.ToolStripMenuItem; $LFMenuOpenFolder.Text = "打开所在文件夹并定位"
        $LFMenuCopyPath   = New-Object System.Windows.Forms.ToolStripMenuItem; $LFMenuCopyPath.Text   = "复制完整路径"
        [void]$LFContextMenu.Items.Add($LFMenuOpenFile)
        [void]$LFContextMenu.Items.Add($LFMenuOpenFolder)
        [void]$LFContextMenu.Items.Add($LFMenuCopyPath)
        $ListView2.ContextMenuStrip = $LFContextMenu

        # ContextMenuStrip 不会自动选中右键点击处的行，需手动在右键按下时先选中该行
        $ListView2.Add_MouseUp({
            param($s, $e)
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
                $hitItem = $ListView2.GetItemAt($e.X, $e.Y)
                if ($null -ne $hitItem) {
                    foreach ($it in $ListView2.Items) { $it.Selected = $false }
                    $hitItem.Selected = $true
                    $hitItem.Focused = $true
                }
            }
        })
        # 右键点在空白处（没有命中任何行）时不弹出菜单，避免对"无选中项"误操作
        $LFContextMenu.Add_Opening({
            param($s, $e)
            if ($ListView2.SelectedItems.Count -eq 0) { $e.Cancel = $true }
        })

        $LFMenuOpenFile.Add_Click({
            if ($ListView2.SelectedItems.Count -eq 0) { return }
            $targetPath = $ListView2.SelectedItems[0].Text
            if (Test-Path -LiteralPath $targetPath) {
                try { Start-Process -FilePath $targetPath -ErrorAction Stop }
                catch { [System.Windows.Forms.MessageBox]::Show("无法打开该文件（可能缺少关联的默认程序）：`r`n$($_.Exception.Message)", "提示", "OK", "Warning") | Out-Null }
            } else {
                [System.Windows.Forms.MessageBox]::Show("文件不存在，可能已被移动或删除。", "提示", "OK", "Warning") | Out-Null
            }
        })

        $LFMenuOpenFolder.Add_Click({
            if ($ListView2.SelectedItems.Count -eq 0) { return }
            $targetPath = $ListView2.SelectedItems[0].Text
            if (Test-Path -LiteralPath $targetPath) {
                # /select 会打开文件所在目录并自动高亮选中该文件
                Start-Process -FilePath "explorer.exe" -ArgumentList "/select,`"$targetPath`""
            } else {
                $parentDir = Split-Path -Path $targetPath -Parent
                if (-not [string]::IsNullOrEmpty($parentDir) -and (Test-Path -LiteralPath $parentDir)) {
                    Start-Process -FilePath "explorer.exe" -ArgumentList "`"$parentDir`""
                } else {
                    [System.Windows.Forms.MessageBox]::Show("路径不存在，可能已被移动或删除。", "提示", "OK", "Warning") | Out-Null
                }
            }
        })

        $LFMenuCopyPath.Add_Click({
            if ($ListView2.SelectedItems.Count -eq 0) { return }
            try { [System.Windows.Forms.Clipboard]::SetText($ListView2.SelectedItems[0].Text) } catch { }
        })

        # 双击行：直接打开所在文件夹并定位（先看一眼文件在哪儿，比直接打开文件更安全）
        $ListView2.Add_DoubleClick({
            if ($ListView2.SelectedItems.Count -eq 0) { return }
            $targetPath = $ListView2.SelectedItems[0].Text
            if (Test-Path -LiteralPath $targetPath) {
                Start-Process -FilePath "explorer.exe" -ArgumentList "/select,`"$targetPath`""
            }
        })

        $BottomPanel2 = New-Object System.Windows.Forms.Panel; $BottomPanel2.Location = New-Object System.Drawing.Point(10,478); $BottomPanel2.Size = New-Object System.Drawing.Size(850,60); $LFForm.Controls.Add($BottomPanel2)
        $SelLabel2 = New-Object System.Windows.Forms.Label; $SelLabel2.Text = "已选择: 0 个文件，合计 0.00 MB"; $SelLabel2.Location = New-Object System.Drawing.Point(0,10); $SelLabel2.Size = New-Object System.Drawing.Size(300,20); $BottomPanel2.Controls.Add($SelLabel2)
        $SelAllBtn2 = New-Object System.Windows.Forms.Button; $SelAllBtn2.Text = "全选"; $SelAllBtn2.Location = New-Object System.Drawing.Point(310,5); $SelAllBtn2.Size = New-Object System.Drawing.Size(60,28); $BottomPanel2.Controls.Add($SelAllBtn2)
        Set-FrostBladeButtonStyle -Btn $SelAllBtn2 -BackColor ([System.Drawing.Color]::FromArgb(233, 236, 239)) -ForeColor ([System.Drawing.Color]::FromArgb(73, 80, 87))
        $SelNoneBtn2 = New-Object System.Windows.Forms.Button; $SelNoneBtn2.Text = "全不选"; $SelNoneBtn2.Location = New-Object System.Drawing.Point(375,5); $SelNoneBtn2.Size = New-Object System.Drawing.Size(60,28); $BottomPanel2.Controls.Add($SelNoneBtn2)
        Set-FrostBladeButtonStyle -Btn $SelNoneBtn2 -BackColor ([System.Drawing.Color]::FromArgb(233, 236, 239)) -ForeColor ([System.Drawing.Color]::FromArgb(73, 80, 87))
        # 大文件面向的是最容易误删重要数据（视频/虚拟机镜像/数据库文件等）的场景，加一个默认勾选的
        # "移入回收站"选项（Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile 的 SendToRecycleBin），
        # 误删了还能找回；取消勾选才走永久删除。
        $RecycleModeChk2 = New-Object System.Windows.Forms.CheckBox; $RecycleModeChk2.Text = "移入回收站(推荐)"; $RecycleModeChk2.Checked = $true; $RecycleModeChk2.Location = New-Object System.Drawing.Point(440,8); $RecycleModeChk2.Size = New-Object System.Drawing.Size(160,22); $BottomPanel2.Controls.Add($RecycleModeChk2)
        $DeleteBtn2 = New-Object System.Windows.Forms.Button; $DeleteBtn2.Text = "删除选中项"; $DeleteBtn2.Font = New-Object System.Drawing.Font("微软雅黑", 9, [System.Drawing.FontStyle]::Bold); $DeleteBtn2.Location = New-Object System.Drawing.Point(620,3); $DeleteBtn2.Size = New-Object System.Drawing.Size(160,32); $BottomPanel2.Controls.Add($DeleteBtn2)
        Set-FrostBladeButtonStyle -Btn $DeleteBtn2 -BackColor ([System.Drawing.Color]::FromArgb(220, 53, 69)) -ForeColor ([System.Drawing.Color]::White)

        function Refresh-LFSelectionSummary {
            [long]$total2 = 0; $cnt2 = 0
            foreach ($item2 in $ListView2.Items) { if ($item2.Checked) { $cnt2++; $total2 += [long]$item2.Tag } }
            $SelLabel2.Text = "已选择: $cnt2 个文件，合计 $(Format-LFSize $total2)"
        }
        $ListView2.Add_ItemChecked({ Refresh-LFSelectionSummary })
        $SelAllBtn2.Add_Click({ foreach ($item2 in $ListView2.Items) { $item2.Checked = $true } })
        $SelNoneBtn2.Add_Click({ foreach ($item2 in $ListView2.Items) { $item2.Checked = $false } })

        # 定时器：增量更新列表（实时进度）
        $LFTimer = New-Object System.Windows.Forms.Timer
        $LFTimer.Interval = 300
        $LFTimer.Add_Tick({
            $StatusLabel2.Text = $Global:LFSync.StatusMsg
            
            # 增量添加新结果
            $results = $Global:LFSync.Results
            $currentCount = $ListView2.Items.Count
            if ($results.Count -gt $currentCount) {
                for ($i = $currentCount; $i -lt $results.Count; $i++) {
                    $r = $results[$i]
                    $modTime = try { (Get-Item -LiteralPath $r.Path -ErrorAction Stop).LastWriteTime.ToString("yyyy-MM-dd HH:mm") } catch { "?" }
                    $li = New-Object System.Windows.Forms.ListViewItem($r.Path)
                    [void]$li.SubItems.Add((Format-LFSize $r.Size))
                    [void]$li.SubItems.Add($modTime)
                    $li.Tag = [long]$r.Size
                    [void]$ListView2.Items.Add($li)
                }
                Refresh-LFSelectionSummary
            }
            
            if (-not $Global:LFSync.IsRunning) {
                $LFTimer.Stop()
                $ScanBtn2.Enabled = $true
                $CancelBtn2.Enabled = $false
                if ($null -ne $Global:LFSync.ActivePS) { $Global:LFSync.ActivePS.Dispose(); $Global:LFSync.ActivePS = $null }
                if ($null -ne $Global:LFSync.ActiveRS) { $Global:LFSync.ActiveRS.Close(); $Global:LFSync.ActiveRS.Dispose(); $Global:LFSync.ActiveRS = $null }
            }
        })

        $ScanBtn2.Add_Click({
            $minBytes2 = $SizeOptions2[$SizeCombo2.SelectedIndex].Bytes
            $excludeSys2 = $ExcludeChk2.Checked
            $ListView2.Items.Clear()

            # 索引0=全部固定磁盘；索引>=1时把 $drives2 换成该盘符的单元素数组即可，LargeFileScanBlock
            # 内部本就对 $Drives 数组做 foreach 逐盘遍历。枚举失败/盘符已拔出时回退到全盘扫描而不报错。
            if ($DriveCombo2.SelectedIndex -le 0 -or $AllFixedDrives2.Count -eq 0) {
                $drives2 = Get-FixedDriveLetters
                $Global:LFSync.StatusMsg = "正在枚举固定磁盘..."
            } else {
                $selectedDrive2 = $AllFixedDrives2[$DriveCombo2.SelectedIndex - 1]
                if ([string]::IsNullOrEmpty($selectedDrive2) -or -not (Test-Path -LiteralPath "$selectedDrive2\")) {
                    $drives2 = Get-FixedDriveLetters
                    $Global:LFSync.StatusMsg = "所选盘符不可用，已自动改为扫描全部固定磁盘..."
                } else {
                    $drives2 = @($selectedDrive2)
                    $Global:LFSync.StatusMsg = "正在扫描盘符 $selectedDrive2 ..."
                }
            }

            $ScanBtn2.Enabled = $false; $CancelBtn2.Enabled = $true
            $LFTimer.Start()

            $runspace2 = [runspacefactory]::CreateRunspace()
            $runspace2.ApartmentState = "STA"; $runspace2.ThreadOptions = "ReuseThread"; $runspace2.Open()
            $ps2 = [powershell]::Create(); $ps2.Runspace = $runspace2
            $ps2.AddScript($LargeFileScanBlock).AddArgument($Global:LFSync).AddArgument([long]$minBytes2).AddArgument($excludeSys2).AddArgument($drives2) | Out-Null
            $Global:LFSync.ActiveRS = $runspace2; $Global:LFSync.ActivePS = $ps2
            [void]$ps2.BeginInvoke()
        })

        $CancelBtn2.Add_Click({ $Global:LFSync.CancelRequested = $true; $CancelBtn2.Enabled = $false })

        $DeleteBtn2.Add_Click({
            $toDelete2 = @()
            foreach ($item2 in $ListView2.Items) { if ($item2.Checked) { $toDelete2 += $item2 } }
            if ($toDelete2.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show("还没有勾选任何文件。", "提示", "OK", "Information") | Out-Null
                return
            }
            [long]$totalBytes2 = 0; foreach ($item2 in $toDelete2) { $totalBytes2 += [long]$item2.Tag }
            $useRecycle2 = $RecycleModeChk2.Checked
            $msg2 = if ($useRecycle2) {
                "即将把 $($toDelete2.Count) 个文件（合计 $(Format-LFSize $totalBytes2)）移入回收站，之后仍可以从回收站找回，确定继续？"
            } else {
                "即将永久删除 $($toDelete2.Count) 个文件，合计 $(Format-LFSize $totalBytes2)。`r`n此操作不经过回收站、不可恢复，确定继续？"
            }
            $res2 = [System.Windows.Forms.MessageBox]::Show($msg2, "危险操作确认", "YesNo", "Warning")
            if ($res2 -ne "Yes") { return }
            $failCount2 = 0
            foreach ($item2 in @($toDelete2)) {
                $p2 = $item2.Text
                try {
                    if ($useRecycle2) {
                        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p2, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
                    } else {
                        Remove-Item -LiteralPath $p2 -Force -ErrorAction Stop
                    }
                    [void]$ListView2.Items.Remove($item2)
                }
                catch { $failCount2++; $item2.ForeColor = [System.Drawing.Color]::Red; $item2.Checked = $false }
            }
            Refresh-LFSelectionSummary
            if ($failCount2 -gt 0) { [System.Windows.Forms.MessageBox]::Show("$failCount2 个文件处理失败（可能被占用、权限不足，或文件过大/位于不支持回收站的位置——可尝试取消勾选`"移入回收站`"后重试），已在列表中标红。", "完成", "OK", "Warning") | Out-Null }
            else { [System.Windows.Forms.MessageBox]::Show("操作完成。", "完成", "OK", "Information") | Out-Null }
        })

        $LFForm.Add_FormClosing({
            $Global:LFSync.CancelRequested = $true
            if ($LFTimer.Enabled) { $LFTimer.Stop() }
        })

        [void]$LFForm.ShowDialog($MainForm)
    }

    $BigFileButton.Add_Click({ Show-LargeFileScanner })

    $MainForm.ShowDialog() | Out-Null
}
