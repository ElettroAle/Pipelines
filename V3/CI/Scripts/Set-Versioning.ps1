# ====================================================================
# Script: Set-Versioning.ps1
# Descrizione: Gestisce il versionamento semantico e i tag Git
# Dipendenze: Variabili d'ambiente impostate da Azure DevOps
# ====================================================================

$envName = $env:TARGET_ENV.ToLower()
$isRequireTag = $env:REQUIRE_TAG
$safeProjName = $env:PROJECT_NAME.ToLower() -replace '\.', '-'

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

        $lastTag = git describe --tags --abbrev=0 2>$null
        if ($LASTEXITCODE -eq 128) { 
            $lastTag = "0.0.0"
            $global:LASTEXITCODE = 0 
            Write-Host "No tags found. Analyzing full history."
            $commitsRaw = git log --pretty=format:"%s"
        } else {
            Write-Host "Last tag found: $lastTag. Analyzing commits since then."
            $commitsRaw = git log "$lastTag..HEAD" --pretty=format:"%s"
        }

        $autoIncrement = "patch"
        if ($commitsRaw) {
            $commitList = $commitsRaw -split "`n"
            $foundValid = $false

            Write-Host "--- Analyzing commit history (newest first) ---"
            foreach ($msg in $commitList) {
                $trimmedMsg = $msg.Trim()
                if (-not $foundValid) {
                    if ($trimmedMsg -match "^feat!:") { $autoIncrement = "major"; $foundValid = $true }
                    elseif ($trimmedMsg -match "^feat:") { $autoIncrement = "minor"; $foundValid = $true }
                    elseif ($trimmedMsg -match "^fix:") { $autoIncrement = "patch"; $foundValid = $true }
                }
            }
        }

        $v = [version]($lastTag.TrimStart('v'))
        $major = $v.Major; $minor = $v.Minor; $patch = $v.Build

        if ($autoIncrement -eq "major") { $major++; $minor = 0; $patch = 0 }
        elseif ($autoIncrement -eq "minor") { $minor++; $patch = 0 }
        else { $patch++ }

        $newTag = "$major.$minor.$patch"

        git tag $newTag
        git push origin $newTag
        Write-Host "##[section]Successfully tagged: $newTag"
    }

    Write-Host "##vso[task.setvariable variable=currentTag]$newTag"
    Write-Host "##vso[task.setvariable variable=gitHash]$shortSha"
    Write-Host "##vso[task.setvariable variable=computedArtifactName]$safeProjName-$envName-$newTag"
}
else {
    Write-Host "##[warning]Tagging is DISABLED — versione calcolata da ultimo tag git"

    $lastTag = git describe --tags --abbrev=0 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($lastTag)) {
        $baseVer = "0.0.0"
        Write-Host "Nessun tag trovato. Versione base: $baseVer"
    } else {
        $baseVer = $lastTag.TrimStart('v')
        Write-Host "Ultimo tag trovato: $lastTag. Versione base: $baseVer"
    }
    $global:LASTEXITCODE = 0

    $ver = "$baseVer.$($env:BUILD_ID)"

    Write-Host "##vso[task.setvariable variable=currentTag]$ver"
    Write-Host "##vso[task.setvariable variable=gitHash]$shortSha"
    Write-Host "##vso[task.setvariable variable=computedArtifactName]$safeProjName-$envName-$ver"
}