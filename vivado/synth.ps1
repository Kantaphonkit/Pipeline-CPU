# vivado/synth.ps1
#
# PowerShell 5.1 equivalent of vivado/synth.sh — non-project-mode Vivado
# synthesis (optionally place/route) of cpu_top from a git snapshot, run in
# an ASCII-only shadow directory. See vivado/synth.tcl for the synthesis
# steps and vivado/synth.sh's header comment for the full rationale
# (Thai-path Vivado bug verified empirically, HEAD-snapshot-by-default
# rationale, etc.) — this script mirrors that logic in PowerShell 5.1
# (no &&, no ??, no ternary).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File vivado/synth.ps1 [-Impl] [-Worktree]
#                                                              [-Hex PATH] [-Period NS]
#
#   -Impl       also run opt_design/place_design/route_design and re-emit
#               timing/utilization reports post-implementation (slow).
#   -Worktree   snapshot rtl/*.v and the IMEM image from the live working tree
#               instead of `git archive HEAD` (only when nothing else is
#               concurrently editing rtl/).
#   -Hex PATH   repo-relative IMEM image (default asm/prog/bpred.hex; see
#               vivado/synth.tcl for why a real program image matters).
#   -Period NS  clock period to constrain to (default 10.000 = 100 MHz). A
#               non-default period suffixes the report filenames, e.g.
#               -Period 12.5 -> vivado/reports/timing_12.5ns.txt.
#
# $env:VIVADO_BIN overrides the Vivado bin directory (default matches
# CLAUDE.md / sim/run.ps1: D:/AMDDesigntools/2026.1/Vivado/bin).
#
# Exit code is 0 iff vivado exits 0, synth.log has no "ERROR:" line, and
# synth.log contains the synth.tcl sentinel "SYNTH_TCL_DONE".

param(
    [switch]$Impl,
    [switch]$Worktree,
    [string]$Hex = "asm/prog/bpred.hex",
    [string]$Period = "10.000"
)

# Reports are suffixed for any non-default period so a met-constraint run does
# not silently overwrite the 100 MHz reference run.
$Suffix = ""
if (($Period -ne "10.000") -and ($Period -ne "10")) {
    $Suffix = "_${Period}ns"
}
# [char]92 is a backslash; written this way to keep the escaping unambiguous.
$HexWin = $Hex.Replace("/", [string][char]92)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent $ScriptDir

if ($env:VIVADO_BIN) {
    $VivadoBin = $env:VIVADO_BIN
} else {
    $VivadoBin = "D:/AMDDesigntools/2026.1/Vivado/bin"
}

$Shadow = Join-Path $env:LOCALAPPDATA "pcpu_synth"

if (Test-Path "$Shadow\rtl") {
    Remove-Item -Recurse -Force "$Shadow\rtl" -Confirm:$false
}
if (Test-Path "$Shadow\asm") {
    Remove-Item -Recurse -Force "$Shadow\asm" -Confirm:$false
}
New-Item -ItemType Directory -Force -Path "$Shadow\rtl" | Out-Null
New-Item -ItemType Directory -Force -Path "$Shadow\asm" | Out-Null

Push-Location $RepoRoot

if ($Worktree) {
    Write-Host "== copying rtl/*.v and asm/smoke.hex from the live working tree (-Worktree) =="
    Copy-Item -Path "rtl\*.v" -Destination "$Shadow\rtl\" -Force
    if (-not $?) {
        Pop-Location
        Write-Error "FAIL: failed to copy rtl\*.v from working tree"
        exit 1
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent (Join-Path $Shadow $HexWin)) | Out-Null
    Copy-Item -Path $HexWin -Destination (Join-Path $Shadow $HexWin) -Force
    if (-not $?) {
        Pop-Location
        Write-Error "FAIL: failed to copy $Hex from working tree"
        exit 1
    }
} else {
    Write-Host "== snapshotting rtl/ and $Hex from 'git archive HEAD' (committed state only) =="

    $rtlTar = Join-Path $env:TEMP "pcpu_synth_rtl.tar"
    if (Test-Path $rtlTar) { Remove-Item -Force $rtlTar }
    git archive --format=tar -o $rtlTar HEAD -- rtl
    if ($LASTEXITCODE -ne 0) {
        Pop-Location
        Write-Error "FAIL: git archive HEAD -- rtl failed"
        exit 1
    }
    tar -xf $rtlTar -C $Shadow
    if ($LASTEXITCODE -ne 0) {
        Pop-Location
        Write-Error "FAIL: tar extract of rtl snapshot failed"
        exit 1
    }
    Remove-Item -Force $rtlTar

    $asmTar = Join-Path $env:TEMP "pcpu_synth_asm.tar"
    if (Test-Path $asmTar) { Remove-Item -Force $asmTar }
    git archive --format=tar -o $asmTar HEAD -- $Hex
    if ($LASTEXITCODE -ne 0) {
        Pop-Location
        Write-Error "FAIL: git archive HEAD -- $Hex failed"
        exit 1
    }
    tar -xf $asmTar -C $Shadow
    if ($LASTEXITCODE -ne 0) {
        Pop-Location
        Write-Error "FAIL: tar extract of $Hex snapshot failed"
        exit 1
    }
    Remove-Item -Force $asmTar
}

Pop-Location

Copy-Item -Path (Join-Path $RepoRoot "vivado\constraints.xdc") -Destination (Join-Path $Shadow "constraints.xdc") -Force
Copy-Item -Path (Join-Path $RepoRoot "vivado\synth.tcl") -Destination (Join-Path $Shadow "synth.tcl") -Force

Push-Location $Shadow

foreach ($f in @("synth.log", "synth.jou", "utilization.txt", "timing.txt", "clocks.txt", "memory.txt", "constraints_gen.xdc")) {
    if (Test-Path $f) { Remove-Item -Force $f }
}

$vivadoExe = Join-Path $VivadoBin "vivado.bat"
$vivadoArgs = @("-mode", "batch", "-source", "synth.tcl", "-log", "synth.log", "-journal", "synth.jou",
                "-tclargs", "--hex", $Hex, "--period", $Period)
if ($Impl) {
    $vivadoArgs += "--impl"
}

Write-Host "== vivado (cwd=$Shadow) =="
& $vivadoExe $vivadoArgs
$vivadoRc = $LASTEXITCODE

Pop-Location

$reportsDir = Join-Path $RepoRoot "vivado\reports"
New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null

foreach ($f in @("synth.log", "synth.jou", "utilization.txt", "timing.txt", "clocks.txt", "memory.txt")) {
    $src = Join-Path $Shadow $f
    if (Test-Path $src) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($f)
        $ext  = [System.IO.Path]::GetExtension($f)
        Copy-Item -Path $src -Destination (Join-Path $reportsDir "$base$Suffix$ext") -Force
    }
}

if ($vivadoRc -ne 0) {
    Write-Error "FAIL: vivado exited $vivadoRc"
    exit 1
}

$logPath = Join-Path $Shadow "synth.log"

# Anchored to line start: Vivado's own log lines never begin with anything
# but the message code itself (e.g. "ERROR: [Common 17-69] ..."), while the
# source-echo lines it prints for every sourced Tcl statement are prefixed
# with "# " (e.g. '#     puts "ERROR: no rtl/*.v files found ..."'), which
# would otherwise false-positive on this script's own error-message strings.
$hasError = $false
if (Test-Path $logPath) {
    $errLines = Select-String -Path $logPath -Pattern "^ERROR:"
    if ($errLines) { $hasError = $true }
}
if ($hasError) {
    Write-Error "FAIL: synth.log contains ERROR: line(s)"
    Select-String -Path $logPath -Pattern "^ERROR:"
    exit 1
}

$doneFound = $false
if (Test-Path $logPath) {
    $doneLines = Select-String -Path $logPath -Pattern "SYNTH_TCL_DONE" -SimpleMatch
    if ($doneLines) { $doneFound = $true }
}
if (-not $doneFound) {
    Write-Error "FAIL: synth.log missing SYNTH_TCL_DONE sentinel -- synth_design likely did not complete"
    exit 1
}

$memReport = Join-Path $reportsDir "memory$Suffix.txt"
if (Test-Path $memReport) {
    Write-Host ""
    Write-Host "== memory primitive counts =="
    Select-String -Path $memReport -Pattern "^[A-Z0-9]+ +count=" | ForEach-Object { $_.Line }
}

Write-Host ""
Write-Host "PASS: synthesis complete. Reports in $reportsDir (suffix '$Suffix')"
exit 0
