# 为 S6 SMB 验证创建临时共享与专用测试账户
#
# 设计原则：
#   - **不使用也不读取用户自己的账户密码**，改为新建一个一次性本地账户
#   - 账户与共享都带 myhub_s6 前缀，便于识别与清理
#   - 配套 smb-teardown.ps1 可完全还原系统状态
#
# 需要管理员权限。
param([switch]$Teardown)

$ErrorActionPreference = 'Continue'

$shareName = 'myhub_s6_share'
$userName  = 'myhub_s6_test'
$sharePath = Join-Path $env:TEMP 'myhub-s6-smb'
$credFile  = Join-Path $env:TEMP 'myhub-s6-cred.txt'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Error 'Administrator privileges required.'
    exit 1
}

if ($Teardown) {
    Write-Host '=== Teardown ==='
    Remove-SmbShare -Name $shareName -Force -ErrorAction SilentlyContinue
    Write-Host "  share removed: $shareName"
    Remove-LocalUser -Name $userName -ErrorAction SilentlyContinue
    Write-Host "  user removed : $userName"
    Remove-Item $sharePath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $credFile -Force -ErrorAction SilentlyContinue
    Write-Host '  temp files removed'
    exit 0
}

Write-Host '=== Setup ==='

# ---- 测试目录与素材 ----
New-Item -ItemType Directory -Force -Path (Join-Path $sharePath 'media') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $sharePath 'docs')  | Out-Null

# 固定内容，便于校验 Range 读的字节正确性
$payload = [byte[]](0..255)            # 256 字节，值等于下标
[System.IO.File]::WriteAllBytes((Join-Path $sharePath 'ramp.bin'), $payload)
Set-Content -Path (Join-Path $sharePath 'readme.txt') `
            -Value 'myhub smb test' -Encoding ascii -NoNewline
Set-Content -Path (Join-Path $sharePath 'media\clip.mkv') `
            -Value 'fake video payload' -Encoding ascii -NoNewline
Write-Host "  sample tree: $sharePath"

# ---- 一次性测试账户 ----
$plain = 'Mh!' + ([guid]::NewGuid().ToString('N').Substring(0, 16)) + 'Zq9'
$secure = ConvertTo-SecureString $plain -AsPlainText -Force

Remove-LocalUser -Name $userName -ErrorAction SilentlyContinue
try {
    # 注意：不要加 -UserMayNotChangePassword，该参数在部分 Windows 版本上
    # 会导致 New-LocalUser 静默失败
    $u = New-LocalUser -Name $userName -Password $secure `
                       -FullName 'MyHub S6 Probe' `
                       -Description 'MyHub S6 probe - safe to delete' `
                       -PasswordNeverExpires -ErrorAction Stop
    Write-Host "  user created: $userName  (SID=$($u.SID.Value))"
} catch {
    Write-Error "New-LocalUser failed: $($_.Exception.Message)"
    exit 1
}

$sid = (Get-LocalUser -Name $userName).SID
# 新建账户的名称到 SID 映射可能尚未在 LSA 缓存中就绪，稍等再授权
Start-Sleep -Milliseconds 800
$account = "$env:COMPUTERNAME\$userName"

# ---- 共享 ----
# 注意：New-SmbShare 的 -FullAccess 只接受账户名，不接受 SID 字符串
Remove-SmbShare -Name $shareName -Force -ErrorAction SilentlyContinue
try {
    New-SmbShare -Name $shareName -Path $sharePath `
                 -FullAccess $account -ErrorAction Stop | Out-Null
    Write-Host "  share created: \\localhost\$shareName"
} catch {
    Write-Error "New-SmbShare failed: $($_.Exception.Message)"
    exit 1
}

# NTFS 读权限（同样用 SID）
try {
    $acl = Get-Acl $sharePath
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sid, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -Path $sharePath -AclObject $acl
    Write-Host '  NTFS ACL granted'
} catch {
    Write-Error "Set-Acl failed: $($_.Exception.Message)"
    exit 1
}

# 凭据交给探针使用（仅本机临时账户，测完随 teardown 删除）
Set-Content -Path $credFile -Value "$userName`n$plain" -Encoding ascii
Write-Host "  credentials -> $credFile"

Write-Host ''
Write-Host "share : \\localhost\$shareName"
Write-Host "user  : $userName"
