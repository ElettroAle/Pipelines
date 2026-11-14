# SPDX-License-Identifier: Apache-2.0

# Modulo Foundry del contratto del modello linguistico (LanguageModel.ps1): chat completions di Azure
# OpenAI con token Entra ID e risposta in json_schema stretto. Il token si chiede alla Azure CLI alla
# prima richiesta; AccessToken lo sostituisce nei test. Un deployment che non accetta il seme risponde
# 400 nominandolo: il client smette di mandarlo e ripete la richiesta.

function Initialize-FoundryLanguageModel($Client) {
    if (-not $Client.Endpoint -or -not $Client.Model) { throw 'endpoint o modello non configurati' }
    $Client.SeedSupported = $null -ne $Client.Seed -and "$($Client.Seed)" -ne ''
    $Client.Token = $null
}

function Get-FoundryAccessToken($Client) {
    if ($Client.AccessToken) { return $Client.AccessToken }
    $token = az account get-access-token --resource 'https://cognitiveservices.azure.com' --query accessToken -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) { throw "token Entra ID non ottenuto: $token" }
    return $token
}

function New-FoundryBody($Client, [string]$System, [string]$User, $Schema, [string]$SchemaName) {
    $body = [ordered]@{ model = $Client.Model }
    if ($Client.ReasoningEffort) { $body.reasoning_effort = $Client.ReasoningEffort }
    $body.messages = @(@{ role = 'system'; content = $System }, @{ role = 'user'; content = $User })
    $body.response_format = @{ type = 'json_schema'; json_schema = @{ name = $SchemaName; strict = $true; schema = $Schema } }
    if ($Client.SeedSupported) { $body.seed = [int]$Client.Seed }
    return $body | ConvertTo-Json -Depth 30
}

function Invoke-FoundryLanguageModel($Client, [string]$System, [string]$User, $Schema, [string]$SchemaName) {
    if (-not $Client.Token) { $Client.Token = Get-FoundryAccessToken $Client }
    for ($attempt = 1; ; $attempt++) {
        $body = New-FoundryBody $Client $System $User $Schema $SchemaName
        try {
            $response = Invoke-RestMethod -Method Post -Uri "$($Client.Endpoint)/openai/v1/chat/completions" -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
                -ContentType 'application/json; charset=utf-8' -Headers @{ Authorization = "Bearer $($Client.Token)" } -TimeoutSec $Client.TimeoutSeconds
            break
        }
        catch {
            $status = [int]$_.Exception.Response.StatusCode
            if ($status -eq 400 -and $Client.SeedSupported -and "$($_.ErrorDetails.Message)" -match 'seed') {
                $Client.SeedSupported = $false
                continue
            }
            $transient = $status -eq 429 -or $status -ge 500
            if (-not $transient -or $attempt -ge $ModelMaxAttempts) { throw }
            Start-Sleep -Seconds (Get-ModelRetryDelay $_.Exception.Response $attempt)
        }
    }
    return @{
        Response = $response.choices[0].message.content | ConvertFrom-Json
        Usage    = @{ Input = [int]$response.usage.prompt_tokens; Output = [int]$response.usage.completion_tokens }
    }
}
