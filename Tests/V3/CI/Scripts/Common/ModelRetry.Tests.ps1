#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Common/ModelRetry.ps1

.DESCRIPTION
    Attesa prima di ripetere una richiesta al modello linguistico rifiutata per un errore transitorio.
#>

BeforeAll {
    . "$PSScriptRoot/../../../../../V3/CI/Scripts/Common/ModelRetry.ps1"

    function New-Response([string]$RetryAfter) {
        $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::TooManyRequests)
        if ($RetryAfter) { $response.Headers.Add('Retry-After', $RetryAfter) }
        return $response
    }
}


Describe "ModelRetry — attesa fra i tentativi" {

    It "Aspetta i secondi indicati da Retry-After" {
        Get-ModelRetryDelay (New-Response '37') 1 | Should -Be 37
    }

    It "Non aspetta quando Retry-After vale zero" {
        Get-ModelRetryDelay (New-Response '0') 5 | Should -Be 0
    }

    It "Senza Retry-After raddoppia l'attesa a ogni tentativo" {
        Get-ModelRetryDelay (New-Response '') 3 | Should -Be 8
    }

    It "Senza Retry-After non aspetta oltre un minuto" {
        Get-ModelRetryDelay (New-Response '') 9 | Should -Be 60
    }

    It "Senza risposta raddoppia l'attesa" {
        Get-ModelRetryDelay $null 2 | Should -Be 4
    }

    It "Ripete la richiesta fino a dieci volte" {
        $ModelMaxAttempts | Should -Be 10
    }
}
