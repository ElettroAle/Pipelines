#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Reference/ReferenceLinks.ps1
#>

BeforeAll {
    . "$PSScriptRoot/../../../../../V3/CI/Scripts/Reference/ReferenceLinks.ps1"
    $Entries = @(
        [pscustomobject]@{ kind = 'module'; name = 'ServiceBus'; url = 'https://wiki/ServiceBus' }
        [pscustomobject]@{ kind = 'module'; name = 'ServiceBusSubscription'; url = 'https://wiki/ServiceBusSubscription' }
        [pscustomobject]@{ kind = 'api'; name = 'BFF'; url = 'https://wiki/BFF' }
        [pscustomobject]@{ kind = 'task'; name = 'terraform:plan'; url = 'https://wiki/Comandi' }
        [pscustomobject]@{ kind = 'task'; name = 'terraform:plan-destroy'; url = 'https://wiki/Comandi' }
    )
}

Describe 'Add-ReferenceLinks' {
    It 'rende un link solo la prima menzione di ogni voce' {
        Add-ReferenceLinks "Il BFF chiama il BFF.`nPoi il BFF risponde." $Entries | Should -Be "Il [BFF](https://wiki/BFF) chiama il BFF.`nPoi il BFF risponde."
    }

    It 'preferisce il nome piu'' lungo e non trova un nome dentro un altro' {
        Add-ReferenceLinks 'Prima terraform:plan-destroy, poi ServiceBusSubscription.' $Entries | Should -Be 'Prima [terraform:plan-destroy](https://wiki/Comandi), poi [ServiceBusSubscription](https://wiki/ServiceBusSubscription).'
    }

    It 'trova solo parole intere' {
        Add-ReferenceLinks 'MyServiceBus, BFFs, Common/Modules/ServiceBus e ServiceBus.tf restano testo.' $Entries | Should -Be 'MyServiceBus, BFFs, Common/Modules/ServiceBus e ServiceBus.tf restano testo.'
    }

    It 'lascia titoli, blocchi di codice, link, immagini e tag come sono' {
        $text = "# BFF`n``````text`nBFF`n```````n::: mermaid`nBFF --> ServiceBus`n:::`n[il BFF](https://altro) ![BFF](img.png) <span title=`"BFF`">x</span> https://host/BFF`nIl BFF."
        Add-ReferenceLinks $text $Entries | Should -Be ($text -replace 'Il BFF\.$', 'Il [BFF](https://wiki/BFF).')
    }

    It 'collega un codice in linea che contiene esattamente il nome, non uno che lo contiene fra altro' {
        Add-ReferenceLinks 'Si lancia `task terraform:plan`, cioe'' `terraform:plan`.' $Entries | Should -Be 'Si lancia `task terraform:plan`, cioe'' [`terraform:plan`](https://wiki/Comandi).'
    }

    It 'non aggiunge un secondo link a una voce gia'' collegata, quindi due applicazioni danno la stessa pagina' {
        $once = Add-ReferenceLinks 'Il ServiceBus e il BFF.' $Entries
        Add-ReferenceLinks $once $Entries | Should -Be $once
    }

    It 'lascia il testo invariato senza voci' {
        Add-ReferenceLinks 'Il BFF.' @() | Should -Be 'Il BFF.'
    }
}

Describe 'Read-ReferenceIndex' {
    It 'legge le voci con nome e indirizzo' {
        $path = Join-Path $TestDrive 'index.json'
        '{"entries":[{"kind":"api","name":"BFF","url":"https://wiki/BFF"},{"kind":"api","name":"","url":"x"}]}' | Set-Content $path
        @(Read-ReferenceIndex $path | ForEach-Object name) | Should -Be @('BFF')
    }

    It 'senza indice non ci sono voci' {
        @(Read-ReferenceIndex (Join-Path $TestDrive 'assente.json')).Count | Should -Be 0
    }
}
