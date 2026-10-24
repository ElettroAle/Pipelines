# Controlli oggettivi su un documento di un repository: le sezioni dichiarate in
# structure.json, il modello C4 in Structurizr DSL se la struttura lo dichiara, diagrammi
# Mermaid validi, rimandi esistenti e soglie numeriche di leggibilita'. Lo stile del testo
# lo giudica Test-DocumentationStyle.ps1. Ogni problema nomina la sezione e il motivo.

. "$PSScriptRoot/MarkdownText.ps1"
. "$PSScriptRoot/Structurizr.ps1"
. "$PSScriptRoot/Mermaid.ps1"

$gateMode = if ($env:GATE_MODE) { $env:GATE_MODE.ToLower() } else { 'enforce' }
$docsDirectory = if ($env:DOCS_DIRECTORY) { $env:DOCS_DIRECTORY } else { 'docs/architecture' }
$structurePath = if ($env:DOCS_STRUCTURE) { $env:DOCS_STRUCTURE } else { "$docsDirectory/structure.json" }
$decisionsDirectory = if ($env:DECISIONS_DIRECTORY) { $env:DECISIONS_DIRECTORY } else { 'docs/decisions' }

$SectionFilePattern = '^\d{2}-.+\.md$'
$ApplicationTag = 'Applicazione'
$DocumentScope = 'documento'
$StructureScope = 'struttura del documento'
$ModelScope = 'modello C4'
$MermaidScope = 'diagrammi Mermaid'
$RequiredLevels = [ordered]@{ systemContextViews = 'vista di contesto'; containerViews = 'vista dei container'; deploymentViews = 'vista di deployment' }
$ViewKinds = @('systemLandscapeViews', 'systemContextViews', 'containerViews', 'componentViews', 'dynamicViews', 'deploymentViews')
$ProseKinds = @('opening', 'quote', 'paragraph', 'list')

$LinkPattern = '(?<!!)\[[^\]]*\]\(([^)\s]+)\)'
$DecisionIdPattern = '(?<![\p{L}\p{N}/-])(\d{4}-[a-z][a-z0-9-]*[a-z0-9])'

function New-Issue([string]$Scope, [string]$Reason, [string]$Detail) {
    return "${Scope}: $Reason ($Detail)"
}

# ── Struttura ─────────────────────────────────────────────────────────────────

# Elenco ordinato dei titoli delle sezioni, soglie di leggibilita' e, facoltativo, il
# modello C4 relativo alla cartella del documento.
function Read-DocumentStructure {
    if (-not (Test-Path $structurePath)) { return $null }
    $structure = Get-Content -Raw $structurePath | ConvertFrom-Json
    $script:SectionTitles = @($structure.sections)
    $script:Readability = $structure.readability
    $script:WorkspaceDsl = if ($structure.model) { Join-Path $docsDirectory $structure.model }
    return $structure
}

function Get-Sections {
    if (-not (Test-Path $docsDirectory)) { return @() }
    return @(Get-ChildItem -Path $docsDirectory -File | Where-Object Name -Match $SectionFilePattern | Sort-Object Name | ForEach-Object {
            $parsed = ConvertFrom-MarkdownSection ([IO.File]::ReadAllText($_.FullName))
            [pscustomobject]@{ File = $_; Title = $parsed.Title; Index = [Array]::IndexOf($SectionTitles, $parsed.Title); Content = $parsed }
        })
}

function Test-SectionStructure($Sections) {
    $Sections | Where-Object Index -LT 0 | ForEach-Object { New-Issue $DocumentScope 'titolo fuori struttura' "$($_.File.Name): $($_.Title)" }
    $SectionTitles | Where-Object { $Sections.Title -notcontains $_ } | ForEach-Object { New-Issue $DocumentScope 'sezione mancante' $_ }
    $Sections | Group-Object Title | Where-Object Count -GT 1 | ForEach-Object { New-Issue $DocumentScope 'sezione duplicata' $_.Name }

    $recognized = @($Sections | Where-Object Index -GE 0)
    $expectedOrder = @($recognized | Sort-Object Index)
    for ($position = 0; $position -lt $recognized.Count; $position++) {
        if ($recognized[$position].Title -ne $expectedOrder[$position].Title) { New-Issue $DocumentScope 'sezione fuori ordine' $recognized[$position].Title }
    }
}

# ── Leggibilità ───────────────────────────────────────────────────────────────

function Test-Readability($Section) {
    if (-not $Readability) { return }
    $abbreviations = @($Readability.abbreviations)
    $prose = @($Section.Content.Blocks | Where-Object Kind -In $ProseKinds | ForEach-Object Text)
    if (-not $prose) { return }

    $index = Get-GulpeaseIndex $prose $abbreviations
    if ($Readability.gulpease -and $null -ne $index -and $index -lt $Readability.gulpease) { New-Issue $Section.Title 'leggibilità' "Gulpease $index, minimo $($Readability.gulpease)" }

    if (-not $Readability.maxWords) { return }
    $prose | ForEach-Object { Get-Sentences $_ $abbreviations } | ForEach-Object {
        $words = Get-WordCount $_
        if ($words -gt $Readability.maxWords) {
            $start = (($_ -split '\s+') | Select-Object -First 8) -join ' '
            New-Issue $Section.Title 'frase troppo lunga' "$words parole, massimo $($Readability.maxWords): «$start…»"
        }
    }
}

# ── Rimandi ───────────────────────────────────────────────────────────────────

function Test-LinkTarget($Section, [string]$Target) {
    $path, $anchor = $Target -split '#', 2
    $targetFile = if ($path) { Join-Path $Section.File.DirectoryName ([uri]::UnescapeDataString($path)) } else { $Section.File.FullName }
    if (-not (Test-Path $targetFile -PathType Leaf)) { return $false }
    if (-not $anchor) { return $true }
    $anchors = (ConvertFrom-MarkdownSection ([IO.File]::ReadAllText($targetFile))).Anchors
    return $anchors -contains [uri]::UnescapeDataString($anchor).ToLowerInvariant()
}

function Test-References($Section) {
    foreach ($block in $Section.Content.Blocks) {
        [regex]::Matches($block.Raw, $LinkPattern) | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch '^[a-z][a-z0-9+.-]*:' } |
            Where-Object { -not (Test-LinkTarget $Section $_) } | ForEach-Object { New-Issue $Section.Title 'rimando inesistente' $_ }
        [regex]::Matches($block.Text, $DecisionIdPattern) | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique |
            Where-Object { -not (Test-Path (Join-Path $decisionsDirectory "$_.md")) } | ForEach-Object { New-Issue $Section.Title 'rimando inesistente' $_ }
    }
}

# ── Modello C4 ────────────────────────────────────────────────────────────────

function Get-ApplicationContainers($Workspace) {
    return @($Workspace.model.softwareSystems | Where-Object { $_ } | ForEach-Object { @($_.containers) } |
            Where-Object { $_ -and $_.tags -and ($_.tags -split ',') -contains $ApplicationTag })
}

function Get-Views($Workspace) {
    return @($ViewKinds | ForEach-Object {
            $kind = $_
            @($Workspace.views.$kind) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Kind = $kind; View = $_ } }
        })
}

function Test-ModelCompleteness($Workspace, $Views, $Sections) {
    $RequiredLevels.Keys | Where-Object { -not @($Workspace.views.$_ | Where-Object { $_ }).Count } | ForEach-Object { New-Issue $ModelScope 'livello mancante' $RequiredLevels[$_] }

    $containersWithComponents = @($Workspace.views.componentViews | Where-Object { $_ } | ForEach-Object containerId)
    Get-ApplicationContainers $Workspace | Where-Object { $containersWithComponents -notcontains $_.id } | ForEach-Object { New-Issue $ModelScope 'container senza vista dei componenti' $_.name }

    $shown = @($Sections | ForEach-Object { $_.Content.Views })
    $Views | Where-Object { $shown -notcontains $_.View.key } | ForEach-Object { New-Issue $ModelScope 'vista non mostrata in nessuna sezione' $_.View.key }
}

# ── Diagrammi ─────────────────────────────────────────────────────────────────

function Test-ViewsExist($Section, $Views) {
    $Section.Content.Views | Where-Object { $Views.View.key -notcontains $_ } | ForEach-Object { New-Issue $Section.Title 'vista inesistente' $_ }
}

function Test-MermaidSections($Sections) {
    $diagrams = @(foreach ($section in $Sections) {
            foreach ($diagram in $section.Content.Diagrams) { [pscustomobject]@{ Id = "$($section.File.Name):$($diagram.Line)"; Text = $diagram.Text; Section = $section; Line = $diagram.Line } }
        })
    $results = @{}
    try { Test-MermaidDiagrams $diagrams | ForEach-Object { $results[$_.id] = $_ } }
    catch { return New-Issue $MermaidScope 'verifica non eseguita' $_.Exception.Message }

    foreach ($diagram in $diagrams) {
        $result = $results[$diagram.Id]
        if ($result.error) { New-Issue $diagram.Section.Title 'diagramma non valido' "$($diagram.Section.File.Name):$($diagram.Line + $result.line) $($result.error)" }
    }
}

function Test-C4Model($Sections) {
    if (-not $WorkspaceDsl) {
        return $Sections | ForEach-Object { $section = $_; $section.Content.Views | ForEach-Object { New-Issue $section.Title 'vista inesistente' $_ } }
    }
    if (-not (Test-Path $WorkspaceDsl)) { return New-Issue $ModelScope 'file mancante' $WorkspaceDsl }
    try { $export = Export-StructurizrWorkspace (Resolve-Path $WorkspaceDsl).Path }
    catch { return New-Issue $ModelScope 'verifica non eseguita' $_.Exception.Message }
    if ($export.Error) { return New-Issue $ModelScope 'non valido' $export.Error }

    $views = Get-Views $export.Workspace
    Test-ModelCompleteness $export.Workspace $views $Sections
    $Sections | ForEach-Object { Test-ViewsExist $_ $views }
}

# ── Esito ─────────────────────────────────────────────────────────────────────

function Get-DocumentationIssues {
    if (-not (Read-DocumentStructure)) { return New-Issue $StructureScope 'file mancante' $structurePath }
    $sections = Get-Sections
    Test-SectionStructure $sections
    Test-C4Model $sections
    Test-MermaidSections $sections
    $sections | ForEach-Object { Test-References $_ }
    $sections | Where-Object Index -GE 0 | ForEach-Object { Test-Readability $_ }
}

function Complete-Verification([string[]]$Issues) {
    if (-not $Issues) {
        Write-Host "##[section]Documento in $docsDirectory valido"
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

if ($gateMode -eq 'off') {
    Write-Host "Verifica del documento disattivata"
    exit 0
}

Complete-Verification @(Get-DocumentationIssues)
