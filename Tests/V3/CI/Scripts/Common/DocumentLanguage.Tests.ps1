#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Common/DocumentLanguage.ps1

.DESCRIPTION
    Le frasi della lingua compongono i testi dei documenti: gli elenchi che contengono si chiudono con la congiunzione
    della lingua (ADR-2170).
#>

BeforeAll {
    $LanguageScript = "$PSScriptRoot/../../../../../V3/CI/Scripts/Common/DocumentLanguage.ps1"

    $Phrases = @(
        @{ Text = 'Elementi: {0}.'; Lists = @('Names') }
        @{ Text = 'Altri: {0}.'; Lists = @('Empty') }
    )

    function Format-Names([string[]]$Items) {
        return Format-LanguagePhrases $Phrases { param($Binding) if ($Binding -eq 'Names') { $Items } }
    }
}

Describe "DocumentLanguage — elenchi composti dalle frasi della lingua (ADR-2170)" {

    Context "In italiano" {
        BeforeAll { $env:DOCUMENT_LANGUAGE = 'IT'; . $LanguageScript }
        AfterAll { $env:DOCUMENT_LANGUAGE = $null }

        It "Un elenco di un solo elemento resta l'elemento" {
            Format-Names @('BFF') | Should -Be 'Elementi: BFF.'
        }

        It "Un elenco di due elementi li unisce con la congiunzione" {
            Format-Names @('BFF', 'Client') | Should -Be 'Elementi: BFF e Client.'
        }

        It "Un elenco di piu' elementi li unisce con la virgola e l'ultimo con la congiunzione" {
            Format-Names @('BFF', 'Client', 'Worker') | Should -Be 'Elementi: BFF, Client e Worker.'
        }

        It "Una frase con un elenco vuoto non si scrive" {
            Format-Names @() | Should -Be ''
        }
    }

    Context "In inglese" {
        BeforeAll { $env:DOCUMENT_LANGUAGE = 'EN'; . $LanguageScript }
        AfterAll { $env:DOCUMENT_LANGUAGE = $null }

        It "Un elenco di un solo elemento resta l'elemento" {
            Format-Names @('BFF') | Should -Be 'Elementi: BFF.'
        }

        It "Un elenco di due elementi li unisce con la congiunzione" {
            Format-Names @('BFF', 'Client') | Should -Be 'Elementi: BFF and Client.'
        }

        It "Un elenco di piu' elementi li unisce con la virgola e l'ultimo con la congiunzione" {
            Format-Names @('BFF', 'Client', 'Worker') | Should -Be 'Elementi: BFF, Client and Worker.'
        }
    }

    Context "Ogni lingua dichiara la congiunzione dei suoi elenchi" {
        It "Il file della lingua <_> ha la congiunzione" -ForEach @('IT', 'EN') {
            (Import-PowerShellDataFile "$PSScriptRoot/../../../../../V3/CI/Scripts/Common/Languages/$_.psd1").ListConjunction | Should -Not -BeNullOrEmpty
        }
    }
}
