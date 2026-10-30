#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Test-Arc42Document.ps1

.DESCRIPTION
    Il template e' l'archivio ufficiale italiano della release fissata nello script, servito da
    un HttpListener locale al posto di GitHub: lo SHA-256 verificato e' quello vero, e nessuna
    prova scarica dalla rete.
#>

BeforeAll {
    . "$PSScriptRoot/../Fixtures/Documentation/DocumentationFixture.ps1"
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../V3/CI/Scripts/Test-Arc42Document.ps1"
    $ExpectedPath = '/2026.10.19/arc42-template-IT-plain-markdownMP.zip'

    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()

    $Releases = [hashtable]::Synchronized(@{ Archive = [IO.File]::ReadAllBytes($Arc42TemplateArchive); Requests = [Collections.ArrayList]::Synchronized([Collections.ArrayList]::new()) })
    $ReleasesListener = [System.Net.HttpListener]::new()
    $ReleasesListener.Prefixes.Add("http://localhost:$port/")
    $ReleasesListener.Start()
    $ReleasesServer = Start-ThreadJob -ArgumentList $ReleasesListener, $Releases -ScriptBlock {
        param($listener, $releases)
        while ($listener.IsListening) {
            try { $context = $listener.GetContext() } catch { break }
            $releases.Requests.Add($context.Request.Url.AbsolutePath) | Out-Null
            $response = $context.Response
            $response.ContentType = 'application/zip'
            $response.OutputStream.Write($releases.Archive, 0, $releases.Archive.Length)
            $response.Close()
        }
    }

    function Invoke-Arc42Check([System.Collections.IDictionary]$Docs, [hashtable]$Environment = @{}) {
        $Releases.Requests.Clear()
        $variables = @{ GATE_MODE = ''; ARC42_LANGUAGE = 'IT'; ARC42_RELEASES_URL = "http://localhost:$port" }
        foreach ($name in $Environment.Keys) { $variables[$name] = $Environment[$name] }
        return Invoke-DocsScript $ScriptPath $Docs $variables
    }
}

AfterAll {
    $ReleasesListener.Stop()
    $ReleasesServer | Wait-Job -Timeout 10 | Remove-Job -Force
}


Describe "Funzionalità: Struttura del documento sul template arc42" {

    Context "Scenario: documento con le sezioni del template" {
        BeforeAll {
            $res = Invoke-Arc42Check (New-ValidDocs)
        }

        It "Allora la verifica passa" {
            Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
            $res.ExitCode | Should -Be 0
        }

        It "E il template e' quello della release fissata nella lingua del documento" {
            $Releases.Requests | Should -Be @($ExpectedPath)
        }
    }

    Context "Schema dello scenario: documento fuori dal template — <difetto>" -ForEach @(
        @{
            difetto  = 'la sezione "Deployment View" mancante'
            elemento = '^documento: sezione mancante \(07_deployment_view\.md: Deployment View\)'
            Mutate   = { param($d) $d['docs/architecture/07_deployment_view.md'] = $null }
        }
        @{
            difetto  = 'un file numerato che il template non ha'
            elemento = '^documento: sezione fuori template \(13_extra\.md: Appendice\)'
            Mutate   = { param($d) $d['docs/architecture/13_extra.md'] = "# Appendice`n" }
        }
        @{
            difetto  = 'un titolo diverso da quello del template'
            elemento = '^documento: titolo diverso dal template \(02_architecture_constraints\.md: Vincoli, atteso «Vincoli di architettura»\)'
            Mutate   = { param($d) Edit-Docs $d 'docs/architecture/02_architecture_constraints.md' '# Vincoli di architettura' '# Vincoli' }
        }
    ) {
        BeforeAll {
            $docs = New-ValidDocs
            & $Mutate $docs
            $res = Invoke-Arc42Check $docs
        }

        It "Allora la verifica fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina il file e il motivo" {
            Get-Issues $res.Output | Where-Object { $_ -match $elemento } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    It "Un titolo che conserva l'attributo del template passa" {
        $docs = New-ValidDocs
        Edit-Docs $docs 'docs/architecture/02_architecture_constraints.md' '# Vincoli di architettura' '# Vincoli di architettura {#section-architecture-constraints}'
        $res = Invoke-Arc42Check $docs
        Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
        $res.ExitCode | Should -Be 0
    }

    It "Un file non numerato accanto alle sezioni non e' una sezione" {
        $docs = New-ValidDocs
        $docs['docs/architecture/README.md'] = "# Come leggere il documento`n"
        $res = Invoke-Arc42Check $docs
        Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
    }
}

Describe "Test-Arc42Document — template della release fissata" {

    It "Una lingua senza template fallisce nominando la lingua e quelle ammesse, senza scaricare" {
        $res = Invoke-Arc42Check (New-ValidDocs) @{ ARC42_LANGUAGE = 'XX' }
        $res.ExitCode | Should -Be 1
        Get-Issues $res.Output | Where-Object { $_ -match '^template arc42: lingua non supportata \(«XX», ammesse: AZ, .*\bIT\b' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        $Releases.Requests | Should -BeNullOrEmpty
    }

    It "Un archivio con SHA-256 diverso da quello fissato fallisce nominando i due valori" {
        $Releases.Archive = [Text.Encoding]::UTF8.GetBytes('non e'' il template')
        try { $res = Invoke-Arc42Check (New-ValidDocs) }
        finally { $Releases.Archive = [IO.File]::ReadAllBytes($Arc42TemplateArchive) }
        $res.ExitCode | Should -Be 1
        Get-Issues $res.Output | Where-Object { $_ -match '^template arc42: SHA-256 diverso \(.+, atteso bdcf1cefe5402fa15bb981a2e178c8714f1137992a38b267ad2de4ff09029d5a, ricevuto [0-9a-f]{64}\)' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
    }

    It "Un template che non si scarica fallisce nominando l'indirizzo" {
        $res = Invoke-Arc42Check (New-ValidDocs) @{ ARC42_RELEASES_URL = 'http://127.0.0.1:9' }
        $res.ExitCode | Should -Be 1
        Get-Issues $res.Output | Where-Object { $_ -match "^template arc42: download non riuscito \(http://127\.0\.0\.1:9$([regex]::Escape($ExpectedPath)): " } | Should -Not -BeNullOrEmpty -Because ($res.Output)
    }
}

Describe "Test-Arc42Document — modalità del controllo" {

    BeforeAll {
        $docs = New-ValidDocs
        $docs['docs/architecture/07_deployment_view.md'] = $null
    }

    It "In modalità warn segnala come warning e non blocca" {
        $res = Invoke-Arc42Check $docs @{ GATE_MODE = 'warn' }
        $res.ExitCode | Should -Be 0
        Get-Issues $res.Output 'warning' | Should -Not -BeNullOrEmpty
        $res.Output | Should -Match 'task\.complete result=SucceededWithIssues'
    }

    It "In modalità off non verifica e non scarica il template" {
        $res = Invoke-Arc42Check $docs @{ GATE_MODE = 'off' }
        $res.ExitCode | Should -Be 0
        Get-Issues $res.Output | Should -BeNullOrEmpty
        $Releases.Requests | Should -BeNullOrEmpty
    }
}
