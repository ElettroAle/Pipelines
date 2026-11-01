# SPDX-License-Identifier: Apache-2.0

#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/AzureRepos/Get-TriggeringRepository.ps1

.DESCRIPTION
    L'API delle run e' un endpoint locale (Fixtures/BuildStub.ps1) che restituisce la run scritta dalla
    prova e registra le richieste; le prove verificano la variabile di output che lo script scrive.
#>

BeforeAll {
    $script:Script = Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts/AzureRepos/Get-TriggeringRepository.ps1"
    $script:StubState = Join-Path ([IO.Path]::GetTempPath()) "pester-trigger-$(New-Guid)"
    New-Item -ItemType Directory -Path $StubState | Out-Null
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
    $script:StubEndpoint = "http://127.0.0.1:$port"
    $stubScript = Resolve-Path "$PSScriptRoot/Fixtures/BuildStub.ps1"
    $script:Stub = Start-ThreadJob -ArgumentList $StubEndpoint, $StubState, "$stubScript" -ScriptBlock {
        param($Endpoint, $State, $Script)
        & $Script $Endpoint $State
    }

    function Set-Run([hashtable]$Run, [int]$Status = 200) {
        Get-ChildItem $StubState -File | Remove-Item -Force
        [IO.File]::WriteAllText((Join-Path $StubState 'build.json'), ($Run | ConvertTo-Json -Depth 5))
        if ($Status -ne 200) { [IO.File]::WriteAllText((Join-Path $StubState 'status'), "$Status") }
    }

    function Get-StubRequests {
        return @(Get-ChildItem $StubState -Filter 'request-*.json' | ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json })
    }

    function Invoke-Script {
        $variables = @{
            SYSTEM_COLLECTIONURI = "$StubEndpoint/org/"; SYSTEM_TEAMPROJECT = 'Aidea Dxp'
            SYSTEM_ACCESSTOKEN = 'token-di-prova'; BUILD_BUILDID = '8912'
        }
        $previous = @{}
        foreach ($name in $variables.Keys) { $previous[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $variables[$name]) }
        try {
            $output = & pwsh -NoProfile -File $Script 2>&1 | Out-String
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
        }
        finally {
            foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
        }
    }
}

AfterAll {
    New-Item -ItemType File -Path (Join-Path $StubState 'stop') -Force | Out-Null
    $Stub | Wait-Job -Timeout 10 | Out-Null
    $Stub | Remove-Job -Force
    Remove-Item -Recurse -Force $StubState -ErrorAction SilentlyContinue
}

Describe 'Funzionalità: Repository che ha avviato la run' {

    Context 'Scenario: un merge in un repository resource avvia la run' {
        BeforeAll {
            Set-Run @{ id = 8912; reason = 'individualCI'; repository = @{ name = 'Aidea.Dxp.Architecture' }; triggerInfo = @{ 'ci.triggerRepository' = '56BE1403-84E9-4789-807E-6D21149C03D0'; 'ci.sourceBranch' = 'refs/heads/main' } }
            $script:Result = Invoke-Script
            $script:Requests = Get-StubRequests
        }

        It 'Allora la variabile di output id porta l''id del repository che ha avviato la run, in minuscolo' {
            $Result.ExitCode | Should -Be 0
            $Result.Output | Should -Match ([regex]::Escape('##vso[task.setvariable variable=id;isOutput=true]56be1403-84e9-4789-807e-6d21149c03d0'))
        }

        It 'E legge la run corrente nel progetto della pipeline' {
            $Requests.Count | Should -Be 1
            $Requests[0].method | Should -Be 'GET'
            $Requests[0].url | Should -BeLike '/org/Aidea%20Dxp/_apis/build/builds/8912?api-version=7.1'
        }

        It 'E si autentica con il token della build' {
            $Requests[0].authorization | Should -Be 'Bearer token-di-prova'
        }
    }

    Context 'Scenario: la run e'' avviata a mano' {
        BeforeAll {
            Set-Run @{ id = 8914; reason = 'manual'; repository = @{ name = 'Aidea.Dxp.Architecture' }; triggerInfo = @{} }
            $script:Result = Invoke-Script
        }

        It 'Allora la variabile di output id e'' vuota' {
            $Result.ExitCode | Should -Be 0
            $Result.Output | Should -Match ([regex]::Escape('##vso[task.setvariable variable=id;isOutput=true]') + '\r?\n')
        }

        It 'E il log dice che la run non viene da un trigger di repository' {
            $Result.Output | Should -Match 'non viene da un trigger di repository'
        }
    }

    Context 'Scenario: l''API delle run rifiuta la richiesta' {
        BeforeAll {
            Set-Run @{} -Status 401
            $script:Result = Invoke-Script
        }

        It 'Allora lo script fallisce senza scrivere la variabile di output' {
            $Result.ExitCode | Should -Not -Be 0
            $Result.Output | Should -Not -Match 'task.setvariable'
        }
    }
}
