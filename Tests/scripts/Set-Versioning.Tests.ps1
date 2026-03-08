#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Set-Versioning.ps1

.DESCRIPTION
    Strategia: ogni test crea un repository git temporaneo reale con la storia
    di commit/tag desiderata, aggiunge un bare repo locale come fake remote
    (per permettere 'git push origin <tag>' senza rete), setta le variabili
    d'ambiente ADO attese dallo script, lo esegue e verifica le variabili
    esposte tramite '##vso[task.setvariable ...]' nell'output.

    Struttura repo per ogni test:
      $FakeOrigin  (bare, usato come remote 'origin')
      $TempRepo    (working repo con commit/tag)
#>

BeforeAll {
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../V3/CI/Scripts/Set-Versioning.ps1"

    # ---------------------------------------------------------------------------
    # Helper: crea repo git temporaneo con fake remote
    # ---------------------------------------------------------------------------
    function New-TestRepo {
        <#
        .PARAMETER Tags
            Hashtable @{ "1.0.0" = <commit_index> } dove commit_index è 0-based.
            Il tag viene applicato al commit all'indice indicato.
        .PARAMETER Commits
            Array di messaggi di commit. L'ultimo è HEAD.
        #>
        param(
            [string[]]$Commits = @("feat: commit iniziale"),
            [hashtable]$Tags = @{}
        )

        # Bare repo come fake origin
        $tmpDir = [System.IO.Path]::GetTempPath()
        $fakeOriginPath = Join-Path $tmpDir "pester-origin-$(New-Guid)"
        git init --bare $fakeOriginPath -q | Out-Null

        # Working repo
        $repoPath = Join-Path $tmpDir "pester-repo-$(New-Guid)"
        New-Item -ItemType Directory -Path $repoPath | Out-Null
        Push-Location $repoPath

        git init -q | Out-Null
        git config user.email "test@pester.local"
        git config user.name "Pester Test"
        git remote add origin $fakeOriginPath

        # Crea i commit
        for ($i = 0; $i -lt $Commits.Count; $i++) {
            "$i" | Set-Content "file$i.txt"
            git add . | Out-Null
            git commit -m $Commits[$i] -q | Out-Null

            # Applica tag a questo commit se richiesto
            foreach ($tagName in $Tags.Keys) {
                if ($Tags[$tagName] -eq $i) {
                    git tag $tagName | Out-Null
                    # Pusha il tag al fake origin per coerenza
                    git push origin $tagName -q 2>$null | Out-Null
                }
            }
        }

        Pop-Location
        return @{ Repo = $repoPath; Origin = $fakeOriginPath }
    }

    # ---------------------------------------------------------------------------
    # Helper: esegue Set-Versioning.ps1 nel repo indicato
    # ---------------------------------------------------------------------------
    function Invoke-SetVersioning {
        param(
            [string]$RepoDir,
            [string]$TargetEnv    = "Development",
            [string]$RequireTag   = "false",
            [string]$ProjectName  = "MyApp",
            [string]$BuildId      = "99"
        )

        Push-Location $RepoDir
        try {
            $env:TARGET_ENV   = $TargetEnv
            $env:REQUIRE_TAG  = $RequireTag
            $env:PROJECT_NAME = $ProjectName
            $env:BUILD_ID     = $BuildId

            $output = & pwsh -NoProfile -NonInteractive -File $ScriptPath 2>&1
            $exitCode = $LASTEXITCODE
            $outputStr = $output -join "`n"

            return @{ ExitCode = $exitCode; Output = $outputStr }
        }
        finally {
            Pop-Location
            $env:TARGET_ENV = $env:REQUIRE_TAG = $env:PROJECT_NAME = $env:BUILD_ID = $null
        }
    }

    # ---------------------------------------------------------------------------
    # Helper: estrae il valore di una variabile ##vso dall'output
    # ---------------------------------------------------------------------------
    function Get-VsoVariable {
        param([string]$Output, [string]$VariableName)
        $m = [regex]::Match($Output, "##vso\[task\.setvariable variable=$([regex]::Escape($VariableName))\](.+)")
        if ($m.Success) { return $m.Groups[1].Value.Trim() }
        return $null
    }

    # ---------------------------------------------------------------------------
    # Helper: pulizia
    # ---------------------------------------------------------------------------
    function Remove-TestRepo([hashtable]$TestRepo) {
        foreach ($path in @($TestRepo.Repo, $TestRepo.Origin)) {
            if ($path -and (Test-Path $path)) {
                Remove-Item -Recurse -Force $path -ErrorAction SilentlyContinue
            }
        }
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# SUITE 1: REQUIRE_TAG=false
# ─────────────────────────────────────────────────────────────────────────────

Describe "Set-Versioning — REQUIRE_TAG=false" {

    It "Nessun tag: currentTag = 0.0.0.{BuildId}" {
        $tr = New-TestRepo -Commits @("feat: primo commit")
        $res = Invoke-SetVersioning -RepoDir $tr.Repo -RequireTag "false" -BuildId "42"
        Remove-TestRepo $tr

        $res.ExitCode | Should -Be 0
        (Get-VsoVariable $res.Output "currentTag") | Should -Be "0.0.0.42"
    }

    It "Tag esistente 1.2.3: currentTag = 1.2.3.{BuildId}" {
        $tr = New-TestRepo `
            -Commits @("feat: primo", "fix: secondo") `
            -Tags @{ "1.2.3" = 0 }
        $res = Invoke-SetVersioning -RepoDir $tr.Repo -RequireTag "false" -BuildId "7"
        Remove-TestRepo $tr

        $res.ExitCode | Should -Be 0
        (Get-VsoVariable $res.Output "currentTag") | Should -Be "1.2.3.7"
    }

    It "Tag con prefisso 'v': v2.0.1 → currentTag = 2.0.1.{BuildId}" {
        $tr = New-TestRepo `
            -Commits @("feat: commit") `
            -Tags @{ "v2.0.1" = 0 }
        $res = Invoke-SetVersioning -RepoDir $tr.Repo -RequireTag "false" -BuildId "5"
        Remove-TestRepo $tr

        $res.ExitCode | Should -Be 0
        (Get-VsoVariable $res.Output "currentTag") | Should -Be "2.0.1.5"
    }

    It "computedArtifactName = {projectName-sanitizzato}-{env}-{version}" {
        $tr = New-TestRepo -Commits @("feat: commit")
        $res = Invoke-SetVersioning -RepoDir $tr.Repo -RequireTag "false" `
            -ProjectName "My.App" -TargetEnv "Development" -BuildId "10"
        Remove-TestRepo $tr

        (Get-VsoVariable $res.Output "computedArtifactName") | Should -Be "my-app-development-0.0.0.10"
    }

    It "gitHash è valorizzato (short SHA, almeno 7 caratteri alfanumerici)" {
        $tr = New-TestRepo -Commits @("feat: commit")
        $res = Invoke-SetVersioning -RepoDir $tr.Repo -RequireTag "false"
        Remove-TestRepo $tr

        $hash = Get-VsoVariable $res.Output "gitHash"
        $hash | Should -Not -BeNullOrEmpty
        $hash | Should -Match "^[0-9a-f]{7,}$"
    }

    It "TARGET_ENV viene lowercasato nel computedArtifactName" {
        $tr = New-TestRepo -Commits @("feat: commit")
        $res = Invoke-SetVersioning -RepoDir $tr.Repo -RequireTag "false" `
            -TargetEnv "Production" -ProjectName "App" -BuildId "1"
        Remove-TestRepo $tr

        (Get-VsoVariable $res.Output "computedArtifactName") | Should -Match "-production-"
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# SUITE 2: REQUIRE_TAG=true — incremento SemVer
# ─────────────────────────────────────────────────────────────────────────────

Describe "Set-Versioning — REQUIRE_TAG=true, incremento SemVer" {

    It "'fix:' dopo tag 1.2.3 → patch bump → 1.2.4" {
        $tr = New-TestRepo `
            -Commits @("feat: base", "fix: bugfix") `
            -Tags @{ "1.2.3" = 0 }
        $res = Invoke-SetVersioning -RepoDir $tr.Repo -RequireTag "true"
        Remove-TestRepo $tr

        $res.ExitCode | Should -Be 0
        (Get-VsoVariable $res.Output "currentTag") | Should -Be "1.2.4"
    }

    It "'feat:' dopo tag 1.2.3 → minor bump → 1.3.0" {
        $tr = New-TestRepo `
            -Commits @("fix: base", "feat: nuova feature") `
            -Tags @{ "0.0.1" = 0 }

        # Ricrea con tag giusto
        Remove-TestRepo $tr
        $tr = New-TestRepo `
            -Commits @("fix: base", "feat: nuova feature") `
            -Tags @{ "1.2.3" = 0 }
        $res = Invoke-SetVersioning -RepoDir $tr.Repo -RequireTag "true"
        Remove-TestRepo $tr

        $res.ExitCode | Should -Be 0
        (Get-VsoVariable $res.Output "currentTag") | Should -Be "1.3.0"
    }

    It "'feat!:' dopo tag 1.2.3 → major bump → 2.0.0" {
        $tr = New-TestRepo `
            -Commits @("fix: base", "feat!: breaking") `
            -Tags @{ "1.2.3" = 0 }
        $res = Invoke-SetVersioning -RepoDir $tr.Repo -RequireTag "true"
        Remove-TestRepo $tr

        $res.ExitCode | Should -Be 0
        (Get-VsoVariable $res.Output "currentTag") | Should -Be "2.0.0"
    }

    It "Nessun tag precedente: parte da 0.0.0, 'feat:' → 0.1.0" {
        $tr = New-TestRepo -Commits @("feat: primo commit")
        $res = Invoke-SetVersioning -RepoDir $tr.Repo -RequireTag "true"
        Remove-TestRepo $tr

        $res.ExitCode | Should -Be 0
        (Get-VsoVariable $res.Output "currentTag") | Should -Be "0.1.0"
    }

    It "Nessun tag precedente: 'fix:' → 0.0.1" {
        $tr = New-TestRepo -Commits @("fix: primo bugfix")
        $res = Invoke-SetVersioning -RepoDir $tr.Repo -RequireTag "true"
        Remove-TestRepo $tr

        $res.ExitCode | Should -Be 0
        (Get-VsoVariable $res.Output "currentTag") | Should -Be "0.0.1"
    }

    It "Nessun tag precedente: 'feat!:' → 1.0.0" {
        $tr = New-TestRepo -Commits @("feat!: breaking iniziale")
        $res = Invoke-SetVersioning -RepoDir $tr.Repo -RequireTag "true"
        Remove-TestRepo $tr

        $res.ExitCode | Should -Be 0
        (Get-VsoVariable $res.Output "currentTag") | Should -Be "1.0.0"
    }

    It "minor bump azzera la patch: 1.2.9 + 'feat:' → 1.3.0 (non 1.3.9)" {
        $tr = New-TestRepo `
            -Commits @("fix: base", "feat: nuova") `
            -Tags @{ "1.2.9" = 0 }
        $res = Invoke-SetVersioning -RepoDir $tr.Repo -RequireTag "true"
        Remove-TestRepo $tr

        (Get-VsoVariable $res.Output "currentTag") | Should -Be "1.3.0"
    }

    It "major bump azzera minor e patch: 2.5.3 + 'feat!:' → 3.0.0" {
        $tr = New-TestRepo `
            -Commits @("fix: base", "feat!: breaking") `
            -Tags @{ "2.5.3" = 0 }
        $res = Invoke-SetVersioning -RepoDir $tr.Repo -RequireTag "true"
        Remove-TestRepo $tr

        (Get-VsoVariable $res.Output "currentTag") | Should -Be "3.0.0"
    }

    It "Il nuovo tag viene pushato al fake remote (git push exit 0)" {
        $tr = New-TestRepo `
            -Commits @("fix: base", "feat: nuova") `
            -Tags @{ "1.0.0" = 0 }
        $res = Invoke-SetVersioning -RepoDir $tr.Repo -RequireTag "true"

        # Verifica che il tag esista nel bare repo (fake origin)
        Push-Location $tr.Repo
        $remoteTags = git ls-remote --tags origin 2>&1
        Pop-Location

        Remove-TestRepo $tr

        $res.ExitCode | Should -Be 0
        ($remoteTags -join "`n") | Should -Match "1\.1\.0"
    }

    It "computedArtifactName con REQUIRE_TAG=true ha formato {proj}-{env}-{semver}" {
        $tr = New-TestRepo `
            -Commits @("fix: base", "fix: patch") `
            -Tags @{ "1.0.0" = 0 }
        $res = Invoke-SetVersioning -RepoDir $tr.Repo -RequireTag "true" `
            -ProjectName "MyService" -TargetEnv "Staging"
        Remove-TestRepo $tr

        (Get-VsoVariable $res.Output "computedArtifactName") | Should -Be "myservice-staging-1.0.1"
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# SUITE 3: REQUIRE_TAG=true — HEAD identico al tag (nessun incremento)
# ─────────────────────────────────────────────────────────────────────────────

Describe "Set-Versioning — REQUIRE_TAG=true, HEAD uguale all'ultimo tag" {

    It "Stessa tree → currentTag rimane invariato, nessun nuovo tag" {
        # Crea repo con tag sull'HEAD corrente (stesso tree)
        $tmpDir = [System.IO.Path]::GetTempPath()
        $fakeOriginPath = Join-Path $tmpDir "pester-origin-$(New-Guid)"
        git init --bare $fakeOriginPath -q | Out-Null

        $repoPath = Join-Path $tmpDir "pester-repo-$(New-Guid)"
        New-Item -ItemType Directory -Path $repoPath | Out-Null
        Push-Location $repoPath

        git init -q | Out-Null
        git config user.email "test@pester.local"
        git config user.name "Pester Test"
        git remote add origin $fakeOriginPath

        "file" | Set-Content "file.txt"
        git add . | Out-Null
        git commit -m "feat: commit" -q | Out-Null
        git tag "2.3.4" | Out-Null
        git push origin "2.3.4" -q 2>$null | Out-Null

        Pop-Location

        $res = Invoke-SetVersioning -RepoDir $repoPath -RequireTag "true"

        # Conta i tag nel remote prima e dopo
        Push-Location $repoPath
        $remoteTags = git ls-remote --tags origin 2>&1
        Pop-Location

        Remove-Item -Recurse -Force $repoPath -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $fakeOriginPath -ErrorAction SilentlyContinue

        $res.ExitCode | Should -Be 0
        (Get-VsoVariable $res.Output "currentTag") | Should -Be "2.3.4"
        # Deve esserci esattamente un tag nel remote (quello originale, non un nuovo)
        ($remoteTags | Select-String "refs/tags").Count | Should -Be 1
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# SUITE 4: Sanitizzazione PROJECT_NAME
# ─────────────────────────────────────────────────────────────────────────────

Describe "Set-Versioning — Sanitizzazione PROJECT_NAME" {

    It "Punti nel nome vengono convertiti in trattini" {
        $tr = New-TestRepo -Commits @("feat: commit")
        $res = Invoke-SetVersioning -RepoDir $tr.Repo -RequireTag "false" `
            -ProjectName "My.Project.Name" -BuildId "1"
        Remove-TestRepo $tr

        (Get-VsoVariable $res.Output "computedArtifactName") | Should -Match "^my-project-name-"
    }

    It "Nome già lowercase rimane invariato" {
        $tr = New-TestRepo -Commits @("feat: commit")
        $res = Invoke-SetVersioning -RepoDir $tr.Repo -RequireTag "false" `
            -ProjectName "myapp" -BuildId "1"
        Remove-TestRepo $tr

        (Get-VsoVariable $res.Output "computedArtifactName") | Should -Match "^myapp-"
    }

    It "Nome con maiuscole viene lowercasato" {
        $tr = New-TestRepo -Commits @("feat: commit")
        $res = Invoke-SetVersioning -RepoDir $tr.Repo -RequireTag "false" `
            -ProjectName "MyApp" -BuildId "1"
        Remove-TestRepo $tr

        (Get-VsoVariable $res.Output "computedArtifactName") | Should -Match "^myapp-"
    }
}
