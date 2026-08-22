<#
Run the out-of-process load smoke on Windows (host-runtime F006, M8).

  test/oop/run.ps1                 the DLL cabal just built
  test/oop/run.ps1 <dir-or-file>   a packaging/pack.ps1 drop, or one DLL

cwd is forced to the repo root because the harness reads the spell file and
the golden by their repo-relative paths. Exit code is the result.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Target
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Push-Location $RepoRoot
try {
    if (-not $Target) {
        $DistDir = Join-Path $RepoRoot 'dist-newstyle'
        if (-not (Test-Path $DistDir)) {
            Write-Error "no dist-newstyle -- run 'cabal build particle-magic-ffi' first"
            exit 4
        }
        $hit = Get-ChildItem -Path $DistDir -Recurse -Filter 'particle-magic-ffi.dll' -File -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if (-not $hit) {
            Write-Error "no particle-magic-ffi.dll under dist-newstyle -- run 'cabal build particle-magic-ffi' first"
            exit 4
        }
        $Lib = $hit.FullName
    } elseif (Test-Path $Target -PathType Container) {
        $Lib = Join-Path $Target 'particle-magic-ffi.dll'
        if (-not (Test-Path $Lib)) { Write-Error "no particle-magic-ffi.dll in $Target"; exit 4 }
    } else {
        if (-not (Test-Path $Target)) { Write-Error "no such library: $Target"; exit 4 }
        $Lib = (Resolve-Path $Target).Path
    }

    $Smoke = Join-Path $RepoRoot 'test\oop\oop-smoke.exe'
    $Src = Join-Path $RepoRoot 'test\oop\oop_smoke.c'
    $stale = (-not (Test-Path $Smoke)) -or
             ((Get-Item $Src).LastWriteTimeUtc -gt (Get-Item $Smoke).LastWriteTimeUtc)
    if ($stale) {
        & (Join-Path $PSScriptRoot 'build.ps1')
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    & $Smoke $Lib --all
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
