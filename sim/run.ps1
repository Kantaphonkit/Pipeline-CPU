<#
.SYNOPSIS
  sim/run.ps1 - compile + elaborate + simulate one testbench with Vivado xsim
  (batch mode, no GUI). PowerShell 5.1 compatible. See docs/INTERFACES.md §7
  and sim/run.sh (identical behaviour, and the ASCII-shadow-dir rationale is
  documented there in full) for the contract this implements.

.DESCRIPTION
  Usage:
    sim/run.ps1 <tb_name> [-g NAME=VALUE ...] [--plusarg +X=Y ...] [--wave]

    <tb_name>          module name; source must be tb/<tb_name>.v
    -g NAME=VALUE      repeatable; passed to `xelab -generic_top "NAME=VALUE"`
    --plusarg +X=Y     repeatable; passed to `xsim -testplusarg X=Y`
    --wave             adds `-debug typical` at elab and dumps
                       sim/work/<tb>/<tb>.wdb via `xsim -wdb`. Default off.

  Exit code is 0 iff sim/work/<tb>/sim.log contains a line starting with
  "PASS" and no line starting with "FAIL". Compile/elaborate errors are
  always nonzero.

  Vivado bin dir is overridable via $env:VIVADO_BIN.

  Why an ASCII-only shadow work dir: the Vivado xvlog/xelab/xsim binaries on
  this machine use legacy ANSI Win32 calls internally and fail to create or
  open files whenever their current working directory contains a character
  outside the system codepage. This repo's path contains Thai characters,
  which triggers exactly that failure. Every tool invocation therefore runs
  with CWD set to an ASCII-only directory under %LOCALAPPDATA% containing
  NTFS junctions rtl/, tb/, asm/ back to this repo's real directories (no
  data is copied), so relative references such as $readmemh("asm/prog.hex")
  resolve exactly as they would with CWD = repo root. Results (sim.log, and
  the .wdb if -wave was given) are copied back into the repo's
  sim/work/<tb>/ afterward.
#>

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$TbName,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

if (-not $Rest) { $Rest = @() }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..")).Path

if ($env:VIVADO_BIN -and $env:VIVADO_BIN -ne "") {
    $VivadoBin = $env:VIVADO_BIN
} else {
    $VivadoBin = "D:/AMDDesigntools/2026.1/Vivado/bin"
}

$Generics = @()
$PlusArgs = @()
$Wave = $false

$i = 0
while ($i -lt $Rest.Count) {
    $arg = $Rest[$i]
    if ($arg -eq "-g") {
        $i++
        if ($i -ge $Rest.Count) { Write-Error "ERROR: -g requires NAME=VALUE"; exit 1 }
        $Generics += $Rest[$i]
    } elseif ($arg -eq "--plusarg") {
        $i++
        if ($i -ge $Rest.Count) { Write-Error "ERROR: --plusarg requires +X=Y"; exit 1 }
        $PlusArgs += $Rest[$i]
    } elseif ($arg -eq "--wave") {
        $Wave = $true
    } else {
        Write-Error "ERROR: unknown argument: $arg"
        exit 1
    }
    $i++
}

$TbSrcRepo = Join-Path $RepoRoot "tb\$TbName.v"
if (-not (Test-Path $TbSrcRepo)) {
    Write-Error "ERROR: testbench source not found: $TbSrcRepo"
    exit 1
}

$RepoWork = Join-Path $RepoRoot "sim\work\$TbName"
New-Item -ItemType Directory -Force -Path $RepoWork | Out-Null

$ShadowBase = Join-Path $env:LOCALAPPDATA "pcpu_sim_shadow"
$Work = Join-Path $ShadowBase "sim\work\$TbName"
New-Item -ItemType Directory -Force -Path $Work | Out-Null

foreach ($d in @("rtl", "tb", "asm")) {
    $link = Join-Path $Work $d
    $target = Join-Path $RepoRoot $d
    if (-not (Test-Path $link)) {
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    }
}

$Log = Join-Path $Work "sim.log"
New-Item -ItemType File -Force -Path $Log | Out-Null

# Runs one Vivado tool, echoing its output live and appending every line to
# $Log with a single consistent encoding (PS 5.1's Tee-Object has no
# -Encoding parameter and defaults to UTF-16LE, which corrupted the log when
# mixed with Set-Content's UTF-8 — hence this helper instead of Tee-Object).
function Invoke-Logged {
    param(
        [string]$Exe,
        [string[]]$ExeArgs
    )
    & $Exe @ExeArgs | ForEach-Object {
        Add-Content -Path $Log -Value $_ -Encoding utf8
        Write-Host $_
    }
    return $LASTEXITCODE
}

function Write-LogLine {
    param([string]$Text)
    Add-Content -Path $Log -Value $Text -Encoding utf8
    Write-Host $Text
}

Push-Location $Work
try {
    $RtlFiles = @()
    if (Test-Path "rtl") {
        $found = Get-ChildItem -Path "rtl" -Filter "*.v" -ErrorAction SilentlyContinue
        if ($found) { $RtlFiles = $found | ForEach-Object { $_.FullName } }
    }
    $TbFile = Join-Path $Work "tb\$TbName.v"

    Write-LogLine "== xvlog =="
    $xvlogArgs = @("--work", "work") + $RtlFiles + @($TbFile)
    $xvlogRc = Invoke-Logged -Exe "$VivadoBin/xvlog.bat" -ExeArgs $xvlogArgs
    if ($xvlogRc -ne 0) {
        Write-LogLine "FAIL: $TbName (xvlog exited $xvlogRc)"
        Copy-Item -Force $Log (Join-Path $RepoWork "sim.log")
        exit 1
    }

    $xelabArgs = @("-L", "work", "--snapshot", "${TbName}_snap", $TbName, "--timescale", "1ns/1ps")
    foreach ($g in $Generics) { $xelabArgs += @("-generic_top", $g) }
    if ($Wave) { $xelabArgs += @("--debug", "typical") }

    Write-LogLine "== xelab =="
    $xelabRc = Invoke-Logged -Exe "$VivadoBin/xelab.bat" -ExeArgs $xelabArgs
    if ($xelabRc -ne 0) {
        Write-LogLine "FAIL: $TbName (xelab exited $xelabRc)"
        Copy-Item -Force $Log (Join-Path $RepoWork "sim.log")
        exit 1
    }

    $xsimArgs = @("${TbName}_snap", "--runall")
    foreach ($p in $PlusArgs) {
        $pv = $p
        if ($pv.StartsWith("+")) { $pv = $pv.Substring(1) }
        $xsimArgs += @("-testplusarg", $pv)
    }
    if ($Wave) { $xsimArgs += @("-wdb", "$TbName.wdb") }

    Write-LogLine "== xsim =="
    $xsimRc = Invoke-Logged -Exe "$VivadoBin/xsim.bat" -ExeArgs $xsimArgs

    Copy-Item -Force $Log (Join-Path $RepoWork "sim.log")
    $wdbPath = Join-Path $Work "$TbName.wdb"
    if ($Wave -and (Test-Path $wdbPath)) {
        Copy-Item -Force $wdbPath (Join-Path $RepoWork "$TbName.wdb")
    }

    if ($xsimRc -ne 0) {
        Add-Content -Path (Join-Path $RepoWork "sim.log") -Value "FAIL: $TbName (xsim exited $xsimRc)" -Encoding utf8
        exit 1
    }
} finally {
    Pop-Location
}

$FinalLog = Join-Path $RepoWork "sim.log"
$content = Get-Content $FinalLog
$hasPass = $false
$hasFail = $false
foreach ($line in $content) {
    if ($line -like "PASS*") { $hasPass = $true }
    if ($line -like "FAIL*") { $hasFail = $true }
}

if ($hasFail) {
    Write-Error "run.ps1: FAIL line(s) found in $FinalLog"
    exit 1
}
if (-not $hasPass) {
    Write-Error "run.ps1: no PASS line found in $FinalLog"
    exit 1
}

exit 0
