# Verifica il corpus degli ADR (MADR con intestazioni italiane) di un repository.
# Si valida l'intero corpus, non solo i file della PR: cosi' resta sempre pulito.

$gateMode = if ($env:GATE_MODE) { $env:GATE_MODE.ToLower() } else { 'enforce' }
$decisionsDirectory = if ($env:DECISIONS_DIRECTORY) { $env:DECISIONS_DIRECTORY } else { 'docs/decisions' }
# Fuori da una PR ADO lascia la macro non espansa: non c'e' un ramo di destinazione.
$targetBranch = $env:TARGET_BRANCH -replace '^refs/heads/', '' -replace '^\$\(.*\)$', ''

$AllowedStatuses = @('proposed', 'accepted', 'rejected', 'deprecated', 'superseded')
$RequiredSections = @('Contesto e problema', 'Opzioni considerate', 'Esito della decisione')
$DecisionFilePattern = '^\d{4}-[a-z0-9-]+\.md$'

# Sostituire una decisione accettata ne cambia solo lo stato e il rimando alla sostituta.
$SupersedingFields = @('status', 'superseded-by')

function ConvertFrom-Decision {
    param([string]$Id, [string]$Content)

    $fields = @{}
    $lines = $Content -split "`r?`n"
    if ($lines[0] -eq '---') {
        $end = [Array]::IndexOf($lines, '---', 1)
        if ($end -gt 0) {
            $lines[1..($end - 1)] | Where-Object { $_ -match '^([\w-]+):\s*(.*)$' } | ForEach-Object { $fields[$Matches[1]] = $Matches[2].Trim() }
        }
    }
    $sections = @($lines | Where-Object { $_ -match '^##\s+(.+?)\s*$' } | ForEach-Object { $Matches[1] })
    return [pscustomobject]@{ Id = $Id; Number = $Id.Substring(0, 4); Fields = $fields; Sections = $sections; Content = $Content }
}

function Get-Decisions {
    if (-not (Test-Path $decisionsDirectory)) { return @() }
    return @(Get-ChildItem -Path $decisionsDirectory -File | Where-Object Name -Match $DecisionFilePattern | ForEach-Object {
            ConvertFrom-Decision -Id $_.BaseName -Content ([IO.File]::ReadAllText($_.FullName))
        })
}

function Test-Status($Decision) {
    if ($AllowedStatuses -notcontains $Decision.Fields['status']) {
        "$($Decision.Id): stato non ammesso '$($Decision.Fields['status'])' (ammessi: $($AllowedStatuses -join ', '))"
    }
}

function Test-Sections($Decision) {
    $RequiredSections | Where-Object { $Decision.Sections -notcontains $_ } | ForEach-Object { "$($Decision.Id): sezione mancante '$_'" }
}

function Test-UniqueNumbers($Decisions) {
    $Decisions | Group-Object Number | Where-Object Count -GT 1 | ForEach-Object {
        $ids = $_.Group.Id -join ', '
        $_.Group | ForEach-Object { "$($_.Id): numero duplicato $($_.Number) ($ids)" }
    }
}

function Test-Supersession($Decision, [hashtable]$ById) {
    $replaced = $Decision.Fields['supersedes']
    if ($replaced) {
        $target = $ById[$replaced]
        if (-not $target -or $target.Fields['status'] -ne 'superseded' -or $target.Fields['superseded-by'] -ne $Decision.Id) {
            "$($Decision.Id): sostituzione non reciproca, '$replaced' non ha stato 'superseded' con superseded-by '$($Decision.Id)'"
        }
    }

    $replacement = $Decision.Fields['superseded-by']
    if ($Decision.Fields['status'] -eq 'superseded') {
        $successor = if ($replacement) { $ById[$replacement] }
        if (-not $successor -or $successor.Fields['supersedes'] -ne $Decision.Id) {
            "$($Decision.Id): sostituzione non reciproca, '$replacement' non dichiara supersedes '$($Decision.Id)'"
        }
    }
}

function Get-ComparableContent($Decision) {
    $kept = $Decision.Content -split "`r?`n" | Where-Object {
        $line = $_
        -not ($SupersedingFields | Where-Object { $line -match "^$([regex]::Escape($_)):" })
    }
    return ($kept -join "`n").Trim()
}

function Test-TargetBranchReadable {
    git rev-parse --verify --quiet "origin/$targetBranch^{commit}" > $null
    $isReadable = $LASTEXITCODE -eq 0
    $global:LASTEXITCODE = 0
    return $isReadable
}

function Get-BaseDecisions {
    $baseRef = "origin/$targetBranch"
    $paths = git ls-tree -r --name-only $baseRef -- $decisionsDirectory
    return @($paths | Where-Object { (Split-Path $_ -Leaf) -match $DecisionFilePattern } | ForEach-Object {
            ConvertFrom-Decision -Id ([IO.Path]::GetFileNameWithoutExtension($_)) -Content ((git show "${baseRef}:$_") -join "`n")
        })
}

function Test-AcceptedUnchanged([hashtable]$ById) {
    if (-not $targetBranch) { return }
    if (-not (Test-TargetBranchReadable)) {
        Write-Host "##[warning]Ramo di destinazione origin/$targetBranch non leggibile: immutabilita' non verificata"
        return
    }

    Get-BaseDecisions | Where-Object { $_.Fields['status'] -eq 'accepted' } | ForEach-Object {
        $current = $ById[$_.Id]
        if (-not $current -or (Get-ComparableContent $current) -ne (Get-ComparableContent $_)) {
            "$($_.Id): decisione accettata non modificabile, si sostituisce con una nuova decisione"
        }
    }
}

function Get-CorpusIssues {
    $decisions = Get-Decisions
    $byId = @{}
    $decisions | ForEach-Object { $byId[$_.Id] = $_ }

    $decisions | ForEach-Object { Test-Status $_; Test-Sections $_; Test-Supersession $_ $byId }
    Test-UniqueNumbers $decisions
    Test-AcceptedUnchanged $byId
}

function Complete-Verification([string[]]$Issues) {
    if (-not $Issues) {
        Write-Host "##[section]Corpus delle decisioni in $decisionsDirectory valido"
        exit 0
    }

    $level = if ($gateMode -eq 'warn') { 'warning' } else { 'error' }
    $Issues | ForEach-Object { Write-Host "##vso[task.logissue type=$level]$_" }
    if ($gateMode -eq 'warn') {
        Write-Host "##vso[task.complete result=SucceededWithIssues;]"
        exit 0
    }
    exit 1
}

if ($gateMode -eq 'off') {
    Write-Host "Verifica delle decisioni disattivata"
    exit 0
}

Complete-Verification @(Get-CorpusIssues)
