#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Documentation/Test-Documentation.ps1

.DESCRIPTION
    Ogni scenario parte dal documento valido della fixture condivisa e vi introduce un solo
    difetto nei rimandi o nel testo. Le soglie sono quelle di un consumer reale: Gulpease 40,
    25 parole per frase. Nessuno strumento esterno: il controllo non conosce formati.
#>

BeforeAll {
    . "$PSScriptRoot/../Common/Fixtures/Documentation/DocumentationFixture.ps1"
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts/Documentation/Test-Documentation.ps1"

    function Invoke-DocsCheck([System.Collections.IDictionary]$Docs, [hashtable]$Environment = @{}) {
        $variables = @{
            GATE_MODE                 = ''
            READABILITY_GULPEASE      = '40'
            READABILITY_MAX_WORDS     = '25'
            READABILITY_ABBREVIATIONS = 'es.;ecc.'
        }
        foreach ($name in $Environment.Keys) { $variables[$name] = $Environment[$name] }
        return Invoke-DocsScript $ScriptPath $Docs $variables
    }
}


Describe "Funzionalità: Controlli comuni sulla documentazione" {

    Context "Scenario: documento con rimandi esistenti e testo entro le soglie" {
        BeforeAll {
            $res = Invoke-DocsCheck (New-ValidDocs)
        }

        It "Allora la verifica passa" {
            Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
            $res.ExitCode | Should -Be 0
        }
    }

    Context "Schema dello scenario: rimando inesistente — <difetto>" -ForEach @(
        @{
            difetto  = 'la decisione "0042-inesistente"'
            elemento = '^Decisioni di progettazione: rimando inesistente \(0042-inesistente\)'
            Mutate   = { param($d) Edit-Docs $d 'docs/architecture/09_architecture_decisions.md' 'come unico ingresso.' 'come unico ingresso. La decisione 0042-inesistente vale ancora.' }
        }
        @{
            difetto  = "un'ancora che la sezione non ha"
            elemento = '^Decisioni di progettazione: rimando inesistente \(05_building_block_view\.md#nessuna\)'
            Mutate   = { param($d) Edit-Docs $d 'docs/architecture/09_architecture_decisions.md' '#in-breve' '#nessuna' }
        }
        @{
            difetto  = 'un file che non esiste'
            elemento = '^Building Block View: rimando inesistente \(09_decisioni\.md\)'
            Mutate   = { param($d) Edit-Docs $d 'docs/architecture/05_building_block_view.md' '(09_architecture_decisions.md)' '(09_decisioni.md)' }
        }
    ) {
        BeforeAll {
            $docs = New-ValidDocs
            & $Mutate $docs
            $res = Invoke-DocsCheck $docs
        }

        It "Allora la verifica fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina la sezione e il rimando" {
            Get-Issues $res.Output | Where-Object { $_ -match $elemento } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    Context "Schema dello scenario: testo oltre le soglie di leggibilità — <sezione>, <motivo>" -ForEach @(
        @{
            sezione = 'Strategia della soluzione'; motivo = 'leggibilità'
            Mutate  = { param($d) Edit-Docs $d 'docs/architecture/04_solution_strategy.md' 'La piattaforma divide il lavoro fra applicazioni piccole. Ogni applicazione fa una cosa sola.' 'Infrastrutturalmente, l''orchestrazione multiprogettuale garantisce interoperabilità transfrontaliera. Contestualmente, l''automatizzazione documentale razionalizza l''amministrazione organizzativa. Conseguentemente, l''interoperabilità infrastrutturale semplifica l''amministrazione multiprogettuale. Parallelamente, l''internazionalizzazione organizzativa rafforza l''orchestrazione documentale interdipartimentale.' }
        }
        @{
            sezione = 'Runtime View'; motivo = 'frase troppo lunga'
            Mutate  = { param($d) Edit-Docs $d 'docs/architecture/06_runtime_view.md' 'con il codice della sessione.' 'con il codice della sessione, che il BFF conserva per tutta la durata della conversazione e che rimanda all''API del Motore ogni volta che il utente scrive un messaggio nuovo o chiude la finestra.' }
        }
    ) {
        BeforeAll {
            $docs = New-ValidDocs
            & $Mutate $docs
            $res = Invoke-DocsCheck $docs
        }

        It "Allora la verifica fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina la sezione e il motivo" {
            Get-Issues $res.Output | Where-Object { $_.StartsWith("${sezione}: $motivo") } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    It "Un documento di un altro formato, senza modello C4 e con file non numerati, passa" {
        $docs = [ordered]@{
            'docs/guide/come-iniziare.md' = New-Section 'Come iniziare' 'da dove si parte?' "<!-- vista: contesto -->`n`nSi apre il portale. Poi si legge la [guida](riferimenti.md)."
            'docs/guide/riferimenti.md'   = New-Section 'Riferimenti' 'dove sono le risposte?' 'Le risposte sono in questa pagina.'
        }
        $res = Invoke-DocsCheck $docs @{ DOCS_DIRECTORY = 'docs/guide' }
        Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
        $res.ExitCode | Should -Be 0
    }
}

Describe "Test-Documentation — modalità del controllo" {

    BeforeAll {
        $docs = New-ValidDocs
        Edit-Docs $docs 'docs/architecture/09_architecture_decisions.md' 'come unico ingresso.' 'come unico ingresso. La decisione 0042-inesistente vale ancora.'
    }

    It "In modalità warn segnala come warning e non blocca" {
        $res = Invoke-DocsCheck $docs @{ GATE_MODE = 'warn' }
        $res.ExitCode | Should -Be 0
        Get-Issues $res.Output 'warning' | Should -Not -BeNullOrEmpty
        $res.Output | Should -Match 'task\.complete result=SucceededWithIssues'
    }

    It "In modalità off non verifica" {
        $res = Invoke-DocsCheck $docs @{ GATE_MODE = 'off' }
        $res.ExitCode | Should -Be 0
        Get-Issues $res.Output | Should -BeNullOrEmpty
    }
}
