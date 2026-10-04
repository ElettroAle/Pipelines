# Release notes della versione appena calcolata da Set-Versioning.ps1: sezione nel
# summary della run e, se richiesto, pagina wiki. Un errore qui non ferma il publish:
# la release e' gia' taggata.

. "$PSScriptRoot/GitCliff.ps1"

$releaseTag = $env:RELEASE_TAG
$outputDir = $env:OUTPUT_DIR
$wikiPagePath = $env:WIKI_PAGE_PATH
$wikiBranch = if ($env:WIKI_BRANCH) { $env:WIKI_BRANCH } else { 'refs/heads/main' }
$wikiName = if ($env:WIKI_NAME) { $env:WIKI_NAME } else { "$($env:SYSTEM_TEAMPROJECT).wiki" }

# Il tag del rilascio precedente sullo stesso ramo e' quello raggiungibile dal primo
# parent: su main copre tutte le versioni di staging promosse dall'ultimo deploy.
function Get-ReleaseRange {
    git rev-parse --verify --quiet 'HEAD^1' > $null
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; return $null }

    $previousTag = git describe --tags --abbrev=0 'HEAD^1' 2>$null
    $global:LASTEXITCODE = 0
    if (-not $previousTag) { return $null }
    return "$previousTag..HEAD"
}

$EntrySeparator = " $([char]0x00B7) "
$workItemsReadable = $true

function Get-RepositoryUrl {
    $remote = (git remote get-url origin 2>$null)
    $global:LASTEXITCODE = 0
    if (-not $remote) { return $null }

    $remote = $remote.Trim() -replace '://[^/@]+@', '://' -replace '\.git$', ''
    if ($remote -match '/_git/' -or $remote -match '^https://github\.com/') { return $remote }
    return $null
}

function Get-PullRequestUrl {
    param([string]$RepositoryUrl, [string]$PullRequestId)

    if (-not $RepositoryUrl) { return $null }
    if ($RepositoryUrl -match '/_git/') { return "$RepositoryUrl/pullrequest/$PullRequestId" }
    return "$RepositoryUrl/pull/$PullRequestId"
}

# Un commit appartiene alla prima PR che lo ha integrato: i merge si visitano dal
# piu' vecchio, cosi' la promozione fra ambienti non prende il posto della PR di sviluppo.
function Get-PullRequestsByCommit {
    param([string]$Range)

    $pullRequests = @{}
    $revisions = if ($Range) { $Range } else { 'HEAD' }
    foreach ($merge in (git log --merges --topo-order --reverse --format="%P`t%s" $revisions)) {
        $parents, $subject = $merge -split "`t", 2
        $parents = $parents.Split(' ')
        if ($subject -notmatch '^Merged PR (\d+):' -or $parents.Count -ne 2) { continue }

        $pullRequestId = $Matches[1]
        foreach ($commit in (git rev-list "$($parents[0])..$($parents[1])")) {
            if (-not $pullRequests.ContainsKey($commit)) { $pullRequests[$commit] = $pullRequestId }
        }
    }
    $global:LASTEXITCODE = 0
    return $pullRequests
}

# Al primo errore si smette di chiedere: una API irraggiungibile costerebbe un timeout per PR.
function Get-PullRequestWorkItems {
    param([string]$RepositoryUrl, [string]$PullRequestId)

    if (-not $script:workItemsReadable -or -not $env:SYSTEM_ACCESSTOKEN -or -not $env:SYSTEM_COLLECTIONURI) { return @() }
    if ($RepositoryUrl -notmatch '/([^/]+)/_git/([^/]+)$') { return @() }

    $uri = "$($env:SYSTEM_COLLECTIONURI)$($Matches[1])/_apis/git/repositories/$($Matches[2])/pullRequests/$PullRequestId/workitems?api-version=7.1"
    try {
        $response = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $($env:SYSTEM_ACCESSTOKEN)" } -TimeoutSec 15 -UseBasicParsing
        return @($response.value | ForEach-Object { [string]$_.id })
    }
    catch {
        $script:workItemsReadable = $false
        Write-Host "##vso[task.logissue type=warning]Work item delle PR non letti, le note escono senza: $($_.Exception.Message)"
        return @()
    }
}

function Format-Link {
    param([string]$Label, [string]$Url)

    if ($Url) { return "[$Label]($Url)" }
    return $Label
}

function Format-Entry {
    param([string]$Text, [string]$Commit, [string]$PullRequestId, [string]$RepositoryUrl, [hashtable]$WorkItemsByPullRequest)

    $commitUrl = if ($RepositoryUrl) { "$RepositoryUrl/commit/$Commit" } else { $null }
    $parts = @($Text, (Format-Link $Commit.Substring(0, 7) $commitUrl))
    if (-not $PullRequestId) { return $parts -join $EntrySeparator }

    $parts += Format-Link "PR $PullRequestId" (Get-PullRequestUrl $RepositoryUrl $PullRequestId)
    if (-not $WorkItemsByPullRequest.ContainsKey($PullRequestId)) {
        $WorkItemsByPullRequest[$PullRequestId] = Get-PullRequestWorkItems $RepositoryUrl $PullRequestId
    }
    $workItems = @($WorkItemsByPullRequest[$PullRequestId] | Where-Object { $Text -notmatch "#$_\b" } | ForEach-Object { "#$_" })
    if ($workItems.Count -gt 0) { $parts += $workItems -join ' ' }
    return $parts -join $EntrySeparator
}

# Il template di cliff.toml chiude ogni voce con l'hash del commit in un commento
# HTML; il '(PR N)' in coda e' quello del messaggio di squash di Azure DevOps.
function Add-EntryLinks {
    param([string]$Markdown, [string]$Range)

    $repositoryUrl = Get-RepositoryUrl
    $pullRequestsByCommit = Get-PullRequestsByCommit $Range
    $workItemsByPullRequest = @{}
    return [regex]::Replace($Markdown, '(?m)^(.*?)(?: \(PR (\d+)\))? <!-- commit:([0-9a-f]+) -->(\r?)$', {
            param($m)
            $commit = $m.Groups[3].Value
            $pullRequestId = if ($m.Groups[2].Success) { $m.Groups[2].Value } else { $pullRequestsByCommit[$commit] }
            (Format-Entry $m.Groups[1].Value $commit $pullRequestId $repositoryUrl $workItemsByPullRequest) + $m.Groups[4].Value
        })
}

function Invoke-WikiRequest {
    param([string]$Method, [string]$PagePath, [string]$Body, [string]$ETag)

    $uri = "$($env:SYSTEM_COLLECTIONURI)$($env:SYSTEM_TEAMPROJECT)/_apis/wiki/wikis/$([uri]::EscapeDataString($wikiName))/pages?path=$([uri]::EscapeDataString($PagePath))&includeContent=true&api-version=7.1"
    $headers = @{ Authorization = "Bearer $($env:SYSTEM_ACCESSTOKEN)" }
    if ($ETag) { $headers['If-Match'] = $ETag }
    $request = @{ Uri = $uri; Method = $Method; Headers = $headers; UseBasicParsing = $true }
    if ($Body) {
        $request['Body'] = [Text.Encoding]::UTF8.GetBytes((@{ content = $Body } | ConvertTo-Json))
        $request['ContentType'] = 'application/json; charset=utf-8'
    }
    return Invoke-WebRequest @request
}

function Get-WikiPage {
    param([string]$PagePath)

    try {
        $response = Invoke-WikiRequest -Method Get -PagePath $PagePath
        $content = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray()) | ConvertFrom-Json
        return @{ ETag = [string]$response.Headers['ETag']; Content = [string]$content.content }
    }
    catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }
        throw
    }
}

# La API non crea le pagine padre mancanti.
function New-WikiParentPages {
    param([string]$PagePath)

    $segments = $PagePath.Trim('/').Split('/')
    for ($i = 1; $i -lt $segments.Count; $i++) {
        $parentPath = '/' + ($segments[0..($i - 1)] -join '/')
        if (-not (Get-WikiPage $parentPath)) {
            Invoke-WikiRequest -Method Put -PagePath $parentPath -Body "[[_TOSP_]]" | Out-Null
        }
    }
}

function Publish-WikiReleaseNotes {
    param([string]$Markdown)

    $page = Get-WikiPage $wikiPagePath
    if (-not $page) {
        New-WikiParentPages $wikiPagePath
        Invoke-WikiRequest -Method Put -PagePath $wikiPagePath -Body $Markdown | Out-Null
        Write-Host "Pagina wiki creata: $wikiPagePath"
        return
    }

    # Una run rieseguita sulla stessa versione non duplica la sezione.
    if ($page.Content -match "(?m)^## $([regex]::Escape($releaseTag))( |$)") {
        Write-Host "La pagina $wikiPagePath contiene gia' la versione $releaseTag"
        return
    }
    Invoke-WikiRequest -Method Put -PagePath $wikiPagePath -Body "$Markdown`n`n$($page.Content)" -ETag $page.ETag | Out-Null
    Write-Host "Pagina wiki aggiornata: $wikiPagePath"
}

try {
    $range = Get-ReleaseRange
    Write-Host "Range delle release notes: $(if ($range) { $range } else { 'intera storia' })"
    $markdown = Add-EntryLinks (Get-ReleaseNotesMarkdown -Range $range -Tag $releaseTag) $range

    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    $notesPath = Join-Path $outputDir 'Release notes.md'
    [IO.File]::WriteAllText($notesPath, $markdown, (New-Object Text.UTF8Encoding $false))
    Write-Host $markdown
    Write-Host "##vso[task.uploadsummary]$notesPath"

    if ($wikiPagePath -and $env:BUILD_SOURCEBRANCH -eq $wikiBranch) {
        Publish-WikiReleaseNotes $markdown
    }
}
catch {
    Write-Host "##vso[task.logissue type=warning]Release notes non pubblicate: $($_.Exception.Message)"
    Write-Host "##vso[task.complete result=SucceededWithIssues;]"
}
exit 0
