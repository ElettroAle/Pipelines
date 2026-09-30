#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/New-ReleaseNotes.ps1

.DESCRIPTION
    Ogni test costruisce un repository git temporaneo con la storia GitFlow
    desiderata (tag su staging, merge di promozione su main), esegue lo script e
    verifica il file delle note, il comando di upload del summary e l'esito.
    Il wiki e' un HttpListener locale che tiene le pagine in memoria: nessuna
    chiamata esce dalla macchina.
#>

BeforeAll {
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../V3/CI/Scripts/New-ReleaseNotes.ps1"

    function New-TestRepo {
        $repoPath = Join-Path ([System.IO.Path]::GetTempPath()) "pester-notes-$(New-Guid)"
        New-Item -ItemType Directory -Path $repoPath | Out-Null
        Push-Location $repoPath
        git init -q -b main | Out-Null
        git config user.email "test@pester.local"
        git config user.name "Pester Test"
        Pop-Location
        return $repoPath
    }

    function Add-Commit([string]$RepoDir, [string]$Message) {
        Push-Location $RepoDir
        git commit -q --allow-empty -m $Message | Out-Null
        Pop-Location
    }

    function Invoke-Git([string]$RepoDir, [string[]]$Arguments) {
        Push-Location $RepoDir
        & git @Arguments 2>&1 | Out-Null
        Pop-Location
    }

    function Invoke-ReleaseNotes {
        param(
            [string]$RepoDir,
            [string]$Tag,
            [string]$WikiPagePath = "",
            [string]$SourceBranch = "refs/heads/staging",
            [string]$GitCliffPath = ""
        )

        $outputDir = Join-Path ([System.IO.Path]::GetTempPath()) "pester-notes-out-$(New-Guid)"
        Push-Location $RepoDir
        $previousCliffPath = $env:GIT_CLIFF_PATH
        try {
            $env:RELEASE_TAG = $Tag
            $env:OUTPUT_DIR = $outputDir
            $env:WIKI_PAGE_PATH = $WikiPagePath
            $env:BUILD_SOURCEBRANCH = $SourceBranch
            if ($GitCliffPath) { $env:GIT_CLIFF_PATH = $GitCliffPath }

            $output = & pwsh -NoProfile -NonInteractive -File $ScriptPath 2>&1
            $exitCode = $LASTEXITCODE
            $notesPath = Join-Path $outputDir 'Release notes.md'
            $notes = if (Test-Path $notesPath) { Get-Content -Raw -Encoding UTF8 $notesPath } else { $null }
            return @{ ExitCode = $exitCode; Output = ($output -join "`n"); Notes = $notes }
        }
        finally {
            Pop-Location
            $env:GIT_CLIFF_PATH = $previousCliffPath
            $env:RELEASE_TAG = $env:OUTPUT_DIR = $env:WIKI_PAGE_PATH = $env:BUILD_SOURCEBRANCH = $null
            Remove-Item -Recurse -Force $outputDir -ErrorAction SilentlyContinue
        }
    }

    function Remove-TestRepo([string]$Path) {
        Remove-Item -Recurse -Force $Path -ErrorAction SilentlyContinue
    }
}


Describe "New-ReleaseNotes — contenuto" {

    It "Raggruppa per tipo con scope e numero della PR" {
        $repo = New-TestRepo
        Add-Commit $repo "chore: base"
        Invoke-Git $repo @('tag', '1.0.0')
        Add-Commit $repo "Merged PR 12: fix(api): null check"
        Add-Commit $repo "Merged PR 13: feat(worker)!: nuova coda"
        Add-Commit $repo "Merged PR 14: docs: readme"
        Invoke-Git $repo @('tag', '2.0.0')

        $res = Invoke-ReleaseNotes -RepoDir $repo -Tag "2.0.0"
        Remove-TestRepo $repo

        $res.ExitCode | Should -Be 0
        $res.Notes | Should -Match "## 2\.0\.0"
        $res.Notes | Should -Match "### Breaking\s+- \*\*worker\*\*: nuova coda \(PR 13\)"
        $res.Notes | Should -Match "### Fix\s+- \*\*api\*\*: null check \(PR 12\)"
        $res.Notes | Should -Match "### Manutenzione\s+- readme \(PR 14\)"
        $res.Notes | Should -Not -Match "base"
    }

    It "Solo commit non convenzionali: finiscono in 'Altre modifiche'" {
        $repo = New-TestRepo
        Add-Commit $repo "chore: base"
        Invoke-Git $repo @('tag', '1.0.0')
        Add-Commit $repo "Merged PR 20: sistemato il login"
        Invoke-Git $repo @('tag', '1.0.1')

        $res = Invoke-ReleaseNotes -RepoDir $repo -Tag "1.0.1"
        Remove-TestRepo $repo

        $res.Notes | Should -Match "### Altre modifiche\s+- sistemato il login \(PR 20\)"
    }

    It "Su main copre le versioni di staging promosse dall'ultimo rilascio e salta i merge" {
        $repo = New-TestRepo
        Add-Commit $repo "chore: base"
        Invoke-Git $repo @('checkout', '-q', '-b', 'staging')
        Add-Commit $repo "Merged PR 1: feat: gia' in prod"
        Invoke-Git $repo @('tag', '1.0.0')
        Invoke-Git $repo @('checkout', '-q', 'main')
        Invoke-Git $repo @('merge', '-q', '--no-ff', 'staging', '-m', 'Merged PR 100: First release')
        Invoke-Git $repo @('checkout', '-q', 'staging')
        Add-Commit $repo "Merged PR 2: fix(bff): timeout"
        Invoke-Git $repo @('tag', '1.0.1')
        Add-Commit $repo "Merged PR 3: feat(fe): tema scuro"
        Invoke-Git $repo @('tag', '1.1.0')
        Invoke-Git $repo @('checkout', '-q', 'main')
        Invoke-Git $repo @('merge', '-q', '--no-ff', 'staging', '-m', 'Merged PR 101: Release 1.1')

        $res = Invoke-ReleaseNotes -RepoDir $repo -Tag "1.1.0" -SourceBranch "refs/heads/main"
        Remove-TestRepo $repo

        $res.Output | Should -Match "Range delle release notes: 1\.0\.0\.\.HEAD"
        $res.Notes | Should -Match "## 1\.1\.0"
        $res.Notes | Should -Match "## 1\.0\.1"
        $res.Notes | Should -Match "tema scuro"
        $res.Notes | Should -Match "timeout"
        $res.Notes | Should -Not -Match "gia' in prod"
        $res.Notes | Should -Not -Match "Release 1\.1"
    }

    It "Remote Azure DevOps: il numero della PR diventa un link alla PR" {
        $repo = New-TestRepo
        Invoke-Git $repo @('remote', 'add', 'origin', 'https://Org@dev.azure.com/Org/Proj/_git/Repo')
        Add-Commit $repo "chore: base"
        Invoke-Git $repo @('tag', '1.0.0')
        Add-Commit $repo "Merged PR 12: fix: null check"

        $res = Invoke-ReleaseNotes -RepoDir $repo -Tag "1.0.1"
        Remove-TestRepo $repo

        $res.Notes | Should -Match ([regex]::Escape("([PR 12](https://dev.azure.com/Org/Proj/_git/Repo/pullrequest/12))"))
    }

    It "Remote GitHub: il link punta a /pull/<n>" {
        $repo = New-TestRepo
        Invoke-Git $repo @('remote', 'add', 'origin', 'https://github.com/Owner/Repo.git')
        Add-Commit $repo "chore: base"
        Invoke-Git $repo @('tag', '1.0.0')
        Add-Commit $repo "Merged PR 7: feat: nuova"

        $res = Invoke-ReleaseNotes -RepoDir $repo -Tag "1.1.0"
        Remove-TestRepo $repo

        $res.Notes | Should -Match ([regex]::Escape("([PR 7](https://github.com/Owner/Repo/pull/7))"))
    }
}


Describe "New-ReleaseNotes — pubblicazione" {

    It "Carica le note nel summary della run" {
        $repo = New-TestRepo
        Add-Commit $repo "feat: primo"

        $res = Invoke-ReleaseNotes -RepoDir $repo -Tag "0.1.0"
        Remove-TestRepo $repo

        $res.Output | Should -Match "##vso\[task\.uploadsummary\].*Release notes\.md"
    }

    It "Wiki richiesto ma run non su main: nessun tentativo di scrittura" {
        $repo = New-TestRepo
        Add-Commit $repo "feat: primo"

        $res = Invoke-ReleaseNotes -RepoDir $repo -Tag "0.1.0" -WikiPagePath "/Release notes/App" -SourceBranch "refs/heads/staging"
        Remove-TestRepo $repo

        $res.ExitCode | Should -Be 0
        $res.Output | Should -Not -Match "wiki"
        $res.Output | Should -Not -Match "SucceededWithIssues"
    }

    It "Errore nella generazione: exit 0 con warning, il publish prosegue" {
        $repo = New-TestRepo
        Add-Commit $repo "feat: primo"

        $res = Invoke-ReleaseNotes -RepoDir $repo -Tag "0.1.0" -GitCliffPath (Join-Path $repo 'git-cliff-inesistente')
        Remove-TestRepo $repo

        $res.ExitCode | Should -Be 0
        $res.Output | Should -Match "##vso\[task\.logissue type=warning\]Release notes non pubblicate"
        $res.Output | Should -Match "##vso\[task\.complete result=SucceededWithIssues;\]"
    }
}


Describe "Funzionalità: Note di rilascio del repository AI" {

    BeforeAll {
        $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()

        $WikiPages = [hashtable]::Synchronized(@{})
        $WikiListener = [System.Net.HttpListener]::new()
        $WikiListener.Prefixes.Add("http://localhost:$port/")
        $WikiListener.Start()
        $WikiServer = Start-ThreadJob -ArgumentList $WikiListener, $WikiPages -ScriptBlock {
            param($listener, $pages)
            while ($listener.IsListening) {
                try { $context = $listener.GetContext() } catch { break }
                $pagePath = [uri]::UnescapeDataString(($context.Request.Url.Query -replace '^.*[?&]path=([^&]*).*$', '$1'))
                $response = $context.Response
                if ($context.Request.HttpMethod -eq 'PUT') {
                    $body = [IO.StreamReader]::new($context.Request.InputStream).ReadToEnd() | ConvertFrom-Json
                    $pages[$pagePath] = $body.content
                    $response.StatusCode = 201
                }
                elseif ($pages.ContainsKey($pagePath)) {
                    $bytes = [Text.Encoding]::UTF8.GetBytes((@{ content = $pages[$pagePath] } | ConvertTo-Json))
                    $response.Headers['ETag'] = '"1"'
                    $response.ContentType = 'application/json'
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                }
                else {
                    $response.StatusCode = 404
                }
                $response.Close()
            }
        }

        function Invoke-ProdPublish([string]$RepoDir) {
            $env:SYSTEM_COLLECTIONURI = "http://localhost:$port/"
            $env:SYSTEM_TEAMPROJECT = 'Aidea.Dxp'
            $env:SYSTEM_ACCESSTOKEN = 'token-di-test'
            try {
                return Invoke-ReleaseNotes -RepoDir $RepoDir -Tag "1.4.0" -WikiPagePath "/Release notes/AI" -SourceBranch "refs/heads/main"
            }
            finally {
                $env:SYSTEM_COLLECTIONURI = $env:SYSTEM_TEAMPROJECT = $env:SYSTEM_ACCESSTOKEN = $null
            }
        }

        function Get-VersionSectionCount([string]$Version) {
            return ([regex]::Matches([string]$WikiPages['/Release notes/AI'], "(?m)^## $([regex]::Escape($Version))( |$)")).Count
        }

        $AiRepo = New-TestRepo
        Add-Commit $AiRepo "feat: nuova capacità"
    }

    AfterAll {
        $WikiListener.Stop()
        $WikiServer | Wait-Job -Timeout 10 | Remove-Job -Force
        Remove-TestRepo $AiRepo
    }

    Context "Scenario: prima publish della versione" {
        BeforeAll {
            $WikiPages.Clear()
            $EngineRun = Invoke-ProdPublish $AiRepo
        }

        It "Quando la publish di prod di Engine rilascia '1.4.0', la pubblicazione riesce" {
            $EngineRun.Output | Should -Not -Match "SucceededWithIssues"
        }

        It "Allora la pagina '/Release notes/AI' contiene la sezione '1.4.0'" {
            Get-VersionSectionCount "1.4.0" | Should -Be 1
        }
    }

    Context "Scenario: seconda publish della stessa versione" {
        BeforeAll {
            $WikiPages.Clear()
            Invoke-ProdPublish $AiRepo | Out-Null
            $WorkerRun = Invoke-ProdPublish $AiRepo
        }

        It "Dato la pagina '/Release notes/AI' con la sezione '1.4.0', la publish di Worker riesce" {
            $WorkerRun.Output | Should -Not -Match "SucceededWithIssues"
        }

        It "Allora la pagina '/Release notes/AI' contiene una sola sezione '1.4.0'" {
            Get-VersionSectionCount "1.4.0" | Should -Be 1
        }
    }
}
