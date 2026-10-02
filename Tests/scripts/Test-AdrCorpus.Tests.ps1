#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Test-AdrCorpus.ps1

.DESCRIPTION
    Ogni test costruisce un repository git temporaneo con un bare repo come origin:
    il corpus di partenza vive su 'main', la PR e' un ramo che lo modifica. Lo script
    gira come in pipeline, con il ramo di destinazione della PR nell'ambiente.
#>

BeforeAll {
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../V3/CI/Scripts/Test-AdrCorpus.ps1"
    $DecisionsDirectory = 'docs/decisions'

    function New-Decision {
        param(
            [string]$Status = 'accepted',
            [string]$Supersedes,
            [string]$SupersededBy,
            [string[]]$Sections = @('Contesto e problema', 'Opzioni considerate', 'Esito della decisione'),
            [string]$Body = 'Testo della decisione.'
        )

        $frontmatter = @('---', "status: $Status", 'date: 2026-10-02')
        if ($Supersedes) { $frontmatter += "supersedes: $Supersedes" }
        if ($SupersededBy) { $frontmatter += "superseded-by: $SupersededBy" }
        $frontmatter += '---'
        $content = @($frontmatter) + @('', '# Titolo', '') + @($Sections | ForEach-Object { "## $_"; ''; $Body; '' })
        return ($content -join "`n")
    }

    function ConvertTo-Decisions([hashtable]$Parameters) {
        $decisions = @{}
        foreach ($name in $Parameters.Keys) {
            $decisionParameters = $Parameters[$name]
            $decisions[$name] = New-Decision @decisionParameters
        }
        return $decisions
    }

    function Write-Decisions([string]$RepoDir, [hashtable]$Decisions) {
        $directory = Join-Path $RepoDir $DecisionsDirectory
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
        foreach ($name in $Decisions.Keys) {
            $path = Join-Path $directory "$name.md"
            if ($null -eq $Decisions[$name]) { Remove-Item $path; continue }
            [IO.File]::WriteAllText($path, $Decisions[$name])
        }
    }

    function Invoke-Git([string]$RepoDir, [string[]]$Arguments) {
        Push-Location $RepoDir
        & git @Arguments 2>&1 | Out-Null
        Pop-Location
    }

    function New-PullRequestRepo {
        param([hashtable]$Main = @{}, [hashtable]$PullRequest = @{})

        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-adr-$(New-Guid)"
        $origin = Join-Path $root 'origin.git'
        $repo = Join-Path $root 'repo'
        git init --bare -q -b main $origin | Out-Null
        git init -q -b main $repo | Out-Null
        Invoke-Git $repo @('config', 'user.email', 'test@pester.local')
        Invoke-Git $repo @('config', 'user.name', 'Pester Test')
        Invoke-Git $repo @('remote', 'add', 'origin', $origin)

        [IO.File]::WriteAllText((Join-Path $repo 'README.md'), 'corpus')
        Write-Decisions $repo $Main
        Invoke-Git $repo @('add', '-A')
        Invoke-Git $repo @('commit', '-q', '-m', 'docs: base')
        Invoke-Git $repo @('push', '-q', 'origin', 'main')
        Invoke-Git $repo @('fetch', '-q', 'origin')

        Invoke-Git $repo @('checkout', '-q', '-b', 'pr')
        Write-Decisions $repo $PullRequest
        Invoke-Git $repo @('add', '-A')
        Invoke-Git $repo @('commit', '-q', '--allow-empty', '-m', 'docs: pr')
        return @{ Root = $root; Repo = $repo }
    }

    function Invoke-AdrCheck {
        param([hashtable]$Main = @{}, [hashtable]$PullRequest = @{}, [string]$Mode = '', [string]$TargetBranch = 'refs/heads/main')

        $fixture = New-PullRequestRepo -Main $Main -PullRequest $PullRequest
        Push-Location $fixture.Repo
        try {
            $env:GATE_MODE = $Mode
            $env:TARGET_BRANCH = $TargetBranch
            $env:DECISIONS_DIRECTORY = $DecisionsDirectory
            $output = & pwsh -NoProfile -NonInteractive -File $ScriptPath 2>&1
            return @{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
        }
        finally {
            Pop-Location
            $env:GATE_MODE = $env:TARGET_BRANCH = $env:DECISIONS_DIRECTORY = $null
            Remove-Item -Recurse -Force $fixture.Root -ErrorAction SilentlyContinue
        }
    }

    function Get-Issues([string]$Output, [string]$Level) {
        return @([regex]::Matches($Output, "##vso\[task\.logissue type=$Level\]([^\r\n]*)") | ForEach-Object { $_.Groups[1].Value })
    }
}


Describe "Funzionalità: Verifica del corpus delle decisioni architetturali" {

    Context "Scenario: decisione ben formata" {
        BeforeAll {
            $res = Invoke-AdrCheck -Main @{ '0001-esempio' = (New-Decision) } -PullRequest @{ '0008-esempio' = (New-Decision -Status proposed) }
        }

        It "Allora la verifica della PR riesce" {
            $res.ExitCode | Should -Be 0
            Get-Issues $res.Output 'error' | Should -BeNullOrEmpty
        }
    }

    Context "Schema dello scenario: decisione non ben formata — <Difetto>" -ForEach @(
        @{ Difetto = 'con stato "approvata"'; Motivo = 'stato non ammesso'
            Main = @{ '0001-esempio' = @{} }
            PullRequest = @{ '0008-esempio' = @{ Status = 'approvata' } } }
        @{ Difetto = 'con il numero di una decisione esistente'; Motivo = 'numero duplicato'
            Main = @{ '0008-altra' = @{} }
            PullRequest = @{ '0008-esempio' = @{ Status = 'proposed' } } }
        @{ Difetto = 'senza la sezione "Esito della decisione"'; Motivo = 'sezione mancante'
            Main = @{ '0001-esempio' = @{} }
            PullRequest = @{ '0008-esempio' = @{ Status = 'proposed'; Sections = @('Contesto e problema', 'Opzioni considerate') } } }
        @{ Difetto = 'che sostituisce una decisione che non la dichiara'; Motivo = 'sostituzione non reciproca'
            Main = @{ '0001-esempio' = @{} }
            PullRequest = @{ '0008-esempio' = @{ Supersedes = '0001-esempio' } } }
    ) {
        BeforeAll {
            $res = Invoke-AdrCheck -Main (ConvertTo-Decisions $Main) -PullRequest (ConvertTo-Decisions $PullRequest)
        }

        It "Allora la verifica della PR fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E il messaggio nomina '0008-esempio' e '<Motivo>'" {
            Get-Issues $res.Output 'error' | Where-Object { $_ -match '0008-esempio' -and $_ -match [regex]::Escape($Motivo) } | Should -Not -BeNullOrEmpty
        }
    }

    Context "Scenario: decisione accettata riscritta" {
        BeforeAll {
            $res = Invoke-AdrCheck -Main @{ '0001-esempio' = (New-Decision) } -PullRequest @{ '0001-esempio' = (New-Decision -Body 'Testo riscritto.') }
        }

        It "Allora la verifica della PR fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E il messaggio nomina '0001-esempio' e 'decisione accettata non modificabile'" {
            Get-Issues $res.Output 'error' | Where-Object { $_ -match '0001-esempio' -and $_ -match 'decisione accettata non modificabile' } | Should -Not -BeNullOrEmpty
        }
    }

    Context "Scenario: decisione accettata sostituita" {
        BeforeAll {
            $res = Invoke-AdrCheck -Main @{ '0001-esempio' = (New-Decision) } -PullRequest @{
                '0009-esempio' = (New-Decision -Supersedes '0001-esempio')
                '0001-esempio' = (New-Decision -Status superseded -SupersededBy '0009-esempio')
            }
        }

        It "Allora la verifica della PR riesce" {
            $res.ExitCode | Should -Be 0
            Get-Issues $res.Output 'error' | Should -BeNullOrEmpty
        }
    }

    Context "Scenario: consumer che sceglie l'avviso" {
        BeforeAll {
            $res = Invoke-AdrCheck -Mode warn -PullRequest @{ '0008-esempio' = (New-Decision -Status approvata) }
        }

        It "Allora la verifica della PR non fallisce" {
            $res.ExitCode | Should -Be 0
        }

        It "E la PR riceve l'avviso 'stato non ammesso'" {
            Get-Issues $res.Output 'warning' | Where-Object { $_ -match 'stato non ammesso' } | Should -Not -BeNullOrEmpty
            $res.Output | Should -Match ([regex]::Escape('##vso[task.complete result=SucceededWithIssues;]'))
        }
    }
}


Describe "Test-AdrCorpus — regole del corpus" {

    It "Una decisione accettata eliminata conta come riscritta" {
        $res = Invoke-AdrCheck -Main @{ '0001-esempio' = (New-Decision) } -PullRequest @{ '0001-esempio' = $null }

        $res.ExitCode | Should -Be 1
        Get-Issues $res.Output 'error' | Where-Object { $_ -match '0001-esempio' -and $_ -match 'decisione accettata non modificabile' } | Should -Not -BeNullOrEmpty
    }

    It "Una decisione proposta si puo' riscrivere" {
        $res = Invoke-AdrCheck -Main @{ '0001-esempio' = (New-Decision -Status proposed) } -PullRequest @{ '0001-esempio' = (New-Decision -Status accepted -Body 'Testo riscritto.') }

        $res.ExitCode | Should -Be 0
    }

    It "Una decisione sostituita deve nominare chi la sostituisce davvero" {
        $res = Invoke-AdrCheck -PullRequest @{ '0001-esempio' = (New-Decision -Status superseded -SupersededBy '0009-inesistente') }

        Get-Issues $res.Output 'error' | Where-Object { $_ -match '0001-esempio' -and $_ -match 'sostituzione non reciproca' } | Should -Not -BeNullOrEmpty
    }

    It "Un file senza frontmatter e' una decisione con stato non ammesso" {
        $res = Invoke-AdrCheck -PullRequest @{ '0002-senza-frontmatter' = "# Titolo`n`n## Contesto e problema`n`n## Opzioni considerate`n`n## Esito della decisione`n" }

        Get-Issues $res.Output 'error' | Where-Object { $_ -match '0002-senza-frontmatter' -and $_ -match 'stato non ammesso' } | Should -Not -BeNullOrEmpty
    }

    It "I file che non sono decisioni numerate non si verificano" {
        $res = Invoke-AdrCheck -PullRequest @{ 'README' = '# Indice'; 'template' = '# Template' }

        $res.ExitCode | Should -Be 0
    }

    It "Fuori da una PR la verifica di immutabilita' non si applica" {
        $res = Invoke-AdrCheck -TargetBranch '$(System.PullRequest.TargetBranch)' -Main @{ '0001-esempio' = (New-Decision) } -PullRequest @{ '0001-esempio' = (New-Decision -Body 'Testo riscritto.') }

        $res.ExitCode | Should -Be 0
        $res.Output | Should -Not -Match 'non leggibile'
    }

    It "Con la modalita' 'off' non si verifica nulla" {
        $res = Invoke-AdrCheck -Mode off -PullRequest @{ '0008-esempio' = (New-Decision -Status approvata) }

        $res.ExitCode | Should -Be 0
        Get-Issues $res.Output '(error|warning)' | Should -BeNullOrEmpty
    }

    It "Ogni difetto ha la propria segnalazione" {
        $res = Invoke-AdrCheck -PullRequest @{
            '0003-a' = (New-Decision -Status approvata)
            '0004-b' = (New-Decision -Sections 'Contesto e problema')
        }

        (Get-Issues $res.Output 'error').Count | Should -Be 3
    }
}
