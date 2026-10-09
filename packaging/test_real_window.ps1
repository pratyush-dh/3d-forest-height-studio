<#
.SYNOPSIS
  Launches the INSTALLED app with its real browser window (headless, with a DevTools port) and checks what Edge opens.
  Used by CI and runnable locally:  .\packaging\test_real_window.ps1 -InstallDir "$env:LOCALAPPDATA\Programs\3D Forest Height Studio"

  Why: a path with spaces ("3D Forest Height Studio") was once split into several Edge arguments. Edge then opened the
  pieces as web pages and, in the brand-new profile it created, signed in and installed the user's synced extensions,
  flooding the screen with extension welcome pages. Tests that skip the window (STUDIO_NO_WINDOW) cannot catch that.
#>
param([Parameter(Mandatory = $true)][string]$InstallDir, [int]$Port = 9444)
$ErrorActionPreference = "Stop"
$failures = @()
$stray = Join-Path $env:LOCALAPPDATA "3D"
if (Test-Path $stray) { throw "Refusing to run: '$stray' already exists. Delete it first so the test can detect a new one." }

Get-CimInstance Win32_Process -Filter "Name='Rscript.exe'" | Where-Object { $_.ExecutablePath -like "$InstallDir*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Seconds 2
Remove-Item Env:STUDIO_NO_WINDOW -ErrorAction SilentlyContinue
$env:STUDIO_EDGE_ARGS = "--remote-debugging-port=$Port --headless=new"
Start-Process wscript.exe -ArgumentList "`"$InstallDir\Studio.vbs`""
$env:STUDIO_EDGE_ARGS = $null

$pages = $null
foreach ($i in 1..60) {
    try { $pages = Invoke-RestMethod "http://127.0.0.1:$Port/json" -TimeoutSec 3
          if (@($pages | Where-Object { $_.type -eq "page" -and $_.url -like "http://127.0.0.1*" }).Count -ge 1) { break } } catch { }
    Start-Sleep -Seconds 2
}
Start-Sleep -Seconds 12   # stray welcome pages, if any, appear a few seconds after start-up
try {
    $open = @((Invoke-RestMethod "http://127.0.0.1:$Port/json") | Where-Object { $_.type -eq "page" })
    $open | ForEach-Object { Write-Host "  page: $($_.url)" }
    if ($open.Count -ne 1) { $failures += "Edge opened $($open.Count) pages; expected exactly 1" }
    elseif ($open[0].url -notlike "http://127.0.0.1*") { $failures += "the one page is not the app: $($open[0].url)" }
} catch { $failures += "could not read Edge's open pages (DevTools port unreachable): the window did not start as expected" }

$cmd = (Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -match "--app=http://127.0.0.1" } | Select-Object -First 1).CommandLine
Write-Host "  cmd : $cmd"
if (-not $cmd) { $failures += "could not find the app's Edge process" }
else {
    if ($cmd -notmatch '"--user-data-dir=[^"]*3D Forest Height Studio[^"]*window-profile"') { $failures += "--user-data-dir is not quoted as ONE argument" }
    if ($cmd -notmatch "--disable-sync") { $failures += "--disable-sync missing" }
    if ($cmd -notmatch "--disable-extensions") { $failures += "--disable-extensions missing" }
}
if (Test-Path $stray) { $failures += "a stray profile folder was created: $stray" }

# shut the app down again
try { $v = Invoke-RestMethod "http://127.0.0.1:$Port/json/version"; $ws = New-Object System.Net.WebSockets.ClientWebSocket
      $ws.ConnectAsync($v.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
      $b = [Text.Encoding]::UTF8.GetBytes('{"id":1,"method":"Browser.close"}')
      $ws.SendAsync([ArraySegment[byte]]$b, "Text", $true, [Threading.CancellationToken]::None).Wait() } catch { }
Start-Sleep -Seconds 14
Get-CimInstance Win32_Process -Filter "Name='Rscript.exe'" | Where-Object { $_.ExecutablePath -like "$InstallDir*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

if ($failures.Count) { $failures | ForEach-Object { Write-Host "FAIL: $_" -ForegroundColor Red }; exit 1 }
Write-Host "Real window test passed" -ForegroundColor Green
