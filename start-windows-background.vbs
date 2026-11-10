Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
baseDir = fso.GetParentFolderName(WScript.ScriptFullName)

WshShell.Run "cmd.exe /c for /f ""tokens=5"" %a in ('netstat -ano ^| findstr :19889 ^| findstr LISTENING') do taskkill /F /PID %a", 0, True

nodeExe = "node"
If fso.FileExists("C:\Program Files\nodejs\node.exe") Then
    nodeExe = "C:\Program Files\nodejs\node.exe"
End If

cmd = """" & nodeExe & """ """ & baseDir & "\desktop\server.js"" --open"
WshShell.Run cmd, 0, False
