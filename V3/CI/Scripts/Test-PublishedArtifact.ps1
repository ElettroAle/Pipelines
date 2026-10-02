# Un pipeline artifact non si sovrascrive: al rerun di uno stage che lo ha gia'
# caricato, l'upload fallirebbe. Se la verifica non riesce si lascia tentare
# l'upload, perche' saltarlo a torto lascerebbe la run senza artifact.

$artifactName = $env:ARTIFACT_NAME

function Get-RunArtifactNames {
    $uri = "$($env:SYSTEM_COLLECTIONURI)$($env:SYSTEM_TEAMPROJECT)/_apis/build/builds/$($env:BUILD_BUILDID)/artifacts?api-version=7.1"
    $headers = @{ Authorization = "Bearer $($env:SYSTEM_ACCESSTOKEN)" }
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -UseBasicParsing
    return @($response.value | ForEach-Object { $_.name })
}

function Set-AlreadyPublished([bool]$Value) {
    Write-Host "##vso[task.setvariable variable=artifactAlreadyPublished]$($Value.ToString().ToLower())"
}

try {
    $isPublished = (Get-RunArtifactNames) -contains $artifactName
    if ($isPublished) {
        Write-Host "Artifact $artifactName gia' pubblicato nella run: caricamento saltato"
    }
    Set-AlreadyPublished $isPublished
}
catch {
    Write-Host "##vso[task.logissue type=warning]Verifica dell'artifact $artifactName non riuscita, il caricamento procede: $($_.Exception.Message)"
    Set-AlreadyPublished $false
}
exit 0
