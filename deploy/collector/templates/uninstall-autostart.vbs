' MyHub 采集器 —— 取消开机自启
Option Explicit

Dim sh
Set sh = CreateObject("WScript.Shell")

On Error Resume Next
sh.RegDelete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run\MyHubCollector"
If Err.Number <> 0 Then
    MsgBox "取消开机自启失败：" & Err.Description, 16, "MyHub 采集器"
    WScript.Quit 1
End If
On Error GoTo 0

MsgBox "已取消开机自启，下次开机不会再自动启动。", 64, "MyHub 采集器"
