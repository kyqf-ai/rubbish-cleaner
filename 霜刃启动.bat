@echo off
:: ------------------------------------------------------------
:: 霜刃 FrostBlade v1.0 - 启动器
:: 作用：隐藏窗口启动 PowerShell，并以管理员权限、同样隐藏窗口的方式，重新执行同目录下的 FrostBlade.ps1
:: 说明：本工具仅面向个人电脑清理场景，不建议在企业/生产环境批量部署或
:: %~dp0 表示本批处理文件所在目录（自带结尾反斜杠，无需再手动拼接）
:: 使用前提：本 .bat 必须和 FrostBlade.ps1 放在同一个文件夹下
:: ------------------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command ^
    "Start-Process PowerShell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%~dp0FrostBlade.ps1\"' -Verb RunAs -WindowStyle Hidden"
exit
