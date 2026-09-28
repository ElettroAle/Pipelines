. "$PSScriptRoot/ConventionalCommit.ps1"

$targetBranch = $env:TARGET_BRANCH -replace 'refs/heads/', ''

$coreProtectedBranches = @('main', 'staging')

$rawAdditionalBranches = $env:ADDITIONAL_TAG_BRANCHES
$additionalProtectedList = if ($rawAdditionalBranches) { $rawAdditionalBranches.Split(',').Trim() } else { @() }

$protectedList = $coreProtectedBranches + $additionalProtectedList

Write-Host "Target Branch: $targetBranch"
Write-Host "Protected Branches (Core + Additional): $($protectedList -join ', ')"

if ($protectedList -contains $targetBranch) {
    Write-Host "Branch $targetBranch is PROTECTED. Checking last real commit message..."
    
    $lastCommitMessage = git log --no-merges -n 1 --pretty=format:"%s"
    
    Write-Host "Last real commit identified: '$lastCommitMessage'"

    if (Get-ConventionalCommitIncrement $lastCommitMessage) {
        Write-Host "##[section]Validation successful: Conventional Commit found."
    } else {
        Write-Host "##[error]MISSING CONVENTIONAL COMMIT: Your last commit must start with 'fix:', 'feat:' or 'BREAKING CHANGE:', optionally with a scope and '!' for breaking changes (e.g. 'fix(api):', 'feat(api)!:')"
        Write-Host "Current message: '$lastCommitMessage'"
        exit 1
    }
} else {
    Write-Host "Tagging not required for branch '$targetBranch'. Skipping check."
}