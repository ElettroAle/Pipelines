# SPDX-License-Identifier: Apache-2.0

# Modello C4 di un documento, scritto in Structurizr DSL in model/workspace.dsl della cartella
# del documento: modello valido, viste di contesto, dei container e di deployment, una vista dei
# componenti per ogni container con il tag delle applicazioni, ogni vista mostrata in una sezione
# con il marcatore di vista, ogni marcatore rivolto a una vista esistente e nessun elemento con il tag
# tecnico nelle viste di contesto. Tag e marcatore seguono la lingua del documento: in italiano
# Applicazione, Tecnico e <!-- vista: chiave -->.

. "$PSScriptRoot/Common/Documentation/VerificationGate.ps1"
. "$PSScriptRoot/Common/Documentation/MarkdownText.ps1"
. "$PSScriptRoot/Common/Diagrams/Structurizr.ps1"

$docsDirectory = if ($env:DOCS_DIRECTORY) { $env:DOCS_DIRECTORY } else { 'docs/architecture' }
$WorkspaceDsl = Join-Path $docsDirectory 'model/workspace.dsl'

$ApplicationTag = $DocumentLanguage.ApplicationTag
$TechnicalTag = $DocumentLanguage.TechnicalTag
$GeneratedTag = $DocumentLanguage.GeneratedTag
$ModelScope = 'modello C4'
$RequiredLevels = [ordered]@{ systemContextViews = 'vista di contesto'; containerViews = 'vista dei container'; deploymentViews = 'vista di deployment' }
$ViewKinds = @('systemLandscapeViews', 'systemContextViews', 'containerViews', 'componentViews', 'dynamicViews', 'deploymentViews')

function Test-HasTag($Element, [string]$Tag) {
    return $Element.tags -and ($Element.tags -split ',') -contains $Tag
}

function Get-ApplicationContainers($Workspace) {
    return @($Workspace.model.softwareSystems | Where-Object { $_ } | ForEach-Object { @($_.containers) } |
            Where-Object { $_ -and (Test-HasTag $_ $ApplicationTag) })
}

function Get-ViewKeys($Workspace) {
    return @($ViewKinds | ForEach-Object { @($Workspace.views.$_) } | Where-Object { $_ } | ForEach-Object key)
}

function Test-RequiredLevels($Workspace) {
    $RequiredLevels.Keys | Where-Object { -not @($Workspace.views.$_ | Where-Object { $_ }).Count } | ForEach-Object { New-Issue $ModelScope 'livello mancante' $RequiredLevels[$_] }
}

function Test-ComponentViews($Workspace) {
    $containersWithComponents = @($Workspace.views.componentViews | Where-Object { $_ } | ForEach-Object containerId)
    Get-ApplicationContainers $Workspace | Where-Object { $containersWithComponents -notcontains $_.id } | ForEach-Object { New-Issue $ModelScope 'container senza vista dei componenti' $_.name }
}

function Test-ContextViewsWithoutTechnicalElements($Workspace) {
    $technical = @{}
    @($Workspace.model.people) + @($Workspace.model.softwareSystems) | Where-Object { $_ -and (Test-HasTag $_ $TechnicalTag) } | ForEach-Object { $technical[$_.id] = $_.name }
    $shown = @($Workspace.views.systemContextViews | Where-Object { $_ } | ForEach-Object { @($_.elements) } | Where-Object { $_ } | ForEach-Object id)
    $technical.Keys | Where-Object { $shown -contains $_ } | ForEach-Object { New-Issue $ModelScope 'elemento tecnico nella vista di contesto' $technical[$_] }
}

function Get-ModelElements($Workspace) {
    $systems = @($Workspace.model.softwareSystems | Where-Object { $_ })
    $containers = @($systems | ForEach-Object { @($_.containers) } | Where-Object { $_ })
    $components = @($containers | ForEach-Object { @($_.components) } | Where-Object { $_ })
    return @($Workspace.model.people | Where-Object { $_ }) + $systems + $containers + $components
}

function Test-GeneratedElementsDescribed($Elements) {
    $Elements | Where-Object { (Test-HasTag $_ $GeneratedTag) -and -not $_.description } | ForEach-Object { New-Issue $ModelScope 'elemento generato senza descrizione' $_.name }
}

# Le relazioni implicite che Structurizr deriva da quelle dichiarate portano linkedRelationshipId e non
# le dichiara nessuno.
function Get-DeclaredRelationships($Elements) {
    return @($Elements | ForEach-Object { @($_.relationships) } | Where-Object { $_ -and -not $_.linkedRelationshipId })
}

function Get-RelationshipName($Relationship, $Elements) {
    $names = @{}
    $Elements | ForEach-Object { $names[$_.id] = $_.name }
    return "$($names[$Relationship.sourceId]) -> $($names[$Relationship.destinationId])"
}

function Test-GeneratedRelationshipsDescribed($Elements) {
    Get-DeclaredRelationships $Elements | Where-Object { (Test-HasTag $_ $GeneratedTag) -and -not $_.description } |
        ForEach-Object { New-Issue $ModelScope 'relazione generata senza cio'' che passa' (Get-RelationshipName $_ $Elements) }
}

# Fra due elementi nati dal codice solo il codice dichiara relazioni: il testo del modello le descrive e
# non ne aggiunge.
function Test-RelationshipsOnlyFromCode($Elements) {
    $generated = @($Elements | Where-Object { Test-HasTag $_ $GeneratedTag } | ForEach-Object id)
    Get-DeclaredRelationships $Elements |
        Where-Object { -not (Test-HasTag $_ $GeneratedTag) -and $generated -contains $_.sourceId -and $generated -contains $_.destinationId } |
        ForEach-Object { New-Issue $ModelScope 'relazione fra elementi generati che il codice non dichiara' (Get-RelationshipName $_ $Elements) }
}

function Test-ViewsShown([string[]]$ViewKeys, $Sections) {
    $shown = @($Sections | ForEach-Object { $_.Content.Views })
    $ViewKeys | Where-Object { $shown -notcontains $_ } | ForEach-Object { New-Issue $ModelScope 'vista non mostrata in nessuna sezione' $_ }
}

function Test-ViewMarkers([string[]]$ViewKeys, $Sections) {
    foreach ($section in $Sections) {
        $section.Content.Views | Where-Object { $ViewKeys -notcontains $_ } | ForEach-Object { New-Issue $section.Title 'vista inesistente' $_ }
    }
}

function Get-ModelIssues {
    if (-not (Test-Path $WorkspaceDsl -PathType Leaf)) { return New-Issue $ModelScope 'modello mancante' $WorkspaceDsl }
    try { $export = Export-StructurizrWorkspace (Resolve-Path $WorkspaceDsl).Path }
    catch { return New-Issue $ModelScope 'verifica non eseguita' $_.Exception.Message }
    if ($export.Error) { return New-Issue $ModelScope 'non valido' $export.Error }

    $sections = Get-DocumentSections $docsDirectory
    $viewKeys = Get-ViewKeys $export.Workspace
    $elements = Get-ModelElements $export.Workspace
    Test-RequiredLevels $export.Workspace
    Test-ComponentViews $export.Workspace
    Test-ContextViewsWithoutTechnicalElements $export.Workspace
    Test-GeneratedElementsDescribed $elements
    Test-GeneratedRelationshipsDescribed $elements
    Test-RelationshipsOnlyFromCode $elements
    Test-ViewsShown $viewKeys $sections
    Test-ViewMarkers $viewKeys $sections
}

Invoke-Verification { Get-ModelIssues } "Modello C4 in $WorkspaceDsl valido" 'Verifica del modello C4 disattivata'
