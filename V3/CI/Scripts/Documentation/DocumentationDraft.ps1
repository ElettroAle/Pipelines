# SPDX-License-Identifier: Apache-2.0

# Il ramo di bozza del documento (Write-DraftSources.ps1, Promote-Documentation.ps1, Sync-DocumentationDraft.ps1).
# Ogni run che scrive la bozza registra nel documento, per ogni repository sorgente, il ramo letto, il commit e il suo
# albero git. Quando i repository sorgente arrivano nel ramo principale con gli stessi alberi, il testo della bozza,
# gia' verificato, diventa quello ufficiale con una PR dal ramo di bozza, senza una nuova stesura; dopo ogni
# aggiornamento del ramo principale la bozza lo riceve con una PR, e le pagine che non differiscono piu' spariscono.

$DraftApiVersion = '7.1'

function Split-DraftList([string]$Value) {
    return @("$Value" -split ';' | ForEach-Object Trim | Where-Object { $_ })
}

# Una variabile della pipeline non definita arriva come la sua macro, $(nome), non come stringa vuota.
function Get-DraftSetting([string]$Value, [string]$Default) {
    $text = "$Value".Trim() -replace '^\$\(.*\)$', ''
    if ($text) { return $text }
    return $Default
}

function Get-DraftBranchSetting([string]$Value, [string]$Default) {
    return (Get-DraftSetting $Value $Default) -replace '^refs/heads/', ''
}

function Get-DraftSettings {
    $target = Get-DraftBranchSetting $env:TARGET_BRANCH 'main'
    return @{
        DraftBranch      = Get-DraftBranchSetting $env:DRAFT_BRANCH 'staging'
        TargetBranch     = $target
        SourceBranch     = Get-DraftBranchSetting $env:SOURCE_BRANCH $target
        SourcesFile      = Get-DraftSetting $env:DRAFT_SOURCES_FILE '.draft-sources'
        SourcesDirectory = Get-DraftSetting $env:DRAFT_SOURCES_DIRECTORY ''
        Repositories     = Split-DraftList (Get-DraftSetting $env:DRAFT_SOURCE_REPOSITORIES '')
    }
}

function Get-DraftGitAuthorization {
    if ($env:SYSTEM_ACCESSTOKEN) { return @('-c', "http.extraheader=AUTHORIZATION: bearer $env:SYSTEM_ACCESSTOKEN") }
    return @()
}

function Invoke-DraftGit([string]$Directory) {
    $authorization = Get-DraftGitAuthorization
    $output = git -C $Directory @authorization @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' '): $output" }
    return @($output | ForEach-Object { "$_" })
}

function Test-DraftRemoteBranch([string]$Directory, [string]$Branch) {
    return [bool]"$(Invoke-DraftGit $Directory ls-remote origin "refs/heads/$Branch")".Trim()
}

function Get-SourceCheckout($Settings, [string]$Repository) {
    if (-not $Settings.SourcesDirectory) { throw 'DRAFT_SOURCES_DIRECTORY e'' obbligatoria: la cartella con il checkout di ogni repository sorgente' }
    return Join-Path $Settings.SourcesDirectory $Repository
}

# Il ramo letto e' il ramo sorgente della bozza; un repository che non lo ha si legge su main.
function Get-SourceRecord($Settings, [string]$Repository) {
    $directory = Get-SourceCheckout $Settings $Repository
    if (-not (Test-Path (Join-Path $directory '.git'))) { throw "checkout di $Repository assente in $directory" }
    $branch = if (Test-DraftRemoteBranch $directory $Settings.SourceBranch) { $Settings.SourceBranch } else { 'main' }
    return [ordered]@{
        repository = $Repository
        branch     = $branch
        commit     = "$(Invoke-DraftGit $directory rev-parse HEAD)".Trim()
        tree       = "$(Invoke-DraftGit $directory rev-parse 'HEAD^{tree}')".Trim()
    }
}

# Solo una run sul ramo di bozza scrive il file: il documento ufficiale non documenta una bozza.
function Write-DraftSources($Settings) {
    if ($Settings.TargetBranch -eq 'main') { return $null }
    if (-not $Settings.Repositories) { throw 'DRAFT_SOURCE_REPOSITORIES e'' obbligatoria: i repository sorgente della bozza' }
    $sources = @($Settings.Repositories | ForEach-Object { Get-SourceRecord $Settings $_ })
    $path = [IO.Path]::GetFullPath($Settings.SourcesFile, (Get-Location).Path)
    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject ([ordered]@{ sources = $sources }) -Depth 5) + "`n")
    return $sources
}

function Update-DraftRemoteBranch([string]$Branch) {
    Invoke-DraftGit . fetch -q origin "+refs/heads/${Branch}:refs/remotes/origin/$Branch" | Out-Null
}

function Read-DraftSources($Settings) {
    if (-not (Test-DraftRemoteBranch . $Settings.DraftBranch)) { return $null }
    Update-DraftRemoteBranch $Settings.DraftBranch
    $object = "refs/remotes/origin/$($Settings.DraftBranch):$($Settings.SourcesFile -replace '\\', '/' -replace '^\./', '')"
    git cat-file -e $object 2>$null
    $found = $LASTEXITCODE -eq 0
    $global:LASTEXITCODE = 0
    if (-not $found) { return $null }
    return @(((Invoke-DraftGit . show $object) -join "`n" | ConvertFrom-Json).sources)
}

function Get-SourceTree($Settings, [string]$Repository) {
    $directory = Get-SourceCheckout $Settings $Repository
    if (-not (Test-Path (Join-Path $directory '.git'))) { return $null }
    return "$(Invoke-DraftGit $directory rev-parse 'HEAD^{tree}')".Trim()
}

# La bozza vale come documento ufficiale solo se ogni repository che documenta arriva nel ramo principale con
# lo stesso albero: un commit in piu', anche se non tocca la documentazione, chiede una nuova stesura.
function Get-PromotionObstacle($Settings, $Sources) {
    if ($null -eq $Sources) { return "nessun $($Settings.SourcesFile) nel ramo $($Settings.DraftBranch)" }
    if (-not @($Sources).Count) { return "$($Settings.SourcesFile) del ramo $($Settings.DraftBranch) non elenca repository sorgente" }
    foreach ($source in $Sources) {
        $tree = Get-SourceTree $Settings $source.repository
        if (-not $tree) { return "checkout di $($source.repository) assente" }
        if ($tree -ne $source.tree) { return "$($source.repository) arriva in $($Settings.TargetBranch) con un albero diverso da quello della bozza" }
    }
    return $null
}

function Test-DraftBranchContains([string]$Branch, [string]$Ancestor) {
    git merge-base --is-ancestor "refs/remotes/origin/$Ancestor" "refs/remotes/origin/$Branch"
    $contains = $LASTEXITCODE -eq 0
    $global:LASTEXITCODE = 0
    return $contains
}

function Get-DraftRepositoryApi {
    $origin = "$(git remote get-url origin)".Trim()
    $name = ($origin.TrimEnd('/') -split '[\\/]')[-1] -replace '\.git$', ''
    return "$("$env:SYSTEM_COLLECTIONURI".TrimEnd('/'))/$env:SYSTEM_TEAMPROJECT/_apis/git/repositories/$name"
}

function Invoke-DraftApi([string]$Method, [string]$Url, $Body) {
    $separator = if ($Url.Contains('?')) { '&' } else { '?' }
    $parameters = @{ Method = $Method; Uri = "$Url${separator}api-version=$DraftApiVersion"; Headers = @{ Authorization = "Bearer $env:SYSTEM_ACCESSTOKEN" }; ContentType = 'application/json; charset=utf-8' }
    if ($null -ne $Body) { $parameters.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 10)) }
    return Invoke-RestMethod @parameters
}

# Il ramo di origine non si cancella: e' il ramo di bozza o il ramo principale. Il merge porta la storia, cosi' il
# punto di partenza dell'aggiornamento della documentazione resta nella storia del ramo di destinazione.
function Publish-BranchPullRequest([string]$Source, [string]$Target, [string]$Title, [string]$Description) {
    $api = Get-DraftRepositoryApi
    $query = "searchCriteria.sourceRefName=refs/heads/$Source&searchCriteria.targetRefName=refs/heads/$Target&searchCriteria.status=active"
    $active = @((Invoke-DraftApi 'GET' "$api/pullrequests?$query" $null).value) | Select-Object -First 1
    if ($active) { return $active }
    $created = Invoke-DraftApi 'POST' "$api/pullrequests" @{ sourceRefName = "refs/heads/$Source"; targetRefName = "refs/heads/$Target"; title = $Title; description = $Description }
    Invoke-DraftApi 'PATCH' "$api/pullrequests/$($created.pullRequestId)" @{
        autoCompleteSetBy = @{ id = $created.createdBy.id }
        completionOptions = @{ mergeStrategy = 'noFastForward'; deleteSourceBranch = $false; transitionWorkItems = $false }
    } | Out-Null
    return $created
}

function Format-DraftSourcesDescription($Sources) {
    $lines = @($Sources | ForEach-Object { "- $($_.repository): $($_.branch) @ $("$($_.commit)".Substring(0, [math]::Min(8, "$($_.commit)".Length))), albero $($_.tree)" })
    return "Il testo della bozza e' gia' verificato e documenta gli stessi alberi dei repository sorgente:`n`n$($lines -join "`n")"
}

function Invoke-DocumentationPromotion($Settings) {
    $sources = Read-DraftSources $Settings
    $obstacle = Get-PromotionObstacle $Settings $sources
    if ($obstacle) { return @{ Promoted = $false; Message = "Nessuna promozione della bozza, la documentazione si riscrive: $obstacle" } }
    Update-DraftRemoteBranch $Settings.TargetBranch
    if (Test-DraftBranchContains $Settings.TargetBranch $Settings.DraftBranch) {
        return @{ Promoted = $true; Message = "Il ramo $($Settings.TargetBranch) contiene gia' la bozza di $($Settings.DraftBranch)" }
    }
    $title = "docs: $($Settings.DraftBranch) documentation promoted to $($Settings.TargetBranch)"
    $pullRequest = Publish-BranchPullRequest $Settings.DraftBranch $Settings.TargetBranch $title (Format-DraftSourcesDescription $sources)
    return @{ Promoted = $true; Message = "Bozza promossa con la PR $($pullRequest.pullRequestId) da $($Settings.DraftBranch) verso $($Settings.TargetBranch)" }
}

function Invoke-DraftSync($Settings) {
    if (-not (Test-DraftRemoteBranch . $Settings.DraftBranch)) { return "Nessun ramo $($Settings.DraftBranch): nessuna bozza da allineare" }
    Update-DraftRemoteBranch $Settings.DraftBranch
    Update-DraftRemoteBranch $Settings.TargetBranch
    if (Test-DraftBranchContains $Settings.DraftBranch $Settings.TargetBranch) { return "La bozza di $($Settings.DraftBranch) contiene gia' $($Settings.TargetBranch)" }
    $title = "docs: $($Settings.DraftBranch) documentation restarts from $($Settings.TargetBranch)"
    $description = "La bozza riparte dal documento ufficiale di $($Settings.TargetBranch): le pagine che non ne differiscono piu' spariscono dalla wiki."
    $pullRequest = Publish-BranchPullRequest $Settings.TargetBranch $Settings.DraftBranch $title $description
    return "PR $($pullRequest.pullRequestId) da $($Settings.TargetBranch) verso $($Settings.DraftBranch)"
}
