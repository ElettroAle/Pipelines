# Esito comune delle verifiche della documentazione: la modalita' off/warn/enforce letta da
# GATE_MODE, un rilievo ##vso[task.logissue] per ogni problema e il codice di uscita.

$gateMode = if ($env:GATE_MODE) { $env:GATE_MODE.ToLower() } else { 'enforce' }

function New-Issue([string]$Scope, [string]$Reason, [string]$Detail) {
    return "${Scope}: $Reason ($Detail)"
}

function Complete-Verification([string[]]$Issues, [string]$Passed) {
    if (-not $Issues) {
        Write-Host "##[section]$Passed"
        exit 0
    }

    $level = if ($gateMode -eq 'warn') { 'warning' } else { 'error' }
    $Issues | Select-Object -Unique | ForEach-Object { Write-Host "##vso[task.logissue type=$level]$_" }
    if ($gateMode -eq 'warn') {
        Write-Host "##vso[task.complete result=SucceededWithIssues;]"
        exit 0
    }
    exit 1
}

function Invoke-Verification([scriptblock]$GetIssues, [string]$Passed, [string]$Disabled) {
    if ($gateMode -eq 'off') {
        Write-Host $Disabled
        exit 0
    }
    Complete-Verification @(& $GetIssues) $Passed
}
