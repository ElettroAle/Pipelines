# SPDX-License-Identifier: Apache-2.0

# Pubblica un documento arc42 nella wiki di progetto di Azure DevOps. Le sezioni diventano pagine
# sotto WIKI_ROOT, nell'ordine dei loro numeri, e le decisioni diventano sottopagine della sezione 9.
# Il nome di default di WIKI_ROOT e la colonna dello stato seguono la lingua del documento.
# I marcatori di vista diventano le immagini dei diagrammi C4, disegnate con C4-PlantUML nella direzione
# che si legge meglio (ViewImages.ps1), e i link puntano alle pagine. Si scrive nel repository git della wiki con un commit solo, che tocca soltanto
# WIKI_ROOT, le sue immagini e la sua voce nell'ordine della radice: il resto della wiki resta com'e'.
# Con DOCUMENT_FORMATS (pdf, docx) le stesse pagine diventano anche un documento unico (Arc42Document.ps1), che
# lo stesso commit allega alla wiki e che la pagina WIKI_ROOT nomina.
# Con DRAFT_DOCS_DIRECTORY ogni pagina che il documento in bozza cambia, o che esiste solo nella bozza, ha una pagina
# sorella con il suffisso della lingua e l'avviso di bozza, e la pagina ufficiale vi rimanda; il documento unico
# resta quello ufficiale.

. "$PSScriptRoot/../Common/MarkdownText.ps1"
. "$PSScriptRoot/../Common/WikiNames.ps1"
. "$PSScriptRoot/../Reference/ReferenceLinks.ps1"
. "$PSScriptRoot/../C4/Structurizr.ps1"
. "$PSScriptRoot/../C4/ViewImages.ps1"
. "$PSScriptRoot/Arc42Document.ps1"

$ErrorActionPreference = 'Stop'

$docsDirectory = if ($env:DOCS_DIRECTORY) { $env:DOCS_DIRECTORY } else { 'docs/architecture' }
$decisionsDirectory = if ($env:DECISIONS_DIRECTORY) { $env:DECISIONS_DIRECTORY } else { 'docs/decisions' }
$wikiDirectory = $env:WIKI_DIRECTORY
$wikiRoot = if ($env:WIKI_ROOT) { $env:WIKI_ROOT } else { $DocumentLanguage.WikiRoot }
$wikiBranch = if ($env:WIKI_BRANCH) { $env:WIKI_BRANCH } else { 'wikiMaster' }
$repositoryUrl = "$($env:SYSTEM_COLLECTIONURI)$($env:SYSTEM_TEAMPROJECT)/_git/$($env:BUILD_REPOSITORY_NAME)"
$draftDocsDirectory = "$env:DRAFT_DOCS_DIRECTORY"
$draftDecisionsDirectory = "$env:DRAFT_DECISIONS_DIRECTORY"
$draftBranch = if ($env:DRAFT_BRANCH) { $env:DRAFT_BRANCH } else { 'staging' }
$sourceVersion = if ($env:BUILD_SOURCEVERSION) { $env:BUILD_SOURCEVERSION.Substring(0, [math]::Min(8, $env:BUILD_SOURCEVERSION.Length)) } else { 'locale' }

$SectionFilePattern = '^(\d+)[_-].+\.md$'
$DecisionFilePattern = '^(\d{4})-.+\.md$'
# Nel template arc42 la sezione 9 raccoglie le decisioni: le loro pagine stanno sotto la sua.
$DecisionsSectionNumber = 9
$MaxPushAttempts = 3
# La wiki tiene immagini e allegati nella cartella .attachments della radice.
$AttachmentsFolder = '.attachments'
$DraftFolder = 'draft'
$LinkPattern = '(\[[^\]]*\]\()([^)\s]+)(\))'
$ExternalLinkPattern = '^(?:[a-z][a-z0-9+.-]*:|#)'

function ConvertTo-RepositoryPath([string]$Path) {
    return ([IO.Path]::GetRelativePath((Get-Location).Path, $Path) -replace '\\', '/')
}

function Join-RepositoryPath([string]$Directory, [string]$Name) {
    if ($Directory -in '', '.') { return $Name }
    return "$Directory/$Name"
}

# Le pagine della bozza prendono il percorso nel repository del file ufficiale corrispondente: i loro link si
# risolvono come quelli delle pagine ufficiali, e una pagina che non cambia produce lo stesso testo.
function New-DocumentLocation([string]$Docs, [string]$Decisions, $Official = $null) {
    $location = (Get-Location).Path
    return [pscustomobject]@{
        Docs            = $Docs
        Decisions       = $Decisions
        DocsSource      = if ($Official) { $Official.DocsSource } else { ConvertTo-RepositoryPath ([IO.Path]::GetFullPath($Docs, $location)) }
        DecisionsSource = if ($Official) { $Official.DecisionsSource } else { ConvertTo-RepositoryPath ([IO.Path]::GetFullPath($Decisions, $location)) }
    }
}

function Read-Markdown([string]$Path) {
    $text = [IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
    $status = $null
    $supersededBy = $null
    if ($text -match '^---\n(?<front>[\s\S]*?)\n---\n') {
        $front = $Matches.front
        $text = $text.Substring($Matches[0].Length)
        if ($front -match '(?m)^status:\s*(\S+)') { $status = $Matches[1] }
        if ($front -match '(?m)^superseded-by:\s*(\S+)') { $supersededBy = $Matches[1] }
    }
    $title = [regex]::Match($text, '(?m)^#\s+(.+?)\s*$').Groups[1].Value
    $body = ([regex]::new('(?m)^#\s+.+\n+')).Replace($text, '', 1)
    return [pscustomobject]@{ Title = $title; Status = $status; SupersededBy = $supersededBy; Body = $body.TrimStart("`n") }
}

# Il titolo di una decisione e' una frase intera, troppo lunga per il nome di una pagina: il nome
# viene dal file, «0001-hard-link-tra-ambienti.md» diventa «0001 Hard link tra ambienti».
function Get-DecisionPageName([string]$FileName) {
    $words = [IO.Path]::GetFileNameWithoutExtension($FileName) -split '-'
    $title = ($words | Select-Object -Skip 1) -join ' '
    return "$($words[0]) $($title.Substring(0, 1).ToUpperInvariant())$($title.Substring(1))"
}

function New-Page([string]$Source, [string]$Name, [string]$ParentPath, $Markdown, [string]$Title = $Name) {
    return [pscustomobject]@{
        Source   = $Source
        Key      = $Source
        DisplayName = $Name
        Title    = $Title
        Name     = ConvertTo-WikiName $Name
        WikiPath = "$ParentPath/$(ConvertTo-WikiName $Name)"
        Status   = $Markdown.Status
        SupersededBy = $Markdown.SupersededBy
        Body     = $Markdown.Body
        Children = [Collections.Generic.List[object]]::new()
        Counterpart = $null
        DraftOnly = $false
        Drafted  = $false
    }
}

function Get-DocumentPages($Location) {
    $rootPath = "/$(ConvertTo-WikiName $wikiRoot)"
    $sections = foreach ($file in (Get-ChildItem -Path $Location.Docs -File | Where-Object Name -Match $SectionFilePattern)) {
        $number = [int]([regex]::Match($file.Name, $SectionFilePattern).Groups[1].Value)
        $markdown = Read-Markdown $file.FullName
        if (-not $markdown.Title) { throw "$($file.Name): la sezione non ha un titolo" }
        $title = ConvertTo-PlainText $markdown.Title
        [pscustomobject]@{ Number = $number; Page = New-Page (Join-RepositoryPath $Location.DocsSource $file.Name) "$number. $title" $rootPath $markdown $title }
    }
    $sections = @($sections | Sort-Object Number)
    if (-not $sections) { throw "nessuna sezione in $($Location.Docs)" }

    $decisionsSection = $sections | Where-Object Number -EQ $DecisionsSectionNumber | Select-Object -First 1
    $decisionsParent = if ($decisionsSection) { $decisionsSection.Page } else { $null }
    $decisionsPath = if ($decisionsParent) { $decisionsParent.WikiPath } else { $rootPath }
    $files = if ($Location.Decisions) { @(Get-ChildItem -Path $Location.Decisions -File -ErrorAction SilentlyContinue) } else { @() }
    $decisions = foreach ($file in ($files | Where-Object Name -Match $DecisionFilePattern | Sort-Object Name)) {
        New-Page (Join-RepositoryPath $Location.DecisionsSource $file.Name) (Get-DecisionPageName $file.Name) $decisionsPath (Read-Markdown $file.FullName)
    }

    $topLevel = [Collections.Generic.List[object]]::new()
    foreach ($section in $sections) { $topLevel.Add($section.Page) }
    foreach ($decision in @($decisions)) {
        if ($decisionsParent) { $decisionsParent.Children.Add($decision) } else { $topLevel.Add($decision) }
    }
    return , $topLevel
}

function Get-AllPages($Pages) {
    foreach ($page in $Pages) {
        $page
        Get-AllPages $page.Children
    }
}

#region Conversione del contenuto

function Resolve-LinkSource($Page, [string]$Target) {
    $path = $Target.Split('#')[0]
    if (-not $path) { return $null }
    $full = [IO.Path]::GetFullPath((Join-Path (Split-Path $Page.Source) ([uri]::UnescapeDataString($path))))
    return ConvertTo-RepositoryPath $full
}

function Convert-Link($Page, [string]$Target, [hashtable]$PagesBySource) {
    if ($Target -match $ExternalLinkPattern) { return $Target }
    $anchor = if ($Target.Contains('#')) { '#' + $Target.Split('#', 2)[1] } else { '' }
    $source = Resolve-LinkSource $Page $Target
    if ($PagesBySource.ContainsKey($source)) { return $PagesBySource[$source].WikiPath + $anchor }
    return "$($repositoryUrl)?path=/$source"
}

function Convert-Links([string]$Line, $Page, [hashtable]$PagesBySource) {
    return [regex]::Replace($Line, $LinkPattern, { param($match) $match.Groups[1].Value + (Convert-Link $Page $match.Groups[2].Value $PagesBySource) + $match.Groups[3].Value })
}

function Get-RowDecision([string]$Row, $Page, [hashtable]$PagesBySource) {
    $firstCell = ($Row.Trim().Trim('|') -split '\|')[0]
    $link = [regex]::Match($firstCell, $LinkPattern)
    if (-not $link.Success -or $link.Groups[2].Value -match $ExternalLinkPattern) { return $null }
    $target = $PagesBySource[(Resolve-LinkSource $Page $link.Groups[2].Value)]
    if ($target -and $target.Status) { return $target }
    return $null
}

# Word e PDF non mostrano lo stile HTML della wiki: nel documento l'avviso e' in grassetto.
function Format-Alert([string]$Text, $Document, [string]$Color = 'red') {
    if ($Document) { return "**$Text**" }
    return "<span style=`"color:$Color;font-weight:bold`">$Text</span>"
}

function Get-StatusLabel([string]$Status, $Document) {
    $label = if ($DocumentLanguage.StatusLabels.ContainsKey($Status)) { $DocumentLanguage.StatusLabels[$Status] } else { $Status }
    if ($DocumentLanguage.StatusNotices.ContainsKey($Status)) { return Format-Alert $label $Document }
    return $label
}

# Una decisione che non vale piu' resta nella wiki con il testo di quando valeva: chi ci arriva da un
# link se ne accorge prima di leggerla e trova la decisione che vale al suo posto.
function Get-StatusNotice($Page, [hashtable]$PagesBySource, $Document) {
    if (-not $Page.Status -or -not $DocumentLanguage.StatusNotices.ContainsKey($Page.Status)) { return $null }
    $notice = "> $(Format-Alert $DocumentLanguage.StatusNotices[$Page.Status] $Document)"
    if ($Page.Status -ne 'superseded' -or -not $Page.SupersededBy) { return $notice }
    $successor = $PagesBySource["$decisionsDirectory/$($Page.SupersededBy).md"]
    $name = Get-DecisionPageName "$($Page.SupersededBy).md"
    $target = if ($Document -and $successor) { "#$(Get-DocumentAnchor $successor)" } elseif ($successor) { $successor.WikiPath } else { $null }
    $reference = if ($target) { "[$name]($target)" } else { $name }
    return "$notice $reference."
}

# Una tabella le cui righe rimandano tutte a una decisione e' un indice delle decisioni: riceve la
# colonna con lo stato di ognuna.
function Add-DecisionStatus([string[]]$Table, $Page, [hashtable]$PagesBySource, $Document) {
    if ($Table.Count -lt 3 -or $Table[1] -notmatch $TableSeparatorPattern) { return $Table }
    $decisions = @($Table | Select-Object -Skip 2 | ForEach-Object { Get-RowDecision $_ $Page $PagesBySource })
    if ($decisions.Count -ne ($Table.Count - 2) -or @($decisions | Where-Object { -not $_ }).Count) { return $Table }
    $rows = @("$($Table[0].TrimEnd()) $($DocumentLanguage.StatusColumn) |", "$($Table[1].TrimEnd()) --- |")
    for ($i = 2; $i -lt $Table.Count; $i++) { $rows += "$($Table[$i].TrimEnd()) $(Get-StatusLabel $decisions[$i - 2].Status $Document) |" }
    return $rows
}

function Get-ViewImagePath([string]$View, [string]$Folder = '') {
    $root = "$AttachmentsFolder/$(ConvertTo-WikiName $wikiRoot)"
    if ($Folder) { return "$root/$Folder/$View.png" }
    return "$root/$View.png"
}

# Una vista della bozza che disegna lo stesso diagramma della vista ufficiale mostra l'immagine ufficiale.
function Get-ViewImageFolder($Views, [string]$Key) {
    if ($Views.DraftViews.ContainsKey($Key)) { return $DraftFolder }
    return ''
}

function Get-WorkspaceView($Workspace, [string]$Key) {
    return @($Workspace.views.PSObject.Properties | Where-Object Name -Like '*Views' | ForEach-Object { @($_.Value) } | Where-Object { $_ -and $_.key -eq $Key }) | Select-Object -First 1
}

# Una vista generata porta la descrizione nella proprieta' description, che il disegno non mostra; una vista scritta a
# mano la porta nella sua descrizione.
function Get-ViewCaption($Workspace, [string]$Key) {
    $view = Get-WorkspaceView $Workspace $Key
    $text = if ($view.properties.description) { $view.properties.description } else { $view.description }
    $description = @("$text" -split '\r?\n' | ForEach-Object Trim | Where-Object { $_ }) -join ' '
    return [pscustomobject]@{ Title = "$($view.title)".Trim(); Description = $description }
}

function ConvertTo-MarkdownLiteral([string]$Text) {
    return $Text -replace '([\\`*_\[\]<>])', '\$1'
}

# Il titolo di una vista e' un titolo della pagina, di un livello sotto quello che la contiene, cosi' l'indice mostra le
# viste; la descrizione, su una riga sola, precede l'immagine. Una vista senza titolo resta la sola immagine, con la chiave.
function Format-ViewImage([string]$Key, $Caption, $Document, $Views, [int]$Level) {
    $target = if ($Document) { Get-DocumentViewFile $Key } else { "/$(Get-ViewImagePath $Key (Get-ViewImageFolder $Views $Key))" }
    if (-not $Caption.Title) { return , $(if ($Document) { "![]($target)" } else { "![$Key]($target)" }) }
    $title = ConvertTo-MarkdownLiteral $Caption.Title
    return @("$('#' * $Level) $title", '') + @(if ($Caption.Description) { (ConvertTo-MarkdownLiteral $Caption.Description), '' }) + "![$title]($target)"
}

function Get-WorkspaceElements($Elements, [hashtable]$Index) {
    foreach ($element in @($Elements | Where-Object { $_ })) {
        $Index["$($element.id)"] = $element
        foreach ($inner in 'containers', 'components', 'children', 'infrastructureNodes', 'containerInstances', 'softwareSystemInstances') {
            Get-WorkspaceElements $element.$inner $Index
        }
    }
}

function Get-ElementIndex($Workspace) {
    $index = @{}
    foreach ($elements in 'people', 'softwareSystems', 'deploymentNodes') { Get-WorkspaceElements $Workspace.model.$elements $index }
    return $index
}

function Get-DslIdentifier($Element) {
    return "$($Element.properties.'structurizr.dsl.identifier')"
}

# Una vista mostra un elemento se lo include o ne include un'istanza.
function Get-ShownIdentifiers($View, [hashtable]$Index) {
    foreach ($shown in @($View.elements | Where-Object { $_ })) {
        $element = $Index["$($shown.id)"]
        Get-DslIdentifier $element
        $instanced = @($element.containerId, $element.softwareSystemId) | Where-Object { $_ }
        if ($instanced) { Get-DslIdentifier $Index["$($instanced[0])"] }
    }
}

# Il gruppo ha una vista d'insieme se la prima vista mostra il soggetto di ognuna delle viste che la seguono.
function Test-OverviewGroup([object[]]$Views, [hashtable]$Index) {
    $shown = @(Get-ShownIdentifiers $Views[0] $Index | Where-Object { $_ })
    $subjects = @($Views | Select-Object -Skip 1 | ForEach-Object { "$($_.properties.subject)" })
    return -not @($subjects | Where-Object { $shown -notcontains $_ }).Count
}

function Get-OverviewGroupLists([object[]]$Captions) {
    $names = @($Captions | ForEach-Object { $DocumentLanguage.ViewNameFormat -f $(if ($_.Title) { $_.Title } else { $_.Key }) })
    return @{ First = @($names[0]); Following = @($names | Select-Object -Skip 1) }
}

function Get-SubjectName([string]$Subject, [hashtable]$Index) {
    $element = $Index.Values | Where-Object { (Get-DslIdentifier $_) -eq $Subject } | Select-Object -First 1
    if ($element.name) { return $element.name }
    return $Subject
}

function Get-LevelName([string]$Level) {
    if ($DocumentLanguage.ViewGroupLevels.ContainsKey($Level)) { return $DocumentLanguage.ViewGroupLevels[$Level] }
    return $Level
}

# Le viste alla pari si presentano con i loro soggetti e i loro livelli, in ordine di comparsa; senza livelli, con i
# soli soggetti.
function Get-PeerGroupLists([object[]]$Views, [hashtable]$Index) {
    $subjects = @($Views | ForEach-Object { "$($_.properties.subject)" } | Where-Object { $_ } | Select-Object -Unique | ForEach-Object { Get-SubjectName $_ $Index })
    $levels = @($Views | ForEach-Object { "$($_.properties.level)" } | Where-Object { $_ } | Select-Object -Unique | ForEach-Object { Get-LevelName $_ })
    return @{ Subjects = $subjects; Levels = $levels; UnleveledSubjects = @(if (-not $levels) { $subjects }) }
}

# Un marcatore che porta piu' viste si apre con le frasi della lingua che dicono come il gruppo e' fatto: una vista
# d'insieme e le sue parti, con i nomi delle viste, oppure viste alla pari, con i loro soggetti e livelli.
function Format-ViewGroupIntroduction($Workspace, [string[]]$Keys, [object[]]$Captions) {
    $views = @($Keys | ForEach-Object { Get-WorkspaceView $Workspace $_ })
    $index = Get-ElementIndex $Workspace
    if (Test-OverviewGroup $views $index) { return Format-GroupPhrases $DocumentLanguage.ViewGroupIntroduction (Get-OverviewGroupLists $Captions) }
    return Format-GroupPhrases $DocumentLanguage.ViewGroupPeers (Get-PeerGroupLists $views $index)
}

function Format-GroupPhrases($Phrases, [hashtable]$GroupLists) {
    return ConvertTo-MarkdownLiteral (Format-LanguagePhrases $Phrases { param($Binding) $GroupLists[$Binding] })
}

# Chi gestisce l'infrastruttura cerca le risorse con il loro nome in Azure, non con quello che hanno nelle viste.
function Get-DeploymentEntries($Nodes, [string[]]$Environments) {
    foreach ($node in @($Nodes | Where-Object { $_ })) {
        if ($Environments -contains $node.environment) {
            @($node) + @($node.infrastructureNodes) + @($node.containerInstances) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Properties = $_.properties; Name = $_.properties.azureName } }
        }
        Get-DeploymentEntries $node.children $Environments
    }
}

function ConvertTo-TableCell([string[]]$Values) {
    return (ConvertTo-MarkdownLiteral (@($Values | Where-Object { $_ } | Sort-Object -Unique) -join ', ')) -replace '\|', '\|'
}

# Una vista con la proprieta' resourceGroups porta, sotto l'immagine, la tabella dei gruppi di risorse degli
# ambienti che nomina: per gruppo, cio' che contiene e i moduli che lo dichiarano, dalle proprieta' degli elementi.
function Format-ResourceGroupTable($Workspace, [string]$Key) {
    $environments = @("$((Get-WorkspaceView $Workspace $Key).properties.resourceGroups)" -split ';' | Where-Object { $_ })
    if (-not $environments) { return @() }
    $groups = @(Get-DeploymentEntries $Workspace.model.deploymentNodes $environments | Where-Object { $_.Name -and $_.Properties.resourceGroup } | Group-Object { $_.Properties.resourceGroup } | Sort-Object Name)
    if (-not $groups) { return @() }
    $columns = $DocumentLanguage.ResourceGroupTable
    $rows = @($groups | ForEach-Object { "| $(ConvertTo-TableCell @($_.Name)) | $(ConvertTo-TableCell @($_.Group.Name)) | $(ConvertTo-TableCell @($_.Group | ForEach-Object { $_.Properties.module })) |" })
    return @('', "| $($columns.Group) | $($columns.Content) | $($columns.Module) |", '| --- | --- | --- |') + $rows
}

# Con $Document il corpo va nel documento unico invece che in una pagina: i link portano dentro il documento,
# i diagrammi Mermaid diventano immagini e le viste i file PNG accanto al documento.
function Convert-PageBody($Page, [hashtable]$PagesBySource, $Views, [hashtable]$ShownViews, $Document = $null) {
    $output = [Collections.Generic.List[string]]::new()
    $table = [Collections.Generic.List[string]]::new()
    $fence = $null
    $diagram = $null
    $headingLevel = 1
    $convertLinks = if ($Document) { { param($Line) Convert-DocumentLinks $Line $Page $PagesBySource } } else { { param($Line) Convert-Links $Line $Page $PagesBySource } }
    $notice = Get-StatusNotice $Page $PagesBySource $Document
    if ($notice) { $output.Add($notice); $output.Add('') }
    $flushTable = {
        foreach ($row in (Add-DecisionStatus $table.ToArray() $Page $PagesBySource $Document)) { $output.Add((& $convertLinks $row)) }
        $table.Clear()
    }
    foreach ($line in ($Page.Body -split "`n")) {
        if ($fence) {
            if ($line -match '^\s*```\s*$') {
                if ($null -ne $diagram) { $output.Add((Add-DocumentDiagram $Document $diagram)) }
                elseif ($fence -eq 'mermaid') { $output.Add(':::') }
                else { $output.Add($line) }
                $fence = $null
                $diagram = $null
            }
            elseif ($null -ne $diagram) { $diagram.Add($line) }
            else { $output.Add($line) }
            continue
        }
        if ($line -match $TablePattern) { $table.Add($line); continue }
        if ($table.Count) { & $flushTable }
        if ($line -match $HeadingPattern) { $headingLevel = $Matches[1].Length }
        if ($line -match $FencePattern) {
            $fence = if ($Matches[1]) { $Matches[1] } else { 'text' }
            if ($fence -eq 'mermaid' -and $Document) { $diagram = [Collections.Generic.List[string]]::new() }
            else { $output.Add($(if ($fence -eq 'mermaid') { '::: mermaid' } else { $line })) }
        }
        elseif ($line -match $ViewMarkerPattern) {
            $marker = $Matches[1]
            $keys = @(Resolve-ViewMarker $marker $Views.Workspace)
            if (-not $keys.Count -or @($keys | Where-Object { -not $Views.Diagrams.ContainsKey($_) }).Count) { throw "$($Page.Source): la vista $marker non esiste nel modello C4" }
            $captions = @($keys | ForEach-Object { Get-ViewCaption $Views.Workspace $_ | Add-Member -NotePropertyName Key -NotePropertyValue $_ -PassThru })
            $introduction = if ($keys.Count -gt 1) { Format-ViewGroupIntroduction $Views.Workspace $keys $captions }
            if ($introduction) { $output.Add($introduction); $output.Add('') }
            for ($index = 0; $index -lt $keys.Count; $index++) {
                $key = $keys[$index]
                $ShownViews[$key] = $Views.Diagrams[$key]
                if ($index) { $output.Add('') }
                foreach ($line in (Format-ViewImage $key $captions[$index] $Document $Views ([math]::Min(6, $headingLevel + 1)))) { $output.Add($line) }
                foreach ($line in (Format-ResourceGroupTable $Views.Workspace $key)) { $output.Add($line) }
            }
        }
        else { $output.Add((& $convertLinks $line)) }
    }
    if ($table.Count) { & $flushTable }
    return ($output -join "`n").TrimEnd("`n") + "`n"
}

#endregion

#region Scrittura nella wiki

function Write-WikiFile([string]$RelativePath, [string]$Content) {
    $path = Join-Path $wikiDirectory $RelativePath
    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
    [IO.File]::WriteAllText($path, $Content)
}

function Write-PageTree($Pages, [string]$Folder, [hashtable]$Contents) {
    foreach ($page in $Pages) {
        Write-WikiFile "$Folder/$($page.Name).md" $Contents[$page.Key]
        if ($page.Children.Count) { Write-PageTree $page.Children "$Folder/$($page.Name)" $Contents }
    }
    Write-WikiFile "$Folder/.order" ((@($Pages | ForEach-Object Name) -join "`n") + "`n")
}

# L'ordine della radice elenca anche le pagine che la pubblicazione non possiede: si aggiunge solo
# la voce del documento, in testa, se manca.
function Update-RootOrder([string]$RootName) {
    $orderFile = Join-Path $wikiDirectory '.order'
    $entries = if (Test-Path $orderFile) { @([IO.File]::ReadAllLines($orderFile) | Where-Object { $_.Trim() }) } else { @() }
    if ($entries -contains $RootName) { return }
    [IO.File]::WriteAllText($orderFile, ((@($RootName) + $entries) -join "`n") + "`n")
}

function Write-ViewImages([hashtable]$Images) {
    foreach ($file in $Images.Keys) {
        $path = Join-Path $wikiDirectory $file
        New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
        [IO.File]::WriteAllBytes($path, $Images[$file])
    }
}

# La pagina radice rimanda ai file del documento, che stanno accanto alle immagini.
function Write-Document($Pages, [hashtable]$Contents, [hashtable]$Images, [System.Collections.IDictionary]$Documents) {
    $rootName = ConvertTo-WikiName $wikiRoot
    $imagesFolder = "$AttachmentsFolder/$rootName"
    Remove-Item -Recurse -Force (Join-Path $wikiDirectory $rootName), (Join-Path $wikiDirectory "$rootName.md"), (Join-Path $wikiDirectory $imagesFolder) -ErrorAction SilentlyContinue
    $rootPage = @('[[_TOSP_]]')
    if ($Documents.Count) { $rootPage += @('') + @($Documents.Keys | ForEach-Object { "- [$_](/$imagesFolder/$_)" }) }
    Write-WikiFile "$rootName.md" (($rootPage -join "`n") + "`n")
    Write-PageTree $Pages $rootName $Contents
    Write-ViewImages $Images
    foreach ($file in $Documents.Keys) {
        $path = Join-Path $wikiDirectory "$imagesFolder/$file"
        New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
        [IO.File]::WriteAllBytes($path, $Documents[$file])
    }
    Update-RootOrder $rootName
    return [pscustomobject]@{ RootName = $rootName; ImagesFolder = $imagesFolder }
}

# git add rifiuta un percorso che non c'e' e non e' mai stato pubblicato: le immagini mancano a un
# documento senza viste C4.
function Get-DocumentPaths($Written) {
    $paths = @("$($Written.RootName).md", $Written.RootName, '.order')
    $imagesPublished = Test-Path (Join-Path $wikiDirectory $Written.ImagesFolder)
    if ($imagesPublished -or (git -C $wikiDirectory ls-files -- $Written.ImagesFolder)) { $paths += $Written.ImagesFolder }
    return $paths
}

function Invoke-WikiGit {
    $output = git -C $wikiDirectory @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git ${args}: $output" }
    return $output
}

function Publish-Document($Pages, [hashtable]$Contents, [hashtable]$Images, [System.Collections.IDictionary]$Documents) {
    $authorization = if ($env:SYSTEM_ACCESSTOKEN) { @('-c', "http.extraheader=AUTHORIZATION: bearer $env:SYSTEM_ACCESSTOKEN") } else { @() }
    $name = if ($env:BUILD_REQUESTEDFOR) { $env:BUILD_REQUESTEDFOR } else { 'Architecture Wiki' }
    $email = if ($env:BUILD_REQUESTEDFOREMAIL) { $env:BUILD_REQUESTEDFOREMAIL } else { 'architecture-wiki@noreply.local' }

    # Un'altra pipeline puo' scrivere nella wiki nel frattempo: a
    # ogni tentativo l'albero si riscrive sopra l'ultimo commit della wiki.
    for ($attempt = 1; $attempt -le $MaxPushAttempts; $attempt++) {
        Invoke-WikiGit @authorization fetch -q origin $wikiBranch | Out-Null
        Invoke-WikiGit reset -q --hard FETCH_HEAD | Out-Null
        $written = Write-Document $Pages $Contents $Images $Documents
        Invoke-WikiGit add -A -- @(Get-DocumentPaths $written) | Out-Null
        git -C $wikiDirectory diff --cached --quiet
        if ($LASTEXITCODE -eq 0) {
            Write-Host "La wiki mostra gia' il documento di $docsDirectory"
            return
        }
        $global:LASTEXITCODE = 0
        Invoke-WikiGit -c "user.name=$name" -c "user.email=$email" commit -q -m "${wikiRoot} @ $sourceVersion" | Out-Null
        git -C $wikiDirectory @authorization push -q origin "HEAD:refs/heads/$wikiBranch" 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Wiki aggiornata: $(@(Get-AllPages $Pages).Count) pagine sotto /$wikiRoot"
            return
        }
        $global:LASTEXITCODE = 0
        Write-Host "Push rifiutato al tentativo ${attempt}: la wiki e' cambiata, si riscrive sopra il commit nuovo"
    }
    throw "la wiki non accetta il push dopo $MaxPushAttempts tentativi"
}

#endregion

# Le immagini vengono dai diagrammi C4-PlantUML; il tipo di ogni vista, che un marcatore come component*
# nomina, dal workspace in JSON.
function Get-Views([string]$Directory) {
    $workspace = Join-Path $Directory 'c4/workspace.dsl'
    if (-not (Test-Path $workspace -PathType Leaf)) { return [pscustomobject]@{ Diagrams = @{}; Workspace = $null; DraftViews = @{} } }
    $path = (Resolve-Path $workspace).Path
    $export = Export-StructurizrWorkspace $path
    if ($export.Error) { throw "modello C4 non valido: $($export.Error)" }
    return [pscustomobject]@{ Diagrams = (Export-StructurizrC4PlantUml $path); Workspace = $export.Workspace; DraftViews = @{} }
}

function Get-ViewImages([hashtable]$ShownViews) {
    if (-not $ShownViews.Count) { return @{} }
    $images = ConvertTo-ViewImages $ShownViews (Get-StructurizrJava)
    $pngs = @{}
    foreach ($key in $images.Keys) { $pngs[$key] = $images[$key].Png }
    return $pngs
}

# I link alla reference stanno solo nelle pagine della wiki: il documento unico, che chi lo riceve legge
# fuori dalla wiki, resta senza.
function Add-ReferenceLinksToPages([hashtable]$Contents) {
    if (-not $env:REFERENCE_ROOT) { return }
    $entries = Read-ReferenceIndex (Join-Path $wikiDirectory "$AttachmentsFolder/$(ConvertTo-WikiName $env:REFERENCE_ROOT)/reference-index.json")
    foreach ($source in @($Contents.Keys)) { $Contents[$source] = Add-ReferenceLinks $Contents[$source] $entries }
}

#region Bozza

function Get-DraftName($Page) {
    return "$($Page.DisplayName)$($DocumentLanguage.DraftSuffix)"
}

function Set-DraftName($Page, [string]$ParentPath) {
    $Page.Name = ConvertTo-WikiName (Get-DraftName $Page)
    $Page.WikiPath = "$ParentPath/$($Page.Name)"
}

# Una pagina della bozza si confronta con la pagina ufficiale dello stesso percorso; senza, esiste solo nella
# bozza e ne prende subito il nome, cosi' i link delle altre pagine della bozza la raggiungono.
function Set-DraftCounterparts($Pages, [string]$ParentPath, [hashtable]$OfficialByPath, [bool]$InDraftOnly) {
    foreach ($page in $Pages) {
        $page.WikiPath = "$ParentPath/$($page.Name)"
        $page.Counterpart = if ($InDraftOnly) { $null } else { $OfficialByPath[$page.WikiPath] }
        if (-not $page.Counterpart) {
            $page.DraftOnly = $true
            Set-DraftName $page $ParentPath
        }
        Set-DraftCounterparts $page.Children $page.WikiPath $OfficialByPath $page.DraftOnly
    }
}

function Get-ChangedViews($Views, $DraftViews) {
    $changed = @{}
    foreach ($key in $DraftViews.Diagrams.Keys) {
        if (-not $Views.Diagrams.ContainsKey($key) -or $Views.Diagrams[$key] -cne $DraftViews.Diagrams[$key]) { $changed[$key] = $true }
    }
    return $changed
}

function Format-DraftNotice {
    return "> $(Format-Alert ($DocumentLanguage.DraftNotice -f $draftBranch) $null $DocumentLanguage.DraftNoticeColor)`n`n"
}

function Format-DraftLink($Draft) {
    $target = $Draft.WikiPath.Replace('(', '%28').Replace(')', '%29')
    return "> $($DocumentLanguage.DraftLink -f $draftBranch) [$(Get-DraftName $Draft)]($target).`n`n"
}

# Il testo si confronta prodotto con lo stesso codice e con le immagini ufficiali; una vista che disegna un
# diagramma diverso cambia la pagina anche a parita' di testo.
function Test-DraftDiffers($Page, [string]$Text, [hashtable]$PageViews, [hashtable]$ChangedViews, [hashtable]$Contents) {
    if (-not $Page.Counterpart) { return $true }
    if ($Text -cne $Contents[$Page.Counterpart.Key]) { return $true }
    return [bool]@($PageViews.Keys | Where-Object { $ChangedViews.ContainsKey($_) }).Count
}

function Add-DraftContent($Page, [string]$Content, [hashtable]$Contents) {
    $Page.Drafted = $true
    $Page.Key = "draft:$($Page.Source)"
    if ($Page.Counterpart) { Set-DraftName $Page $Page.WikiPath.Substring(0, $Page.WikiPath.LastIndexOf('/')) }
    $Contents[$Page.Key] = (Format-DraftNotice) + $Content
    if ($Page.Counterpart) { $Contents[$Page.Counterpart.Key] = (Format-DraftLink $Page) + $Contents[$Page.Counterpart.Key] }
}

function New-TreeNode([string]$Name, [string]$Key, $Children, $Owner) {
    return [pscustomobject]@{ Name = $Name; Key = $Key; Children = $Children; Owner = $Owner }
}

function Get-LastOwnedNode([Collections.Generic.List[object]]$Nodes, $Owner) {
    for ($i = $Nodes.Count - 1; $i -ge 0; $i--) { if ($Nodes[$i].Owner -eq $Owner) { return $i } }
    return -1
}

# La pagina in bozza sta subito dopo la sua pagina ufficiale; una pagina solo della bozza sta dopo quella che la
# precede nella bozza.
function Merge-DraftTree($Official, $Draft) {
    $nodes = [Collections.Generic.List[object]]::new()
    foreach ($page in @($Official | Where-Object { $_ })) {
        $counterpart = @($Draft | Where-Object { $_.Counterpart -eq $page }) | Select-Object -First 1
        $draftChildren = if ($counterpart) { $counterpart.Children } else { $null }
        $nodes.Add((New-TreeNode $page.Name $page.Key (Merge-DraftTree $page.Children $draftChildren) $page))
        if ($counterpart -and $counterpart.Drafted) { $nodes.Add((New-TreeNode $counterpart.Name $counterpart.Key @() $page)) }
    }
    $anchor = -1
    foreach ($page in @($Draft | Where-Object { $_ })) {
        if ($page.Counterpart) { $anchor = Get-LastOwnedNode $nodes $page.Counterpart; continue }
        $anchor++
        $nodes.Insert($anchor, (New-TreeNode $page.Name $page.Key (Merge-DraftTree @() $page.Children) $page))
    }
    return , $nodes
}

function Add-DraftPages($Pages, [hashtable]$Contents, $Views, $Location) {
    $officialByPath = @{}
    foreach ($page in (Get-AllPages $Pages)) { $officialByPath[$page.WikiPath] = $page }
    $draftPages = Get-DocumentPages $Location
    Set-DraftCounterparts $draftPages "/$(ConvertTo-WikiName $wikiRoot)" $officialByPath $false
    $draftBySource = @{}
    foreach ($page in (Get-AllPages $draftPages)) { $draftBySource[$page.Source] = $page }

    $draftViews = Get-Views $Location.Docs
    $changedViews = Get-ChangedViews $Views $draftViews
    $comparedViews = [pscustomobject]@{ Diagrams = $draftViews.Diagrams; Workspace = $draftViews.Workspace; DraftViews = @{} }
    $draftViews.DraftViews = $changedViews
    $shownViews = @{}
    # Ogni pagina si confronta prima che una bozza cambi nome o contenuto: i link della bozza portano alle pagine
    # ufficiali, e il testo ufficiale confrontato e' ancora senza rimando.
    $drafted = foreach ($page in @(Get-AllPages $draftPages)) {
        $pageViews = @{}
        $text = Convert-PageBody $page $draftBySource $comparedViews $pageViews
        if (Test-DraftDiffers $page $text $pageViews $changedViews $Contents) {
            [pscustomobject]@{ Page = $page; Content = Convert-PageBody $page $draftBySource $draftViews $shownViews }
        }
    }
    foreach ($entry in @($drafted)) { Add-DraftContent $entry.Page $entry.Content $Contents }
    $drawn = @{}
    foreach ($key in $shownViews.Keys) { if ($changedViews.ContainsKey($key)) { $drawn[$key] = $shownViews[$key] } }
    Write-Host "Bozza di $($Location.Docs): $(@(Get-AllPages $draftPages | Where-Object Drafted).Count) pagine diverse dal documento ufficiale"
    return [pscustomobject]@{ Tree = (Merge-DraftTree $Pages $draftPages); Images = (Get-ViewImages $drawn) }
}

#endregion

function Publish-Arc42Wiki {
    if (-not $wikiDirectory -or -not (Test-Path (Join-Path $wikiDirectory '.git'))) { throw "WIKI_DIRECTORY non indica un checkout della wiki: '$wikiDirectory'" }
    $formats = Get-DocumentFormats "$env:DOCUMENT_FORMATS"
    $official = New-DocumentLocation $docsDirectory $decisionsDirectory
    $pages = Get-DocumentPages $official
    $pagesBySource = @{}
    foreach ($page in (Get-AllPages $pages)) { $pagesBySource[$page.Source] = $page }
    $views = Get-Views $docsDirectory
    $shownViews = @{}
    $contents = @{}
    foreach ($page in $pagesBySource.Values) { $contents[$page.Key] = Convert-PageBody $page $pagesBySource $views $shownViews }
    $images = Get-ViewImages $shownViews
    $documents = if ($formats) { New-Arc42Document $pages $pagesBySource $views $images $formats } else { [ordered]@{} }
    $imageFiles = @{}
    foreach ($key in $images.Keys) { $imageFiles[(Get-ViewImagePath $key)] = $images[$key] }
    $tree = $pages
    if ($draftDocsDirectory) {
        $draft = Add-DraftPages $pages $contents $views (New-DocumentLocation $draftDocsDirectory $draftDecisionsDirectory $official)
        $tree = $draft.Tree
        foreach ($key in $draft.Images.Keys) { $imageFiles[(Get-ViewImagePath $key $DraftFolder)] = $draft.Images[$key] }
    }
    Add-ReferenceLinksToPages $contents
    Publish-Document $tree $contents $imageFiles $documents
}

try { Publish-Arc42Wiki }
catch {
    Write-Host "##vso[task.logissue type=error]wiki: $($_.Exception.Message)"
    exit 1
}
