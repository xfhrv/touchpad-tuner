# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Ecstasy (https://github.com/xfhrv)

# Rebuild the TouchpadTuner launcher exe.
# Uses the .NET Framework C# compiler that ships with Windows - no SDK required.
# Usage: powershell -ExecutionPolicy Bypass -File .\build-launcher.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path $csc)) { throw 'Cannot find .NET Framework 4.x csc.exe.' }

$out = Join-Path $root 'TouchpadTuner.exe'
$icon = Join-Path $root 'app.ico'
$source = Join-Path $root 'src\Launcher.cs'

& $csc /nologo /target:winexe /platform:anycpu /optimize+ /warn:4 `
    "/out:$out" `
    "/win32icon:$icon" `
    /r:System.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll `
    $source

if ($LASTEXITCODE -ne 0) { throw "Compile failed with exit code $LASTEXITCODE" }
if (-not (Test-Path $out)) { throw 'No exe produced.' }
Write-Host "Build OK: $out"
