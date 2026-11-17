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
            componentViews     = @([pscustomobject]@{ key = 'componenti-worker' }, [pscustomobject]@{ key = 'componenti-api' })
            deploymentViews    = @([pscustomobject]@{ key = 'deployment_dev_rg-b' }, [pscustomobject]@{ key = 'deployment_dev' }, [pscustomobject]@{ key = 'deployment_dev_rg-a' }, [pscustomobject]@{ key = 'deployment_prod' })
        }
    }
}


Describe "Structurizr — viste di un marcatore" {

    It "Un marcatore con la chiave nomina quella vista" {
        Resolve-ViewMarker 'contesto' $Workspace | Should -Be @('contesto')
    }

    It "Un marcatore con il tipo e l'asterisco nomina tutte le viste del tipo, in ordine di chiave" {
        Resolve-ViewMarker 'component*' $Workspace | Should -Be @('componenti-api', 'componenti-worker')
    }

    It "Un tipo senza viste non nomina nessuna vista" {
        @(Resolve-ViewMarker 'dynamic*' $Workspace).Count | Should -Be 0
    }

    It "Un marcatore con un prefisso che non e' un tipo e l'asterisco nomina le viste la cui chiave inizia con il prefisso, in ordine di chiave" {
        Resolve-ViewMarker 'deployment_dev*' $Workspace | Should -Be @('deployment_dev', 'deployment_dev_rg-a', 'deployment_dev_rg-b')
    }

    It "Un prefisso che nessuna chiave porta non nomina nessuna vista" {
        @(Resolve-ViewMarker 'deployment_qa*' $Workspace).Count | Should -Be 0
    }
}
