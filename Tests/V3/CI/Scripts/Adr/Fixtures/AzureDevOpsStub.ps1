# SPDX-License-Identifier: Apache-2.0

# Endpoint locale dell'API di Azure DevOps per i test della registrazione delle decisioni. Le risposte
# stanno in routes.json, una voce "METODO /percorso" (percorso decodificato, senza query) con status e
# body; una richiesta senza voce riceve 404. Ogni richiesta resta in request-<n>.json con metodo,
# percorso, query e corpo. Set-AzureDevOpsRoutes sostituisce le voci e azzera le richieste.

function Start-AzureDevOpsStub {
    $state = Join-Path ([IO.Path]::GetTempPath()) "pester-azure-devops-$(New-Guid)"
    New-Item -ItemType Directory -Path $state | Out-Null
    [IO.File]::WriteAllText((Join-Path $state 'routes.json'), '{}')
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
    $endpoint = "http://127.0.0.1:$port"
    $job = Start-ThreadJob -ArgumentList $endpoint, $state -ScriptBlock {
        param($Endpoint, $State)
        $listener = [Net.HttpListener]::new()
        $listener.Prefixes.Add("$Endpoint/")
        $listener.Start()
        New-Item -ItemType File -Path (Join-Path $State 'ready') | Out-Null
        $stopFile = Join-Path $State 'stop'
        while (-not (Test-Path $stopFile)) {
            $pending = $listener.GetContextAsync()
            while (-not $pending.Wait(200)) { if (Test-Path $stopFile) { break } }
            if (-not $pending.IsCompleted) { break }
            $context = $pending.Result
            $reader = [IO.StreamReader]::new($context.Request.InputStream, [Text.Encoding]::UTF8)
            $body = $reader.ReadToEnd()
            $path = [uri]::UnescapeDataString($context.Request.Url.AbsolutePath)
            $count = @(Get-ChildItem $State -Filter 'request-*.json').Count + 1
            $request = [ordered]@{ method = $context.Request.HttpMethod; path = $path; query = $context.Request.Url.Query; body = $body }
            [IO.File]::WriteAllText((Join-Path $State "request-$count.json"), ($request | ConvertTo-Json -Depth 5))
            $routes = Get-Content -Raw (Join-Path $State 'routes.json') | ConvertFrom-Json -AsHashtable
            $route = $routes["$($context.Request.HttpMethod) $path"]
            if (-not $route) { $route = @{ status = 404; body = @{ message = "no route for $($context.Request.HttpMethod) $path" } } }
            $payload = $route.body | ConvertTo-Json -Depth 20 -Compress
            $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
            $context.Response.StatusCode = [int]$route.status
            $context.Response.ContentType = 'application/json'
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $context.Response.Close()
        }
        $listener.Stop()
    }
    $ready = Join-Path $state 'ready'
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path $ready)) {
        if ($job.State -eq 'Failed' -or [DateTime]::UtcNow -gt $deadline) { throw "endpoint di Azure DevOps non avviato: $($job | Receive-Job -ErrorAction SilentlyContinue)" }
        Start-Sleep -Milliseconds 50
    }
    return @{ Endpoint = $endpoint; State = $state; Job = $job }
}

function Stop-AzureDevOpsStub($Stub) {
    New-Item -ItemType File -Path (Join-Path $Stub.State 'stop') -Force | Out-Null
    $Stub.Job | Wait-Job -Timeout 10 | Out-Null
    $Stub.Job | Remove-Job -Force
    Remove-Item -Recurse -Force $Stub.State -ErrorAction SilentlyContinue
}

function Set-AzureDevOpsRoutes($Stub, [hashtable]$Routes) {
    Get-ChildItem $Stub.State -Filter 'request-*.json' | Remove-Item -Force
    [IO.File]::WriteAllText((Join-Path $Stub.State 'routes.json'), (ConvertTo-Json -InputObject $Routes -Depth 20))
}

function Get-AzureDevOpsRequests($Stub) {
    return @(Get-ChildItem $Stub.State -Filter 'request-*.json' | Sort-Object { [int]($_.BaseName -replace '\D', '') } | ForEach-Object {
            $request = Get-Content -Raw $_.FullName | ConvertFrom-Json
            [pscustomobject]@{ Method = $request.method; Path = $request.path; Query = $request.query; Body = $request.body }
        })
}

# Le voci di una board e dei suoi repository sorgente, descritti per integrazione:
#   Integrations: @{ Repository; Id; Closed; DevelopmentBranch; Merged = @(@{ Id; WorkItems; Target }) }
#     senza DevelopmentBranch la PR va nel ramo principale e porta i suoi WorkItems
#   WorkItems: @{ <id> = @{ Type; Title; Description; Format } }
#   Repositories: i repository sorgente senza integrazioni, con l'elenco delle PR vuoto
function New-AzureDevOpsRoutes([string]$Project, [object[]]$Integrations, [hashtable]$WorkItems, [string[]]$Repositories = @(), [int]$NextWorkItem = 9001) {
    $routes = @{ "GET /$Project/_apis/git/repositories" = @{ status = 200; body = @{ value = @() } } }
    foreach ($repository in $Repositories) { $routes["GET /$Project/_apis/git/repositories/$repository/pullrequests"] = @{ status = 200; body = @{ value = @() } } }
    foreach ($group in ($Integrations | Group-Object { $_.Repository })) {
        $repository = $group.Name
        $routes["GET /$Project/_apis/git/repositories/$repository/pullrequests"] = @{ status = 200; body = @{ value = @($group.Group | ForEach-Object {
                        @{ pullRequestId = $_.Id; closedDate = $_.Closed; status = 'completed'; targetRefName = 'refs/heads/main'; repository = @{ name = $repository } }
                    }) }
        }
        foreach ($integration in $group.Group) {
            if (-not $integration.DevelopmentBranch) {
                $routes["GET /$Project/_apis/git/repositories/$repository/pullRequests/$($integration.Id)/workitems"] = @{ status = 200; body = @{ value = @($integration.WorkItems | ForEach-Object { @{ id = "$_" } }) } }
                continue
            }
            $routes["GET /$Project/_apis/git/repositories/$repository/pullRequests/$($integration.Id)/commits"] = @{ status = 200; body = @{ value = @($integration.Merged | ForEach-Object {
                            @{ commitId = "$($_.Id)"; comment = "Merged PR $($_.Id): lavoro $($_.Id)" }
                        }) + @(@{ commitId = 'feature'; comment = 'feat: un commit del lavoro' })
                }
            }
            foreach ($merged in $integration.Merged) {
                $target = if ($merged.Target) { $merged.Target } else { $integration.DevelopmentBranch }
                $routes["GET /$Project/_apis/git/pullrequests/$($merged.Id)"] = @{ status = 200; body = @{ pullRequestId = $merged.Id; status = 'completed'; targetRefName = "refs/heads/$target"; repository = @{ name = $repository } } }
                $routes["GET /$Project/_apis/git/repositories/$repository/pullRequests/$($merged.Id)/workitems"] = @{ status = 200; body = @{ value = @($merged.WorkItems | ForEach-Object { @{ id = "$_" } }) } }
            }
        }
    }
    foreach ($id in $WorkItems.Keys) {
        $item = $WorkItems[$id]
        $type = if ($item.Type) { $item.Type } else { 'Task' }
        $format = if ($item.Format) { $item.Format } else { 'markdown' }
        $routes["GET /$Project/_apis/wit/workitems/$id"] = @{ status = 200; body = @{
                id = [int]$id; fields = @{ 'System.WorkItemType' = $type; 'System.Title' = "$($item.Title)"; 'System.Description' = "$($item.Description)" }
                multilineFieldsFormat = @{ 'System.Description' = $format }
            }
        }
    }
    $routes["POST /$Project/_apis/wit/workitems/`$Bug"] = @{ status = 200; body = @{ id = $NextWorkItem } }
    return $routes
}
