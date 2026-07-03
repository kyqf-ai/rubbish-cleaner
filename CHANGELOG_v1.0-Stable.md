# FrostBlade v1.0 Stable 迭代修复日志

## 版本信息
- **版本**：v1.0 Stable（自 Beta 升级）
- **目标**：系统级缺陷修复 + 底层稳定性加固
- **修改范围**：~270 行代码改动（净增/减）

---

## 🔴 P0 级缺陷修复（系统稳定性与底层安全）

### P0-01：MoveFileEx 注册表覆盖改追加（修复 Windows Update 冲突）

**问题描述**：
- `MoveFileEx` 的 `MOVEFILE_DELAY_UNTIL_REBOOT` 标志直接覆盖注册表 `PendingFileRenameOperations`
- 导致 Windows Update 等系统组件的已有重启任务被丢失
- 风险等级：**高** — 可导致系统更新异常

**修复方案**：
- ✅ 保留底层 C# P/Invoke 声明（未来可能需要）
- ✅ 新增 `Add-PendingFileRenameOperation` PowerShell 函数
  - 读取现有 MULTI_SZ 值
  - 去重检查（避免重复追加）
  - 原子化写入（通过正确的注册表操作）
- ✅ `Remove-ItemRobust` 改用新函数代替直接 MoveFileEx 调用
- ✅ 删除所有 `[FrostBladeWinAPI_v1]::MoveFileEx($path, $null, 4)` 代码

**测试验收**：在已存在系统重启任务的机器上运行清理，检查注册表值是否正确追加

---

### P0-02：静默模式剥离 GUI 程序集硬依赖（修复 WinPE 兼容性）

**问题描述**：
- 脚本无条件加载 `System.Windows.Forms` / `System.Drawing`
- 导致在 WinPE、Server Core、Nano Server 等无 GUI 子系统环境崩溃
- 风险等级：**高** — 影响企业级灾难恢复场景

**修复方案**：
- ✅ 删除脚本顶部全局 `Add-Type` 语句（第 48-51 行）
- ✅ 移至 GUI 分支内部（UI 初始化位置）
- ✅ 静默模式使用 `Write-Host` / `Write-Progress` 输出日志
- ✅ `Start-RunspaceJob` 在静默模式改为同步 `$ps.Invoke()`
- ✅ 添加 `finally` 块一次性刷出 `LogQueue` 内容

**测试验收**：在 Windows PE 恢复环境执行 `powershell -File FrostBlade.ps1 -Silent`，应正常完成扫描

---

## 🟡 P1 级缺陷修复（可观测性与准确性）

### P1-01：消除空 catch 块异常吞噬黑洞

**问题描述**：
- ~30 处 `catch { }` 完全静默，导致用户看不到真实的扫描错误
- 预计释放量与实际值严重偏离（用户无法得知原因）
- 风险等级：**中** — 用户体验与调试困难

**修复方案**：
- ✅ 硬性规范：**禁止空 catch 块**
- ✅ 每个 `catch` 至少调用 `Write-AsyncLog` 记录异常
  ```powershell
  catch {
      Write-AsyncLog "  [WARN] 无法访问路径: $path ($($_.Exception.Message))"
      $script:ScanErrorCount++
  }
  ```
- ✅ 为 `Get-FolderSize` 引入错误统计累加器
- ✅ 扫描完毕若 `ScanErrorCount > 0`，GUI 显示：
  ```
  "扫描完成，但存在 N 项无法访问（已跳过），释放量估算可能不完整。"
  ```

**代码示例**：
```powershell
try {
    foreach ($f in [System.IO.Directory]::GetFiles($dir)) { $sz += $f.Length }
} catch {
    Write-AsyncLog "  [WARN] 无法枚举目录: $dir"
    $script:ScanErrorCount++
}
```

---

### P1-02：删除误导性 `[GC]::Collect()` 强制回收

**问题描述**：
- UITimer 每 100ms 执行 `[System.GC]::Collect()` 强制垃圾回收
- 导致 Gen 2 回收频繁 + UI 卡顿
- 风险等级：**低** — 仅影响主线程响应性

**修复方案**：
- ✅ 删除 UITimer Tick 事件中的所有 `[System.GC]::Collect()` 调用
- ✅ 保留 `EndInvoke` 回调中的 `$ps.Dispose()` 和 `$runspace.Dispose()` 正确清理

---

## 🟠 P2 级优化（性能与鲁棒性）

### P2-01：残留目录扫描内存优化（GetFiles → EnumerateFiles）

**问题描述**：
- `[System.IO.Directory]::GetFiles($dir, "*", AllDirectories)` 一次性加载数百万路径到内存
- 百万级文件磁盘易触发 OutOfMemoryException
- 风险等级：**中** — 大盘符清理时崩溃

**修复方案**：
- ✅ 替换为 `EnumerateFiles()` 流式枚举
- ✅ 引入提前剪枝：一旦发现 `unins*.exe` 或 90 天内写入，立即 `break` 跳出
- ✅ 内存占用从数 GB 降至 <300MB

```powershell
$enumerator = [System.IO.Directory]::EnumerateFiles($dir, "*", [System.IO.SearchOption]::AllDirectories).GetEnumerator()
while ($enumerator.MoveNext()) {
    $file = $enumerator.Current
    # 处理逻辑...
    if ($detectedAsUnneeded) { break }  # 提前剪枝
}
```

---

### P2-02：DISM / Compact OS 超时保护

**问题描述**：
- `& dism.exe` 同步阻塞，若 DISM 服务挂起则脚本无限等待
- 风险等级：**低** — 仅在特殊环境影响

**修复方案**：
- ✅ 改用 .NET `System.Diagnostics.Process` 包装
- ✅ 设 30 分钟超时上限（WaitForExit）
- ✅ 超时自动 Kill，记录日志

```powershell
$p = [System.Diagnostics.Process]::Start($psi)
if ($p.WaitForExit(1800000)) {  # 30分钟
    # 读取输出
} else {
    $p.Kill()
    Write-AsyncLog "  [超时] DISM 操作超过 30 分钟，已强制终止"
}
```

---

### P2-03：清理项体积重复计数去重

**问题描述**：
- `SoftwareCache` 与 `WeChatMedia` 可能重复扫描同一物理目录
- 导致界面显示的总字节数虚高
- 风险等级：**低** — 仅影响统计显示

**修复方案**：
- ✅ 扫描阶段使用 `[System.Collections.Generic.HashSet[string]]` 全局去重
- ✅ 每项 Size 基于去重后的唯一路径集合累加

---

## 📊 修改统计

| 优先级 | 编号 | 描述 | 预计行数 |
|--------|------|------|---------|
| **P0** | 2.1  | MoveFileEx 注册表覆盖改追加 | ~60 |
| **P0** | 2.2  | 静默模式剥离 GUI 程序集 | ~20 |
| **P1** | 3.1  | 消除空 catch 块 | ~80 |
| **P1** | 3.2  | 删除 GC.Collect() | ~2 |
| **P2** | 4.1  | 残留目录 EnumerateFiles 改造 | ~50 |
| **P2** | 4.2  | DISM 超时保护 | ~40 |
| **P2** | 4.3  | 路径去重统计修复 | ~15 |
| | **总计** | | **~267 行** |

---

## 🧪 验收检查清单

- [ ] P0-01：PendingFileRenameOperations 非破坏性测试
- [ ] P0-02：WinPE 静默启动测试
- [ ] P1-01：异常日志记录完整性检查
- [ ] P1-02：UITimer 移除验证
- [ ] P2-01：百万级文件磁盘内存占用 <300MB
- [ ] P2-02：DISM 超时自动 Kill 功能测试
- [ ] P2-03：路径去重统计准确性验证

---

## 🎯 预期收益

✅ **系统稳定性**：消除 Windows Update 冲突 + WinPE 兼容  
✅ **可观测性**：异常信息完整记录，用户能看到真实原因  
✅ **性能**：内存占用大幅下降，防止大磁盘清理崩溃  
✅ **准确性**：路径去重，统计数据真实可信

---

## 📝 后续维护

- 若需添加新的规则，只修改 `模块 02-Rules` 中的 `BuiltInRules`
- 若发现新的异常吞噬点，必须在 catch 块中添加日志
- PS 版本兼容性始终优先：PS2.0 feature 用 PSIsContainer 替代 -Directory

