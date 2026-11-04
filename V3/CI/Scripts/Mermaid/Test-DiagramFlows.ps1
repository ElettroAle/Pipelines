# SPDX-License-Identifier: Apache-2.0

# Flussi coerenti con la struttura che lo stesso documento dichiara. Ogni flusso delle sezioni ha un
# diagramma di sequenza a livello dei container; nei dettagli un componente sta nel riquadro del suo
# container, e ogni chiamata fra due partecipanti diversi e' una relazione del modello C4. Una
# decisione con la struttura nel codice ha anche il flusso nel codice, con un diagramma di sequenza
# fatto delle classi del suo diagramma delle classi.

. "$PSScriptRoot/../Common/VerificationGate.ps1"
. "$PSScriptRoot/../Common/MarkdownText.ps1"
. "$PSScriptRoot/../C4/Structurizr.ps1"
. "$PSScriptRoot/Mermaid.ps1"

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

function New-ModelIndex($Workspace) {
    $byName = @{}
    $containers = @{}
    $componentNames = [System.Collections.Generic.HashSet[string]]::new()
    $relations = [System.Collections.Generic.HashSet[string]]::new()
    $addElement = {
        param($Element)
        if (-not $byName.ContainsKey($Element.name)) { $byName[$Element.name] = @() }
        $byName[$Element.name] += $Element.id
    }
    $elements = [System.Collections.Generic.List[object]]::new()
    foreach ($person in @($Workspace.model.people | Where-Object { $_ })) { & $addElement $person; $elements.Add($person) }
    foreach ($system in @($Workspace.model.softwareSystems | Where-Object { $_ })) {
        & $addElement $system; $elements.Add($system)
        foreach ($container in @($system.containers | Where-Object { $_ })) {
            & $addElement $container; $elements.Add($container)
            $components = @{}
            foreach ($component in @($container.components | Where-Object { $_ })) {
                $components[$component.name] = $component.id
                [void]$componentNames.Add($component.name)
                $elements.Add($component)
            }
            $containers[$container.id] = $components
        }
    }
    foreach ($relation in @($elements | ForEach-Object { @($_.relationships) } | Where-Object { $_ })) { [void]$relations.Add("$($relation.sourceId)>$($relation.destinationId)") }
    return [pscustomobject]@{ ByName = $byName; Containers = $containers; ComponentNames = $componentNames; Relations = $relations }
}

function Get-BoxComponents([string]$Box, $Model) {
    $ids = @($Model.ByName[$Box] | Where-Object { $_ -and $Model.Containers.ContainsKey($_) })
    if ($ids.Count -eq 1) { return $Model.Containers[$ids[0]] }
}

function Resolve-Participant([string]$Name, [string]$Box, $Model) {
    if ($Box) {
        $components = Get-BoxComponents $Box $Model
        if ($components) { return $components[$Name] }
        return
    }
    $ids = @($Model.ByName[$Name])
    if ($ids.Count -eq 1) { return $ids[0] }
}

function Get-Placements($Diagram) {
    return @($Diagram.Parsed.placements | Where-Object { $_ } | Sort-Object name, box -Unique)
}

function Test-Boxes($Diagram, $Model, [string]$Location) {
    foreach ($box in @(Get-Placements $Diagram | Where-Object box | ForEach-Object box | Select-Object -Unique)) {
        if (-not (Get-BoxComponents $box $Model)) { New-Issue $Diagram.Section.Title 'riquadro fuori dai container del modello C4' "$Location $box" }
    }
}

function Test-Participant($Placement, $Diagram, $Model, [string]$Location) {
    $known = $Model.ByName.ContainsKey($Placement.name) -or $Model.ComponentNames.Contains($Placement.name)
    if (-not $known) { return New-Issue $Diagram.Section.Title 'partecipante fuori dal modello C4' "$Location $($Placement.name)" }
    if ($Placement.box) {
        $components = Get-BoxComponents $Placement.box $Model
        if ($components -and -not $components.ContainsKey($Placement.name)) { New-Issue $Diagram.Section.Title 'componente fuori dal riquadro del suo container' "$Location $($Placement.name) nel riquadro $($Placement.box)" }
        return
    }
    $ids = @($Model.ByName[$Placement.name])
    if (-not $ids) { New-Issue $Diagram.Section.Title 'componente fuori da ogni riquadro' "$Location $($Placement.name)" }
    elseif ($ids.Count -gt 1) { New-Issue $Diagram.Section.Title 'partecipante ambiguo nel modello C4' "$Location $($Placement.name)" }
}

function Test-WholeAndDecomposed($Diagram, [string]$Location) {
    $placements = Get-Placements $Diagram
    $boxes = @($placements | Where-Object box | ForEach-Object box | Select-Object -Unique)
    @($placements | Where-Object { -not $_.box -and $boxes -contains $_.name } | ForEach-Object name | Select-Object -Unique) |
        ForEach-Object { New-Issue $Diagram.Section.Title 'container intero e con i suoi componenti' "$Location $_" }
}

function Test-Participants($Diagram, $Model) {
    $location = "$($Diagram.Section.File.Name):$($Diagram.Line)"
    Test-Boxes $Diagram $Model $location
    foreach ($placement in (Get-Placements $Diagram)) { Test-Participant $placement $Diagram $Model $location }
    Test-WholeAndDecomposed $Diagram $location
}

function Test-Calls($Diagram, $Model) {
    $location = "$($Diagram.Section.File.Name):$($Diagram.Line)"
    foreach ($call in @($Diagram.Parsed.calls)) {
        if (-not $call -or ($call.from -eq $call.to -and $call.fromBox -eq $call.toBox)) { continue }
        $source = Resolve-Participant $call.from $call.fromBox $Model
        $destination = Resolve-Participant $call.to $call.toBox $Model
        if (-not $source -or -not $destination) { continue }
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
