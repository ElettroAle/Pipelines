# Pubblica un documento arc42 nella wiki di progetto di Azure DevOps. Le sezioni diventano pagine
# sotto WIKI_ROOT, nell'ordine dei loro numeri, e le decisioni diventano sottopagine della sezione 9.
# Il nome di default di WIKI_ROOT e la colonna dello stato seguono la lingua del documento.
# I marcatori di vista diventano i diagrammi C4 esportati in Mermaid, e i link puntano alle pagine.
# Si scrive nel repository git della wiki con un commit solo, che tocca soltanto WIKI_ROOT e la sua
# voce nell'ordine della radice: le altre pagine della wiki restano come sono.

. "$PSScriptRoot/MarkdownText.ps1"
. "$PSScriptRoot/Structurizr.ps1"

$ErrorActionPreference = 'Stop'

$docsDirectory = if ($env:DOCS_DIRECTORY) { $env:DOCS_DIRECTORY } else { 'docs/architecture' }
$decisionsDirectory = if ($env:DECISIONS_DIRECTORY) { $env:DECISIONS_DIRECTORY } else { 'docs/decisions' }
$wikiDirectory = $env:WIKI_DIRECTORY
$wikiRoot = if ($env:WIKI_ROOT) { $env:WIKI_ROOT } else { $DocumentLanguage.WikiRoot }
$wikiBranch = if ($env:WIKI_BRANCH) { $env:WIKI_BRANCH } else { 'wikiMaster' }
$repositoryUrl = "$($env:SYSTEM_COLLECTIONURI)$($env:SYSTEM_TEAMPROJECT)/_git/$($env:BUILD_REPOSITORY_NAME)"

$SectionFilePattern = '^(\d+)[_-].+\.md$'
$DecisionFilePattern = '^(\d{4})-.+\.md$'
# Nel template arc42 la sezione 9 raccoglie le decisioni: le loro pagine stanno sotto la sua.
$DecisionsSectionNumber = 9
$MaxPushAttempts = 3
$LinkPattern = '(\[[^\]]*\]\()([^)\s]+)(\))'
$ExternalLinkPattern = '^(?:[a-z][a-z0-9+.-]*:|#)'
# Il nome di file di una pagina scrive gli spazi come trattini, quindi codifica il trattino stesso
# e i caratteri che un nome di file non ammette; il simbolo di percentuale va per primo.
$EncodedCharacters = @('%', '-', ':', '<', '>', '*', '?', '|', '#', '"', '\', '/')

function ConvertTo-WikiName([string]$Title) {
    $name = $Title
    foreach ($character in $EncodedCharacters) { $name = $name.Replace($character, ('%{0:X2}' -f [int][char]$character)) }
    return $name.Replace(' ', '-')
}

function ConvertTo-RepositoryPath([string]$Path) {
    return ([IO.Path]::GetRelativePath((Get-Location).Path, $Path) -replace '\\', '/')
}

function Read-Markdown([string]$Path) {
    $text = [IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
    $status = $null
    if ($text -match '^---\n(?<front>[\s\S]*?)\n---\n') {
        if ($Matches.front -match '(?m)^status:\s*(\S+)') { $status = $Matches[1] }
        $text = $text.Substring($Matches[0].Length)
    }
    $title = [regex]::Match($text, '(?m)^#\s+(.+?)\s*$').Groups[1].Value
    $body = ([regex]::new('(?m)^#\s+.+\n+')).Replace($text, '', 1)
    return [pscustomobject]@{ Title = $title; Status = $status; Body = $body.TrimStart("`n") }
}

# Il titolo di una decisione e' una frase intera, troppo lunga per il nome di una pagina: il nome
# viene dal file, «0001-hard-link-tra-ambienti.md» diventa «0001 Hard link tra ambienti».
function Get-DecisionPageName([string]$FileName) {
    $words = [IO.Path]::GetFileNameWithoutExtension($FileName) -split '-'
    $title = ($words | Select-Object -Skip 1) -join ' '
    return "$($words[0]) $($title.Substring(0, 1).ToUpperInvariant())$($title.Substring(1))"
}

function New-Page([string]$Source, [string]$Name, [string]$ParentPath, $Markdown) {
    return [pscustomobject]@{
        Source   = $Source
        Name     = ConvertTo-WikiName $Name
        WikiPath = "$ParentPath/$(ConvertTo-WikiName $Name)"
        Status   = $Markdown.Status
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
        [pscustomobject]@{ Number = $number; Page = New-Page (ConvertTo-RepositoryPath $file.FullName) "$number. $(ConvertTo-PlainText $markdown.Title)" $rootPath $markdown }
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

function Get-StatusLabel([string]$Status) {
    if ($DocumentLanguage.StatusLabels.ContainsKey($Status)) { return $DocumentLanguage.StatusLabels[$Status] }
    return $Status
}

# Una tabella le cui righe rimandano tutte a una decisione e' un indice delle decisioni: riceve la
# colonna con lo stato di ognuna.
function Add-DecisionStatus([string[]]$Table, $Page, [hashtable]$PagesBySource) {
    if ($Table.Count -lt 3 -or $Table[1] -notmatch $TableSeparatorPattern) { return $Table }
    $decisions = @($Table | Select-Object -Skip 2 | ForEach-Object { Get-RowDecision $_ $Page $PagesBySource })
    if ($decisions.Count -ne ($Table.Count - 2) -or @($decisions | Where-Object { -not $_ }).Count) { return $Table }
    $rows = @("$($Table[0].TrimEnd()) $($DocumentLanguage.StatusColumn) |", "$($Table[1].TrimEnd()) --- |")
    for ($i = 2; $i -lt $Table.Count; $i++) { $rows += "$($Table[$i].TrimEnd()) $(Get-StatusLabel $decisions[$i - 2].Status) |" }
    return $rows
}

# I diagrammi di Structurizr scrivono le etichette in HTML con stili: la wiki le mostra meglio come
# testo con gli a capo.
function ConvertTo-WikiMermaid([string]$Diagram) {
    $plain = $Diagram -replace "`r`n", "`n" -replace '</div>\s*<div[^>]*>', '<br/>' -replace '</?div[^>]*>', ''
    return @('::: mermaid') + @($plain.TrimEnd("`n") -split "`n") + @(':::')
}

function Convert-PageBody($Page, [hashtable]$PagesBySource, [hashtable]$Views) {
    $output = [Collections.Generic.List[string]]::new()
    $table = [Collections.Generic.List[string]]::new()
    $fence = $null
    $flushTable = {
        foreach ($row in (Add-DecisionStatus $table.ToArray() $Page $PagesBySource)) { $output.Add((Convert-Links $row $Page $PagesBySource)) }
        $table.Clear()
    }
    foreach ($line in ($Page.Body -split "`n")) {
        if ($fence) {
            if ($line -match '^\s*```\s*$') {
                $output.Add($(if ($fence -eq 'mermaid') { ':::' } else { $line }))
                $fence = $null
            }
            else { $output.Add($line) }
            continue
        }
        if ($line -match $TablePattern) { $table.Add($line); continue }
        if ($table.Count) { & $flushTable }
        if ($line -match $FencePattern) {
            $fence = if ($Matches[1]) { $Matches[1] } else { 'text' }
            $output.Add($(if ($fence -eq 'mermaid') { '::: mermaid' } else { $line }))
        }
        elseif ($line -match $ViewMarkerPattern) {
            $key = $Matches[1]
            if (-not $Views.ContainsKey($key)) { throw "$($Page.Source): la vista $key non esiste nel modello C4" }
            foreach ($diagramLine in (ConvertTo-WikiMermaid $Views[$key])) { $output.Add($diagramLine) }
        }
        else { $output.Add((Convert-Links $line $Page $PagesBySource)) }
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

# L'ordine della radice elenca anche le pagine che la pubblicazione non possiede: si aggiunge solo
# la voce del documento, in testa, se manca.
function Update-RootOrder([string]$RootName) {
    $orderFile = Join-Path $wikiDirectory '.order'
    $entries = if (Test-Path $orderFile) { @([IO.File]::ReadAllLines($orderFile) | Where-Object { $_.Trim() }) } else { @() }
    if ($entries -contains $RootName) { return }
    [IO.File]::WriteAllText($orderFile, ((@($RootName) + $entries) -join "`n") + "`n")
}

function Write-Document($Pages, [hashtable]$Contents) {
    $rootName = ConvertTo-WikiName $wikiRoot
    Remove-Item -Recurse -Force (Join-Path $wikiDirectory $rootName), (Join-Path $wikiDirectory "$rootName.md") -ErrorAction SilentlyContinue
    Write-WikiFile "$rootName.md" "[[_TOSP_]]`n"
    Write-PageTree $Pages $rootName $Contents
    Update-RootOrder $rootName
    return $rootName
}

function Invoke-WikiGit {
    $output = git -C $wikiDirectory @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git ${args}: $output" }
    return $output
}

function Publish-Document($Pages, [hashtable]$Contents) {
    $authorization = if ($env:SYSTEM_ACCESSTOKEN) { @('-c', "http.extraheader=AUTHORIZATION: bearer $env:SYSTEM_ACCESSTOKEN") } else { @() }
    $name = if ($env:BUILD_REQUESTEDFOR) { $env:BUILD_REQUESTEDFOR } else { 'Architecture Wiki' }
    $email = if ($env:BUILD_REQUESTEDFOREMAIL) { $env:BUILD_REQUESTEDFOREMAIL } else { 'architecture-wiki@noreply.local' }
    $source = if ($env:BUILD_SOURCEVERSION) { $env:BUILD_SOURCEVERSION.Substring(0, [math]::Min(8, $env:BUILD_SOURCEVERSION.Length)) } else { 'locale' }

    # Un'altra pipeline, come quella delle release note, puo' scrivere nella wiki nel frattempo: a
    # ogni tentativo l'albero si riscrive sopra l'ultimo commit della wiki.
    for ($attempt = 1; $attempt -le $MaxPushAttempts; $attempt++) {
        Invoke-WikiGit @authorization fetch -q origin $wikiBranch | Out-Null
        Invoke-WikiGit reset -q --hard FETCH_HEAD | Out-Null
        $rootName = Write-Document $Pages $Contents
        Invoke-WikiGit add -A -- "$rootName.md" $rootName .order | Out-Null
        git -C $wikiDirectory diff --cached --quiet
        if ($LASTEXITCODE -eq 0) {
            Write-Host "La wiki mostra gia' il documento di $docsDirectory"
            return
        }
        $global:LASTEXITCODE = 0
        Invoke-WikiGit -c "user.name=$name" -c "user.email=$email" commit -q -m "${wikiRoot} @ $source" | Out-Null
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

function Get-Views {
    $workspace = Join-Path $docsDirectory 'model/workspace.dsl'
    if (-not (Test-Path $workspace -PathType Leaf)) { return @{} }
    return Export-StructurizrMermaid (Resolve-Path $workspace).Path
}

function Publish-Arc42Wiki {
    if (-not $wikiDirectory -or -not (Test-Path (Join-Path $wikiDirectory '.git'))) { throw "WIKI_DIRECTORY non indica un checkout della wiki: '$wikiDirectory'" }
    $pages = Get-DocumentPages
    $pagesBySource = @{}
    foreach ($page in (Get-AllPages $pages)) { $pagesBySource[$page.Source] = $page }
    $views = Get-Views
    $contents = @{}
    foreach ($page in $pagesBySource.Values) { $contents[$page.Source] = Convert-PageBody $page $pagesBySource $views }
    Publish-Document $pages $contents
}

try { Publish-Arc42Wiki }
catch {
    Write-Host "##vso[task.logissue type=error]wiki: $($_.Exception.Message)"
    exit 1
}
