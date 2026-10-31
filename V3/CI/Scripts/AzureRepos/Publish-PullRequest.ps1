# SPDX-License-Identifier: Apache-2.0

# Porta su un ramo del repository della cartella di lavoro le cartelle o i file di PULL_REQUEST_PATHS,
# come la pipeline li ha scritti, e apre una PR verso PULL_REQUEST_TARGET. Il ramo puo' gia' esistere
# con i commit di un passo precedente: si riparte da li'. Se le cartelle sul ramo non differiscono dal
# ramo di destinazione non si apre nessuna PR, e un ramo rimasto senza PR si cancella. Una PR gia'
# attiva sullo stesso ramo si aggiorna. Il repository e' quello di origin, nel progetto della pipeline.

$ErrorActionPreference = 'Stop'

$Paths = @("$env:PULL_REQUEST_PATHS" -split ';' | ForEach-Object Trim | Where-Object { $_ })
$Branch = "$env:PULL_REQUEST_BRANCH" -replace '^refs/heads/', ''
$Target = if ($env:PULL_REQUEST_TARGET) { $env:PULL_REQUEST_TARGET -replace '^refs/heads/', '' } else { 'main' }
$Title = "$env:PULL_REQUEST_TITLE"
$Description = "$env:PULL_REQUEST_DESCRIPTION"
$OriginDirectory = "$env:PULL_REQUEST_ORIGIN_DIRECTORY"
$MergeStrategy = if ($env:PULL_REQUEST_MERGE_STRATEGY) { $env:PULL_REQUEST_MERGE_STRATEGY } else { 'noFastForward' }
$OriginLabel = if ($env:PULL_REQUEST_ORIGIN_LABEL) { $env:PULL_REQUEST_ORIGIN_LABEL } else { 'Origin' }
$AutoComplete = "$env:PULL_REQUEST_AUTO_COMPLETE" -ne 'false'
$DeleteSourceBranch = "$env:PULL_REQUEST_DELETE_SOURCE_BRANCH" -ne 'false'
$Draft = "$env:PULL_REQUEST_DRAFT" -eq 'true'
$ApiVersion = '7.1'
# Il limite della descrizione di una PR di Azure Repos.
$MaxDescriptionLength = 4000

function Get-GitAuthorization {
    if ($env:SYSTEM_ACCESSTOKEN) { return @('-c', "http.extraheader=AUTHORIZATION: bearer $env:SYSTEM_ACCESSTOKEN") }
    return @()
}

function Invoke-Git([string]$Directory) {
    $authorization = Get-GitAuthorization
    $out = git -C $Directory @authorization @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' '): $out" }
    return $out
}

function Test-RemoteBranch([string]$Name) {
    $authorization = Get-GitAuthorization
    $found = git @authorization ls-remote origin "refs/heads/$Name" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "origin non raggiungibile: $found" }
    return [bool]"$found".Trim()
}

function Get-RepositoryApi {
    $origin = "$(git remote get-url origin)".Trim()
    $name = ($origin.TrimEnd('/') -split '[\\/]')[-1] -replace '\.git$', ''
    return "$($env:SYSTEM_COLLECTIONURI.TrimEnd('/'))/$env:SYSTEM_TEAMPROJECT/_apis/git/repositories/$name"
}

function Invoke-Api([string]$Method, [string]$Url, $Body) {
    $headers = @{ Authorization = "Bearer $env:SYSTEM_ACCESSTOKEN" }
    $separator = if ($Url.Contains('?')) { '&' } else { '?' }
    $parameters = @{ Method = $Method; Uri = "$Url${separator}api-version=$ApiVersion"; Headers = $headers; ContentType = 'application/json; charset=utf-8' }
    if ($null -ne $Body) { $parameters.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 10)) }
    return Invoke-RestMethod @parameters
}

function Get-RepositoryPath([string]$Path) {
    $prefix = "$(git rev-parse --show-prefix)".Trim()
    return ($prefix + ($Path -replace '\\', '/' -replace '^\./', '')).TrimEnd('/')
}

function Get-OriginLine {
    if (-not $OriginDirectory) { return }
    $subject = "$(git -C $OriginDirectory log -1 --format=%s)".Trim()
    $commit = "$(git -C $OriginDirectory rev-parse --short=8 HEAD)".Trim()
    $repository = Split-Path -Leaf "$(git -C $OriginDirectory remote get-url origin)".Trim().TrimEnd('/')
    return "${OriginLabel}: $subject ($repository@$commit)"
}

function Get-PullRequestDescription {
    $text = (@($Description, (Get-OriginLine)) | Where-Object { $_ }) -join "`n`n"
    if ($text.Length -gt $MaxDescriptionLength) { $text = $text.Substring(0, $MaxDescriptionLength) }
    return $text
}

function New-BranchWorktree([bool]$BranchExists) {
    Invoke-Git . fetch -q origin "+refs/heads/${Target}:refs/remotes/origin/$Target" | Out-Null
    $start = "refs/remotes/origin/$Target"
    if ($BranchExists) {
        Invoke-Git . fetch -q origin "+refs/heads/${Branch}:refs/remotes/origin/$Branch" | Out-Null
        $start = "refs/remotes/origin/$Branch"
    }
    $worktree = Join-Path ([IO.Path]::GetTempPath()) "pull-request-$(New-Guid)"
    Invoke-Git . worktree add -q --detach $worktree $start | Out-Null
    return $worktree
}

function Copy-Paths([string]$Worktree) {
    foreach ($path in $Paths) {
        $relative = Get-RepositoryPath $path
        Invoke-Git $Worktree rm -r -q --ignore-unmatch -- $relative | Out-Null
        $destination = Join-Path $Worktree $relative
        Remove-Item -Recurse -Force $destination -ErrorAction SilentlyContinue
        if (Test-Path $path) {
            New-Item -ItemType Directory -Force -Path (Split-Path $destination) | Out-Null
            Copy-Item -Recurse -Force $path $destination
        }
        Invoke-Git $Worktree add -A -- $relative | Out-Null
    }
}

function Save-Branch([string]$Worktree) {
    git -C $Worktree diff --cached --quiet
    if ($LASTEXITCODE -eq 0) { return $false }
    $name = if ($env:BUILD_REQUESTEDFOR) { $env:BUILD_REQUESTEDFOR } else { 'Pipeline' }
    $email = if ($env:BUILD_REQUESTEDFOREMAIL) { $env:BUILD_REQUESTEDFOREMAIL } else { 'pipeline@noreply.local' }
    Invoke-Git $Worktree -c "user.name=$name" -c "user.email=$email" commit -q -m $Title | Out-Null
    Invoke-Git $Worktree push -q origin "HEAD:refs/heads/$Branch" | Out-Null
    return $true
}

function Test-BranchDiffers([string]$Worktree) {
    $relatives = @($Paths | ForEach-Object { Get-RepositoryPath $_ })
    git -C $Worktree diff --quiet "refs/remotes/origin/$Target" HEAD -- @relatives
    return $LASTEXITCODE -ne 0
}

function Get-ActivePullRequest([string]$Api) {
    $query = "searchCriteria.sourceRefName=refs/heads/$Branch&searchCriteria.targetRefName=refs/heads/$Target&searchCriteria.status=active"
    return @((Invoke-Api 'GET' "$Api/pullrequests?$query" $null).value) | Select-Object -First 1
}

function New-PullRequest([string]$Api) {
    $created = Invoke-Api 'POST' "$Api/pullrequests" @{
        sourceRefName = "refs/heads/$Branch"; targetRefName = "refs/heads/$Target"
        title = $Title; description = Get-PullRequestDescription; isDraft = $Draft
    }
    $completion = @{ completionOptions = @{ mergeStrategy = $MergeStrategy; deleteSourceBranch = $DeleteSourceBranch; transitionWorkItems = $false } }
    if ($AutoComplete) { $completion.autoCompleteSetBy = @{ id = $created.createdBy.id } }
    Invoke-Api 'PATCH' "$Api/pullrequests/$($created.pullRequestId)" $completion | Out-Null
    return $created
}

function Update-PullRequest([string]$Api, $PullRequest) {
    Invoke-Api 'PATCH' "$Api/pullrequests/$($PullRequest.pullRequestId)" @{ title = $Title; description = Get-PullRequestDescription } | Out-Null
    return $PullRequest
}

function Remove-StaleBranch([string]$Api, [bool]$BranchExists) {
    if (-not $BranchExists -or (Get-ActivePullRequest $Api)) { return }
    Invoke-Git . push -q origin --delete $Branch | Out-Null
    Write-Host "Ramo $Branch senza differenze da ${Target}: cancellato"
}

function Publish-PullRequest {
    if (-not $Paths -or -not $Branch -or -not $Title) { throw 'PULL_REQUEST_PATHS, PULL_REQUEST_BRANCH e PULL_REQUEST_TITLE sono obbligatori' }
    $api = Get-RepositoryApi
    $branchExists = Test-RemoteBranch $Branch
    $worktree = New-BranchWorktree $branchExists
    try {
        Copy-Paths $worktree
        $pushed = Save-Branch $worktree
        if (-not (Test-BranchDiffers $worktree)) {
            Write-Host "Nessuna differenza da ${Target} in $($Paths -join ', '): nessuna PR"
            Remove-StaleBranch $api ($branchExists -or $pushed)
            return
        }
        $active = Get-ActivePullRequest $api
        $pullRequest = if ($active) { Update-PullRequest $api $active } else { New-PullRequest $api }
        Write-Host "PR $($pullRequest.pullRequestId) da $Branch verso $Target"
    }
    finally {
        git worktree remove --force $worktree 2>&1 | Out-Null
        $global:LASTEXITCODE = 0
    }
}

try {
    Publish-PullRequest
}
catch {
    Write-Host "##vso[task.logissue type=error]pull request: $($_.Exception.Message)"
    exit 1
}
