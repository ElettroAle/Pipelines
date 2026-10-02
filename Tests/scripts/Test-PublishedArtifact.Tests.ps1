#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Test-PublishedArtifact.ps1

.DESCRIPTION
    L'API Build e' un HttpListener locale che risponde con gli artifact della run
    tenuti in memoria, o con un errore: nessuna chiamata esce dalla macchina.
#>

BeforeAll {
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../V3/CI/Scripts/Test-PublishedArtifact.ps1"

    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()

    $BuildApi = [hashtable]::Synchronized(@{ Artifacts = @(); StatusCode = 200; Requests = [Collections.ArrayList]::Synchronized([Collections.ArrayList]::new()) })
    $ApiListener = [System.Net.HttpListener]::new()
    $ApiListener.Prefixes.Add("http://localhost:$port/")
    $ApiListener.Start()
    $ApiServer = Start-ThreadJob -ArgumentList $ApiListener, $BuildApi -ScriptBlock {
        param($listener, $api)
        while ($listener.IsListening) {
            try { $context = $listener.GetContext() } catch { break }
            $api.Requests.Add(@{ Path = $context.Request.Url.AbsolutePath; Authorization = $context.Request.Headers['Authorization'] }) | Out-Null
            $response = $context.Response
            $response.StatusCode = $api.StatusCode
            if ($api.StatusCode -eq 200) {
                $value = @($api.Artifacts | ForEach-Object { @{ name = $_; resource = @{ type = 'PipelineArtifact' } } })
                $bytes = [Text.Encoding]::UTF8.GetBytes((@{ count = $value.Count; value = $value } | ConvertTo-Json -Depth 4))
                $response.ContentType = 'application/json'
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            $response.Close()
        }
    }

    function Invoke-ArtifactCheck([string]$ArtifactName) {
        $env:ARTIFACT_NAME = $ArtifactName
        $env:SYSTEM_COLLECTIONURI = "http://localhost:$port/"
        $env:SYSTEM_TEAMPROJECT = 'Aidea.Dxp'
        $env:BUILD_BUILDID = '4946'
        $env:SYSTEM_ACCESSTOKEN = 'token-di-test'
        try {
            $output = & pwsh -NoProfile -NonInteractive -File $ScriptPath 2>&1
            return @{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
        }
        finally {
            $env:ARTIFACT_NAME = $env:SYSTEM_COLLECTIONURI = $env:SYSTEM_TEAMPROJECT = $env:BUILD_BUILDID = $env:SYSTEM_ACCESSTOKEN = $null
        }
    }

    function Get-AlreadyPublished([string]$Output) {
        if ($Output -match '##vso\[task\.setvariable variable=artifactAlreadyPublished\](\w+)') { return $Matches[1] }
        return $null
    }
}

AfterAll {
    $ApiListener.Stop()
    $ApiServer | Wait-Job -Timeout 10 | Remove-Job -Force
}


Describe "Funzionalità: Rerun dello stage di publish con artifact già pubblicato" {

    Context "Scenario: rerun dopo un caricamento riuscito" {
        BeforeAll {
            $BuildApi.StatusCode = 200
            $BuildApi.Artifacts = @('app-production-2.2.0')
            $Rerun = Invoke-ArtifactCheck 'app-production-2.2.0'
        }

        It "Allora il caricamento dell'artifact viene saltato" {
            Get-AlreadyPublished $Rerun.Output | Should -Be 'true'
        }

        It "E il log dichiara che 'app-production-2.2.0' è già pubblicato nella run" {
            $Rerun.Output | Should -Match "app-production-2\.2\.0.*gia' pubblicato"
        }
    }

    Context "Scenario: prima esecuzione" {
        BeforeAll {
            $BuildApi.StatusCode = 200
            $BuildApi.Artifacts = @()
            $FirstRun = Invoke-ArtifactCheck 'app-production-2.2.0'
        }

        It "Allora l'artifact viene caricato" {
            Get-AlreadyPublished $FirstRun.Output | Should -Be 'false'
        }
    }

    Context "Scenario: verifica non disponibile" {
        BeforeAll {
            $BuildApi.StatusCode = 500
            $FailedCheck = Invoke-ArtifactCheck 'app-production-2.2.0'
        }

        It "Allora l'artifact viene caricato" {
            Get-AlreadyPublished $FailedCheck.Output | Should -Be 'false'
        }

        It "E il log segnala che la verifica non è riuscita" {
            $FailedCheck.Output | Should -Match '##vso\[task\.logissue type=warning\]'
        }
    }
}


Describe "Test-PublishedArtifact — interrogazione dell'API" {

    BeforeEach {
        $BuildApi.StatusCode = 200
        $BuildApi.Requests.Clear()
    }

    It "Interroga gli artifact della run corrente con il token della pipeline" {
        $BuildApi.Artifacts = @()
        Invoke-ArtifactCheck 'app-production-2.2.0' | Out-Null

        $BuildApi.Requests[0].Path | Should -Be '/Aidea.Dxp/_apis/build/builds/4946/artifacts'
        $BuildApi.Requests[0].Authorization | Should -Be 'Bearer token-di-test'
    }

    It "Un artifact con un altro nome non conta come gia' pubblicato" {
        $BuildApi.Artifacts = @('app-production-2.1.0', 'app-production-2.2.0-extra')
        $res = Invoke-ArtifactCheck 'app-production-2.2.0'

        Get-AlreadyPublished $res.Output | Should -Be 'false'
    }

    It "Non fallisce mai lo step, nemmeno quando l'API risponde con un errore" {
        $BuildApi.StatusCode = 401
        $res = Invoke-ArtifactCheck 'app-production-2.2.0'

        $res.ExitCode | Should -Be 0
    }
}
