# 注册 Windows 计划任务：每天 06:00 采集前一天的内容
# 用法（管理员或普通用户均可）：
#   powershell -ExecutionPolicy Bypass -File scripts\register-task.ps1
# 卸载：
#   Unregister-ScheduledTask -TaskName "MyHubCollector" -Confirm:$false

param(
    [string]$TaskName = "MyHubCollector",
    [string]$Time = "06:00",
    [string]$Python = "python"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $root "data\logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$log = Join-Path $logDir "collect.log"
# 注意：必须先切到项目目录，config 才有正确的 BASE_DIR
$action = New-ScheduledTaskAction -Execute "cmd.exe" `
    -Argument "/c cd /d `"$root`" && `"$Python`" -m app collect >> `"$log`" 2>&1" `
    -WorkingDirectory $root

$trigger = New-ScheduledTaskTrigger -Daily -At $Time
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 4)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Description "MyHub 每日关注内容采集" -Force | Out-Null

Write-Host "已注册计划任务 '$TaskName'，每天 $Time 运行。日志：$log"
Write-Host "手动测试：cd `"$root`"; $Python -m app collect --no-download"
