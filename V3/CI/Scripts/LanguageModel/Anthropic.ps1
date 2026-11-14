# SPDX-License-Identifier: Apache-2.0

# Modulo Anthropic del contratto del modello linguistico (LanguageModel.ps1): API Messages a consumo,
# autenticata con la chiave in ANTHROPIC_API_KEY, con la risposta in output_config.format json_schema e
# il livello di ragionamento in output_config.effort. Niente campionamento, seme o configurazione del
# ragionamento: con la versione dell'API dichiarata i modelli li rifiutano. Un rifiuto o una risposta
# troncata sono errori: nessun altro modello risponde al posto di quello scelto.

$AnthropicDefaultEndpoint = 'https://api.anthropic.com'
$AnthropicApiVersion = '2026-10-21'
$AnthropicDefaultMaxTokens = 32000
$AnthropicFailedStops = @('refusal', 'max_tokens')

function Initialize-AnthropicLanguageModel($Client) {
    if (-not $Client.Model) { throw 'modello non configurato' }
    # Una variabile della pipeline non definita arriva come la sua macro, $(nome), non come stringa vuota.
    if (-not $env:ANTHROPIC_API_KEY -or $env:ANTHROPIC_API_KEY -match '^\$\(.+\)$') { throw 'chiave Anthropic non configurata (ANTHROPIC_API_KEY)' }
    $Client.ApiKey = $env:ANTHROPIC_API_KEY
    if (-not $Client.Endpoint) { $Client.Endpoint = $AnthropicDefaultEndpoint }
    if ($Client.MaxTokens -le 0) { $Client.MaxTokens = $AnthropicDefaultMaxTokens }
}

function New-AnthropicBody($Client, [string]$System, [string]$User, $Schema) {
    $outputConfig = [ordered]@{ format = @{ type = 'json_schema'; schema = $Schema } }
    if ($Client.ReasoningEffort) { $outputConfig.effort = $Client.ReasoningEffort }
    return [ordered]@{
        model         = $Client.Model
        max_tokens    = $Client.MaxTokens
        system        = $System
        messages      = @(@{ role = 'user'; content = $User })
        output_config = $outputConfig
    } | ConvertTo-Json -Depth 30
}

function Read-AnthropicResponse($Client, $Response) {
    if ($Response.stop_reason -in $AnthropicFailedStops) {
        $category = if ($Response.stop_details.category) { " ($($Response.stop_details.category))" } else { '' }
        throw "risposta di $($Client.Model) interrotta: stop_reason $($Response.stop_reason)$category"
    }
    $text = @($Response.content | Where-Object type -EQ 'text') | Select-Object -First 1
    if (-not $text) { throw "risposta di $($Client.Model) senza testo" }
    return @{
        Response = $text.text | ConvertFrom-Json
        Usage    = @{ Input = [int]$Response.usage.input_tokens; Output = [int]$Response.usage.output_tokens }
    }
}

function Invoke-AnthropicLanguageModel($Client, [string]$System, [string]$User, $Schema, [string]$SchemaName) {
    $body = New-AnthropicBody $Client $System $User $Schema
    $headers = @{ 'x-api-key' = $Client.ApiKey; 'anthropic-version' = $AnthropicApiVersion }
    for ($attempt = 1; ; $attempt++) {
        try {
            $response = Invoke-RestMethod -Method Post -Uri "$($Client.Endpoint)/v1/messages" -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
                -ContentType 'application/json' -Headers $headers -TimeoutSec $Client.TimeoutSeconds
            break
        }
        catch {
            $status = [int]$_.Exception.Response.StatusCode
            $transient = $status -eq 429 -or $status -ge 500
            if ($transient -and $attempt -lt $ModelMaxAttempts) {
                Start-Sleep -Seconds (Get-ModelRetryDelay $_.Exception.Response $attempt)
                continue
            }
            if (-not $status) { throw }
            throw "richiesta ad Anthropic non riuscita ($status): $($_.ErrorDetails.Message)"
        }
    }
    return Read-AnthropicResponse $Client $response
}
