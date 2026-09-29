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

function Get-PullRequestUrlBase {
    $remote = (git remote get-url origin 2>$null)
    $global:LASTEXITCODE = 0
    if (-not $remote) { return $null }

    $remote = $remote.Trim() -replace '://[^/@]+@', '://' -replace '\.git$', ''
    if ($remote -match '/_git/') { return "$remote/pullrequest/" }
    if ($remote -match '^https://github\.com/') { return "$remote/pull/" }
    return $null
}

function Add-PullRequestLinks {
    param([string]$Markdown)

    $urlBase = Get-PullRequestUrlBase
    if (-not $urlBase) { return $Markdown }
    return [regex]::Replace($Markdown, '\(PR (\d+)\)', { param($m) "([PR $($m.Groups[1].Value)]($urlBase$($m.Groups[1].Value)))" })
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
    $markdown = Add-PullRequestLinks (Get-ReleaseNotesMarkdown -Range $range -Tag $releaseTag)

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
