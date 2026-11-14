#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/LanguageModel/LanguageModel.ps1

.DESCRIPTION
    La scelta del fornitore nel contratto del modello linguistico: quale modulo nasce dal fornitore
    dichiarato e quale risponde a Invoke-LanguageModel.
#>

BeforeAll {
    . "$PSScriptRoot/../../../../../V3/CI/Scripts/LanguageModel/LanguageModel.ps1"
    $script:PreviousKey = $env:ANTHROPIC_API_KEY
    $env:ANTHROPIC_API_KEY = 'chiave-di-prova'
}

AfterAll { $env:ANTHROPIC_API_KEY = $PreviousKey }

Describe "LanguageModel — scelta del fornitore" {

    It "Senza fornitore dichiarato usa Foundry" {
        (New-LanguageModel -Endpoint 'https://foundry.example' -Model 'giudice').Provider | Should -Be 'foundry'
    }

    It "Il fornitore si riconosce senza badare a maiuscole e spazi" {
        (New-LanguageModel -Provider ' Anthropic ' -Model 'claude-sonnet-5-5').Provider | Should -Be 'anthropic'
    }

    It "Un fornitore sconosciuto è un errore che elenca quelli disponibili" {
        { New-LanguageModel -Provider 'openai' -Model 'gpt' } | Should -Throw "fornitore del modello sconosciuto: openai (anthropic, foundry)"
    }

    It "Invoke-LanguageModel chiama il modulo del fornitore del client" {
        Mock Invoke-AnthropicLanguageModel { @{ Response = 'da Anthropic'; Usage = @{ Input = 1; Output = 2 } } }
        Mock Invoke-FoundryLanguageModel { @{ Response = 'da Foundry'; Usage = @{ Input = 1; Output = 2 } } }
        $client = New-LanguageModel -Provider 'anthropic' -Model 'claude-sonnet-5-5'
        (Invoke-LanguageModel $client 'istruzioni' 'domanda' @{} 'schema').Response | Should -Be 'da Anthropic'
        Should -Invoke Invoke-FoundryLanguageModel -Times 0 -Exactly
    }

    It "Il client conserva il tempo massimo di attesa di una risposta" {
        (New-LanguageModel -Endpoint 'https://foundry.example' -Model 'giudice' -TimeoutSeconds 900).TimeoutSeconds | Should -Be 900
    }
}
