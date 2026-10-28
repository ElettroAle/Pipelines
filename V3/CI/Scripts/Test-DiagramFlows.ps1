# Flussi coerenti con la struttura che lo stesso documento dichiara. Nelle sezioni ogni partecipante
# di un diagramma di sequenza e' un elemento del modello C4, un container applicativo compare con i
# suoi componenti e ogni chiamata fra due partecipanti diversi e' una relazione del modello. Una
# decisione con la struttura nel codice ha anche il flusso nel codice, con un diagramma di sequenza
# fatto delle classi del suo diagramma delle classi.

. "$PSScriptRoot/VerificationGate.ps1"
. "$PSScriptRoot/MarkdownText.ps1"
. "$PSScriptRoot/Structurizr.ps1"
. "$PSScriptRoot/Mermaid.ps1"

$docsDirectory = if ($env:DOCS_DIRECTORY) { $env:DOCS_DIRECTORY } else { 'docs/architecture' }
$decisionsDirectory = if ($env:DECISIONS_DIRECTORY) { $env:DECISIONS_DIRECTORY } else { 'docs/decisions' }
$WorkspaceDsl = Join-Path $docsDirectory 'model/workspace.dsl'

$FlowsScope = 'flussi dei diagrammi'
$ModelScope = 'modello C4'
$ApplicationTag = $DocumentLanguage.ApplicationTag
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

function Get-ModelElements($Workspace) {
    $elements = [System.Collections.Generic.List[object]]::new()
    foreach ($person in @($Workspace.model.people)) { if ($person) { $elements.Add($person) } }
    foreach ($system in @($Workspace.model.softwareSystems)) {
        if (-not $system) { continue }
        $elements.Add($system)
        foreach ($container in @($system.containers)) {
            if (-not $container) { continue }
            $elements.Add($container)
            foreach ($component in @($container.components)) { if ($component) { $elements.Add($component) } }
        }
    }
    return $elements
}

function New-ModelIndex($Workspace) {
    $byName = @{}
    $relations = [System.Collections.Generic.HashSet[string]]::new()
    $wholeContainers = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($element in (Get-ModelElements $Workspace)) {
        if (-not $byName.ContainsKey($element.name)) { $byName[$element.name] = @() }
        $byName[$element.name] += $element.id
        foreach ($relation in @($element.relationships)) { if ($relation) { [void]$relations.Add("$($relation.sourceId)>$($relation.destinationId)") } }
        $isApplication = $element.tags -and ($element.tags -split ',') -contains $ApplicationTag
        if ($isApplication -and @($element.components | Where-Object { $_ }).Count) { [void]$wholeContainers.Add($element.id) }
    }
    return [pscustomobject]@{ ByName = $byName; Relations = $relations; WholeContainers = $wholeContainers }
}

function Test-Participants($Diagram, $Model) {
    $location = "$($Diagram.Section.File.Name):$($Diagram.Line)"
    foreach ($name in @($Diagram.Parsed.participants | Select-Object -Unique)) {
        $ids = @($Model.ByName[$name])
        if (-not $ids) { New-Issue $Diagram.Section.Title 'partecipante fuori dal modello C4' "$location $name" }
        elseif ($ids.Count -gt 1) { New-Issue $Diagram.Section.Title 'partecipante ambiguo nel modello C4' "$location $name" }
        elseif ($Model.WholeContainers.Contains($ids[0])) { New-Issue $Diagram.Section.Title 'container applicativo al posto dei suoi componenti' "$location $name" }
    }
}

function Test-Calls($Diagram, $Model) {
    $location = "$($Diagram.Section.File.Name):$($Diagram.Line)"
    foreach ($call in @($Diagram.Parsed.calls)) {
        if (-not $call -or $call.from -eq $call.to) { continue }
        $source = @($Model.ByName[$call.from])
        $destination = @($Model.ByName[$call.to])
        if ($source.Count -ne 1 -or $destination.Count -ne 1) { continue }
        if (-not $Model.Relations.Contains("$($source[0])>$($destination[0])")) { New-Issue $Diagram.Section.Title 'chiamata senza relazione nel modello C4' "$location $($call.from) -> $($call.to)" }
    }
}

function Get-DocumentFlowIssues([object[]]$Sequences) {
    if (-not $Sequences) { return }
    if (-not (Test-Path $WorkspaceDsl -PathType Leaf)) { return New-Issue $ModelScope 'modello mancante' $WorkspaceDsl }
    $export = Export-StructurizrWorkspace (Resolve-Path $WorkspaceDsl).Path
    if ($export.Error) { return New-Issue $ModelScope 'non valido' $export.Error }

    $model = New-ModelIndex $export.Workspace
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
