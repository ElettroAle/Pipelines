#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Verify-SemVer.ps1

.DESCRIPTION
    Strategia: ogni Context crea un repository git temporaneo reale, imposta
    le variabili d'ambiente che lo script si aspetta, esegue lo script e verifica
    l'exit code e i messaggi di output.

    Lo script non ha dipendenze esterne oltre a 'git', quindi non sono necessari
    altri mock.
#>

BeforeAll {
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../V3/CI/Scripts/Verify-SemVer.ps1"

    # Helper: crea un repo git temporaneo con un commit avente il messaggio indicato
    function New-TempGitRepo {
        param(
            [string]$CommitMessage,
            [switch]$WithMergeCommit  # Se true, aggiunge un merge commit sopra il commit reale
        )

        $repoDir = Join-Path ([System.IO.Path]::GetTempPath()) "pester-verify-$(New-Guid)"
        New-Item -ItemType Directory -Path $repoDir | Out-Null

        Push-Location $repoDir
        git init -q
        git config user.email "test@pester.local"
        git config user.name "Pester Test"

        # Commit iniziale (necessario per poter fare merge)
        "init" | Set-Content "init.txt"
        git add . | Out-Null
        git commit -m "chore: initial commit" -q | Out-Null

        if ($WithMergeCommit) {
            # Simula un merge: crea branch secondario, poi merge
            git checkout -b feature-branch -q | Out-Null
            "feature" | Set-Content "feature.txt"
            git add . | Out-Null
            git commit -m $CommitMessage -q | Out-Null   # <-- il commit reale è qui

            git checkout main -q 2>$null
            if ($LASTEXITCODE -ne 0) { git checkout master -q 2>$null }

            # Merge senza fast-forward per creare un merge commit
            git merge feature-branch --no-ff -m "Merge branch 'feature-branch'" -q | Out-Null
        }
        else {
            # Commit normale con il messaggio di test
            "change" | Set-Content "change.txt"
            git add . | Out-Null
            git commit -m $CommitMessage -q | Out-Null
        }

        Pop-Location
        return $repoDir
    }

    # Helper: esegue lo script nel repo indicato e restituisce exit code + output
    function Invoke-VerifySemVer {
        param(
            [string]$RepoDir,
            [string]$TargetBranch,
            [string]$AdditionalBranches = ""
        )

        Push-Location $RepoDir
        try {
            $env:TARGET_BRANCH = $TargetBranch
            $env:ADDITIONAL_TAG_BRANCHES = $AdditionalBranches

            $output = & pwsh -NoProfile -NonInteractive -File $ScriptPath 2>&1
            $exitCode = $LASTEXITCODE

            return @{ ExitCode = $exitCode; Output = $output -join "`n" }
        }
        finally {
            Pop-Location
            $env:TARGET_BRANCH = $null
            $env:ADDITIONAL_TAG_BRANCHES = $null
        }
    }

    # Helper: pulizia repo temporanei
    function Remove-TempRepo([string]$Path) {
        if (Test-Path $Path) {
            Remove-Item -Recurse -Force $Path -ErrorAction SilentlyContinue
        }
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# SUITE 1: Branch protetti core (main, staging)
# ─────────────────────────────────────────────────────────────────────────────

Describe "Verify-SemVer — Branch protetti (main, staging)" {

    Context "Commit validi su 'main'" {

        It "Accetta 'fix: ...' su main" {
            $repo = New-TempGitRepo -CommitMessage "fix: corregge calcolo patch"
            $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "main"
            Remove-TempRepo $repo

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match "Validation successful"
        }

        It "Accetta 'feat: ...' su main" {
            $repo = New-TempGitRepo -CommitMessage "feat: aggiunge nuova feature"
            $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "main"
            Remove-TempRepo $repo

            $result.ExitCode | Should -Be 0
        }

        It "Accetta 'feat!: ...' (breaking change) su main" {
            $repo = New-TempGitRepo -CommitMessage "feat!: breaking change nel contratto API"
            $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "main"
            Remove-TempRepo $repo

            $result.ExitCode | Should -Be 0
        }

        It "Accetta 'BREAKING CHANGE: ...' su main" {
            $repo = New-TempGitRepo -CommitMessage "BREAKING CHANGE: rimozione parametro deprecato"
            $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "main"
            Remove-TempRepo $repo

            $result.ExitCode | Should -Be 0
        }
    }

    Context "Commit validi su 'staging'" {

        It "Accetta 'fix: ...' su staging" {
            $repo = New-TempGitRepo -CommitMessage "fix: hotfix staging"
            $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "staging"
            Remove-TempRepo $repo

            $result.ExitCode | Should -Be 0
        }

        It "Accetta 'feat: ...' su staging" {
            $repo = New-TempGitRepo -CommitMessage "feat: feature su staging"
            $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "staging"
            Remove-TempRepo $repo

            $result.ExitCode | Should -Be 0
        }
    }

    Context "Commit NON validi su 'main'" {

        It "Rifiuta 'chore: ...' su main" {
            $repo = New-TempGitRepo -CommitMessage "chore: aggiorna dipendenze"
            $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "main"
            Remove-TempRepo $repo

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match "MISSING CONVENTIONAL COMMIT"
        }

        It "Rifiuta messaggio senza prefisso" {
            $repo = New-TempGitRepo -CommitMessage "aggiornamento generico"
            $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "main"
            Remove-TempRepo $repo

            $result.ExitCode | Should -Be 1
        }

        It "Rifiuta 'docs: ...' su main" {
            $repo = New-TempGitRepo -CommitMessage "docs: aggiorna README"
            $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "main"
            Remove-TempRepo $repo

            $result.ExitCode | Should -Be 1
        }

        It "Rifiuta 'FEAT: ...' (uppercase) su main" {
            $repo = New-TempGitRepo -CommitMessage "FEAT: nuova funzionalita maiuscolo"
            $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "main"
            Remove-TempRepo $repo

            $result.ExitCode | Should -Be 1
        }

        It "Rifiuta 'refactor: ...' su main" {
            $repo = New-TempGitRepo -CommitMessage "refactor: rinomina variabile"
            $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "main"
            Remove-TempRepo $repo

            $result.ExitCode | Should -Be 1
        }

        It "Mostra il messaggio del commit nel testo dell'errore" {
            $msg = "update: messaggio non convenzionale"
            $repo = New-TempGitRepo -CommitMessage $msg
            $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "main"
            Remove-TempRepo $repo

            $result.Output | Should -Match [regex]::Escape($msg)
        }
    }

    Context "Merge commit — lo script guarda il commit reale (--no-merges)" {

        It "Vede il commit non-merge sottostante: 'fix:' → PASS" {
            # Il commit reale è 'fix:', sopra c'è un merge commit
            $repo = New-TempGitRepo -CommitMessage "fix: bugfix sotto il merge" -WithMergeCommit
            $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "main"
            Remove-TempRepo $repo

            $result.ExitCode | Should -Be 0
        }

        It "Vede il commit non-merge sottostante: 'chore:' → FAIL" {
            $repo = New-TempGitRepo -CommitMessage "chore: manutenzione sotto il merge" -WithMergeCommit
            $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "main"
            Remove-TempRepo $repo

            $result.ExitCode | Should -Be 1
        }
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# SUITE 2: Branch non protetti — il check viene skippato
# ─────────────────────────────────────────────────────────────────────────────

Describe "Verify-SemVer — Branch non protetti" {

    It "Skip su 'dev' con commit non convenzionale" {
        $repo = New-TempGitRepo -CommitMessage "WIP: lavori in corso"
        $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "dev"
        Remove-TempRepo $repo

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match "Skipping check"
    }

    It "Skip su 'feature/nuova-cosa' con qualsiasi messaggio" {
        $repo = New-TempGitRepo -CommitMessage "aggiornamento senza prefisso"
        $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "feature/nuova-cosa"
        Remove-TempRepo $repo

        $result.ExitCode | Should -Be 0
    }

    It "Skip su branch con prefisso 'refs/heads/' (ADO passa il ref completo)" {
        $repo = New-TempGitRepo -CommitMessage "chore: test"
        # ADO passa refs/heads/dev → lo script deve rimuovere il prefisso
        $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "refs/heads/dev"
        Remove-TempRepo $repo

        $result.ExitCode | Should -Be 0
    }

    It "Branch 'main' con prefisso 'refs/heads/' viene trattato come protetto" {
        $repo = New-TempGitRepo -CommitMessage "chore: non convenzionale"
        $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "refs/heads/main"
        Remove-TempRepo $repo

        $result.ExitCode | Should -Be 1
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# SUITE 3: ADDITIONAL_TAG_BRANCHES
# ─────────────────────────────────────────────────────────────────────────────

Describe "Verify-SemVer — ADDITIONAL_TAG_BRANCHES" {

    It "Branch 'release' aggiunto → commit 'fix:' accettato" {
        $repo = New-TempGitRepo -CommitMessage "fix: fix su release"
        $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "release" -AdditionalBranches "release"
        Remove-TempRepo $repo

        $result.ExitCode | Should -Be 0
    }

    It "Branch 'release' aggiunto → commit 'chore:' rifiutato" {
        $repo = New-TempGitRepo -CommitMessage "chore: pulizia su release"
        $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "release" -AdditionalBranches "release"
        Remove-TempRepo $repo

        $result.ExitCode | Should -Be 1
    }

    It "Branch 'release' NON aggiunto → chore accettato (non protetto)" {
        $repo = New-TempGitRepo -CommitMessage "chore: pulizia"
        $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "release" -AdditionalBranches ""
        Remove-TempRepo $repo

        $result.ExitCode | Should -Be 0
    }

    It "Lista multipla: 'hotfix,release' → entrambi protetti" {
        $repo = New-TempGitRepo -CommitMessage "docs: non valido"
        $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "hotfix" -AdditionalBranches "hotfix,release"
        Remove-TempRepo $repo

        $result.ExitCode | Should -Be 1
    }

    It "Lista multipla: branch non in lista → skip" {
        $repo = New-TempGitRepo -CommitMessage "docs: non valido"
        $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "develop" -AdditionalBranches "hotfix,release"
        Remove-TempRepo $repo

        $result.ExitCode | Should -Be 0
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# SUITE 4: Data-driven da fixtures/valid-commits.txt e invalid-commits.txt
# ─────────────────────────────────────────────────────────────────────────────

Describe "Verify-SemVer — Fixture: commit validi su main" {

    BeforeDiscovery {
        $lines = Get-Content "$PSScriptRoot/../fixtures/valid-commits.txt" -ErrorAction Stop
        $script:ValidCases = $lines |
            Where-Object { $_ -match '\S' } |
            ForEach-Object { @{ Msg = $_.Trim() } }
    }

    It "PASS su main: '<Msg>'" -TestCases $script:ValidCases {
        param([string]$Msg)
        $repo = New-TempGitRepo -CommitMessage $Msg
        $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "main"
        Remove-TempRepo $repo

        $result.ExitCode | Should -Be 0
    }
}

Describe "Verify-SemVer — Fixture: commit non validi su main" {

    BeforeDiscovery {
        $lines = Get-Content "$PSScriptRoot/../fixtures/invalid-commits.txt" -ErrorAction Stop
        $script:InvalidCases = $lines |
            Where-Object { $_ -match '\S' } |
            ForEach-Object { @{ Msg = $_.Trim() } }
    }

    It "FAIL su main: '<Msg>'" -TestCases $script:InvalidCases {
        param([string]$Msg)
        $repo = New-TempGitRepo -CommitMessage $Msg
        $result = Invoke-VerifySemVer -RepoDir $repo -TargetBranch "main"
        Remove-TempRepo $repo

        $result.ExitCode | Should -Be 1
    }
}
