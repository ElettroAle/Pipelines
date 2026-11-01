# SPDX-License-Identifier: Apache-2.0

# Endpoint locale che risponde come l'API delle run di Azure Pipelines: a ogni GET restituisce build.json
# della cartella di stato. status forza un codice HTTP. Le richieste ricevute restano in request-<n>.json
# con metodo, URL e intestazione Authorization.

param([string]$Endpoint, [string]$State)

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("$Endpoint/")
$listener.Start()
$count = 0
$stopFile = Join-Path $State 'stop'
while (-not (Test-Path $stopFile)) {
    $pending = $listener.GetContextAsync()
    while (-not $pending.Wait(200)) { if (Test-Path $stopFile) { break } }
    if (-not $pending.IsCompleted) { break }
    $context = $pending.Result
    $count++
    $request = [ordered]@{ method = $context.Request.HttpMethod; url = $context.Request.RawUrl; authorization = $context.Request.Headers['Authorization'] }
    [IO.File]::WriteAllText((Join-Path $State "request-$count.json"), ($request | ConvertTo-Json))

    $statusFile = Join-Path $State 'status'
    $status = if (Test-Path $statusFile) { [int](Get-Content -Raw $statusFile) } else { 200 }
    $payload = if ($status -eq 200) { Get-Content -Raw (Join-Path $State 'build.json') } else { '{"message":"errore di prova"}' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $context.Response.StatusCode = $status
    $context.Response.ContentType = 'application/json'
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $context.Response.Close()
}
$listener.Stop()
