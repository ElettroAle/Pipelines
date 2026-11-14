# SPDX-License-Identifier: Apache-2.0

# Contratto del modello linguistico dei passi di documentazione. Uno script chiede il client a
# New-LanguageModel e le risposte a Invoke-LanguageModel, senza conoscere il fornitore: ogni altro file
# di questa cartella e' il modulo di un fornitore, che prende il nome dal file e offre
# Initialize-<Nome>LanguageModel e Invoke-<Nome>LanguageModel. Un fornitore nuovo e' un file in piu'.

. "$PSScriptRoot/../Common/ModelRetry.ps1"

$LanguageModelProviders = [ordered]@{}
foreach ($providerFile in @(Get-ChildItem $PSScriptRoot -Filter '*.ps1' | Where-Object Name -NE 'LanguageModel.ps1' | Sort-Object Name)) {
    . $providerFile.FullName
    $LanguageModelProviders[$providerFile.BaseName.ToLowerInvariant()] = $providerFile.BaseName
}

function New-LanguageModel([string]$Provider, [string]$Endpoint, [string]$Model, [string]$ReasoningEffort, $Seed, [string]$AccessToken, [int]$MaxTokens, [int]$TimeoutSeconds = 600) {
    $name = if ("$Provider".Trim()) { "$Provider".Trim().ToLowerInvariant() } else { 'foundry' }
    if (-not $LanguageModelProviders.Contains($name)) { throw "fornitore del modello sconosciuto: $("$Provider".Trim()) ($($LanguageModelProviders.Keys -join ', '))" }
    $client = @{
        Provider        = $name
        Endpoint        = "$Endpoint".Trim().TrimEnd('/')
        Model           = $Model
        ReasoningEffort = $ReasoningEffort
        Seed            = $Seed
        AccessToken     = $AccessToken
        MaxTokens       = $MaxTokens
        TimeoutSeconds  = $TimeoutSeconds
    }
    & "Initialize-$($LanguageModelProviders[$name])LanguageModel" $client
    return $client
}

# Restituisce la risposta letta secondo lo schema e i token usati: @{ Response; Usage = @{ Input; Output } }.
function Invoke-LanguageModel($Client, [string]$System, [string]$User, $Schema, [string]$SchemaName) {
    return & "Invoke-$($LanguageModelProviders[$Client.Provider])LanguageModel" $Client $System $User $Schema $SchemaName
}
