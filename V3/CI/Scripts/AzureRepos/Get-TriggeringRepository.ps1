# SPDX-License-Identifier: Apache-2.0

# Scrive nella variabile di output id l'id del repository Azure Repos che ha avviato la run con un trigger
# di repository, vuota se la run non viene da un trigger di repository. Build.Repository.Name non basta:
# nelle condizioni degli stage nomina il repository self anche quando la run l'ha avviata un altro
# repository. L'id si legge da triggerInfo della run, l'unico campo che lo porta.

$ErrorActionPreference = 'Stop'

$ApiVersion = '7.1'

function Get-Run {
    $url = "$($env:SYSTEM_COLLECTIONURI.TrimEnd('/'))/$env:SYSTEM_TEAMPROJECT/_apis/build/builds/${env:BUILD_BUILDID}?api-version=$ApiVersion"
    return Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $env:SYSTEM_ACCESSTOKEN" }
}

function Get-TriggeringRepositoryId($Run) {
    $id = $Run.triggerInfo.'ci.triggerRepository'
    if ($id) { return "$id".ToLowerInvariant() }
    return ''
}

$repositoryId = Get-TriggeringRepositoryId (Get-Run)
$shown = if ($repositoryId) { $repositoryId } else { 'nessuno: la run non viene da un trigger di repository' }
Write-Host "Repository che ha avviato la run: $shown"
Write-Host "##vso[task.setvariable variable=id;isOutput=true]$repositoryId"
