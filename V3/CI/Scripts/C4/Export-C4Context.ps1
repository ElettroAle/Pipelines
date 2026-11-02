# SPDX-License-Identifier: Apache-2.0

# Persone e sistemi esterni del modello C4, dai testi che Write-C4ModelText.ps1 ha scritto per ogni
# repository sorgente (*.text.json in GENERATED_DIRECTORY), in Structurizr DSL da includere nel modello
# prima del sistema. Si scrive in CONTEXT_FILE quando il documento si compone e non si committa: ogni run
# di un repository scrive solo la propria parte. Un identificativo dichiarato da piu' testi vale una
# volta, con il testo che viene prima per nome, quello che Write-C4ModelText.ps1 riconosce come proprietario.

. "$PSScriptRoot/../Common/VerificationGate.ps1"
. "$PSScriptRoot/../Common/DocumentLanguage.ps1"

$GeneratedDirectory = if ($env:GENERATED_DIRECTORY) { $env:GENERATED_DIRECTORY } else { 'docs/architecture/model/generated' }
$ContextFile = if ($env:CONTEXT_FILE) { $env:CONTEXT_FILE } else { 'docs/architecture/model/context.dsl' }
$TechnicalTag = $DocumentLanguage.TechnicalTag
$ExternalTag = $DocumentLanguage.ExternalTag
$Scope = 'contesto del modello C4'

function Read-ModelTexts {
    foreach ($file in (Get-ChildItem -Path $GeneratedDirectory -Filter '*.text.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $content = try { Get-Content -Raw $file.FullName | ConvertFrom-Json -ErrorAction Stop } catch { $null }
        [pscustomobject]@{ File = $file.Name; Content = $content }
    }
}

function Format-Text([string]$Text) {
    return '"' + (($Text -replace '\s+', ' ').Trim() -replace '"', '\"') + '"'
}

function Format-Actor([string]$Id, $Actor, [string]$Kind, [string[]]$Tags) {
    $allTags = @($Tags) + @(if ($Actor.technical) { $TechnicalTag })
    return "$Id = $Kind $(Format-Text $Actor.name) $(Format-Text $Actor.description) $(Format-Text ($allTags -join ','))"
}

function Get-Actors($Contents, [string]$Part) {
    $actors = [ordered]@{}
    $Contents | ForEach-Object { $_.$Part.PSObject.Properties } | Where-Object { -not $actors.Contains($_.Name) } | ForEach-Object { $actors[$_.Name] = $_.Value }
    return $actors.GetEnumerator() | Sort-Object Key
}

function Format-Context($Contents) {
    $lines = @("// Persone e sistemi esterni del modello C4, dai testi scritti con Write-C4ModelText.ps1: non si modifica a mano.")
    $lines += @(Get-Actors $Contents 'people' | ForEach-Object { Format-Actor $_.Key $_.Value 'person' @() })
    $lines += @(Get-Actors $Contents 'externalSystems' | ForEach-Object { Format-Actor $_.Key $_.Value 'softwareSystem' @($ExternalTag) })
    return ($lines -join "`n") + "`n"
}

function Write-Context([string]$Content) {
    $path = [IO.Path]::GetFullPath($ContextFile, (Get-Location).Path)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    [IO.File]::WriteAllText($path, $Content)
}

function Get-ContextIssues {
    $texts = @(Read-ModelTexts)
    $unreadable = @($texts | Where-Object { -not $_.Content } | ForEach-Object { New-Issue $Scope 'testo del modello non leggibile' $_.File })
    if ($unreadable) { return $unreadable }
    Write-Context (Format-Context @($texts.Content))
}

Invoke-Verification { Get-ContextIssues } "Contesto del modello C4 scritto in $ContextFile" 'Contesto del modello C4 disattivato'
