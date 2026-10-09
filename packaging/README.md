# Packaging the Windows installer

The installer is **fully offline**: it contains portable R, the app's R packages (installed from CRAN binaries),
the app, and a small launcher. People who download it do not need R, RStudio, a terminal, or any package installs.

## What gets built

```
dist\                       (produced by build.ps1, ~445 MB; not committed)
  R\                        portable R runtime (copied from your R installation, minus docs/tests/Tcl)
  lib\                      the app's R packages and their dependencies
  studio\                   app\ + R\ (pipeline code) + launch_studio.R
  Studio.vbs                hidden-window launcher: uses only the bundled R, sets the per-user data folder
  studio.ico, LICENSE.txt, THIRD_PARTY_NOTICES.txt, VERSION
release\
  3D-Forest-Height-Studio-Setup-<version>.exe   (~140 MB, produced by installer.iss)
```

## Build it yourself

Requirements: Windows 10/11 x64, R (the same minor version you want to ship), internet, and
[Inno Setup 6](https://jrsoftware.org/isinfo.php) (`winget install JRSoftware.InnoSetup`).

```powershell
.\packaging\build.ps1                # 5-10 min the first time (downloads ~350 MB of CRAN binaries)
.\packaging\build.ps1 -ReuseLib      # quick rebuild when only the app code changed
& "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" packaging\installer.iss     # ~3 min
```

The version comes from `APP_VERSION` in `app/app.R` (override with `-Version` and `/DAppVersion=`).
`packaging/make_icon.py` regenerates the icon.

## How the installed app behaves

- **Per-user install** (no administrator prompt) into `%LOCALAPPDATA%\Programs\3D Forest Height Studio`.
- **Data** (downloaded tiles, boundaries, caches, logs) lives in `%LOCALAPPDATA%\3D Forest Height Studio`,
  never in the program folder. The uninstaller asks before deleting it; silent uninstalls keep it.
- The launcher starts the app on a **free port**, opens it in a chromeless **Edge** window (Chrome, then the
  default browser, as fallbacks) and **stops R when the last window closes** (10 s grace for reloads).
  A second launch re-uses the running instance.
- The 3D engine (three.js) is bundled, so the viewer works offline. Downloading tiles still needs internet.

## Verified locally (Windows 11)

| Check | Result |
|---|---|
| Bundle runs from a relocated folder with a scrubbed environment (no R on PATH, no user library) | pass |
| Silent install, no admin prompt | pass (39 s) |
| Launch from a scrubbed environment; only the bundled `Rscript.exe` runs | pass (warm start ~6 s, cold ~21 s) |
| Full browser flow on the installed app: region, tiles, build, explore, R-code tab, HTML export | pass, no console errors |
| App stops itself after the last window closes | pass (~11 s) |
| In-place upgrade, then silent uninstall (program folder, shortcut and registry entry removed) | pass |

Not yet verified: a machine that has never had R or Rtools, other Windows versions, antivirus behaviour, and the
GitHub Actions workflow (`.github/workflows/release.yml`) itself.

## Known limitations

- **Unsigned installer**: Windows SmartScreen shows "Windows protected your PC" on first run
  (More info, then Run anyway). Code signing would remove the warning.
- Windows x64 only. macOS and Linux users run from source (see the main README).
- R is GPL; its license texts and source pointer ship in `THIRD_PARTY_NOTICES.txt`.
