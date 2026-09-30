# ====================================================================
# Script: Set-Versioning.ps1
# Descrizione: Gestisce il versionamento semantico e i tag Git
# Dipendenze: Variabili d'ambiente impostate da Azure DevOps
# ====================================================================

. "$PSScriptRoot/GitCliff.ps1"

$envName = $env:TARGET_ENV.ToLower()
$isRequireTag = $env:REQUIRE_TAG
$safeProjName = $env:PROJECT_NAME.ToLower() -replace '\.', '-'
$prereleaseLabel = if ($env:PRERELEASE_LABEL) { $env:PRERELEASE_LABEL } else { 'dev' }

$shortSha = git rev-parse --short HEAD
if ($LASTEXITCODE -ne 0) { $shortSha = "unknown" }

if ($isRequireTag -eq "true") {
    Write-Host "##[section]Tagging is ENABLED for environment: $envName"

    $lastTag = git describe --tags --abbrev=0 2>$null

    $isIdentical = $false
    if ($LASTEXITCODE -eq 0) {
        $headTree = git rev-parse "HEAD^{tree}"
        $tagTree = git rev-parse "$lastTag^{tree}"

        if ($headTree -eq $tagTree) {
            $isIdentical = $true
        }
    }

    if ($isIdentical) {
        $newTag = $lastTag
        Write-Host "Il codice e' identico al tag $newTag (Merge senza modifiche). Nessun incremento necessario."
        $global:LASTEXITCODE = 0
    }
    else {
        $global:LASTEXITCODE = 0

        $newTag = Get-NextReleaseVersion
        Write-Host "Next release version from git-cliff: $newTag"

        git tag $newTag
        git push origin $newTag
        Write-Host "##[section]Successfully tagged: $newTag"
    }
}
else {
    Write-Host "##[warning]Tagging is DISABLED - prerelease della prossima versione, nessun tag"

    $nextRelease = Get-NextReleaseVersion
    $lastTag = git describe --tags --abbrev=0 2>$null
    $global:LASTEXITCODE = 0
    # Senza commit dall'ultimo tag git-cliff restituisce il tag stesso: un prerelease
    # di quella versione ordinerebbe prima del rilascio gia' uscito.
    if ($lastTag -and $nextRelease -eq $lastTag.TrimStart('v')) {
        $v = [version]$nextRelease
        $nextRelease = "$($v.Major).$($v.Minor).$($v.Build + 1)"
    }

    $newTag = "$nextRelease-$prereleaseLabel.$($env:BUILD_ID)"
    Write-Host "Prerelease version: $newTag"
}

# AssemblyVersion e FileVersion accettano solo quattro numeri <= 65535: il prerelease
# e il build id restano in Version e InformationalVersion.
$releaseCore = [version](($newTag -replace '-.*$', '').TrimStart('v'))
Write-Host "##vso[task.setvariable variable=currentTag]$newTag"
Write-Host "##vso[task.setvariable variable=assemblyVersion]$($releaseCore.Major).$($releaseCore.Minor).$($releaseCore.Build).0"
Write-Host "##vso[task.setvariable variable=gitHash]$shortSha"
Write-Host "##vso[task.setvariable variable=computedArtifactName]$safeProjName-$envName-$newTag"
Write-Host "##vso[build.updatebuildnumber]$newTag"
if ($isRequireTag -eq "true") { Write-Host "##vso[build.addbuildtag]release" }
