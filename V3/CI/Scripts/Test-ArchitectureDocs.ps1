# Verifica la documentazione architetturale di un repository: dodici sezioni arc42,
# modello C4 in Structurizr DSL completo dei suoi livelli, diagrammi Mermaid validi,
# elementi e relazioni dei diagrammi spiegati nel testo, rimandi esistenti e testo
# conforme alla guida di stile (docs/style.json). Ogni problema nomina la sezione e il motivo.

. "$PSScriptRoot/MarkdownText.ps1"
. "$PSScriptRoot/Structurizr.ps1"
. "$PSScriptRoot/Mermaid.ps1"

$gateMode = if ($env:GATE_MODE) { $env:GATE_MODE.ToLower() } else { 'enforce' }
$docsDirectory = if ($env:DOCS_DIRECTORY) { $env:DOCS_DIRECTORY } else { 'docs/architecture' }
$styleRulesPath = if ($env:STYLE_RULES) { $env:STYLE_RULES } else { 'docs/style.json' }
$workspaceDsl = if ($env:WORKSPACE_DSL) { $env:WORKSPACE_DSL } else { 'docs/architecture/model/workspace.dsl' }
$decisionsDirectory = if ($env:DECISIONS_DIRECTORY) { $env:DECISIONS_DIRECTORY } else { 'docs/decisions' }

$Arc42Titles = @(
    'Introduzione e obiettivi', 'Vincoli', 'Contesto e ambito', 'Strategia di soluzione',
    'Vista dei building block', 'Vista di runtime', 'Vista di deployment', 'Concetti trasversali',
    'Decisioni architetturali', 'Requisiti di qualità', 'Rischi e debito tecnico', 'Glossario'
)
$GlossaryTitle = 'Glossario'
$SectionFilePattern = '^\d{2}-.+\.md$'
$ApplicationTag = 'Applicazione'
$DocumentScope = 'documento'
$ModelScope = 'modello C4'
$StyleScope = 'guida di stile'
$MermaidScope = 'diagrammi Mermaid'
$RequiredLevels = [ordered]@{ systemContextViews = 'vista di contesto'; containerViews = 'vista dei container'; deploymentViews = 'vista di deployment' }
$ViewKinds = @('systemLandscapeViews', 'systemContextViews', 'containerViews', 'componentViews', 'dynamicViews', 'deploymentViews')
$ProseKinds = @('paragraph', 'list')

$AcronymPattern = '(?<![\p{L}\p{N}])[A-Z][A-Z0-9]+(?![\p{L}\p{N}])'
$CamelCasePattern = '(?<![\p{L}\p{N}])[A-Z][a-z0-9]+(?:[A-Z][A-Za-z0-9]*)+(?![\p{L}\p{N}])'
$InlineCodePattern = '`([^`\s/]+)`'
$ItalicPattern = '(?<![*\p{L}\p{N}])\*(?!\*)([^*]+?)\*(?![*\p{L}\p{N}])|(?<![\p{L}\p{N}_])_([^_]+?)_(?![\p{L}\p{N}_])'
$BoldPattern = '\*\*([^*]+)\*\*'
$LinkPattern = '(?<!!)\[[^\]]*\]\(([^)\s]+)\)'
$DecisionIdPattern = '(?<![\p{L}\p{N}/-])(\d{4}-[a-z][a-z0-9-]*[a-z0-9])'

function New-Issue([string]$Scope, [string]$Reason, [string]$Detail) {
    return "${Scope}: $Reason ($Detail)"
}

function Get-PhrasePattern([string]$Phrase) {
    return '(?i)(?<![\p{L}\p{N}])' + [regex]::Escape($Phrase) + '(?![\p{L}\p{N}])'
}

function Test-Mentions([string]$Text, [string]$Name) {
    return [regex]::IsMatch($Text, (Get-PhrasePattern $Name))
}

# ── Struttura arc42 ───────────────────────────────────────────────────────────

function Get-Sections {
    if (-not (Test-Path $docsDirectory)) { return @() }
    return @(Get-ChildItem -Path $docsDirectory -File | Where-Object Name -Match $SectionFilePattern | Sort-Object Name | ForEach-Object {
            $parsed = ConvertFrom-MarkdownSection ([IO.File]::ReadAllText($_.FullName))
            [pscustomobject]@{ File = $_; Title = $parsed.Title; Arc42Index = [Array]::IndexOf($Arc42Titles, $parsed.Title); Content = $parsed }
        })
}

function Test-Arc42Structure($Sections) {
    $Sections | Where-Object Arc42Index -LT 0 | ForEach-Object { New-Issue $DocumentScope 'titolo non arc42' "$($_.File.Name): $($_.Title)" }
    $Arc42Titles | Where-Object { $Sections.Title -notcontains $_ } | ForEach-Object { New-Issue $DocumentScope 'sezione mancante' $_ }
    $Sections | Group-Object Title | Where-Object Count -GT 1 | ForEach-Object { New-Issue $DocumentScope 'sezione duplicata' $_.Name }

    $recognized = @($Sections | Where-Object Arc42Index -GE 0)
    $expectedOrder = @($recognized | Sort-Object Arc42Index)
    for ($position = 0; $position -lt $recognized.Count; $position++) {
        if ($recognized[$position].Title -ne $expectedOrder[$position].Title) { New-Issue $DocumentScope 'sezione fuori ordine' $recognized[$position].Title }
    }
}

# ── Guida di stile ────────────────────────────────────────────────────────────

function Get-StyleRules {
    if (-not (Test-Path $styleRulesPath)) { return $null }
    return Get-Content -Raw $styleRulesPath | ConvertFrom-Json
}

function Test-SectionShape($Section, $Style) {
    $opening = ($Section.Content.Blocks | Where-Object Kind -EQ 'opening' | Select-Object -First 1).Text
    $missingLabels = @($Style.opening | Where-Object { -not $opening -or -not $opening.Contains($_) })
    if ($missingLabels) { New-Issue $Section.Title 'apertura mancante' ($missingLabels -join ', ') }

    $parts = @($Section.Content.Parts)
    if ($parts[0] -ne $Style.parts.first) { New-Issue $Section.Title 'ordine della sezione' "«$($Style.parts.first)» non è la prima parte" }
    if ($parts -contains $Style.parts.last -and $parts[-1] -ne $Style.parts.last) { New-Issue $Section.Title 'ordine della sezione' "«$($Style.parts.last)» non è l'ultima parte" }
}

function Test-Readability($Section, $Style) {
    $abbreviations = @($Style.sentences.abbreviations)
    $opening = @($Section.Content.Blocks | Where-Object Kind -EQ 'opening' | ForEach-Object Text)
    $body = @($Section.Content.Blocks | Where-Object Kind -In $ProseKinds | ForEach-Object Text)

    $openingIndex = if ($opening) { Get-GulpeaseIndex $opening $abbreviations }
    if ($null -ne $openingIndex -and $openingIndex -lt $Style.gulpease.opening) { New-Issue $Section.Title 'leggibilità' "apertura: Gulpease $openingIndex, minimo $($Style.gulpease.opening)" }
    $bodyIndex = if ($body) { Get-GulpeaseIndex $body $abbreviations }
    if ($null -ne $bodyIndex -and $bodyIndex -lt $Style.gulpease.body) { New-Issue $Section.Title 'leggibilità' "Gulpease $bodyIndex, minimo $($Style.gulpease.body)" }

    @($opening) + @($body) | ForEach-Object { Get-Sentences $_ $abbreviations } | ForEach-Object {
        $words = Get-WordCount $_
        if ($words -gt $Style.sentences.maxWords) {
            $start = (($_ -split '\s+') | Select-Object -First 8) -join ' '
            New-Issue $Section.Title 'frase troppo lunga' "$words parole, massimo $($Style.sentences.maxWords): «$start…»"
        }
    }
}

function Test-Wording($Section, $Style) {
    $text = ($Section.Content.Blocks | ForEach-Object Text) -join "`n"
    @($Style.fillers) | Where-Object { $_ -and (Test-Mentions $text $_) } | ForEach-Object { New-Issue $Section.Title 'riempitivo' "«$_»" }
    @($Style.selfReferences) | Where-Object { $_ -and (Test-Mentions $text $_) } | ForEach-Object { New-Issue $Section.Title 'autoreferenziale' "«$_»" }
    if ($Style.jargon) {
        $Style.jargon.PSObject.Properties | Where-Object { Test-Mentions $text $_.Name } | ForEach-Object { New-Issue $Section.Title 'gergo evitabile' "«$($_.Name)», si usa «$($_.Value)»" }
    }
}

# ── Termini, sigle, nomi interni e concetti ───────────────────────────────────

function Get-GlossaryTerms($Sections) {
    $glossary = $Sections | Where-Object Title -EQ $GlossaryTitle | Select-Object -First 1
    if (-not $glossary) { return @() }
    return @($glossary.Content.Blocks | ForEach-Object {
            if ($_.Raw -match '^\s*\*\*([^*]+)\*\*') { $Matches[1].Trim().ToLowerInvariant() }
            elseif ($_.Kind -eq 'table' -and $_.Raw -match '^\s*\|\s*([^|]+?)\s*\|') { (ConvertTo-PlainText $Matches[1]).ToLowerInvariant() }
        })
}

# I blocchi di testo nell'ordine di lettura, con il codice in linea sostituito da spazi
# perche' le posizioni restino confrontabili con il testo originale.
function Get-ReadingStream($Sections) {
    $position = 0
    foreach ($section in ($Sections | Where-Object { $_.Arc42Index -ge 0 -and $_.Title -ne $GlossaryTitle })) {
        foreach ($block in $section.Content.Blocks) {
            $withoutLinks = $block.Raw -replace '!\[[^\]]*\]\([^)]*\)', '' -replace '\[([^\]]*)\]\([^)]*\)', '$1'
            $light = [regex]::Replace($withoutLinks, '`[^`]*`', { param($m) ' ' * $m.Length })
            [pscustomobject]@{ Position = $position++; Section = $section.Title; Kind = $block.Kind; Raw = $withoutLinks; Light = $light }
        }
    }
}

function Get-FirstOccurrences($Stream, [string]$Pattern, [string]$Property = 'Light') {
    $first = [ordered]@{}
    foreach ($entry in $Stream) {
        foreach ($match in [regex]::Matches($entry.$Property, $Pattern)) {
            $value = ($match.Groups | Select-Object -Skip 1 | Where-Object Success | Select-Object -First 1).Value
            if (-not $value) { $value = $match.Value }
            if (-not $first.Contains($value)) { $first[$value] = [pscustomobject]@{ Entry = $entry; Match = $match; Value = $value } }
        }
    }
    return $first.Values
}

function Test-ExplainedAtFirstUse($Occurrence) {
    $text = $Occurrence.Entry.Light
    $before = $text.Substring(0, $Occurrence.Match.Index)
    $after = $text.Substring($Occurrence.Match.Index + $Occurrence.Match.Length)
    return ($before.EndsWith('(') -and $after.StartsWith(')')) -or $after.StartsWith(' (') -or ($before.EndsWith('**') -and $after.StartsWith('**'))
}

function Test-Acronyms($Stream, $Glossary) {
    Get-FirstOccurrences $Stream $AcronymPattern | ForEach-Object {
        if (-not (Test-ExplainedAtFirstUse $_)) { New-Issue $_.Entry.Section 'sigla non spiegata' $_.Value }
        if ($Glossary -notcontains $_.Value.ToLowerInvariant()) { New-Issue $_.Entry.Section 'termine senza glossario' $_.Value }
    }
}

function Test-ItalicTerms($Stream, $Glossary) {
    Get-FirstOccurrences $Stream $ItalicPattern | Where-Object { $Glossary -notcontains $_.Value.Trim().ToLowerInvariant() } | ForEach-Object {
        New-Issue $_.Entry.Section 'termine senza glossario' $_.Value.Trim()
    }
}

function Test-InternalNames($Stream, $Glossary) {
    $explainedCode = @{}
    Get-FirstOccurrences $Stream $InlineCodePattern 'Raw' | ForEach-Object {
        $after = $_.Entry.Raw.Substring($_.Match.Index + $_.Match.Length)
        $explainedCode[$_.Value] = $after.StartsWith(' (') -or $Glossary -contains $_.Value.ToLowerInvariant()
        if (-not $explainedCode[$_.Value]) { New-Issue $_.Entry.Section 'nome interno non spiegato' $_.Value }
    }
    Get-FirstOccurrences $Stream $CamelCasePattern | Where-Object { -not $explainedCode.ContainsKey($_.Value) } | ForEach-Object {
        if (-not (Test-ExplainedAtFirstUse $_) -and $Glossary -notcontains $_.Value.ToLowerInvariant()) { New-Issue $_.Entry.Section 'nome interno non spiegato' $_.Value }
    }
}

function Test-ConceptOrder($Stream, $Style) {
    $labels = @($Style.opening)
    $definitions = Get-FirstOccurrences @($Stream | Where-Object Kind -NE 'opening') $BoldPattern | Where-Object { $labels -notcontains $_.Value }
    foreach ($definition in $definitions) {
        $pattern = Get-PhrasePattern $definition.Value
        $earlyUse = $Stream | Where-Object Position -LE $definition.Entry.Position | Where-Object {
            $limit = if ($_.Position -eq $definition.Entry.Position) { $definition.Match.Index } else { $_.Light.Length }
            [regex]::IsMatch($_.Light.Substring(0, $limit), $pattern)
        } | Select-Object -First 1
        if ($earlyUse) { New-Issue $earlyUse.Section 'ordine dei concetti' $definition.Value }
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

function Get-ModelIndex($Workspace) {
    $index = @{ Names = @{}; Relationships = @{}; Applications = @() }
    $pending = [Collections.Generic.Queue[object]]::new()
    @($Workspace.model.people) + @($Workspace.model.softwareSystems) + @($Workspace.model.deploymentNodes) | Where-Object { $_ } | ForEach-Object { $pending.Enqueue($_) }

    $instances = @()
    while ($pending.Count) {
        $element = $pending.Dequeue()
        if ($element.name) { $index.Names[$element.id] = $element.name } else { $instances += $element }
        if ($element.tags -and ($element.tags -split ',') -contains $ApplicationTag) { $index.Applications += $element }
        @($element.relationships) | Where-Object { $_ } | ForEach-Object { $index.Relationships[$_.id] = $_ }
        @($element.containers) + @($element.components) + @($element.children) + @($element.containerInstances) + @($element.softwareSystemInstances) + @($element.infrastructureNodes) |
            Where-Object { $_ } | ForEach-Object { $pending.Enqueue($_) }
    }
    $instances | ForEach-Object { $index.Names[$_.id] = $index.Names[$(if ($_.containerId) { $_.containerId } else { $_.softwareSystemId })] }
    return $index
}

function Get-Views($Workspace) {
    return @($ViewKinds | ForEach-Object {
            $kind = $_
            @($Workspace.views.$kind) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Kind = $kind; View = $_ } }
        })
}

function Test-ModelCompleteness($Workspace, $Views, $Index, $Sections) {
    $RequiredLevels.Keys | Where-Object { -not @($Workspace.views.$_ | Where-Object { $_ }).Count } | ForEach-Object { New-Issue $ModelScope 'livello mancante' $RequiredLevels[$_] }

    $containersWithComponents = @($Workspace.views.componentViews | Where-Object { $_ } | ForEach-Object containerId)
    $Index.Applications | Where-Object { $containersWithComponents -notcontains $_.id } | ForEach-Object { New-Issue $ModelScope 'container senza vista dei componenti' $_.name }

    $shown = @($Sections | ForEach-Object { $_.Content.Views })
    $Views | Where-Object { $shown -notcontains $_.View.key } | ForEach-Object { New-Issue $ModelScope 'vista non mostrata in nessuna sezione' $_.View.key }
}

# ── Spiegazione dei diagrammi ─────────────────────────────────────────────────

function Test-DiagramExplained($Section, [string]$Diagram, [string[]]$Elements, [object[]]$Relationships) {
    $texts = @($Section.Content.Blocks | ForEach-Object Text)
    $all = $texts -join "`n"
    $Elements | Where-Object { $_ } | Select-Object -Unique | Where-Object { -not (Test-Mentions $all $_) } | ForEach-Object {
        New-Issue $Section.Title 'elemento non spiegato' "$_, $Diagram"
    }
    $Relationships | Where-Object { $_[0] -and $_[1] -and $_[0] -ne $_[1] } | Where-Object {
        $pair = $_
        -not ($texts | Where-Object { (Test-Mentions $_ $pair[0]) -and (Test-Mentions $_ $pair[1]) })
    } | ForEach-Object { New-Issue $Section.Title 'relazione non spiegata' "$($_[0]) → $($_[1]), $Diagram" }
}

function Test-ViewsExplained($Section, $Views, $Index) {
    foreach ($key in $Section.Content.Views) {
        $view = ($Views | Where-Object { $_.View.key -eq $key } | Select-Object -First 1).View
        if (-not $view) { New-Issue $Section.Title 'vista inesistente' $key; continue }
        $elements = @($view.elements | Where-Object { $_ } | ForEach-Object { $Index.Names[$_.id] })
        $relationships = @($view.relationships | Where-Object { $_ } | ForEach-Object { $Index.Relationships[$_.id] } | Where-Object { $_ } |
                ForEach-Object { , @($Index.Names[$_.sourceId], $Index.Names[$_.destinationId]) })
        Test-DiagramExplained $Section "vista $key" $elements $relationships
    }
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
        if ($result.error) {
            New-Issue $diagram.Section.Title 'diagramma non valido' "$($diagram.Section.File.Name):$($diagram.Line + $result.line) $($result.error)"
            continue
        }
        $relationships = @($result.relationships | Where-Object { $_ } | ForEach-Object { , @($_) })
        Test-DiagramExplained $diagram.Section "diagramma alla riga $($diagram.Line)" @($result.elements) $relationships
    }
}

function Test-C4Model($Sections) {
    if (-not (Test-Path $workspaceDsl)) { return New-Issue $ModelScope 'file mancante' $workspaceDsl }
    try { $export = Export-StructurizrWorkspace (Resolve-Path $workspaceDsl).Path }
    catch { return New-Issue $ModelScope 'verifica non eseguita' $_.Exception.Message }
    if ($export.Error) { return New-Issue $ModelScope 'non valido' $export.Error }

    $views = Get-Views $export.Workspace
    $index = Get-ModelIndex $export.Workspace
    Test-ModelCompleteness $export.Workspace $views $index $Sections
    $Sections | ForEach-Object { Test-ViewsExplained $_ $views $index }
}

# ── Esito ─────────────────────────────────────────────────────────────────────

function Test-Writing($Sections) {
    $style = Get-StyleRules
    if (-not $style) { return New-Issue $StyleScope 'file mancante' $styleRulesPath }

    $Sections | Where-Object Arc42Index -GE 0 | ForEach-Object { Test-SectionShape $_ $style; Test-Readability $_ $style; Test-Wording $_ $style }
    $glossary = Get-GlossaryTerms $Sections
    $stream = @(Get-ReadingStream $Sections)
    Test-Acronyms $stream $glossary
    Test-ItalicTerms $stream $glossary
    Test-InternalNames $stream $glossary
    Test-ConceptOrder $stream $style
}

function Get-DocumentationIssues {
    $sections = Get-Sections
    Test-Arc42Structure $sections
    Test-C4Model $sections
    Test-MermaidSections $sections
    $sections | ForEach-Object { Test-References $_ }
    Test-Writing $sections
}

function Complete-Verification([string[]]$Issues) {
    if (-not $Issues) {
        Write-Host "##[section]Documentazione architetturale in $docsDirectory valida"
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
    Write-Host "Verifica della documentazione architetturale disattivata"
    exit 0
}

Complete-Verification @(Get-DocumentationIssues)
