# SPDX-License-Identifier: Apache-2.0

# Endpoint locale che risponde come l'API delle PR di Azure Repos. Le PR attive sono quelle di
# active.json nella cartella di stato; una PR creata ha id 101 e l'identita' build-identity come autore.
# status forza un codice HTTP. Le richieste ricevute restano in request-<n>.json con metodo, URL e corpo.

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
    $reader = [IO.StreamReader]::new($context.Request.InputStream, [Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    $count++
    $request = [ordered]@{ method = $context.Request.HttpMethod; url = $context.Request.RawUrl; body = if ($body) { $body | ConvertFrom-Json } else { $null } }
    [IO.File]::WriteAllText((Join-Path $State "request-$count.json"), ($request | ConvertTo-Json -Depth 10))

    $statusFile = Join-Path $State 'status'
    $status = if (Test-Path $statusFile) { [int](Get-Content -Raw $statusFile) } else { 200 }
    $payload = switch ($context.Request.HttpMethod) {
        'GET' {
            $activeFile = Join-Path $State 'active.json'
            $active = if (Test-Path $activeFile) { @(Get-Content -Raw $activeFile | ConvertFrom-Json) } else { @() }
            @{ value = $active; count = $active.Count } | ConvertTo-Json -Depth 6 -Compress
        }
        'POST' { @{ pullRequestId = 101; createdBy = @{ id = 'build-identity' } } | ConvertTo-Json -Compress }
        default { '{}' }
    }
    if ($status -ne 200) { $payload = '{"message":"errore di prova"}' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $context.Response.StatusCode = $status
    $context.Response.ContentType = 'application/json'
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $context.Response.Close()
}
$listener.Stop()
