<#
.SYNOPSIS
    Prove the Windows drop's MSVC import library is actually linkable, by
    building a host with cl.exe and running it. host-runtime F007 T5.

.DESCRIPTION
    The claim "the drop ships an MSVC import library" is only worth
    anything if an MSVC host links against it and comes up. This script is
    that claim, executed:

      1. pack the drop (packaging/pack.ps1) unless one was handed in
      2. compile examples/c/main.c with cl.exe, including only the drop's
         header and linking only the drop's particle-magic-ffi.lib -- no
         path into dist-newstyle, no GHC anywhere
      3. run it over a real spell file for a full lifecycle (cast, 120
         frames of advance + observe, free, shutdown)
      4. assert the executable's only DLL imports are the library itself
         and Windows' own

    The exit code is the conclusion: 0 means an MSVC-built host links and
    runs against this drop.

.PARAMETER DropDir
    An existing drop to test. Default: pack a fresh one into
    dist\windows-x86_64.

.PARAMETER Spell
    The spell file to cast. Default: assets\spells\ring-fire.json.

.PARAMETER KeepWork
    Leave the build directory in place for inspection.
#>
[CmdletBinding()]
param(
    [string] $DropDir = '',
    [string] $Spell = '',
    [switch] $KeepWork
)

$ErrorActionPreference = 'Stop'

function Die([string] $Message, [int] $Code = 1) {
    [Console]::Error.WriteLine("smoke-msvc.ps1: $Message")
    exit $Code
}

function Note([string] $Message) {
    Write-Host "smoke-msvc.ps1: $Message"
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
$WorkDir = Join-Path $RepoRoot 'dist\msvc-smoke'
if (-not $Spell) { $Spell = Join-Path $RepoRoot 'assets\spells\ring-fire.json' }
if (-not (Test-Path $Spell)) { Die "no such spell file: $Spell" 2 }

if (-not $DropDir) {
    $DropDir = Join-Path $RepoRoot 'dist\windows-x86_64'
    Note "packing a fresh drop into $DropDir"
    & (Join-Path $PSScriptRoot 'pack.ps1') -OutDir $DropDir
    if ($LASTEXITCODE -ne 0) { Die "pack.ps1 failed with $LASTEXITCODE" $LASTEXITCODE }
}

foreach ($name in @('particle-magic-ffi.dll', 'particle-magic-ffi.lib', 'particle_magic.h')) {
    if (-not (Test-Path (Join-Path $DropDir $name))) { Die "the drop is missing $name" 2 }
}

# ------------------------------------------------------------------- MSVC

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { Die "vswhere.exe not found -- this smoke needs Visual Studio" 4 }

$installPath = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath 2>$null
if (-not $installPath) { Die "vswhere found no VC toolset -- this smoke needs the C++ workload" 4 }

$vcvars = Join-Path $installPath 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) { Die "no vcvars64.bat under $installPath" 4 }
Note "using $installPath"

# --------------------------------------------------------------- build

if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

# The host receives a folder; that folder is all this build is allowed to
# see. Copying the DLL next to the exe is what a game does when it ships.
Copy-Item (Join-Path $DropDir 'particle-magic-ffi.dll') $WorkDir

$mainC = Join-Path $RepoRoot 'examples\c\main.c'
if (-not (Test-Path $mainC)) { Die "no such example host: $mainC" 2 }

$exe = Join-Path $WorkDir 'pm_msvc.exe'
# cd into the work directory rather than passing /Fo: a trailing backslash
# before a closing quote is an escape to cmd, and the .obj path comes out
# mangled. Object and executable both land in the cwd this way.
$build = "call `"$vcvars`" >nul && cd /d `"$WorkDir`" && cl.exe /nologo /W3 /I `"$DropDir`" " +
         "`"$mainC`" `"$(Join-Path $DropDir 'particle-magic-ffi.lib')`" /Fe:pm_msvc.exe"
& cmd.exe /c $build
if ($LASTEXITCODE -ne 0) { Die "cl.exe failed with $LASTEXITCODE" 5 }
if (-not (Test-Path $exe)) { Die "cl.exe reported success but produced no $exe" 5 }
Note "cl.exe linked $([System.IO.Path]::GetFileName($exe)) against the drop's import library"

# ----------------------------------------------------------------- run

Push-Location $WorkDir
try {
    $output = & $exe $Spell 2>&1
    $runExit = $LASTEXITCODE
} finally { Pop-Location }

$lines = @($output | ForEach-Object { "$_" })
if ($runExit -ne 0) {
    $lines | ForEach-Object { [Console]::Error.WriteLine($_) }
    Die "the MSVC host exited with $runExit" 6
}

$frames = @($lines | Where-Object { $_ -like 'frame *' }).Count
if ($frames -ne 120) { Die "expected 120 frame lines, got $frames" 6 }
if (-not ($lines -contains 'finished: 0')) {
    Die "the host did not print 'finished: 0' (last line: $($lines[-1]))" 6
}
Note "ran a full lifecycle: 120 frames, finished: 0"

# ------------------------------------------------------------ dependents

$dumpbin = "call `"$vcvars`" >nul && dumpbin.exe /nologo /dependents `"$exe`""
$deps = & cmd.exe /c $dumpbin
$dllDeps = @($deps | Select-String -Pattern '^\s+(\S+\.dll)\s*$' |
    ForEach-Object { $_.Matches[0].Groups[1].Value.ToLowerInvariant() } | Sort-Object -Unique)
$allowed = @('particle-magic-ffi.dll', 'kernel32.dll', 'vcruntime140.dll', 'api-ms-win-crt-runtime-l1-1-0.dll')
$unexpected = @($dllDeps | Where-Object { $_ -notlike 'api-ms-win-*' -and $allowed -notcontains $_ })
if ($unexpected.Count -gt 0) {
    Die "the MSVC host imports unexpected DLLs: $($unexpected -join ', ')" 7
}
Note "imports: $($dllDeps -join ', ')"

if (-not $KeepWork) { Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue }

Note "MSVC smoke passed"
exit 0
