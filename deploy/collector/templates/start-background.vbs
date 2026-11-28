' MyHub 采集器 —— 后台启动（无窗口、不弹浏览器）
' 开机自启就是由页面开关注册本脚本，
' 也可以手动双击运行，之后用浏览器访问 http://127.0.0.1:17865/
Option Explicit

Dim fso, sh, root, py
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

root = fso.GetParentFolderName(WScript.ScriptFullName)
py = root & "\runtime\python.exe"

If Not fso.FileExists(py) Then
    WScript.Quit 1
End If

sh.CurrentDirectory = root

' 子进程继承这里的 PROCESS 环境变量
sh.Environment("PROCESS")("PYTHONUTF8") = "1"
sh.Environment("PROCESS")("PYTHONIOENCODING") = "utf-8"
If fso.FolderExists(root & "\runtime\ms-playwright") Then
    sh.Environment("PROCESS")("PLAYWRIGHT_BROWSERS_PATH") = root & "\runtime\ms-playwright"
End If

' 第二个参数 0 = 隐藏窗口，第三个参数 False = 不等它结束
sh.Run """" & py & """ -m app serve --port 17865 --no-browser", 0, False
