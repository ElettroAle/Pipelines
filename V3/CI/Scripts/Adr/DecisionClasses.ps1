# SPDX-License-Identifier: Apache-2.0

# Classi governate dalle decisioni. Una decisione con la struttura nel codice dichiara in governs i
# pattern sui nomi completi delle classi che governa: prefissi che finiscono con * e contengono per intero
# il namespace di ogni classe che coprono, mai il nome di una sola classe ne' un namespace intero.
# Le classi del codice .NET dei repository sorgente (SOURCE_DIRECTORY) che corrispondono a quei pattern
# sono le classi del diagramma delle classi della decisione; una classe che nessun pattern copre non si
# controlla. Usato da Test-DecisionClasses.ps1.

. "$PSScriptRoot/../Common/VerificationGate.ps1"
. "$PSScriptRoot/../Common/DocumentLanguage.ps1"
. "$PSScriptRoot/../Common/MarkdownText.ps1"
. "$PSScriptRoot/../Mermaid/Mermaid.ps1"
. "$PSScriptRoot/../C4/DotNet10Code.ps1"

$decisionsDirectory = if ($env:DECISIONS_DIRECTORY) { $env:DECISIONS_DIRECTORY } else { 'docs/decisions' }

$ClassesScope = 'classi delle decisioni'
$StructureSection = $DocumentLanguage.AdrCodeStructureSection
$DecisionFilePattern = '^\d{4}-[a-z0-9-]+\.md$'
$ClosedStatuses = @('superseded', 'deprecated', 'rejected')
$GovernsField = 'governs'

# I campi del frontmatter: un valore sulla riga della chiave, o una lista di voci sotto la chiave.
function Get-FrontMatter([string]$Content) {
    $fields = @{}
    $lines = $Content -split "`r?`n"
    if ($lines[0] -ne '---') { return $fields }
    $key = $null
    foreach ($line in ($lines | Select-Object -Skip 1)) {
        if ($line -eq '---') { break }
        if ($line -match '^([\w-]+):\s*(.*)$') {
            $key = $Matches[1]
            $fields[$key] = if ($Matches[2].Trim()) { $Matches[2].Trim() } else { @() }
        }
        elseif ($key -and $line -match '^\s+-\s+(.+?)\s*$') { $fields[$key] = @($fields[$key]) + $Matches[1] }
    }
    return $fields
}

function Get-Decisions {
    foreach ($section in @(Get-DocumentSections $decisionsDirectory | Where-Object { $_.File.Name -match $DecisionFilePattern })) {
        $fields = Get-FrontMatter ([IO.File]::ReadAllText($section.File.FullName))
        if ("$($fields['status'])".ToLowerInvariant() -in $ClosedStatuses) { continue }
        [pscustomobject]@{
            Id       = $section.File.BaseName
            Section  = $section
            Governs  = @($fields[$GovernsField] | Where-Object { $_ })
            Classes  = @()
            Diagrams = @($section.Content.Diagrams | Where-Object { $_.Part -eq $StructureSection })
        }
    }
}

function Test-GovernedBy([string]$FullName, [string]$Pattern) {
    if ($Pattern.EndsWith('*')) { return $FullName.StartsWith($Pattern.TrimEnd('*'), [StringComparison]::Ordinal) }
    return $FullName -ceq $Pattern
}

function Get-Namespace([string]$FullName) {
    $dot = $FullName.LastIndexOf('.')
    if ($dot -lt 0) { return '' }
    return $FullName.Substring(0, $dot)
}

# Un prefisso che si ferma prima della fine del namespace di una classe che copre prende quel namespace
# intero, con i namespace annidati.
function Get-GovernsEntryIssues($Decision, $Types) {
    foreach ($entry in $Decision.Governs) {
        if (-not $entry.EndsWith('*')) { New-Issue $Decision.Id "voce di $GovernsField con il nome di una sola classe" $entry; continue }
        $prefix = $entry.TrimEnd('*')
        $wide = @(Get-GovernedTypes $Types @($entry) | Where-Object { $namespace = Get-Namespace $_.FullName; $namespace -and -not $prefix.StartsWith("$namespace.", [StringComparison]::Ordinal) })
        if ($wide) { New-Issue $Decision.Id "voce di $GovernsField che copre un namespace intero" $entry }
    }
}

function Get-GovernedTypes($Types, [string[]]$Patterns) {
    return @($Types | Where-Object { $type = $_; @($Patterns | Where-Object { Test-GovernedBy $type.FullName $_ }).Count })
}

# Il nome di una classe del diagramma senza i parametri generici (Repository~T~ o Repository<T>).
function Get-ClassName([string]$Label) {
    return ($Label -split '[~<]')[0].Trim()
}

# Ogni decisione riceve le classi dei suoi diagrammi delle classi; un diagramma che non si legge lo
# segnala la verifica dei diagrammi Mermaid.
function Add-DiagramClasses([object[]]$Decisions) {
    $diagrams = @(foreach ($decision in $Decisions) {
            $index = 0
            foreach ($diagram in $decision.Diagrams) { [pscustomobject]@{ Id = "$($decision.Id):$index"; Text = $diagram.Text; Decision = $decision }; $index++ }
        })
    $results = @{}
    Invoke-MermaidParser $diagrams | ForEach-Object { $results[$_.id] = $_ }
    foreach ($diagram in $diagrams) {
        $parsed = $results[$diagram.Id]
        if ($parsed.type -ne 'classDiagram') { continue }
        $diagram.Decision.Classes = @($diagram.Decision.Classes) + @($parsed.classes | ForEach-Object { Get-ClassName $_ })
    }
}

function Get-StructureIssues($Decision) {
    $hasStructure = $Decision.Section.Content.Parts -contains $StructureSection
    if ($hasStructure -and -not $Decision.Governs) { return New-Issue $Decision.Id "parte '$StructureSection' senza la lista $GovernsField" $StructureSection }
    if (-not $hasStructure) { return New-Issue $Decision.Id "lista $GovernsField senza la parte '$StructureSection'" $GovernsField }
    if (-not $Decision.Classes) { return New-Issue $Decision.Id 'struttura nel codice senza diagramma delle classi' $StructureSection }
}

function Get-DecisionClassIssues($Decision, $Types) {
    $structureIssue = Get-StructureIssues $Decision
    if ($structureIssue) { return $structureIssue }

    Get-GovernsEntryIssues $Decision $Types
    $governed = Get-GovernedTypes $Types $Decision.Governs
    $governed | Where-Object { $Decision.Classes -cnotcontains $_.Name } | Sort-Object FullName -Unique |
        ForEach-Object { New-Issue $Decision.Id 'classe governata assente dal diagramma delle classi' $_.FullName }
    $Decision.Governs | Where-Object { -not (Get-GovernedTypes $Types @($_)) } |
        ForEach-Object { New-Issue $Decision.Id "voce di $GovernsField che non copre classi del codice" $_ }
}

function Get-DecisionClassesIssues {
    $decisions = @(Get-Decisions | Where-Object { $_.Governs -or $_.Section.Content.Parts -contains $StructureSection })
    if (-not $decisions) { return }
    if (-not (Test-Path $SourceDirectory -PathType Container)) { return New-Issue $ClassesScope 'codice sorgente assente' $SourceDirectory }

    try { Add-DiagramClasses $decisions }
    catch { return New-Issue $ClassesScope 'verifica non eseguita' $_.Exception.Message }
    $types = @(Get-ProductionTypes (Read-DotNetProjects))
    foreach ($decision in $decisions) { Get-DecisionClassIssues $decision $types }
}
