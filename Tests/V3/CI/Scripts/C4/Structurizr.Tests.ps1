#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/C4/Structurizr.ps1

.DESCRIPTION
    Le viste che un marcatore di vista nomina, sul workspace esportato in JSON: le prove non
    chiamano la Structurizr CLI.
#>

BeforeAll {
    . "$PSScriptRoot/../../../../../V3/CI/Scripts/C4/Structurizr.ps1"

    $Workspace = [pscustomobject]@{
        views = [pscustomobject]@{
            systemContextViews = @([pscustomobject]@{ key = 'contesto' })
            componentViews     = @([pscustomobject]@{ key = 'componenti-api' }, [pscustomobject]@{ key = 'componenti-worker' })
        }
    }
}


Describe "Structurizr — viste di un marcatore" {

    It "Un marcatore con la chiave nomina quella vista" {
        Resolve-ViewMarker 'contesto' $Workspace | Should -Be @('contesto')
    }

    It "Un marcatore con il tipo e l'asterisco nomina tutte le viste del tipo, nell'ordine del modello" {
        Resolve-ViewMarker 'component*' $Workspace | Should -Be @('componenti-api', 'componenti-worker')
    }

    It "Un tipo senza viste non nomina nessuna vista" {
        @(Resolve-ViewMarker 'deployment*' $Workspace).Count | Should -Be 0
    }
}
