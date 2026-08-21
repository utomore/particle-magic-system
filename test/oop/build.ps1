<#
Build the out-of-process load smoke on Windows (host-runtime F006, M8).

The harness is plain C and links no Haskell package -- the only libraries
it needs are the C runtime and kernel32, both of which every compiler here
links by default. Three compilers are tried in order:

  1. cl.exe     if the shell has already been through vcvars64
  2. clang.exe  the one ghcup installs with its MinGW toolchain, so this
                works on a machine that has GHC and nothing else
  3. gcc.exe    anything else on PATH

Windows exports no RTS symbol (particle-magic-ffi.def closes the export
face), so PM_OOP_WITH_RTS_HEADERS is deliberately NOT set here: there is
nothing to read the layout of. PM_OOP_HAS_RTS_STATS is decided from the
header, exactly as build.sh does it.

Exit code is the result. Prints the executable's path on success.
#>
[CmdletBinding()]
param(
    [string] $Out
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Src = Join-Path $RepoRoot 'test\oop\oop_smoke.c'
$Include = Join-Path $RepoRoot 'include'
if (-not $Out) { $Out = Join-Path $RepoRoot 'test\oop\oop-smoke.exe' }

function Die($msg, $code = 4) { Write-Error $msg; exit $code }

if (-not (Test-Path $Src)) { Die "no $Src" }

# PM_OOP_HAS_RTS_STATS: does PmConfig carry a statistics field yet?
$header = Get-Content (Join-Path $Include 'particle_magic.h') -Raw
$defs = @()
if ($header -match 'uint32_t stats;') {
    $defs += 'PM_OOP_HAS_RTS_STATS'
    Write-Host 'build.ps1: PmConfig.stats is in the header'
} else {
    Write-Host 'build.ps1: no PmConfig.stats in the header -- statistics will not be requested'
}

function Find-Compiler {
    foreach ($name in @('cl', 'clang', 'gcc')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return @{ Kind = $name; Path = $cmd.Source } }
    }
    # ghcup ships clang with its MinGW bundle but does not put it on PATH.
    foreach ($root in @("$env:SystemDrive\ghcup\ghc", "$env:USERPROFILE\.ghcup\ghc")) {
        if (Test-Path $root) {
            $hit = Get-ChildItem -Path $root -Recurse -Filter 'clang.exe' -File -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if ($hit) { return @{ Kind = 'clang'; Path = $hit.FullName } }
        }
    }
    return $null
}

$compiler = Find-Compiler
if (-not $compiler) {
    Die "no C compiler: run vcvars64 for cl.exe, or install ghcup's MinGW toolchain"
}

Write-Host "build.ps1: using $($compiler.Kind) at $($compiler.Path)"

if ($compiler.Kind -eq 'cl') {
    $args = @('/nologo', '/W3', '/O1', "/I$Include")
    foreach ($d in $defs) { $args += "/D$d" }
    $obj = Join-Path $env:TEMP 'oop_smoke.obj'
    $args += @($Src, "/Fe:$Out", "/Fo:$obj")
    & $compiler.Path @args
} else {
    $args = @('-std=c99', '-O1', '-Wall', "-I$Include")
    foreach ($d in $defs) { $args += "-D$d" }
    $args += @($Src, '-o', $Out, '-lm')
    & $compiler.Path @args
}

if ($LASTEXITCODE -ne 0) { Die "the C compiler failed (exit $LASTEXITCODE)" $LASTEXITCODE }
if (-not (Test-Path $Out)) { Die "the compiler reported success but $Out is not there" }

Write-Host "build.ps1: $Out"
