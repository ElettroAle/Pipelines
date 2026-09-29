. "$PSScriptRoot/GitCliff.ps1"

$targetBranch = $env:TARGET_BRANCH -replace 'refs/heads/', ''
$gateMode = if ($env:GATE_MODE) { $env:GATE_MODE.ToLower() } else { 'enforce' }

$coreGatedBranches = if ($env:GATED_BRANCHES) { $env:GATED_BRANCHES.Split(',').Trim() } else { @('main', 'staging') }
$rawAdditionalBranches = $env:ADDITIONAL_TAG_BRANCHES
$additionalGatedList = if ($rawAdditionalBranches) { $rawAdditionalBranches.Split(',').Trim() } else { @() }
$gatedList = @($coreGatedBranches) + $additionalGatedList

Write-Host "Target Branch: $targetBranch"
Write-Host "Gated Branches: $($gatedList -join ', ')"
Write-Host "Gate mode: $gateMode"

function Get-PullRequestTitle {
    if ($env:PR_TITLE) { return $env:PR_TITLE }
    if (-not $env:PR_ID -or -not $env:SYSTEM_ACCESSTOKEN) { return $null }

    $uri = "$($env:SYSTEM_COLLECTIONURI)$($env:SYSTEM_TEAMPROJECT)/_apis/git/pullrequests/$($env:PR_ID)?api-version=7.1"
    try {
        $pullRequest = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $($env:SYSTEM_ACCESSTOKEN)" } -UseBasicParsing
        return $pullRequest.title
    }
    catch {
        Write-Host "##[warning]Titolo della PR $($env:PR_ID) non leggibile ($($_.Exception.Message)): si valida l'ultimo commit"
        return $null
    }
}

# Con lo squash il titolo della PR diventa il messaggio del commit: lo si valida come
# commit reale, creato fuori da ogni branch, cosi' git-cliff applica le stesse regole
# del bump e delle release notes senza toccare HEAD.
function New-DetachedCommit {
    param([string]$Message)

    $env:GIT_AUTHOR_NAME = $env:GIT_COMMITTER_NAME = 'Verify-SemVer'
    $env:GIT_AUTHOR_EMAIL = $env:GIT_COMMITTER_EMAIL = 'verify-semver@pipeline.local'
    return (git commit-tree 'HEAD^{tree}' -p HEAD -m $Message).Trim()
}

function Complete-Rejected {
    param([string]$Subject)

    $reason = "MISSING CONVENTIONAL COMMIT: il titolo deve iniziare con un tipo ammesso da cliff.toml (feat, fix, chore, docs, refactor, perf, test, ci, build, style, revert), con scope opzionale e '!' per le breaking change (es. 'fix(api):', 'feat(api)!:')"
    if ($gateMode -eq 'warn') {
        Write-Host "##vso[task.logissue type=warning]$reason"
        Write-Host "Current message: '$Subject'"
        Write-Host "##vso[task.complete result=SucceededWithIssues;]"
        exit 0
    }
    Write-Host "##[error]$reason"
    Write-Host "Current message: '$Subject'"
    exit 1
}

if ($gateMode -eq 'off') {
    Write-Host "Gate disabled. Skipping check."
    exit 0
}

if ($gatedList -notcontains $targetBranch) {
    Write-Host "Gate not required for branch '$targetBranch'. Skipping check."
    exit 0
}

$title = Get-PullRequestTitle
if ($title) {
    $subject = if ($env:PR_ID) { "Merged PR $($env:PR_ID): $title" } else { $title }
    Write-Host "Branch $targetBranch is GATED. Checking PR title: '$subject'"
}
else {
    $subject = git log --no-merges -n 1 --pretty=format:"%s"
    Write-Host "Branch $targetBranch is GATED. Checking last real commit message: '$subject'"
}

$commit = New-DetachedCommit $subject
$unclassified = Get-UnclassifiedCommitMessages "$commit^..$commit"
if ($unclassified.Count -gt 0) {
    Complete-Rejected $subject
}

Write-Host "##[section]Validation successful: Conventional Commit found."
