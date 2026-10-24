# Modello C4 di un documento, scritto in Structurizr DSL in model/workspace.dsl della cartella
# del documento: modello valido, viste di contesto, dei container e di deployment, una vista dei
# componenti per ogni container con il tag Applicazione, ogni vista mostrata in una sezione con
# il marcatore <!-- vista: chiave --> e ogni marcatore rivolto a una vista esistente.

. "$PSScriptRoot/VerificationGate.ps1"
. "$PSScriptRoot/MarkdownText.ps1"
. "$PSScriptRoot/Structurizr.ps1"

$docsDirectory = if ($env:DOCS_DIRECTORY) { $env:DOCS_DIRECTORY } else { 'docs/architecture' }
$WorkspaceDsl = Join-Path $docsDirectory 'model/workspace.dsl'

$ApplicationTag = 'Applicazione'
$ModelScope = 'modello C4'
$RequiredLevels = [ordered]@{ systemContextViews = 'vista di contesto'; containerViews = 'vista dei container'; deploymentViews = 'vista di deployment' }
$ViewKinds = @('systemLandscapeViews', 'systemContextViews', 'containerViews', 'componentViews', 'dynamicViews', 'deploymentViews')

function Get-ApplicationContainers($Workspace) {
    return @($Workspace.model.softwareSystems | Where-Object { $_ } | ForEach-Object { @($_.containers) } |
            Where-Object { $_ -and $_.tags -and ($_.tags -split ',') -contains $ApplicationTag })
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
    Test-RequiredLevels $export.Workspace
    Test-ComponentViews $export.Workspace
    Test-ViewsShown $viewKeys $sections
    Test-ViewMarkers $viewKeys $sections
}

Invoke-Verification { Get-ModelIssues } "Modello C4 in $WorkspaceDsl valido" 'Verifica del modello C4 disattivata'
