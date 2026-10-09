' Starts 3D Forest Height Studio without showing a console window.
' Uses only the bundled R runtime and library, never the user's own R installation.
Option Explicit
Dim sh, fso, root, data, studio, rscript, cmd, userEnv, key

Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

root   = fso.GetParentFolderName(WScript.ScriptFullName)
studio = root & "\studio"
data   = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\3D Forest Height Studio"
If Not fso.FolderExists(data) Then fso.CreateFolder(data)

Set userEnv = sh.Environment("Process")
userEnv("STUDIO_DATA_DIR")  = data
userEnv("R_HOME")           = root & "\R"
userEnv("R_LIBS")           = root & "\lib"
userEnv("R_LIBS_USER")      = root & "\lib"
userEnv("R_LIBS_SITE")      = ""
userEnv("R_ENVIRON_USER")   = root & "\no-such-file"
userEnv("R_PROFILE_USER")   = root & "\no-such-file"
If userEnv("PROCESSOR_ARCHITECTURE") = "" Then userEnv("PROCESSOR_ARCHITECTURE") = "AMD64"

rscript = root & "\R\bin\x64\Rscript.exe"
sh.CurrentDirectory = data   ' never write into the program folder (it may be read-only)

' cmd /c "<exe> <script> > log 2>&1"  (the outer quotes are consumed by cmd)
cmd = "cmd /c """"" & rscript & """ """ & studio & "\launch_studio.R"" > """ & data & "\studio.log"" 2>&1"""
sh.Run cmd, 0, False
