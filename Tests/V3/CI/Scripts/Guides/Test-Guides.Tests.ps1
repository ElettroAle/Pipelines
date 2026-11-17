#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Guides/Test-Guides.ps1 e GuideChecks.ps1

.DESCRIPTION
    Ogni test scrive in una cartella temporanea un tutorial e una procedura validi, vi introduce un solo
    difetto e lancia la verifica come in pipeline, con la cartella delle guide nell'ambiente.
#>

BeforeAll {
    $script:ScriptPath = Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts/Guides/Test-Guides.ps1"
    . (Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts/Common/VerificationGate.ps1")
    . (Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts/Guides/GuideChecks.ps1")

    $script:Tutorial = @'
# Primo avvio in locale

Al termine il Motore risponde sul tuo computer.

## Prepara il computer

1. Installa il kit di sviluppo.
2. Clona il repository.

```bash
# perché questo commento non conta
dotnet run
```

## Risultato

Il Motore risponde all'indirizzo locale.
'@

    $script:Procedure = @'
# Aggiungere un tenant

## Compito

Aggiungi un tenant a un ambiente esistente.

## Prerequisiti

- Accesso al repository dell'infrastruttura.

## Risultato atteso

Il tenant compare nella configurazione dell'ambiente.

## Passi

1. Crea la cartella del tenant.
2. Apri la PR. Il perché del flusso sta nella [sezione 8](../../architecture/08_concepts.md).
'@

    function New-Guides([hashtable]$Files = @{}) {
        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-guides-$(New-Guid)"
        $guides = @{
            'docs/guides/tutorials/primo-avvio.md'        = $Tutorial
            'docs/guides/procedures/aggiungere-tenant.md' = $Procedure
            'docs/guides/home.md'                         = "# Home`n`nPerché sei qui? Scegli la tua strada.`n"
        }
        foreach ($name in $Files.Keys) { $guides[$name] = $Files[$name] }
        foreach ($name in $guides.Keys) {
            if ($null -eq $guides[$name]) { continue }
            $path = Join-Path $root $name
            New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
            [IO.File]::WriteAllText($path, $guides[$name])
        }
        return $root
    }

    function Invoke-GuidesCheck([string]$Root, [string]$Directory = 'docs/guides', [string]$Language = 'IT') {
        Push-Location $Root
        try {
            $env:GUIDES_DIRECTORY = $Directory
            $env:DOCUMENT_LANGUAGE = $Language
            $env:GATE_MODE = 'enforce'
            $output = & pwsh -NoProfile -NonInteractive -File $ScriptPath 2>&1
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output | ForEach-Object { "$_" }) }
        }
        finally { Pop-Location }
    }

    function Get-Errors($Result) {
        return @($Result.Output | Where-Object { $_ -match '^##vso\[task\.logissue type=error\](.*)$' } | ForEach-Object { $Matches[1] })
    }
}

AfterAll {
    'GUIDES_DIRECTORY', 'DOCUMENT_LANGUAGE', 'GATE_MODE' | ForEach-Object { Remove-Item "env:$_" -ErrorAction SilentlyContinue }
}

Describe 'Funzionalità: Guide della piattaforma ordinate per tipo' {
    AfterEach { if ($script:Root) { Remove-Item -Recurse -Force $script:Root -ErrorAction SilentlyContinue } }

    Context 'Schema dello scenario: una guida fa una cosa sola' {
        It 'la guida di tipo "<tipo>" che <difetto>: la verifica fallisce nominando la guida e "<motivo>"' -ForEach @(
            @{ tipo = 'tutorial'; difetto = 'non porta il lettore a un risultato funzionante passo dopo passo'; motivo = 'risultato mancante'
                Guide = 'docs/guides/tutorials/primo-avvio.md'; Text = "# Primo avvio`n`nUn po' di storia del progetto.`n`n## Contesto`n`nIl Motore nasce nel 2024.`n" }
            @{ tipo = 'procedure'; difetto = 'non dichiara all''inizio il compito, i prerequisiti e il risultato atteso'; motivo = 'apertura della procedura'
                Guide = 'docs/guides/procedures/aggiungere-tenant.md'; Text = "# Aggiungere un tenant`n`n## Passi`n`n1. Crea la cartella.`n" }
            @{ tipo = 'procedure'; difetto = 'contiene la spiegazione del perché invece del rimando al documento arc42'; motivo = 'spiegazione fuori posto'
                Guide = 'docs/guides/procedures/aggiungere-tenant.md'; Text = { $Procedure.Replace('1. Crea la cartella del tenant.', '1. Crea la cartella del tenant, perché ogni tenant ha un workspace suo.') } }
        ) {
            $content = if ($Text -is [scriptblock]) { & $Text } else { $Text }
            $script:Root = New-Guides @{ $Guide = $content }

            $result = Invoke-GuidesCheck $Root

            $result.ExitCode | Should -Be 1
            Get-Errors $result | Should -Match ('^' + [regex]::Escape("${Guide}: $motivo"))
        }
    }

    Context 'Guide che fanno una cosa sola' {
        It 'tutorial con passi e risultato e procedura con apertura e rimandi: la verifica passa' {
            $script:Root = New-Guides

            $result = Invoke-GuidesCheck $Root

            $result.ExitCode | Should -Be 0
            Get-Errors $result | Should -BeNullOrEmpty
        }

        It 'senza cartella delle guide non verifica nulla' {
            $script:Root = New-Guides

            (Invoke-GuidesCheck $Root '').ExitCode | Should -Be 0
        }
    }
}

Describe 'Test-TutorialResult' {
    It 'chiede che il risultato sia l''ultima sezione' {
        Test-TutorialResult "# T`n`n1. Passo.`n`n## Risultato`n`nFunziona.`n`n## Approfondimenti`n`nAltro.`n" | Should -BeFalse
    }

    It 'chiede un risultato non vuoto' {
        Test-TutorialResult "# T`n`n1. Passo.`n`n## Risultato`n`n" | Should -BeFalse
    }

    It 'chiede passi numerati fuori dai blocchi di codice' {
        Test-TutorialResult "# T`n`n``````text`n1. non e' un passo`n```````n`n## Risultato`n`nFunziona.`n" | Should -BeFalse
    }

    It 'non scambia per sezione un titolo dentro un blocco di codice' {
        Test-TutorialResult "# T`n`n1. Passo.`n`n## Risultato`n`nFunziona.`n`n``````md`n## Altro`n```````n" | Should -BeTrue
    }
}

Describe 'Test-ProcedureOpening' {
    It 'rifiuta le parti dell''apertura in un altro ordine' {
        Test-ProcedureOpening "# P`n`n## Prerequisiti`n`nUno.`n`n## Compito`n`nDue.`n`n## Risultato atteso`n`nTre.`n" | Should -BeFalse
    }

    It 'rifiuta una parte dell''apertura vuota' {
        Test-ProcedureOpening "# P`n`n## Compito`n`nUno.`n`n## Prerequisiti`n`n## Risultato atteso`n`nTre.`n" | Should -BeFalse
    }
}

Describe 'Get-MisplacedExplanations' {
    It 'trova ogni segnale della lingua del documento, senza distinguere le maiuscole' -ForEach @(
        @{ Text = 'Poiché il runner è fuori dalla rete, usa ARM.' }
        @{ Text = 'Il motivo è la rete chiusa.' }
        @{ Text = 'Si fa così dato che serve.' }
    ) {
        @(Get-MisplacedExplanations $Text) | Should -HaveCount 1
    }

    It 'non trova un segnale dentro un''altra parola' {
        @(Get-MisplacedExplanations 'Configura il servizio affinché risponda.') | Should -HaveCount 0
    }

    It 'accetta il perché che rimanda con un link' {
        @(Get-MisplacedExplanations 'Il perché è nella [sezione 8](../08.md).') | Should -HaveCount 0
    }
}

Describe 'Get-GuideIssues' {
    BeforeEach {
        $script:Root = New-Guides @{
            'docs/guides/tutorials/senza-risultato.md' = "# T`n`nTesto.`n"
            'docs/guides/procedures/senza-apertura.md' = "# P`n`n## Compito`n`nUno.`n`nIl motivo e' la rete.`n"
        }
        Push-Location $Root
    }
    AfterEach {
        Pop-Location
        Remove-Item -Recurse -Force $Root -ErrorAction SilentlyContinue
    }

    It 'nomina ogni guida con il suo motivo e non verifica la home' {
        $issues = @(Get-GuideIssues 'docs/guides')

        $issues | Should -HaveCount 3
        $issues[0] | Should -BeLike 'docs/guides/tutorials/senza-risultato.md: risultato mancante*'
        $issues[1] | Should -BeLike 'docs/guides/procedures/senza-apertura.md: apertura della procedura*'
        $issues[2] | Should -BeLike 'docs/guides/procedures/senza-apertura.md: spiegazione fuori posto («Il motivo e'' la rete.…»*'
    }

    It 'elenca tutorial, procedure e home con il loro tipo' {
        (Get-GuideFiles 'docs/guides' | ForEach-Object Type) | Should -Be @('tutorial', 'tutorial', 'procedure', 'procedure', 'home')
    }

    It 'con una cartella che non esiste non ha guide' {
        Get-GuideFiles 'docs/nessuna' | Should -BeNullOrEmpty
    }
}

Describe 'Get-GuideIssues in inglese' {
    It 'usa le parti della procedura della lingua del documento' {
        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-guides-$(New-Guid)"
        New-Item -ItemType Directory -Force "$root/g/procedures" | Out-Null
        [IO.File]::WriteAllText("$root/g/procedures/add.md", "# Add`n`n## Task`n`nAdd it.`n`n## Prerequisites`n`nNone.`n`n## Expected result`n`nAdded.`n`n## Steps`n`n1. Do it because it works.`n")
        try {
            $result = Invoke-GuidesCheck $root 'g' 'EN'

            Get-Errors $result | Should -Be @('g/procedures/add.md: misplaced explanation («Do it because it works.…» senza rimando al documento che spiega il perché)')
        }
        finally { Remove-Item -Recurse -Force $root }
    }
}

Describe 'Get-GuidesDirectory' {
    It 'tratta la macro di una variabile non definita come nessuna cartella' {
        $env:GUIDES_DIRECTORY = '$(guidesDirectory)'

        Get-GuidesDirectory | Should -BeNullOrEmpty
    }
}
