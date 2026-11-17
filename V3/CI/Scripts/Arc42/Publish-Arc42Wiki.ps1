# SPDX-License-Identifier: Apache-2.0

# Pubblica un documento arc42 nella wiki di progetto di Azure DevOps. Le sezioni diventano pagine
# sotto WIKI_ROOT, nell'ordine dei loro numeri, e le decisioni diventano sottopagine della sezione 9.
# Il nome di default di WIKI_ROOT e la colonna dello stato seguono la lingua del documento.
# I marcatori di vista diventano le immagini dei diagrammi C4, disegnate con C4-PlantUML nella direzione
# che si legge meglio (ViewImages.ps1), e i link puntano alle pagine. Si scrive nel repository git della wiki con un commit solo, che tocca soltanto
# WIKI_ROOT, le sue immagini e la sua voce nell'ordine della radice: il resto della wiki resta com'e'.
# Con DOCUMENT_FORMATS (pdf, docx) le stesse pagine diventano anche un documento unico (Arc42Document.ps1), che
# lo stesso commit allega alla wiki e che la pagina WIKI_ROOT nomina.
# Le guide di GUIDES_DIRECTORY (Guides.ps1) diventano pagine sotto le radici dei tutorial e delle procedure,
# e la loro home la prima pagina della wiki; il documento unico contiene tutorial e procedure, non la home.

. "$PSScriptRoot/../Common/MarkdownText.ps1"
. "$PSScriptRoot/../Common/WikiNames.ps1"
. "$PSScriptRoot/../Common/Guides.ps1"
. "$PSScriptRoot/../Reference/ReferenceLinks.ps1"
. "$PSScriptRoot/../C4/Structurizr.ps1"
. "$PSScriptRoot/../C4/ViewImages.ps1"
. "$PSScriptRoot/Arc42Document.ps1"

$ErrorActionPreference = 'Stop'

$docsDirectory = if ($env:DOCS_DIRECTORY) { $env:DOCS_DIRECTORY } else { 'docs/architecture' }
$decisionsDirectory = if ($env:DECISIONS_DIRECTORY) { $env:DECISIONS_DIRECTORY } else { 'docs/decisions' }
$wikiDirectory = $env:WIKI_DIRECTORY
$wikiRoot = if ($env:WIKI_ROOT) { $env:WIKI_ROOT } else { $DocumentLanguage.WikiRoot }
$guidesDirectory = Get-GuidesDirectory
$wikiBranch = if ($env:WIKI_BRANCH) { $env:WIKI_BRANCH } else { 'wikiMaster' }
$repositoryUrl = "$($env:SYSTEM_COLLECTIONURI)$($env:SYSTEM_TEAMPROJECT)/_git/$($env:BUILD_REPOSITORY_NAME)"
$sourceVersion = if ($env:BUILD_SOURCEVERSION) { $env:BUILD_SOURCEVERSION.Substring(0, [math]::Min(8, $env:BUILD_SOURCEVERSION.Length)) } else { 'locale' }

$SectionFilePattern = '^(\d+)[_-].+\.md$'
$DecisionFilePattern = '^(\d{4})-.+\.md$'
# Nel template arc42 la sezione 9 raccoglie le decisioni: le loro pagine stanno sotto la sua.
$DecisionsSectionNumber = 9
$MaxPushAttempts = 3
# La wiki tiene immagini e allegati nella cartella .attachments della radice.
$AttachmentsFolder = '.attachments'
$LinkPattern = '(\[[^\]]*\]\()([^)\s]+)(\))'
$ExternalLinkPattern = '^(?:[a-z][a-z0-9+.-]*:|#)'

function ConvertTo-RepositoryPath([string]$Path) {
    return ([IO.Path]::GetRelativePath((Get-Location).Path, $Path) -replace '\\', '/')
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
        Title    = $Title
        Name     = ConvertTo-WikiName $Name
        WikiPath = "$ParentPath/$(ConvertTo-WikiName $Name)"
        Status   = $Markdown.Status
        SupersededBy = $Markdown.SupersededBy
        Body     = $Markdown.Body
        Children = [Collections.Generic.List[object]]::new()
    }
}

function Get-DocumentPages {
    $rootPath = "/$(ConvertTo-WikiName $wikiRoot)"
    $sections = foreach ($file in (Get-ChildItem -Path $docsDirectory -File | Where-Object Name -Match $SectionFilePattern)) {
        $number = [int]([regex]::Match($file.Name, $SectionFilePattern).Groups[1].Value)
        $markdown = Read-Markdown $file.FullName
        if (-not $markdown.Title) { throw "$($file.Name): la sezione non ha un titolo" }
        $title = ConvertTo-PlainText $markdown.Title
        [pscustomobject]@{ Number = $number; Page = New-Page (ConvertTo-RepositoryPath $file.FullName) "$number. $title" $rootPath $markdown $title }
    }
    $sections = @($sections | Sort-Object Number)
    if (-not $sections) { throw "nessuna sezione in $docsDirectory" }

    $decisionsSection = $sections | Where-Object Number -EQ $DecisionsSectionNumber | Select-Object -First 1
    $decisionsParent = if ($decisionsSection) { $decisionsSection.Page } else { $null }
    $decisionsPath = if ($decisionsParent) { $decisionsParent.WikiPath } else { $rootPath }
    $decisions = foreach ($file in (Get-ChildItem -Path $decisionsDirectory -File -ErrorAction SilentlyContinue | Where-Object Name -Match $DecisionFilePattern | Sort-Object Name)) {
        New-Page (ConvertTo-RepositoryPath $file.FullName) (Get-DecisionPageName $file.Name) $decisionsPath (Read-Markdown $file.FullName)
    }

    $topLevel = [Collections.Generic.List[object]]::new()
    foreach ($section in $sections) { $topLevel.Add($section.Page) }
    foreach ($decision in @($decisions)) {
        if ($decisionsParent) { $decisionsParent.Children.Add($decision) } else { $topLevel.Add($decision) }
    }
    return , $topLevel
}

function Get-GuidePages {
    $homePage = $null
    $roots = [ordered]@{}
    foreach ($guide in @(Get-GuideFiles $guidesDirectory)) {
        $source = ConvertTo-RepositoryPath $guide.File.FullName
        $markdown = Read-Markdown $guide.File.FullName
        if ($guide.Type -eq 'home') {
            $homePage = New-Page $source $DocumentLanguage.Guides.HomePage '' $markdown
            continue
        }
        if (-not $markdown.Title) { throw "${source}: la guida non ha un titolo" }
        if (-not $roots.Contains($guide.Type)) {
            $rootTitle = if ($guide.Type -eq 'tutorial') { $DocumentLanguage.Guides.TutorialsRoot } else { $DocumentLanguage.Guides.ProceduresRoot }
            $roots[$guide.Type] = New-Page (ConvertTo-RepositoryPath (Split-Path $guide.File.FullName)) $rootTitle '' ([pscustomobject]@{ Body = '' })
        }
        $root = $roots[$guide.Type]
        $root.Children.Add((New-Page $source (ConvertTo-PlainText $markdown.Title) $root.WikiPath $markdown))
    }
    return [pscustomobject]@{ Home = $homePage; Roots = @($roots.Values) }
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
function Format-Alert([string]$Text, $Document) {
    if ($Document) { return "**$Text**" }
    return "<span style=`"color:red;font-weight:bold`">$Text</span>"
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

function Get-ViewImagePath([string]$View) {
    return "$AttachmentsFolder/$(ConvertTo-WikiName $wikiRoot)/$View.png"
}

# Con $Document il corpo va nel documento unico invece che in una pagina: i link portano dentro il documento,
# i diagrammi Mermaid diventano immagini e le viste i file PNG accanto al documento.
function Convert-PageBody($Page, [hashtable]$PagesBySource, $Views, [hashtable]$ShownViews, $Document = $null) {
    $output = [Collections.Generic.List[string]]::new()
    $table = [Collections.Generic.List[string]]::new()
    $fence = $null
    $diagram = $null
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
        if ($line -match $FencePattern) {
            $fence = if ($Matches[1]) { $Matches[1] } else { 'text' }
            if ($fence -eq 'mermaid' -and $Document) { $diagram = [Collections.Generic.List[string]]::new() }
            else { $output.Add($(if ($fence -eq 'mermaid') { '::: mermaid' } else { $line })) }
        }
        elseif ($line -match $ViewMarkerPattern) {
            $marker = $Matches[1]
            $keys = @(Resolve-ViewMarker $marker $Views.Workspace)
            if (-not $keys.Count -or @($keys | Where-Object { -not $Views.Diagrams.ContainsKey($_) }).Count) { throw "$($Page.Source): la vista $marker non esiste nel modello C4" }
            foreach ($key in $keys) {
                $ShownViews[$key] = $Views.Diagrams[$key]
                $output.Add($(if ($Document) { "![]($(Get-DocumentViewFile $key))" } else { "![$key](/$(Get-ViewImagePath $key))" }))
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
        Write-WikiFile "$Folder/$($page.Name).md" $Contents[$page.Source]
        if ($page.Children.Count) { Write-PageTree $page.Children "$Folder/$($page.Name)" $Contents }
    }
    Write-WikiFile "$Folder/.order" ((@($Pages | ForEach-Object Name) -join "`n") + "`n")
}

# L'ordine della radice elenca anche le pagine che la pubblicazione non possiede: si aggiungono in
# testa solo le voci che mancano, e la home va sempre per prima.
function Update-RootOrder([string[]]$Names, [string]$First) {
    $orderFile = Join-Path $wikiDirectory '.order'
    $entries = if (Test-Path $orderFile) { @([IO.File]::ReadAllLines($orderFile) | Where-Object { $_.Trim() }) } else { @() }
    $entries = @($Names | Where-Object { $entries -notcontains $_ }) + $entries
    if ($First) { $entries = @($First) + @($entries | Where-Object { $_ -ne $First }) }
    [IO.File]::WriteAllText($orderFile, ($entries -join "`n") + "`n")
}

function Write-ViewImages([hashtable]$Images) {
    foreach ($view in $Images.Keys) {
        $path = Join-Path $wikiDirectory (Get-ViewImagePath $view)
        New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
        [IO.File]::WriteAllBytes($path, $Images[$view])
    }
}

# La pagina radice rimanda ai file del documento, che stanno accanto alle immagini.
function Write-Document($Pages, [hashtable]$Contents, [hashtable]$Images, [System.Collections.IDictionary]$Documents, $Guides) {
    $rootName = ConvertTo-WikiName $wikiRoot
    $imagesFolder = "$AttachmentsFolder/$rootName"
    $guideRoots = @($Guides.Roots | ForEach-Object Name)
    $homeName = if ($Guides.Home) { $Guides.Home.Name } else { $null }
    $guidePaths = @($homeName | Where-Object { $_ } | ForEach-Object { "$_.md" }) + @($guideRoots | ForEach-Object { $_, "$_.md" })
    Remove-Item -Recurse -Force (@($rootName, "$rootName.md", $imagesFolder) + $guidePaths | ForEach-Object { Join-Path $wikiDirectory $_ }) -ErrorAction SilentlyContinue
    if ($homeName) { Write-WikiFile "$homeName.md" $Contents[$Guides.Home.Source] }
    foreach ($root in $Guides.Roots) {
        Write-WikiFile "$($root.Name).md" "[[_TOSP_]]`n"
        Write-PageTree $root.Children $root.Name $Contents
    }
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
    Update-RootOrder (@($homeName | Where-Object { $_ }) + @($rootName) + $guideRoots) $homeName
    return [pscustomobject]@{ RootName = $rootName; ImagesFolder = $imagesFolder; Guides = $guidePaths }
}

# git add rifiuta un percorso che non c'e' e non e' mai stato pubblicato: le immagini mancano a un
# documento senza viste C4.
function Get-DocumentPaths($Written) {
    $paths = @("$($Written.RootName).md", $Written.RootName, '.order') + $Written.Guides
    $imagesPublished = Test-Path (Join-Path $wikiDirectory $Written.ImagesFolder)
    if ($imagesPublished -or (git -C $wikiDirectory ls-files -- $Written.ImagesFolder)) { $paths += $Written.ImagesFolder }
    return $paths
}

function Invoke-WikiGit {
    $output = git -C $wikiDirectory @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git ${args}: $output" }
    return $output
}

function Publish-Document($Pages, [hashtable]$Contents, [hashtable]$Images, [System.Collections.IDictionary]$Documents, $Guides) {
    $authorization = if ($env:SYSTEM_ACCESSTOKEN) { @('-c', "http.extraheader=AUTHORIZATION: bearer $env:SYSTEM_ACCESSTOKEN") } else { @() }
    $name = if ($env:BUILD_REQUESTEDFOR) { $env:BUILD_REQUESTEDFOR } else { 'Architecture Wiki' }
    $email = if ($env:BUILD_REQUESTEDFOREMAIL) { $env:BUILD_REQUESTEDFOREMAIL } else { 'architecture-wiki@noreply.local' }

    # Un'altra pipeline puo' scrivere nella wiki nel frattempo: a
    # ogni tentativo l'albero si riscrive sopra l'ultimo commit della wiki.
    for ($attempt = 1; $attempt -le $MaxPushAttempts; $attempt++) {
        Invoke-WikiGit @authorization fetch -q origin $wikiBranch | Out-Null
        Invoke-WikiGit reset -q --hard FETCH_HEAD | Out-Null
        $written = Write-Document $Pages $Contents $Images $Documents $Guides
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
function Get-Views {
    $workspace = Join-Path $docsDirectory 'c4/workspace.dsl'
    if (-not (Test-Path $workspace -PathType Leaf)) { return [pscustomobject]@{ Diagrams = @{}; Workspace = $null } }
    $path = (Resolve-Path $workspace).Path
    $export = Export-StructurizrWorkspace $path
    if ($export.Error) { throw "modello C4 non valido: $($export.Error)" }
    return [pscustomobject]@{ Diagrams = (Export-StructurizrC4PlantUml $path); Workspace = $export.Workspace }
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

function Publish-Arc42Wiki {
    if (-not $wikiDirectory -or -not (Test-Path (Join-Path $wikiDirectory '.git'))) { throw "WIKI_DIRECTORY non indica un checkout della wiki: '$wikiDirectory'" }
    $formats = Get-DocumentFormats "$env:DOCUMENT_FORMATS"
    $pages = Get-DocumentPages
    $guides = Get-GuidePages
    $documentPages = @($pages) + @($guides.Roots)
    $documentPagesBySource = @{}
    foreach ($page in (Get-AllPages $documentPages)) { $documentPagesBySource[$page.Source] = $page }
    $pagesBySource = $documentPagesBySource.Clone()
    if ($guides.Home) { $pagesBySource[$guides.Home.Source] = $guides.Home }
    $views = Get-Views
    $shownViews = @{}
    $contents = @{}
    foreach ($page in $pagesBySource.Values) { $contents[$page.Source] = Convert-PageBody $page $pagesBySource $views $shownViews }
    $images = Get-ViewImages $shownViews
    $documents = if ($formats) { New-Arc42Document $documentPages $documentPagesBySource $views $images $formats } else { [ordered]@{} }
    Add-ReferenceLinksToPages $contents
    Publish-Document $pages $contents $images $documents $guides
}

try { Publish-Arc42Wiki }
catch {
    Write-Host "##vso[task.logissue type=error]wiki: $($_.Exception.Message)"
    exit 1
}
