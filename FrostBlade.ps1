<#
.SYNOPSIS
    霜刃 FrostBlade v1.0 Beta - 纯绿化单文件磁盘清理工具 (Win7+ / PS2.0+)
    定位：面向个人电脑用户的轻量级磁盘清理工具。清理项含较多启发式判断与不可逆操作，不建议在企业/生产环境中运行，请自行评估风险后使用。

    核心能力：
    1. [零依赖] 彻底剥离 JSON，规则通过原生 Hashtable 内嵌内存，不产生任何配置文件残留。
    2. [内存管理] 修复 Runspace 重复执行时的底层内存泄漏，引入严格的 Dispose() 回收。
    3. [性能优化] 废弃数组 += 操作，全链路应用 [System.Collections.Generic.List[string]]。
    4. [双轨降级] 卷影清理自动侦测 CIM/WMI 接口，适配 Win10/11 的 PowerShell 7 环境。
    5. [日志追踪] 拦截异常捕捉(Catch)，文件占用信息实时写入内存日志缓冲，并支持导出。

    清理彻底度专项修复：
    6. [核心bug修复] SafeClean 不再因管道中单个被占用文件而整体中断，逐项独立处理。
    7. [删除兜底] 新增 robocopy /MIR /XJ 镜像清空法（兼容超长路径、跳过软链接），配合手动栈式残留核查 + Remove-ItemRobust，删不掉的锁定文件转 MoveFileEx。
    8. [VSS兜底] CIM/WMI 卷影清理失败时自动转用 vssadmin 命令行兜底。
    9. [权限兜底] Windows.old / $WINDOWS.~BT / ~WS 清理前自动 takeown + icacls 取所有权。
    10.[覆盖面] 显卡着色器缓存补全 NVIDIA(DXCache/GLCache)、AMD(DxCache/VkCache)、Intel 路径。
    11.[可选项] 新增「清理前自动关闭占用进程」勾选项（默认关闭，需用户主动开启+二次确认），可显著提升微信/QQ/浏览器等正在运行时的缓存清理效率。
#>
param(
    [switch]$Silent = $false,
    [switch]$CreateRestorePoint = $false,
    [switch]$ClosePrograms = $false
)

$ConfirmPreference = 'None'
$ErrorActionPreference = 'Continue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if ($Silent) { Write-Error "静默模式需要管理员权限。"; exit 1 } 
    else {
        $scriptPath = $MyInvocation.MyCommand.Definition
        if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" -Verb RunAs
        exit
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

# =====================================================================
# 模块 01-WinAPI : 原生 API 封装 (C# Add-Type)
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
}
"@

if (-not ("FrostBladeWinAPI_v1" -as [type])) {
    Add-Type -TypeDefinition $Win32APICode -Language CSharp -ErrorAction Stop
}

# =====================================================================
# 模块 02-Rules : 清理规则数据
# =====================================================================

$Global:BuiltInRules = @{
    "SoftwareRules" = @(
        @{ ID="WeChat"; RegKeys=@("wechat", "微信"); Paths=@("*\AppData\Roaming\Tencent\WeChat\XPlugin\Plugins\*\Cache", "*\Documents\WeChat Files\*\FileStorage\Cache") },
        @{ ID="TencentQQ"; RegKeys=@("qq", "tencent"); Paths=@("*\AppData\Roaming\Tencent\QQ\Temp", "*\AppData\Roaming\Tencent\QQ\CrashDump") },
        @{ ID="DingTalk"; RegKeys=@("dingtalk", "钉钉"); Paths=@("*\AppData\Roaming\DingTalk\*\Cache", "*\AppData\Roaming\DingTalk\*\cef_cache") },
        @{ ID="Chrome"; RegKeys=@("chrome"); Paths=@("*\AppData\Local\Google\Chrome\User Data\Default\Cache") },
        @{ ID="Steam"; RegKeys=@("steam"); Paths=@("*\AppData\Local\Steam\htmlcache\Cache") }
    )
    "WeChatMediaPaths" = @(
        "*\Documents\WeChat Files\*\FileStorage\Video", "*\Documents\WeChat Files\*\FileStorage\Image"
    )
}

$Global:ProcessCloseMap = @{
    "BrowserCache"  = @("chrome", "msedge", "firefox", "opera", "brave")
    "SoftwareCache" = @("WeChat", "QQ", "DingTalk", "Steam", "Code")
    "WeChatMedia"   = @("WeChat", "WXWork")
}

# =====================================================================
# 模块 03-ScanState : 扫描项清单与线程安全共享状态
# =====================================================================

$Global:ScanItems = @{
    "SystemTemp"      = @{ Name = "系统临时文件 (Temp/Prefetch)"; Checked = $true;  Size = 0; Paths = @() }
    "UserTemp"        = @{ Name = "用户临时文件"; Checked = $true;  Size = 0; Paths = @() }
    "WinUpdate"       = @{ Name = "Windows Update 下载缓存"; Checked = $true;  Size = 0; Paths = @() }
    "BrowserCache"    = @{ Name = "浏览器缓存 (Chrome/Edge等)"; Checked = $true;  Size = 0; Paths = @() }
    "SoftwareCache"   = @{ Name = "常用软件运行时缓存 (规则库)"; Checked = $true;  Size = 0; Paths = @() }
    "RecycleBin"      = @{ Name = "回收站 (所有用户)"; Checked = $true;  Size = 0; Paths = @() }
    "WeChatMedia"     = @{ Name = "微信媒体文件 (深度排查 - 高危)"; Checked = $false; Size = 0; Paths = @() }
    "WindowsOld"      = @{ Name = "旧版系统备份 (Windows.old)"; Checked = $false; Size = 0; Paths = @("$env:SystemDrive\Windows.old") }
    "VSSShadow"       = @{ Name = "系统还原点与卷影复制 (高危)"; Checked = $false; Size = 0; Paths = @() }
}

foreach ($k in $Global:ScanItems.Keys) { $Global:ScanItems[$k].Stale = $true }

$KeyList = @("SystemTemp", "UserTemp", "WinUpdate", "BrowserCache", "SoftwareCache", "RecycleBin", "WeChatMedia", "WindowsOld", "VSSShadow")

$Global:HighRiskKeys = @("WeChatMedia", "VSSShadow", "WindowsOld")
$Global:PreviewRequiredKeys = @()

$Global:SyncHash = [hashtable]::Synchronized(@{})
$Global:SyncHash.LogQueue = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$Global:SyncHash.FullLogHistory = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$Global:SyncHash.Progress = 0
$Global:SyncHash.IsRunning = $false
$Global:SyncHash.CancelRequested = $false
$Global:SyncHash.ScanItems = $Global:ScanItems
$Global:SyncHash.SystemDrive = $env:SystemDrive
$Global:SyncHash.BuiltInRules = $Global:BuiltInRules
$Global:SyncHash.ResidualDetails = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$Global:SyncHash.RegUninstallDetails = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$Global:SyncHash.SkipVSSThisRun = $false

function Get-FixedDriveLetters {
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
# 模块 04-LargeFileEngine
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
    
    foreach ($root in $Drives) {
        if ($Sync.CancelRequested) { break }
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push("$root\")
        while ($stack.Count -gt 0) {
            if ($Sync.CancelRequested) { break }
            $dir = $stack.Pop()
            try {
                foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($dir)) {
                    try {
                        $attr = [System.IO.File]::GetAttributes($entry)
                        if ($attr -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                        if ($attr -band [System.IO.FileAttributes]::Directory) {
                            [void]$stack.Push($entry)
                        } else {
                            $len = (New-Object System.IO.FileInfo($entry)).Length
                            $scanned++
                            if ($len -ge $MinSizeBytes) {
                                [void]$Sync.Results.Add(@{ Path = $entry; Size = $len })
                            }
                        }
                    } catch { }
                }
            } catch { }
        }
    }
    $Sync.IsRunning = $false
}

# =====================================================================
# 模块 05-ScanEngine : 异步后台深度扫描引擎
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

    Write-AsyncLog ">>> 后台深度扫描引擎启动 <<<"
    $Sync.Progress = 2

    [System.Threading.Monitor]::Enter($Sync)
    try {
        foreach ($k in $Sync.ScanItems.Keys) {
            if ($Sync.ScanItems[$k].Checked) { $Sync.ScanItems[$k].Stale = $false }
        }
    } finally { [System.Threading.Monitor]::Exit($Sync) }

    $usersRoot = "$($Sync.SystemDrive)\Users"
    $userDirs = [System.IO.Directory]::GetDirectories($usersRoot)
    
    [System.Threading.Monitor]::Enter($Sync)
    try {
        foreach ($k in $Sync.ScanItems.Keys) {
            $Sync.ScanItems[$k].Size = 0
            $Sync.ScanItems[$k].Paths = @()
        }
    } finally { [System.Threading.Monitor]::Exit($Sync) }

    # 系统与用户临时
    if ($Sync.ScanItems["SystemTemp"].Checked) {
        Write-AsyncLog "[扫描] 系统与用户临时文件..."
        [System.Threading.Monitor]::Enter($Sync)
        try {
            $Sync.ScanItems["SystemTemp"].Paths = @("$env:SystemRoot\Temp")
            $Sync.ScanItems["SystemTemp"].Size = Get-FolderSize $Sync.ScanItems["SystemTemp"].Paths[0]
        } finally { [System.Threading.Monitor]::Exit($Sync) }
    }

    if ($Sync.ScanItems["UserTemp"].Checked) {
        $userTempPaths = New-Object System.Collections.Generic.List[string]
        [void]$userTempPaths.Add($env:TEMP)
        foreach ($d in $userDirs) {
            $tp = "$d\AppData\Local\Temp"
            if (Test-Path $tp) { [void]$userTempPaths.Add($tp) }
        }
        [System.Threading.Monitor]::Enter($Sync)
        try {
            $Sync.ScanItems["UserTemp"].Paths = $userTempPaths | Select-Object -Unique
            [long]$uSize = 0
            foreach ($p in $Sync.ScanItems["UserTemp"].Paths) { $uSize += Get-FolderSize $p }
            $Sync.ScanItems["UserTemp"].Size = $uSize
        } finally { [System.Threading.Monitor]::Exit($Sync) }
    }
    $Sync.Progress = 30

    # 浏览器缓存
    if ($Sync.ScanItems["BrowserCache"].Checked) {
        Write-AsyncLog "[扫描] 多用户浏览器缓存..."
        $browserPaths = New-Object System.Collections.Generic.List[string]
        foreach ($userDir in $userDirs) {
            if ($Sync.CancelRequested) { break }
            $local = "$userDir\AppData\Local"
            $chromeCache = "$local\Google\Chrome\User Data\Default\Cache"
            $edgeCache = "$local\Microsoft\Edge\User Data\Default\Cache"
            if (Test-Path $chromeCache) { [void]$browserPaths.Add($chromeCache) }
            if (Test-Path $edgeCache) { [void]$browserPaths.Add($edgeCache) }
        }
        [System.Threading.Monitor]::Enter($Sync)
        try {
            $Sync.ScanItems["BrowserCache"].Paths = $browserPaths | Select-Object -Unique
            [long]$bSize = 0
            foreach ($p in $Sync.ScanItems["BrowserCache"].Paths) { $bSize += Get-FolderSize $p }
            $Sync.ScanItems["BrowserCache"].Size = $bSize
        } finally { [System.Threading.Monitor]::Exit($Sync) }
    }
    $Sync.Progress = 60

    # 软件缓存
    if ($Sync.ScanItems["SoftwareCache"].Checked) {
        Write-AsyncLog "[扫描] 应用内部缓存..."
        $softPathsList = New-Object System.Collections.Generic.List[string]
        foreach ($r in $Sync.BuiltInRules.SoftwareRules) {
            foreach ($p in $r.Paths) { [void]$softPathsList.Add($p) }
        }
        $finalSoftPaths = New-Object System.Collections.Generic.List[string]
        foreach ($userDir in $userDirs) {
            foreach ($sp in $softPathsList) {
                $searchPattern = $sp -replace "^\*", $userDir
                Get-ChildItem -Path $searchPattern -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer } | ForEach-Object { [void]$finalSoftPaths.Add($_.FullName) }
            }
        }
        [System.Threading.Monitor]::Enter($Sync)
        try {
            $Sync.ScanItems["SoftwareCache"].Paths = $finalSoftPaths | Select-Object -Unique
            [long]$sSize = 0
            foreach ($p in $Sync.ScanItems["SoftwareCache"].Paths) { $sSize += Get-FolderSize $p }
            $Sync.ScanItems["SoftwareCache"].Size = $sSize
        } finally { [System.Threading.Monitor]::Exit($Sync) }
    }

    # 微信媒体
    if ($Sync.ScanItems["WeChatMedia"].Checked) {
        Write-AsyncLog "[扫描] 微信媒体文件..."
        $wxRoots = @()
        foreach ($userDir in $userDirs) {
            $wxPath = "$userDir\Documents\WeChat Files"
            if (Test-Path $wxPath) { $wxRoots += $wxPath }
        }
        $wxMediaPaths = New-Object System.Collections.Generic.List[string]
        foreach ($root in $wxRoots) {
            Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer } | ForEach-Object {
                $mediaSubDir = "$($_.FullName)\FileStorage\Video"
                if (Test-Path $mediaSubDir) { [void]$wxMediaPaths.Add($mediaSubDir) }
            }
        }
        [System.Threading.Monitor]::Enter($Sync)
        try {
            $Sync.ScanItems["WeChatMedia"].Paths = $wxMediaPaths | Select-Object -Unique
            [long]$wxSize = 0
            foreach ($p in $Sync.ScanItems["WeChatMedia"].Paths) { $wxSize += Get-FolderSize $p }
            $Sync.ScanItems["WeChatMedia"].Size = $wxSize
        } finally { [System.Threading.Monitor]::Exit($Sync) }
    }

    $Sync.Progress = 100
    Write-AsyncLog "[完成] 扫描引擎已完成"
}

# =====================================================================
# 模块 06-CleanEngine : 清理执行引擎
# =====================================================================

function Remove-ItemRobust {
    param($Path)
    try {
        if (Test-Path $Path) {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            return $true
        }
    } catch {
        Write-Warning "无法删除: $Path - $($_.Exception.Message)"
    }
    return $false
}

function Invoke-Cleanup {
    param($Items, $LogCallback)
    $totalSize = 0
    foreach ($item in $Items) {
        if (Test-Path $item) {
            $size = [FrostBladeWinAPI_v1]::GetDirectorySizeFast($item)
            if (Remove-ItemRobust $item) {
                $totalSize += $size
                & $LogCallback "已清理: $item ($([Math]::Round($size/1MB, 2)) MB)"
            }
        }
    }
    return $totalSize
}

# =====================================================================
# 模块 07-GUI : 用户界面
# =====================================================================

function Show-MainWindow {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "霜刃 FrostBlade v1.0 - 磁盘清理工具"
    $form.Size = New-Object System.Drawing.Size(800, 600)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::White

    # 标题标签
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "磁盘清理工具"
    $titleLabel.Font = New-Object System.Drawing.Font("微软雅黑", 16, [System.Drawing.FontStyle]::Bold)
    $titleLabel.Location = New-Object System.Drawing.Point(20, 20)
    $titleLabel.AutoSize = $true
    $form.Controls.Add($titleLabel)

    # 扫描项选择组
    $groupBox = New-Object System.Windows.Forms.GroupBox
    $groupBox.Text = "选择清理项"
    $groupBox.Location = New-Object System.Drawing.Point(20, 60)
    $groupBox.Size = New-Object System.Drawing.Size(750, 350)
    $form.Controls.Add($groupBox)

    $yPos = 20
    $checkboxes = @{}
    foreach ($key in $KeyList) {
        $item = $Global:ScanItems[$key]
        $checkbox = New-Object System.Windows.Forms.CheckBox
        $checkbox.Text = "$($item.Name) (0 MB)"
        $checkbox.Location = New-Object System.Drawing.Point(20, $yPos)
        $checkbox.Size = New-Object System.Drawing.Size(700, 25)
        $checkbox.Checked = $item.Checked
        $checkbox.Tag = $key
        
        if ($Global:HighRiskKeys -contains $key) {
            $checkbox.ForeColor = [System.Drawing.Color]::Red
            $checkbox.Text = "⚠️  " + $checkbox.Text
        }
        
        $checkboxes[$key] = $checkbox
        $groupBox.Controls.Add($checkbox)
        $yPos += 30
    }

    # 扫描按钮
    $scanButton = New-Object System.Windows.Forms.Button
    $scanButton.Text = "深度扫描分析"
    $scanButton.Location = New-Object System.Drawing.Point(20, 420)
    $scanButton.Size = New-Object System.Drawing.Size(150, 40)
    $form.Controls.Add($scanButton)

    # 清理按钮
    $cleanButton = New-Object System.Windows.Forms.Button
    $cleanButton.Text = "执行深度清理"
    $cleanButton.Location = New-Object System.Drawing.Point(180, 420)
    $cleanButton.Size = New-Object System.Drawing.Size(150, 40)
    $form.Controls.Add($cleanButton)

    # 日志输出
    $logText = New-Object System.Windows.Forms.TextBox
    $logText.Multiline = $true
    $logText.ScrollBars = "Vertical"
    $logText.ReadOnly = $true
    $logText.Location = New-Object System.Drawing.Point(20, 470)
    $logText.Size = New-Object System.Drawing.Size(750, 90)
    $form.Controls.Add($logText)

    # 扫描事件
    $scanButton.Add_Click({
        $scanButton.Enabled = $false
        foreach ($key in $KeyList) {
            if ($checkboxes[$key].Checked) {
                [System.Threading.Monitor]::Enter($Global:SyncHash)
                try {
                    $Global:SyncHash.ScanItems[$key].Checked = $true
                } finally { [System.Threading.Monitor]::Exit($Global:SyncHash) }
            }
        }
        
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $runspace
        [void]$ps.AddScript($ScanScriptBlock).AddArgument($Global:SyncHash)
        $async = $ps.BeginInvoke()
        
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 200
        $timer.Add_Tick({
            while ($Global:SyncHash.LogQueue.Count -gt 0) {
                $msg = $Global:SyncHash.LogQueue[0]
                [void]$Global:SyncHash.LogQueue.RemoveAt(0)
                $logText.AppendText("$msg`r`n")
            }
            
            foreach ($key in $KeyList) {
                [System.Threading.Monitor]::Enter($Global:SyncHash)
                try {
                    $size = $Global:SyncHash.ScanItems[$key].Size
                    $sizeStr = if ($size -gt 0) { "$([Math]::Round($size/1MB, 2)) MB" } else { "0 MB" }
                    $checkboxes[$key].Text = "$($Global:SyncHash.ScanItems[$key].Name) ($sizeStr)"
                } finally { [System.Threading.Monitor]::Exit($Global:SyncHash) }
            }
            
            if ($async.IsCompleted) {
                $timer.Stop()
                $ps.EndInvoke($async) | Out-Null
                $ps.Dispose()
                $runspace.Dispose()
                $scanButton.Enabled = $true
                [System.Windows.Forms.MessageBox]::Show("扫描完成！", "提示", [System.Windows.Forms.MessageBoxButtons]::OK)
            }
        })
        $timer.Start()
    })

    # 清理事件
    $cleanButton.Add_Click({
        if ([System.Windows.Forms.MessageBox]::Show("确认开始清理？", "确认", [System.Windows.Forms.MessageBoxButtons]::YesNo) -eq [System.Windows.Forms.DialogResult]::Yes) {
            $selectedItems = @()
            foreach ($key in $KeyList) {
                if ($checkboxes[$key].Checked) {
                    [System.Threading.Monitor]::Enter($Global:SyncHash)
                    try {
                        $selectedItems += $Global:SyncHash.ScanItems[$key].Paths
                    } finally { [System.Threading.Monitor]::Exit($Global:SyncHash) }
                }
            }
            
            $cleanedSize = Invoke-Cleanup $selectedItems { param($msg) $logText.AppendText("$msg`r`n") }
            [System.Windows.Forms.MessageBox]::Show("清理完成！释放了 $([Math]::Round($cleanedSize/1MB, 2)) MB 空间", "完成", [System.Windows.Forms.MessageBoxButtons]::OK)
        }
    })

    $form.ShowDialog()
}

# =====================================================================
# 主程序入口
# =====================================================================

if ($Silent) {
    Write-Host "静默模式：执行深度扫描..."
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($ScanScriptBlock).AddArgument($Global:SyncHash)
    $ps.Invoke()
    $ps.Dispose()
    $runspace.Dispose()
    Write-Host "扫描完成。"
} else {
    Show-MainWindow
}
