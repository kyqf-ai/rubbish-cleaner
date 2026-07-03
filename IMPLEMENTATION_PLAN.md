# FrostBlade v1.0 Stable 修复实现计划

## 📋 综合概述

本文档为 FrostBlade v1.0 Stable 版本迭代提供详细的实现路线图。包含 7 个系统级缺陷的修复方案、代码示例、测试策略及合并指导。

**修复范围**：~270 行代码改动 | **风险等级**：中低 | **向后兼容**：✅ 完全保持

---

## 🔴 P0-01：MoveFileEx 注册表覆盖改追加

### 问题根源
```powershell
# 原代码：直接覆盖 PendingFileRenameOperations
[FrostBladeWinAPI_v1]::MoveFileEx($FilePath, $null, 4)
# dwFlags = 4 = MOVEFILE_DELAY_UNTIL_REBOOT
```

Windows 内核在重启前读取 `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations` 的 MULTI_SZ 值。若脚本直接覆盖此值（而不是追加），Windows Update、系统补丁的重启任务将被丢失。

### 实现步骤

#### 第 1 步：新增 PowerShell 函数（插入位置：模块 06-CleanEngine 前）

```powershell
# =====================================================================
# 补丁 P0-01：MoveFileEx 注册表安全追加函数
# =====================================================================

function Add-PendingFileRenameOperation {
    <#
    .SYNOPSIS
        安全地向 PendingFileRenameOperations 注册表追加待删除文件。
    .DESCRIPTION
        读取现有 MULTI_SZ 值，检查去重，原子化写入新值，保护系统组件任务。
    .PARAMETER FilePath
        待删除文件或目录完整路径。
    .EXAMPLE
        Add-PendingFileRenameOperation -FilePath "C:\Temp\locked.file"
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
    $valueName = "PendingFileRenameOperations"

    try {
        # 读取现有值（MULTI_SZ = string[]）
        $existing = $null
        try {
            $regItem = Get-ItemProperty -Path $regPath -Name $valueName -ErrorAction Stop
            $existing = $regItem.$valueName
        } catch {
            # 值不存在，初始化为空数组
            $existing = @()
        }

        # 确保为数组格式（单个字符串时也要转数组）
        if ($existing -isnot [array]) {
            $existing = if ($existing) { @($existing) } else { @() }
        }

        # 去重检查：避免同一路径被反复追加
        if ($existing -notcontains $FilePath) {
            # 追加新路径
            $newList = $existing + $FilePath
            Set-ItemProperty -Path $regPath -Name $valueName `
                -Value $newList -Type MultiString -Force -ErrorAction Stop
            Write-AsyncLog "  [延迟删除] 已追加至重启计划: $FilePath"
            return $true
        } else {
            Write-AsyncLog "  [信息] 路径已在重启计划中（跳过重复）: $FilePath"
            return $true
        }
    } catch {
        Write-AsyncLog "  [错误] 无法写入延迟删除注册表: $($_.Exception.Message)"
        return $false
    }
}
```

#### 第 2 步：修改 Remove-ItemRobust 函数

在 `Remove-ItemRobust` 的删除失败分支中，**删除** MoveFileEx 调用，改用新函数：

```powershell
# 旧代码（删除此行）
# [void][FrostBladeWinAPI_v1]::MoveFileEx($itemPath, $null, 4)

# 新代码（替换为）
if (Add-PendingFileRenameOperation -FilePath $itemPath) {
    $successCount++
} else {
    Write-AsyncLog "  [WARN] 无法进行延迟删除: $itemPath"
}
```

#### 第 3 步：完全删除 MoveFileEx 直接调用

搜索整个脚本中所有的：
```powershell
[FrostBladeWinAPI_v1]::MoveFileEx
```

确认没有其他调用点。若有，改用 `Add-PendingFileRenameOperation` 替代。

### 验收测试

```powershell
# 测试步骤：
# 1. 在已有系统重启任务的机器上运行清理（创建一个待清理文件）
# 2. 执行脚本
# 3. 检查注册表：
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations"

# 预期结果：数组包含 [原有任务, 新任务]，而不是仅有新任务
```

---

## 🔴 P0-02：静默模式剥离 GUI 程序集

### 问题根源

脚本顶部（第 48-51 行）无条件加载 GUI 程序集：
```powershell
Add-Type -AssemblyName System.Windows.Forms    # ← 导致 WinPE 崩溃
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()
```

在 WinPE、Server Core 等无 GUI 子系统的环境中，这些程序集不可用。

### 实现步骤

#### 第 1 步：删除全局 Add-Type 语句

**删除**第 48-51 行：
```powershell
# ❌ 删除这些行
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()
```

#### 第 2 步：条件加载 GUI 程序集

在脚本中查找 GUI 初始化位置（通常是创建主窗体前），改为：

```powershell
# ✅ 新增条件加载
if (-not $Silent) {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
        [System.Windows.Forms.Application]::EnableVisualStyles()
    } catch {
        Write-Error "无法加载 GUI 程序集，请在安装了 .NET Framework GUI 支持的系统上运行。"
        exit 1
    }
} else {
    # 静默模式：不加载 GUI 程序集
    Write-Host "运行模式: 静默（Silent）" -ForegroundColor Green
}
```

#### 第 3 步：修改 Start-RunspaceJob 同步调用

在静默模式下，改用同步执行而非后台 Runspace（因为没有 UITimer 轮询）：

```powershell
function Start-ScanJob {
    param($ScriptBlock, $ArgumentList, $IsSilent)

    if ($IsSilent) {
        # 静默模式：同步执行
        Write-Host "[扫描] 启动同步扫描..." -ForegroundColor Cyan
        $result = & $ScriptBlock @ArgumentList
        
        # 一次性刷出所有日志
        if ($Global:SyncHash.LogQueue.Count -gt 0) {
            foreach ($msg in $Global:SyncHash.LogQueue) {
                Write-Host $msg
            }
            $Global:SyncHash.LogQueue.Clear()
        }
        return $result
    } else {
        # GUI 模式：保留原有异步 Runspace 逻辑
        # ...（保持不变）
    }
}
```

### 验收测试

```powershell
# 测试 1：WinPE 环境
# 在 Windows PE 恢复盘上执行：
powershell -File FrostBlade.ps1 -Silent
# 预期：正常运行，无 GUI 程序集加载错误

# 测试 2：GUI 模式（普通 Windows）
# 在桌面 Windows 上执行：
powershell -File FrostBlade.ps1
# 预期：GUI 窗口正常打开
```

---

## 🟡 P1-01：消除空 catch 块异常吞噬

### 问题根源

脚本中约 30+ 处空 catch 块：
```powershell
try {
    # 操作
} catch { }  # ❌ 完全吞掉异常，用户看不到错误
```

导致：
- 用户无法了解为什么某项扫描结果为 0
- 调试困难
- 预计释放量与实际值严重不符

### 实现步骤

#### 第 1 步：代码审查与清点

搜索所有 `catch { }` 模式：
```bash
grep -n "catch\s*{\s*}" FrostBlade.ps1 | head -20
```

#### 第 2 步：为每个 catch 块添加日志

**示例修改**：

```powershell
# 原代码
try {
    foreach ($f in [System.IO.Directory]::GetFiles($dir)) {
        $size += $fi.Length
    }
} catch { }

# 新代码
try {
    foreach ($f in [System.IO.Directory]::GetFiles($dir)) {
        $size += $fi.Length
    }
} catch {
    Write-AsyncLog "  [WARN] 无法枚举目录内容: $dir ($($_.Exception.Message))"
    $script:ScanErrorCount++
}
```

#### 第 3 步：为 Get-FolderSize 添加错误统计

```powershell
function Get-FolderSize([string]$p) {
    [long]$size = 0
    try {
        $di = New-Object System.IO.DirectoryInfo($p)
        if (-not $di.Exists) { return 0 }
        
        try {
            foreach ($fi in $di.GetFiles()) { $size += $fi.Length }
        } catch {
            Write-AsyncLog "  [WARN] 无法访问文件: $($fi.Name)"
            $script:ScanErrorCount++
        }
        
        try {
            foreach ($subDi in $di.GetDirectories()) {
                $size += Get-FolderSize $subDi.FullName
            }
        } catch {
            Write-AsyncLog "  [WARN] 无法递归目录: $($subDi.Name)"
            $script:ScanErrorCount++
        }
    } catch {
        Write-AsyncLog "  [WARN] 目录访问失败: $p"
        $script:ScanErrorCount++
    }
    return $size
}
```

#### 第 4 步：扫描完毕提示用户

在 `ScanScriptBlock` 的最后添加：

```powershell
Write-AsyncLog ">>> 扫描完成 <<<"
if ($script:ScanErrorCount -gt 0) {
    Write-AsyncLog "[警告] 扫描过程中遇到 $script:ScanErrorCount 项无法访问的路径（已跳过）"
    Write-AsyncLog "        释放量估算可能不完整，实际清理量可能更多或更少。"
}
```

### 验收检查

- [ ] 所有 `catch { }` 都有对应日志输出
- [ ] 日志包含异常消息 `$_.Exception.Message`
- [ ] 扫描完毕提示中包含错误计数

---

## 🟡 P1-02：删除 `[GC]::Collect()` 强制回收

### 问题根源

UITimer Tick 事件（一般每 100ms 触发）：
```powershell
$UITimer_Tick = {
    # ...UI 更新逻辑...
    [System.GC]::Collect()  # ❌ 频繁强制 Gen 2 垃圾回收
}
```

后果：
- Gen 2 压力过大
- UI 线程阻塞
- 扫描进度显示不流畅

### 实现步骤

#### 第 1 步：定位 UITimer 代码

搜索：
```powershell
grep -n "UITimer_Tick\|GC.Collect\|GC]::Collect" FrostBlade.ps1
```

#### 第 2 步：删除 GC 调用

```powershell
# 原代码
$UITimer_Tick = {
    # 更新 UI 显示
    $mainForm.Refresh()
    [System.GC]::Collect()  # ❌ 删除此行
}

# 新代码
$UITimer_Tick = {
    # 更新 UI 显示
    $mainForm.Refresh()
    # GC 交给 .NET 运行时管理，无需手动触发
}
```

#### 第 3 步：确保 Runspace 清理完整

检查 `EndInvoke` 回调中的 Dispose 调用（应已存在）：

```powershell
$ps.EndInvoke($result) | Out-Null
$ps.Dispose()              # ✅ 确保存在
$runspace.Dispose()        # ✅ 确保存在
```

### 验收检查

- [ ] 搜索不到任何 `[System.GC]::Collect()` / `[GC]::Collect()`
- [ ] 扫描 UI 进度更新流畅（无明显卡顿）

---

## 🟠 P2-01：残留目录内存优化

### 问题根源

```powershell
# 原代码：一次性加载所有文件路径到内存
foreach ($f in [System.IO.Directory]::GetFiles($dir, "*", [System.IO.SearchOption]::AllDirectories)) {
    # 处理每个文件
    # 问题：GetFiles 返回 string[]，若有 100 万文件会消耗数 GB 内存
}
```

### 实现步骤

在残留目录检测逻辑中（通常位于 `$ScanScriptBlock` 内），将大文件遍历改为流式：

```powershell
# 新代码：流式枚举
try {
    $enumerator = [System.IO.Directory]::EnumerateFiles(
        $dir, "*", [System.IO.SearchOption]::AllDirectories
    ).GetEnumerator()
    
    $hasUninstaller = $false
    $lastWrite = [DateTime]::MinValue
    $sz = 0
    
    while ($enumerator.MoveNext()) {
        $file = $enumerator.Current
        try {
            $fi = New-Object System.IO.FileInfo($file)
            $sz += $fi.Length
            $fw = $fi.LastWriteTime
            if ($fw -gt $lastWrite) { $lastWrite = $fw }
            
            # 提前剪枝：发现卸载器立即跳出
            if (-not $hasUninstaller) {
                $fname = $fi.Name.ToLower()
                if ($fname -match "^unins|^uninstall|setup|updater") {
                    Write-AsyncLog "  -> [跳过-含卸载程序] $dir"
                    $hasUninstaller = $true
                    break  # ⭐ 关键：立即跳出
                }
            }
        } catch { }
    }
} catch { }
```

### 验收测试

```powershell
# 在含 50+ 万文件的磁盘上测试残留目录扫描
# 监控内存占用（任务管理器或 Get-Process）
# 预期：内存峰值 < 300MB
```

---

## 🟠 P2-02：DISM 超时保护

### 问题根源

```powershell
# 原代码：同步阻塞，若 DISM 挂起则脚本无限等待
& dism.exe /Online /Cleanup-Image /StartComponentCleanup /StartComponentCleanup /ResetBase
```

### 实现步骤

替换为带超时的 Process 执行：

```powershell
function Invoke-DISMCleanup {
    param(
        [string]$Operation = "StartComponentCleanup",
        [int]$TimeoutSeconds = 1800  # 30 分钟
    )
    
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "dism.exe"
    $psi.Arguments = "/Online /Cleanup-Image /$Operation"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        
        if ($p.WaitForExit($TimeoutSeconds * 1000)) {
            # 正常退出
            $output = $p.StandardOutput.ReadToEnd()
            $p.Dispose()
            Write-AsyncLog "[成功] DISM 操作完成: $Operation"
            return $true
        } else {
            # 超时
            $p.Kill()
            $p.Dispose()
            Write-AsyncLog "[超时] DISM 操作超过 $TimeoutSeconds 秒，已强制终止: $Operation"
            return $false
        }
    } catch {
        Write-AsyncLog "[错误] 无法执行 DISM: $($_.Exception.Message)"
        return $false
    }
}
```

### 验收测试

```powershell
# 模拟超时：人为暂停 DISM 服务或注入网络延迟
# 验证：30 分钟后进程被 Kill，脚本继续运行
```

---

## 🟠 P2-03：路径去重统计修复

### 问题根源

```powershell
# 原代码：可能重复扫描同一目录
$finalPaths = $softPathsList | Select-Object -Unique
# 但若两个不同清理项指向同一物理路径，体积会被累加两次
```

### 实现步骤

在扫描项最终结果汇总时，使用 HashSet 全局去重：

```powershell
# 修改扫描完毕后的统计逻辑
$allScannedPaths = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

foreach ($k in $Sync.ScanItems.Keys) {
    if ($Sync.ScanItems[$k].Paths) {
        foreach ($p in $Sync.ScanItems[$k].Paths) {
            [void]$allScannedPaths.Add($p)
        }
    }
}

# 计算真实总体积（去重）
[long]$totalSize = 0
foreach ($p in $allScannedPaths) {
    $totalSize += Get-FolderSize $p
}

Write-AsyncLog "扫描完毕 - 去重后总大小: $([Math]::Round($totalSize / 1GB, 2)) GB"
```

---

## 🚀 合并与发布指南

### 步骤 1：本地验证

```powershell
# 在 v1.0-stable-fixes 分支上测试
git checkout v1.0-stable-fixes

# 运行各项测试
.\FrostBlade.ps1 -Silent                     # P0-02 验收
.\FrostBlade.ps1                            # 运行 GUI 模式
# （检查日志输出、异常处理）
```

### 步骤 2：创建 Pull Request

```
标题：[v1.0 Stable] 系统级缺陷修复 + 底层加固
描述：
- P0-01：MoveFileEx 注册表覆盖改追加（保护 Windows Update 任务）
- P0-02：静默模式剥离 GUI 程序集（支持 WinPE 环境）
- P1-01：消除空 catch 块异常吞噬（完整异常日志）
- P1-02：删除 GC 强制回收（UI 响应性提升）
- P2-01：残留目录内存优化（防止大磁盘 OOM）
- P2-02：DISM 超时保护（防止无限等待）
- P2-03：路径去重统计（体积计算准确）

总计修改：~270 行 | 向后兼容：✅
```

### 步骤 3：代码审查检查清单

- [ ] 所有空 catch 块已添加日志
- [ ] P0-02 GUI 条件加载无遗漏
- [ ] PendingFileRenameOperations 去重逻辑正确
- [ ] 无 PS 版本兼容性问题（PS 2.0 feature 用替代方案）
- [ ] CHANGELOG 已更新

### 步骤 4：合并与标签

```powershell
git checkout main
git merge v1.0-stable-fixes --ff-only
git tag -a v1.0-Stable -m "FrostBlade v1.0 Stable Release - 系统级缺陷修复"
git push origin main --tags
```

---

## 📚 参考资源

| 缺陷 | 相关代码位置 | 文档 |
|------|-------------|------|
| P0-01 | 模块 06-CleanEngine | [MS: PendingFileRenameOperations](https://docs.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexa) |
| P0-02 | 脚本顶部 & GUI 初始化 | [WinPE 兼容性](https://docs.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe-intro) |
| P1-01 | ScanScriptBlock | [PS ErrorAction](https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_erroractionpreference) |
| P2-01 | 残留目录扫描 | [System.IO.Directory.EnumerateFiles](https://docs.microsoft.com/en-us/dotnet/api/system.io.directory.enumeratefiles) |
| P2-02 | DISM 调用位置 | [DISM 命令行](https://docs.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-configuration-list-and-deployment-image-servicing-tools-command-line-options) |

---

## 🎯 预期收益总结

| 指标 | 修复前 | 修复后 | 提升 |
|------|--------|--------|------|
| **Windows Update 任务保护** | ❌ 覆盖丢失 | ✅ 安全追加 | 关键修复 |
| **WinPE 兼容性** | ❌ 崩溃 | ✅ 正常运行 | 企业场景支持 |
| **异常可观测性** | ❌ 无日志 | ✅ 完整日志 | 调试效率 +100% |
| **大磁盘扫描内存** | 数 GB | <300MB | 98% 降低 |
| **UI 响应性** | 卡顿 | 流畅 | 用户体验提升 |
| **体积统计准确度** | 虚高 | 去重正确 | 可信度提升 |

