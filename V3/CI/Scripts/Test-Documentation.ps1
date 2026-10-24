# Controlli oggettivi su un documento di un repository: le sezioni del template dichiarato,
# il modello C4 in Structurizr DSL se il documento lo contiene, diagrammi Mermaid validi,
# rimandi esistenti e soglie numeriche di leggibilita'. Lo stile del testo lo giudica
# Test-DocumentationStyle.ps1. Ogni problema nomina la sezione e il motivo.

. "$PSScriptRoot/MarkdownText.ps1"
. "$PSScriptRoot/Structurizr.ps1"
. "$PSScriptRoot/Mermaid.ps1"

$gateMode = if ($env:GATE_MODE) { $env:GATE_MODE.ToLower() } else { 'enforce' }
$docsDirectory = if ($env:DOCS_DIRECTORY) { $env:DOCS_DIRECTORY } else { 'docs/architecture' }
$decisionsDirectory = if ($env:DECISIONS_DIRECTORY) { $env:DECISIONS_DIRECTORY } else { 'docs/decisions' }
$templateSource = $env:DOCS_TEMPLATE
$templateSha256 = $env:DOCS_TEMPLATE_SHA256
$minimumGulpease = [int]$env:READABILITY_GULPEASE
$maximumWords = [int]$env:READABILITY_MAX_WORDS
$abbreviations = @("$env:READABILITY_ABBREVIATIONS" -split ';' | ForEach-Object Trim | Where-Object { $_ })
$WorkspaceDsl = Join-Path $docsDirectory 'model/workspace.dsl'

$SectionFilePattern = '^\d+[_-].+\.md$'
$HeadingAttributesPattern = '\s*\{#[^}]*\}\s*$'
$RemoteSourcePattern = '^https?://'
$ApplicationTag = 'Applicazione'
$DocumentScope = 'documento'
$TemplateScope = 'template del documento'
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

function New-TemplateError([string]$Reason, [string]$Detail) {
    return [InvalidOperationException]::new((New-Issue $TemplateScope $Reason $Detail))
}

# ── Template ──────────────────────────────────────────────────────────────────

# Il template e' un archivio zip pubblicato, con SHA-256 obbligatorio come ogni strumento
# scaricato in pipeline, oppure un archivio o una cartella del repository.
function Expand-DocumentTemplate {
    if (-not $templateSource) { throw (New-TemplateError 'non dichiarato' 'parametro docsTemplate') }
    $remote = $templateSource -match $RemoteSourcePattern
    if (-not $remote -and (Test-Path $templateSource -PathType Container)) { return (Resolve-Path $templateSource).Path }
    if ($remote -and -not $templateSha256) { throw (New-TemplateError 'SHA-256 non dichiarato' $templateSource) }

    $workDirectory = Join-Path ([IO.Path]::GetTempPath()) "document-template-$(New-Guid)"
    New-Item -ItemType Directory -Path $workDirectory | Out-Null
    $archive = Join-Path $workDirectory 'template.zip'
    if ($remote) {
        try { Invoke-WebRequest -Uri $templateSource -OutFile $archive -UseBasicParsing }
        catch { throw (New-TemplateError 'download non riuscito' "${templateSource}: $($_.Exception.Message)") }
    }
    elseif (Test-Path $templateSource -PathType Leaf) { Copy-Item $templateSource $archive }
    else { throw (New-TemplateError 'file mancante' $templateSource) }

    $actual = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($templateSha256 -and $actual -ne $templateSha256.ToLowerInvariant()) { throw (New-TemplateError 'SHA-256 diverso' "atteso $templateSha256, ricevuto $actual") }
    $expanded = Join-Path $workDirectory 'template'
    Expand-Archive -Path $archive -DestinationPath $expanded
    return $expanded
}

function Get-SectionTitle($Content) {
    return $Content.Title -replace $HeadingAttributesPattern, ''
}

# Le sezioni del template sono i suoi file Markdown numerati: il nome del file da' l'ordine e
# la sezione del documento con lo stesso nome riporta il suo titolo di primo livello.
function Get-TemplateSections([string]$Directory) {
    $sections = [ordered]@{}
    Get-ChildItem -Path $Directory -Recurse -File | Where-Object Name -Match $SectionFilePattern | Sort-Object Name |
        ForEach-Object { $sections[$_.Name] = Get-SectionTitle (ConvertFrom-MarkdownSection ([IO.File]::ReadAllText($_.FullName))) }
    return $sections
}

# ── Struttura ─────────────────────────────────────────────────────────────────

function Get-Sections($TemplateSections) {
    if (-not (Test-Path $docsDirectory)) { return @() }
    return @(Get-ChildItem -Path $docsDirectory -File | Where-Object Name -Match $SectionFilePattern | Sort-Object Name | ForEach-Object {
            $parsed = ConvertFrom-MarkdownSection ([IO.File]::ReadAllText($_.FullName))
            [pscustomobject]@{ File = $_; Title = Get-SectionTitle $parsed; Expected = $TemplateSections[$_.Name]; Content = $parsed }
        })
}

function Test-SectionStructure($Sections, $TemplateSections) {
    $Sections | Where-Object { $null -eq $_.Expected } | ForEach-Object { New-Issue $DocumentScope 'sezione fuori template' "$($_.File.Name): $($_.Title)" }
    $TemplateSections.Keys | Where-Object { $Sections.File.Name -notcontains $_ } | ForEach-Object { New-Issue $DocumentScope 'sezione mancante' "${_}: $($TemplateSections[$_])" }
    $Sections | Where-Object { $_.Expected -and $_.Title -ne $_.Expected } | ForEach-Object { New-Issue $DocumentScope 'titolo diverso dal template' "$($_.File.Name): $($_.Title), atteso «$($_.Expected)»" }
}

# ── Leggibilità ───────────────────────────────────────────────────────────────

function Test-Readability($Section) {
    $prose = @($Section.Content.Blocks | Where-Object Kind -In $ProseKinds | ForEach-Object Text)
    if (-not $prose) { return }

    $index = Get-GulpeaseIndex $prose $abbreviations
    if ($minimumGulpease -and $null -ne $index -and $index -lt $minimumGulpease) { New-Issue $Section.Title 'leggibilità' "Gulpease $index, minimo $minimumGulpease" }

    if (-not $maximumWords) { return }
    $prose | ForEach-Object { Get-Sentences $_ $abbreviations } | ForEach-Object {
        $words = Get-WordCount $_
        if ($words -gt $maximumWords) {
            $start = (($_ -split '\s+') | Select-Object -First 8) -join ' '
            New-Issue $Section.Title 'frase troppo lunga' "$words parole, massimo ${maximumWords}: «$start…»"
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
    if (-not (Test-Path $WorkspaceDsl)) {
        return $Sections | ForEach-Object { $section = $_; $section.Content.Views | ForEach-Object { New-Issue $section.Title 'vista inesistente' $_ } }
    }
    try { $export = Export-StructurizrWorkspace (Resolve-Path $WorkspaceDsl).Path }
    catch { return New-Issue $ModelScope 'verifica non eseguita' $_.Exception.Message }
    if ($export.Error) { return New-Issue $ModelScope 'non valido' $export.Error }

    $views = Get-Views $export.Workspace
    Test-ModelCompleteness $export.Workspace $views $Sections
    $Sections | ForEach-Object { Test-ViewsExist $_ $views }
}

# ── Esito ─────────────────────────────────────────────────────────────────────

function Get-DocumentationIssues {
    try { $templateSections = Get-TemplateSections (Expand-DocumentTemplate) }
    catch [InvalidOperationException] { return $_.Exception.Message }
    $sections = Get-Sections $templateSections
    Test-SectionStructure $sections $templateSections
    Test-C4Model $sections
    Test-MermaidSections $sections
    $sections | ForEach-Object { Test-References $_ }
    $sections | Where-Object Expected | ForEach-Object { Test-Readability $_ }
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
