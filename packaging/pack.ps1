<#
.SYNOPSIS
    Assemble the Windows release drop. host-runtime F007, design.md C4.

.DESCRIPTION
    What a host receives is a folder, not a source tree. This script builds
    that folder out of what `cabal build particle-magic-ffi` already
    produced: the standalone DLL (the RTS is inside it, so a host needs no
    GHC installation), the MinGW import library cabal emits beside it, an
    MSVC import library made here, the C header, and a version file.

    The MSVC import library is generated from particle-magic-ffi.def -- the
    same export list the DLL itself was linked with, not a second copy of
    the truth. Two producers, in order of preference:

      1. lib.exe /def:  (located through vswhere)
      2. llvm-dlltool -d  (shipped with ghcup's mingw, no MSVC needed)

    Both have been verified to produce a library MSVC's cl.exe links
    against; see packaging/smoke-msvc.ps1, which builds a host with one.

.PARAMETER OutDir
    Where to write the drop. Default: dist\windows-x86_64 under the repo.

.PARAMETER Verify
    After packing, assert the drop is complete and the import libraries
    are non-empty. (The end-to-end check is smoke-msvc.ps1.)

.PARAMETER NoMsvc
    Skip the vswhere/lib.exe path and go straight to llvm-dlltool. Exists
    so the fallback is exercised on a machine that does have MSVC, rather
    than discovered for the first time on a runner that does not.

.NOTES
    The exit code is the whole interface: 0 means the drop is complete,
    anything else names the missing file or failing tool on stderr. CI
    consumes the code, not the message.
#>
[CmdletBinding()]
param(
    [string] $OutDir = '',
    [switch] $Verify,
    [switch] $NoMsvc
)

$ErrorActionPreference = 'Stop'

function Die([string] $Message, [int] $Code = 1) {
    [Console]::Error.WriteLine("pack.ps1: $Message")
    exit $Code
}

function Note([string] $Message) {
    Write-Host "pack.ps1: $Message"
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
$PlatformId = 'windows-x86_64'
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot "dist\$PlatformId" }

$Header = Join-Path $RepoRoot 'include\particle_magic.h'
$CabalFile = Join-Path $RepoRoot 'particle-magic.cabal'
$DefFile = Join-Path $RepoRoot 'particle-magic-ffi.def'

foreach ($required in @($Header, $CabalFile, $DefFile)) {
    if (-not (Test-Path $required)) { Die "missing input: $required" }
}

$DistDir = Join-Path $RepoRoot 'dist-newstyle'
if (-not (Test-Path $DistDir)) {
    Die "no dist-newstyle -- run 'cabal build particle-magic-ffi' first"
}

$Dll = Get-ChildItem -Path $DistDir -Recurse -Filter 'particle-magic-ffi.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $Dll) { Die "no particle-magic-ffi.dll under dist-newstyle -- run 'cabal build particle-magic-ffi' first" }

$MingwLib = Get-ChildItem -Path $DistDir -Recurse -Filter 'particle-magic-ffi.dll.a' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $MingwLib) { Die "no particle-magic-ffi.dll.a beside the DLL -- the MinGW import library is part of the drop" }

if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Copy-Item $Dll.FullName (Join-Path $OutDir 'particle-magic-ffi.dll')
Copy-Item $MingwLib.FullName (Join-Path $OutDir 'particle-magic-ffi.dll.a')
Copy-Item $Header (Join-Path $OutDir 'particle_magic.h')
Copy-Item $DefFile (Join-Path $OutDir 'particle-magic-ffi.def')

# ------------------------------------------------------ MSVC import library

function Find-LibExe {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { return $null }
    $installPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath 2>$null
    if (-not $installPath) { return $null }
    $candidate = Get-ChildItem -Path (Join-Path $installPath 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'bin\Hostx64\x64\lib.exe' } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
    return $candidate
}

function Find-LlvmDlltool {
    $onPath = Get-Command llvm-dlltool -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $roots = @()
    $ghc = Get-Command ghc -ErrorAction SilentlyContinue
    if ($ghc) { $roots += (Split-Path -Parent (Split-Path -Parent $ghc.Source)) }
    if ($env:GHCUP_INSTALL_BASE_PREFIX) { $roots += (Join-Path $env:GHCUP_INSTALL_BASE_PREFIX 'ghcup') }
    $roots += 'C:\ghcup'
    $roots += (Join-Path $env:USERPROFILE '.ghcup')
    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path $root)) { continue }
        $hit = Get-ChildItem -Path $root -Recurse -Filter 'llvm-dlltool.exe' -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

$ImportLib = Join-Path $OutDir 'particle-magic-ffi.lib'
$Producer = ''

$libExe = $null
if (-not $NoMsvc) { $libExe = Find-LibExe }
if ($libExe) {
    Push-Location $OutDir
    try {
        & $libExe /nologo /def:particle-magic-ffi.def /machine:x64 /out:particle-magic-ffi.lib | Out-Null
    } finally { Pop-Location }
    if ($LASTEXITCODE -eq 0 -and (Test-Path $ImportLib)) { $Producer = "lib.exe ($libExe)" }
}

if (-not $Producer) {
    $dlltool = Find-LlvmDlltool
    if (-not $dlltool) {
        Die "no MSVC import library producer: vswhere found no lib.exe and no llvm-dlltool.exe is reachable"
    }
    Push-Location $OutDir
    try {
        & $dlltool -m i386:x86-64 -d particle-magic-ffi.def -D particle-magic-ffi.dll -l particle-magic-ffi.lib | Out-Null
    } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $ImportLib)) {
        Die "llvm-dlltool failed to produce particle-magic-ffi.lib"
    }
    $Producer = "llvm-dlltool ($dlltool)"
}

Note "MSVC import library produced by $Producer"

# lib.exe leaves an .exp beside the .lib; it is a linker intermediate, not
# part of what a host receives, and the .def was only an input.
Remove-Item (Join-Path $OutDir 'particle-magic-ffi.exp') -ErrorAction SilentlyContinue
Remove-Item (Join-Path $OutDir 'particle-magic-ffi.def') -ErrorAction SilentlyContinue

# -------------------------------------------------------------- version file

$PkgVersion = (Select-String -Path $CabalFile -Pattern '^version:\s*([0-9.]+)' |
    Select-Object -First 1).Matches[0].Groups[1].Value
if (-not $PkgVersion) { Die "no version: field in $CabalFile" }

$AbiVersion = (Select-String -Path $Header -Pattern '^#define\s+PM_ABI_VERSION\s+([0-9]+)' |
    Select-Object -First 1).Matches[0].Groups[1].Value
if (-not $AbiVersion) { Die "no PM_ABI_VERSION in $Header" }

$Commit = 'unknown'
try {
    $rev = & git -C $RepoRoot rev-parse HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $rev) { $Commit = $rev.Trim() }
} catch { $Commit = 'unknown' }

# --- pm-version.json BEGIN (field set is the contract: packaging/artifacts.json
# --- restates it and test/PackagingSpec.hs asserts the three agree) ---
$VersionJson = @"
{
  "package-version": "$PkgVersion",
  "abi-version": $AbiVersion,
  "platform": "$PlatformId",
  "commit": "$Commit"
}
"@
# --- pm-version.json END ---
# No BOM: this file is parsed by whatever the host has, and a UTF-8 BOM in
# front of '{' defeats a surprising number of JSON readers. Set-Content
# -Encoding utf8 writes one in Windows PowerShell 5.1, hence the .NET call.
[System.IO.File]::WriteAllText(
    (Join-Path $OutDir 'pm-version.json'),
    $VersionJson + "`n",
    (New-Object System.Text.UTF8Encoding($false)))

Note "packed $PlatformId into $OutDir (package $PkgVersion, ABI $AbiVersion, commit $Commit)"

# ------------------------------------------------------------------- verify

$Expected = @(
    'particle-magic-ffi.dll',
    'particle-magic-ffi.dll.a',
    'particle-magic-ffi.lib',
    'particle_magic.h',
    'pm-version.json'
)
foreach ($name in $Expected) {
    $p = Join-Path $OutDir $name
    if (-not (Test-Path $p)) { Die "the drop is missing $name" 3 }
    if ((Get-Item $p).Length -le 0) { Die "the drop's $name is empty" 3 }
}

if ($Verify) {
    $dllSize = (Get-Item (Join-Path $OutDir 'particle-magic-ffi.dll')).Length
    if ($dllSize -lt 1MB) {
        Die "particle-magic-ffi.dll is $dllSize bytes -- a standalone DLL embeds the RTS and cannot be this small" 3
    }
    Note "drop is complete: $($Expected.Count) files, DLL $([int]($dllSize / 1MB)) MiB"
}

exit 0
