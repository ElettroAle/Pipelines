# SPDX-License-Identifier: Apache-2.0

# Flussi coerenti con la struttura che lo stesso documento dichiara. Ogni flusso delle sezioni ha un
# diagramma di sequenza a livello dei container; un partecipante e' un elemento del modello C4 per il
# suo identificativo e ne porta il nome (DiagramModel.ps1), nei dettagli un componente sta nel riquadro
# del suo container, e ogni chiamata fra due elementi diversi e' una relazione del modello C4. Una
# decisione con la struttura nel codice ha anche il flusso nel codice, con un diagramma di sequenza
# fatto delle classi del suo diagramma delle classi.

. "$PSScriptRoot/../Common/VerificationGate.ps1"
. "$PSScriptRoot/../Common/MarkdownText.ps1"
. "$PSScriptRoot/../C4/Structurizr.ps1"
. "$PSScriptRoot/Mermaid.ps1"
. "$PSScriptRoot/DiagramModel.ps1"

$docsDirectory = if ($env:DOCS_DIRECTORY) { $env:DOCS_DIRECTORY } else { 'docs/architecture' }
$decisionsDirectory = if ($env:DECISIONS_DIRECTORY) { $env:DECISIONS_DIRECTORY } else { 'docs/decisions' }
$WorkspaceDsl = Join-Path $docsDirectory 'c4/workspace.dsl'

$FlowsScope = 'flussi dei diagrammi'
$ModelScope = 'modello C4'
$StructureSection = $DocumentLanguage.AdrCodeStructureSection
$FlowSection = $DocumentLanguage.AdrCodeFlowSection
$DecisionFilePattern = '^\d{4}-[a-z0-9-]+\.md$'
$ClosedStatuses = @('superseded', 'deprecated', 'rejected')

function Get-Diagrams($Sections) {
    return @(foreach ($section in $Sections) {
            foreach ($diagram in $section.Content.Diagrams) {
                [pscustomobject]@{ Id = "$($section.File.Name):$($diagram.Line)"; Text = $diagram.Text; Section = $section; Line = $diagram.Line; Part = $diagram.Part; Parsed = $null }
            }
        })
}

function Get-DecisionStatus($Section) {
    $match = [regex]::Match([IO.File]::ReadAllText($Section.File.FullName), '(?s)\A---\r?\n.*?^status:\s*(\S+)', 'Multiline')
    return $(if ($match.Success) { $match.Groups[1].Value.ToLowerInvariant() } else { '' })
}

function Get-OpenDecisions {
    return @(Get-DocumentSections $decisionsDirectory | Where-Object { $_.File.Name -match $DecisionFilePattern -and (Get-DecisionStatus $_) -notin $ClosedStatuses })
}

function Add-ParsedDiagrams([object[]]$Diagrams) {
    $results = @{}
    Invoke-MermaidParser $Diagrams | ForEach-Object { $results[$_.id] = $_ }
    foreach ($diagram in $Diagrams) { $diagram.Parsed = $results[$diagram.Id] }
}

function Get-SequenceDiagrams([object[]]$Diagrams) {
    return @($Diagrams | Where-Object { $_.Parsed.type -eq 'sequence' })
}

function Get-Placements($Diagram) {
    return @($Diagram.Parsed.placements | Where-Object { $_ })
}

function Get-Location($Diagram) {
    return "$($Diagram.Section.File.Name):$($Diagram.Line)"
}

function Test-Boxes($Diagram, $Model, [string]$Location) {
    foreach ($box in @(Get-Placements $Diagram | Where-Object box | ForEach-Object box | Select-Object -Unique)) {
        if (-not (Get-ContainerNamed $box $Model)) { New-Issue $Diagram.Section.Title 'riquadro fuori dai container del modello C4' "$Location $box" }
    }
}

function Test-Participant($Placement, $Diagram, $Model, [string]$Location) {
    $id = Resolve-ElementId $Placement.id $Model
    if (-not $id) { return New-Issue $Diagram.Section.Title 'partecipante fuori dal modello C4' "$Location $(@($Placement.id, $Placement.name) | Select-Object -Unique)" }
    $element = $Model.Elements[$id]
    if ($Placement.name -cne $element.Name) { New-Issue $Diagram.Section.Title 'etichetta diversa dal nome nel modello C4' "$Location $($Placement.id) $($Placement.name), nel modello $($element.Name)" }
    if ($element.Kind -ne 'component') {
        if ($Placement.box) { New-Issue $Diagram.Section.Title 'componente fuori dal riquadro del suo container' "$Location $($Placement.name) nel riquadro $($Placement.box)" }
        return
    }
    if (-not $Placement.box) { return New-Issue $Diagram.Section.Title 'componente fuori da ogni riquadro' "$Location $($Placement.name)" }
    $box = Get-ContainerNamed $Placement.box $Model
    if ($box -and $box -cne $element.Container) { New-Issue $Diagram.Section.Title 'componente fuori dal riquadro del suo container' "$Location $($Placement.name) nel riquadro $($Placement.box)" }
}

function Test-WholeAndDecomposed($Diagram, $Model, [string]$Location) {
    $ids = @(Get-Placements $Diagram | ForEach-Object { Resolve-ElementId $_.id $Model } | Where-Object { $_ })
    $decomposed = @($ids | ForEach-Object { $Model.Elements[$_].Container } | Where-Object { $_ } | Select-Object -Unique)
    @($ids | Where-Object { $decomposed -ccontains $_ } | Select-Object -Unique) |
        ForEach-Object { New-Issue $Diagram.Section.Title 'container intero e con i suoi componenti' "$Location $($Model.Elements[$_].Name)" }
}

function Test-Participants($Diagram, $Model) {
    $location = Get-Location $Diagram
    Test-Boxes $Diagram $Model $location
    foreach ($placement in (Get-Placements $Diagram)) { Test-Participant $placement $Diagram $Model $location }
    Test-WholeAndDecomposed $Diagram $Model $location
}

function Test-Calls($Diagram, $Model) {
    $location = Get-Location $Diagram
    foreach ($call in @($Diagram.Parsed.calls)) {
        if (-not $call) { continue }
        $source = Resolve-ElementId $call.fromId $Model
        $destination = Resolve-ElementId $call.toId $Model
        if (-not $source -or -not $destination -or $source -ceq $destination) { continue }
        if (-not $Model.Relations.Contains("$source>$destination")) { New-Issue $Diagram.Section.Title 'chiamata senza relazione nel modello C4' "$location $($call.from) -> $($call.to)" }
    }
}

function Test-ContainerLevel([object[]]$Sequences) {
    foreach ($flow in ($Sequences | Group-Object { "$($_.Section.File.FullName)|$($_.Part)" })) {
        $first = $flow.Group[0]
        $atContainerLevel = @($flow.Group | Where-Object { -not @($_.Parsed.placements | Where-Object { $_.box }) })
        if ($atContainerLevel) { continue }
        New-Issue $first.Section.Title 'flusso senza diagramma a livello dei container' "$($first.Section.File.Name) $($first.Part)"
    }
}

function Get-DocumentFlowIssues([object[]]$Sequences) {
    if (-not $Sequences) { return }
    if (-not (Test-Path $WorkspaceDsl -PathType Leaf)) { return New-Issue $ModelScope 'modello mancante' $WorkspaceDsl }
    $export = Export-StructurizrWorkspace (Resolve-Path $WorkspaceDsl).Path
    if ($export.Error) { return New-Issue $ModelScope 'non valido' $export.Error }

    $model = New-ModelIndex $export.Workspace
    Test-ContainerLevel $Sequences
    foreach ($diagram in $Sequences) {
        Test-Participants $diagram $model
        Test-Calls $diagram $model
    }
}

function Get-DecisionFlowIssues($Decision, [object[]]$Diagrams) {
    if ($Decision.Content.Parts -notcontains $StructureSection) { return }
    $id = $Decision.File.BaseName
    if ($Decision.Content.Parts -notcontains $FlowSection) { return New-Issue $id 'parte mancante' $FlowSection }

    $own = @($Diagrams | Where-Object { $_.Section -eq $Decision })
    $sequences = Get-SequenceDiagrams @($own | Where-Object { $_.Part -eq $FlowSection })
    if (-not $sequences) { return New-Issue $id 'flusso senza diagramma di sequenza' $FlowSection }

    $classes = @($own | Where-Object { $_.Part -eq $StructureSection -and $_.Parsed.type -eq 'classDiagram' } | ForEach-Object { @($_.Parsed.classes) })
    foreach ($diagram in $sequences) {
        @($diagram.Parsed.participants | Select-Object -Unique) | Where-Object { $classes -notcontains $_ } |
            ForEach-Object { New-Issue $id 'partecipante fuori dal diagramma delle classi' "$($diagram.Section.File.Name):$($diagram.Line) $_" }
    }
}

function Get-FlowIssues {
    $documentDiagrams = Get-Diagrams (Get-DocumentSections $docsDirectory)
    $decisions = Get-OpenDecisions
    $decisionDiagrams = Get-Diagrams $decisions
    try {
        Add-ParsedDiagrams (@($documentDiagrams) + @($decisionDiagrams))
        Get-DocumentFlowIssues (Get-SequenceDiagrams $documentDiagrams)
    }
    catch { return New-Issue $FlowsScope 'verifica non eseguita' $_.Exception.Message }

    foreach ($decision in $decisions) { Get-DecisionFlowIssues $decision $decisionDiagrams }
}

Invoke-Verification { Get-FlowIssues } "Flussi dei diagrammi in $docsDirectory e $decisionsDirectory coerenti con la struttura" 'Verifica dei flussi dei diagrammi disattivata'
