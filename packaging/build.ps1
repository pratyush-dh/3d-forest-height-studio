<#
.SYNOPSIS
  Assembles the self-contained app folder (dist\) that the installer packages:
  portable R + the app's R packages + the app + launcher. Nothing machine-specific is baked in.

.PARAMETER Version   Version string written into the bundle (default: from app\app.R).
.PARAMETER RHome     R installation to copy (default: newest under Program Files\R, or $env:R_HOME).
.PARAMETER Out       Output folder (default: <repo>\dist).
.PARAMETER ReuseLib  Keep an existing dist\lib instead of reinstalling packages (faster rebuilds while developing).
#>
param(
    [string]$Version = "",
    [string]$RHome = "",
    [string]$Out = "",
    [switch]$ReuseLib
)
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
if (-not $Out) { $Out = Join-Path $repo "dist" }
if (-not $Version) {
    $m = Select-String -Path (Join-Path $repo "app\app.R") -Pattern 'APP_VERSION <- "([^"]+)"' | Select-Object -First 1
    $Version = $m.Matches[0].Groups[1].Value
}
if (-not $RHome) {
    if ($env:R_HOME -and (Test-Path "$env:R_HOME\bin\x64\Rscript.exe")) { $RHome = $env:R_HOME }
    else { $RHome = (Get-ChildItem "$env:ProgramFiles\R" -Directory -Filter "R-*" | Sort-Object Name -Descending | Select-Object -First 1).FullName }
}
if (-not (Test-Path "$RHome\bin\x64\Rscript.exe")) { throw "R not found at '$RHome'. Pass -RHome." }
Write-Host "Building 3D Forest Height Studio $Version from R at $RHome" -ForegroundColor Cyan

$keepLib = $ReuseLib -and (Test-Path "$Out\lib")
if (Test-Path $Out) {
    Get-ChildItem $Out -Force | Where-Object { -not ($keepLib -and $_.Name -eq "lib") } | Remove-Item -Recurse -Force
}
New-Item -ItemType Directory -Force $Out | Out-Null

# 1. R runtime (without documentation, tests and Tcl/Tk, none of which the app uses)
Write-Host "1/5 copying the R runtime"
robocopy $RHome "$Out\R" /E /NFL /NDL /NJH /NJS /NP /XD doc tests Tcl | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }

# 2. App packages, installed by the bundled R itself so the bundle is self-consistent
$rscript = "$Out\R\bin\x64\Rscript.exe"
function Invoke-BundledR([string]$file, [string[]]$extra = @()) {
    $env:R_LIBS_USER = "$Out\no-such-lib"; $env:R_LIBS_SITE = ""; $env:R_PROFILE_USER = "$Out\none"; $env:R_ENVIRON_USER = "$Out\none"
    & $rscript $file @extra
    if ($LASTEXITCODE -ne 0) { throw "Rscript failed: $file ($LASTEXITCODE)" }
}
if ($keepLib) { Write-Host "2/5 re-using existing library" }
else {
    Write-Host "2/5 installing R packages from CRAN binaries (several minutes, ~350 MB download)"
    $env:BUNDLE_LIB = "$Out\lib"
    Invoke-BundledR "$PSScriptRoot\install_libs.R"
}

# 3. Trim what is never used at run time
Write-Host "3/5 trimming"
Get-ChildItem "$Out\lib" -Directory | ForEach-Object {
    foreach ($d in "doc", "tests", "html", "help", "demo", "examples") { $p = Join-Path $_.FullName $d; if (Test-Path $p) { Remove-Item $p -Recurse -Force } }
}

# 4. The app + launcher
Write-Host "4/5 copying the app"
$studio = "$Out\studio"
New-Item -ItemType Directory -Force $studio | Out-Null
robocopy "$repo\app" "$studio\app" /E /NFL /NDL /NJH /NJS /NP | Out-Null
robocopy "$repo\R" "$studio\R" /E /NFL /NDL /NJH /NJS /NP | Out-Null
Copy-Item "$repo\launch_studio.R" "$studio\launch_studio.R"
Copy-Item "$PSScriptRoot\Studio.vbs" "$Out\Studio.vbs"
Copy-Item "$repo\LICENSE" "$Out\LICENSE.txt"
if (Test-Path "$PSScriptRoot\studio.ico") { Copy-Item "$PSScriptRoot\studio.ico" "$Out\studio.ico" }
Set-Content -Path "$Out\VERSION" -Value $Version -Encoding ASCII
Invoke-BundledR "$PSScriptRoot\make_notices.R" @("$Out\lib", "$Out\THIRD_PARTY_NOTICES.txt", $Version)

# 5. Report
$mb = { param($p) "{0,6:N0} MB" -f ((Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB) }
Write-Host "5/5 done" -ForegroundColor Green
Write-Host ("  R runtime : " + (& $mb "$Out\R"))
Write-Host ("  R library : " + (& $mb "$Out\lib"))
Write-Host ("  app       : " + (& $mb "$Out\studio"))
Write-Host ("  total     : " + (& $mb $Out) + "   ->  $Out")
