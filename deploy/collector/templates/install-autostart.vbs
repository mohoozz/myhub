' MyHub 采集器 —— 注册开机自启（当前用户，无需管理员）
Option Explicit

Dim fso, sh, root, py, script, cmd, answer
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

root = fso.GetParentFolderName(WScript.ScriptFullName)
py = root & "\runtime\python.exe"
script = root & "\start-background.vbs"

If Not fso.FileExists(py) Then
    MsgBox "找不到 runtime\python.exe，压缩包可能没有解压完整，请重新解压后再试。", 16, "MyHub 采集器"
    WScript.Quit 1
End If
If Not fso.FileExists(script) Then
    MsgBox "找不到 start-background.vbs，请把压缩包完整解压后再运行本脚本。", 16, "MyHub 采集器"
    WScript.Quit 1
End If

cmd = "wscript.exe """ & script & """"
On Error Resume Next
sh.RegWrite "HKCU\Software\Microsoft\Windows\CurrentVersion\Run\MyHubCollector", cmd, "REG_SZ"
If Err.Number <> 0 Then
    MsgBox "写入开机自启失败：" & Err.Description, 16, "MyHub 采集器"
    WScript.Quit 1
End If
On Error GoTo 0

answer = MsgBox("已设置为开机自动后台启动（当前用户）。" & vbCrLf & vbCrLf & _
    "服务地址：http://127.0.0.1:17865/" & vbCrLf & _
    "（端口固定；起不来时原因见 data\logs\myhub-collector.log）" & vbCrLf & _
    "日志目录：" & root & "\data\logs" & vbCrLf & vbCrLf & _
    "要现在就在后台启动一次吗？", 4 + 32, "MyHub 采集器")

If answer = 6 Then
    sh.Run "wscript.exe """ & script & """", 0, False
End If
