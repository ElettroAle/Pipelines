#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/ScenarioCoverage.cs

.DESCRIPTION
    Lo script si esegue come processo (dotnet run), come in pipeline. Le fixture
    in Tests/fixtures/scenario-coverage sono prodotte da una run reale di
    Reqnroll 3.3.4 + xUnit con BUILD_BUILDID=4242:
      green → scenari verdi, uno Schema dello scenario, una Regola, @ignore su
              scenario e su Funzionalità
      red   → una riga di esempio fallita e una frase senza binding
    I casi che richiedono corpus diversi copiano una fixture in TestDrive e la alterano.
#>

BeforeAll {
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../V3/CI/Scripts/ScenarioCoverage.cs"
    $FixturesRoot = Resolve-Path "$PSScriptRoot/../fixtures/scenario-coverage"
    $MessagesFile = 'scenario-coverage/4242.ndjson'

    function Invoke-ScenarioCoverage {
        param([string[]]$Arguments)
        $output = & dotnet run $ScriptPath -- @Arguments 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }

    function Invoke-OnCorpus {
        param([string]$Root, [string]$Messages = $MessagesFile)
        Invoke-ScenarioCoverage @('--root', $Root, '--messages-file', $Messages)
    }

    function Copy-Fixture {
        param([string]$Name)
        $target = Join-Path $TestDrive "$Name-$(New-Guid)"
        Copy-Item -Path (Join-Path $FixturesRoot $Name) -Destination $target -Recurse
        $target
    }

    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    # Il primo dotnet run compila la file-based app: lo si paga una volta sola.
    & dotnet build $ScriptPath 2>&1 | Out-Null
}

Describe 'ScenarioCoverage' {

    Context 'Corpus interamente verificato' {
        BeforeAll { $result = Invoke-OnCorpus (Join-Path $FixturesRoot 'green') }

        It 'esce con 0' {
            $result.ExitCode | Should -Be 0
        }

        It 'conta ogni riga di esempio e ogni scenario dentro una Regola' {
            $result.Output | Should -Match '6 attesi, 4 verificati, 2 in attesa \(@ignore\), 0 problemi'
        }

        It 'elenca come in attesa lo scenario @ignore e la Funzionalità @ignore mai eseguita' {
            $result.Output | Should -Match 'IN ATTESA Spec/Features/Carrello\.feature:20 '
            $result.Output | Should -Match 'IN ATTESA Spec/Features/TuttoIgnorato\.feature:4 '
        }
    }

    Context 'Scenari eseguiti ma non superati' {
        BeforeAll { $result = Invoke-OnCorpus (Join-Path $FixturesRoot 'red') }

        It 'esce con 1' {
            $result.ExitCode | Should -Be 1
        }

        It 'nomina la sola riga di esempio fallita, non lo schema intero' {
            $result.Output | Should -Match 'PROBLEMA Spec/Features/Carrello\.feature:17 Aggiunte multiple — fallito'
            $result.Output | Should -Not -Match 'Carrello\.feature:16 '
        }

        It 'distingue la frase senza binding da un fallimento' {
            $result.Output | Should -Match 'PROBLEMA Spec/Features/Carrello\.feature:19 Frase senza binding — frase senza binding'
        }
    }

    Context 'Un .feature che nessun test esegue' {
        BeforeAll {
            $root = Copy-Fixture 'green'
            New-Item -ItemType Directory -Path "$root/docs" | Out-Null
            Set-Content -Path "$root/docs/Orfano.feature" -Encoding utf8 -Value @(
                '# language: it', 'Funzionalità: Documento orfano', '  Scenario: Mai compilato', '    Dato qualcosa')
            $result = Invoke-OnCorpus $root
        }

        It 'esce con 1 e nomina lo scenario non eseguito' {
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'PROBLEMA docs/Orfano\.feature:3 Mai compilato — non eseguito da nessun test'
        }
    }

    Context 'Messages di una run diversa da quella corrente' {
        BeforeAll { $result = Invoke-OnCorpus (Join-Path $FixturesRoot 'green') 'scenario-coverage/9999.ndjson' }

        It 'non li legge: ogni scenario non @ignore risulta non eseguito' {
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match '0 verificati, 2 in attesa \(@ignore\), 4 problemi — 2 file \.feature, 0 file di messages'
        }
    }

    Context 'Sorgenti non allineati alla build che ha prodotto i messages' {
        BeforeAll {
            $root = Copy-Fixture 'green'
            $feature = "$root/Spec/Features/Carrello.feature"
            $lines = [System.Collections.Generic.List[string]](Get-Content $feature -Encoding utf8)
            $lines.Insert(5, '  # riga aggiunta dopo la build')
            Set-Content -Path $feature -Value $lines -Encoding utf8
            $result = Invoke-OnCorpus $root
        }

        It 'segnala sia lo scenario spostato non eseguito sia l''esecuzione senza scenario' {
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'Carrello\.feature:7 Aggiunta di un articolo — non eseguito da nessun test'
            $result.Output | Should -Match 'Carrello\.feature:6 +— eseguito ma assente dal \.feature attuale'
        }
    }

    Context 'Un .feature eseguito che non esiste più sotto la root' {
        BeforeAll {
            $root = Copy-Fixture 'green'
            Remove-Item "$root/Spec/Features/Carrello.feature"
            $result = Invoke-OnCorpus $root
        }

        It 'esce con 1 segnalando l''esecuzione orfana' {
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'PROBLEMA Features/Carrello\.feature .*eseguito ma assente dai \.feature sotto la root'
        }
    }

    Context 'Gherkin non valido' {
        BeforeAll {
            $root = Copy-Fixture 'green'
            Set-Content -Path "$root/Spec/Features/Rotto.feature" -Encoding utf8 -Value @(
                '# language: it', 'Funzionalità: Rotto', '  Scenario: X', '    Dato qualcosa', 'Funzionalità: Seconda funzionalità nello stesso file')
            $result = Invoke-OnCorpus $root
        }

        It 'è un problema del corpus, non un errore di invocazione' {
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'PROBLEMA Spec/Features/Rotto\.feature +— Gherkin non valido'
        }
    }

    Context 'Nessun file .feature' {
        BeforeAll {
            $root = Join-Path $TestDrive "empty-$(New-Guid)"
            New-Item -ItemType Directory -Path $root | Out-Null
            $result = Invoke-OnCorpus $root
        }

        It 'esce con 0 senza verificare nulla' {
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'nessun file \.feature, niente da verificare'
        }
    }

    Context 'Riepilogo markdown' {
        BeforeAll {
            $summary = Join-Path $TestDrive "summary-$(New-Guid).md"
            $result = Invoke-ScenarioCoverage @('--root', (Join-Path $FixturesRoot 'red'), '--messages-file', $MessagesFile, '--summary', $summary)
        }

        It 'riporta problemi e scenari in attesa in tabelle separate' {
            $content = Get-Content $summary -Raw -Encoding utf8
            $content | Should -Match '## Problemi'
            $content | Should -Match '\| `Spec/Features/Carrello\.feature:17` \| Aggiunte multiple \| fallito \|'
            $content | Should -Match '## In attesa \(@ignore\)'
        }
    }

    Context 'File .feature con fine riga CRLF' {
        BeforeAll {
            $root = Copy-Fixture 'green'
            Get-ChildItem "$root/Spec/Features" -Filter *.feature | ForEach-Object {
                $text = [System.IO.File]::ReadAllText($_.FullName) -replace "`r?`n", "`r`n"
                [System.IO.File]::WriteAllText($_.FullName, $text)
            }
            $result = Invoke-OnCorpus $root
        }

        It 'riconosce le stesse righe di un checkout LF' {
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '6 attesi, 4 verificati, 2 in attesa'
        }
    }

    Context 'Modalità warn' {
        BeforeAll {
            $red = Join-Path $FixturesRoot 'red'
            $local = Invoke-ScenarioCoverage @('--root', $red, '--messages-file', $MessagesFile, '--mode', 'warn')
            $env:TF_BUILD = 'True'
            try {
                $agent = Invoke-ScenarioCoverage @('--root', $red, '--messages-file', $MessagesFile, '--mode', 'warn')
                $unreadable = Copy-Fixture 'green'
                Add-Content -Path "$unreadable/Spec/bin/Release/net10.0/$MessagesFile" -Value '{non json'
                $agentUnreadable = Invoke-ScenarioCoverage @('--root', $unreadable, '--messages-file', $MessagesFile, '--mode', 'warn')
            }
            finally {
                Remove-Item Env:TF_BUILD
            }
        }

        It 'riporta i problemi ma esce con 0' {
            $local.ExitCode | Should -Be 0
            $local.Output | Should -Match 'PROBLEMA Spec/Features/Carrello\.feature:17'
        }

        It 'fuori da Azure Pipelines non emette logging command' {
            $local.Output | Should -Not -Match '##vso\['
        }

        It 'su un agent segna lo step SucceededWithIssues con un warning' {
            $agent.Output | Should -Match '##vso\[task\.logissue type=warning\]Copertura scenari non verificata'
            $agent.Output | Should -Match '##vso\[task\.complete result=SucceededWithIssues;\]'
        }

        It 'non blocca nemmeno su messages illeggibili' {
            $agentUnreadable.ExitCode | Should -Be 0
            $agentUnreadable.Output | Should -Match '##vso\[task\.complete result=SucceededWithIssues;\]'
        }
    }

    Context 'Modalità enforce su un agent' {
        BeforeAll {
            $summary = Join-Path $TestDrive "summary-$(New-Guid).md"
            $env:TF_BUILD = 'True'
            try {
                $result = Invoke-ScenarioCoverage @('--root', (Join-Path $FixturesRoot 'red'), '--messages-file', $MessagesFile, '--mode', 'enforce', '--summary', $summary)
            }
            finally {
                Remove-Item Env:TF_BUILD
            }
        }

        It 'esce con 1 con un errore e senza SucceededWithIssues' {
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match '##vso\[task\.logissue type=error\]'
            $result.Output | Should -Not -Match 'SucceededWithIssues'
        }

        It 'pubblica il riepilogo markdown' {
            $result.Output | Should -Match '##vso\[task\.uploadsummary\].*summary-.*\.md'
        }
    }

    Context 'Invocazione non valida' {
        It 'esce con 2 senza --messages-file' {
            (Invoke-ScenarioCoverage @('--root', $TestDrive)).ExitCode | Should -Be 2
        }

        It 'esce con 2 con un''opzione sconosciuta' {
            (Invoke-ScenarioCoverage @('--root', $TestDrive, '--messages-file', 'x.ndjson', '--level', 'warn')).ExitCode | Should -Be 2
        }

        It 'esce con 2 con una modalità sconosciuta, anche su un agent' {
            $env:TF_BUILD = 'True'
            try {
                (Invoke-ScenarioCoverage @('--root', $TestDrive, '--messages-file', 'x.ndjson', '--mode', 'soft')).ExitCode | Should -Be 2
            }
            finally {
                Remove-Item Env:TF_BUILD
            }
        }

        It 'esce con 2 se la root non esiste' {
            (Invoke-ScenarioCoverage @('--root', (Join-Path $TestDrive 'assente'), '--messages-file', 'x.ndjson')).ExitCode | Should -Be 2
        }

        It 'esce con 2 su un file di messages illeggibile' {
            $root = Copy-Fixture 'green'
            Add-Content -Path "$root/Spec/bin/Release/net10.0/$MessagesFile" -Value '{non json'
            $result = Invoke-OnCorpus $root
            $result.ExitCode | Should -Be 2
            $result.Output | Should -Match 'non è un Cucumber Message leggibile'
        }
    }
}
