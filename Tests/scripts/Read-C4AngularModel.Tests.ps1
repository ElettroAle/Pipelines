#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Read-C4AngularModel.ps1

.DESCRIPTION
    Ogni scenario costruisce un repository Angular finto, esegue il solo lettore Angular e legge il
    frammento che lascia per lo scrittore.
#>

BeforeAll {
    . "$PSScriptRoot/../fixtures/c4/C4CodeFixture.ps1"
}

Describe "Lettore Angular del modello C4" {

    Context "Scenario: il frammento dell'applicazione Angular" {
        BeforeAll {
            $res = Invoke-C4Reader (New-ClientRepository) 'Aidea.Dxp.Client.Web' 'angular'
        }

        It "Allora la lettura riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il frammento dichiara letti angular.json e package.json" {
            $res.Fragment.manifests | Should -Be @('angular.json', 'package.json')
        }

        It "E l'applicazione prende il nome del repository senza il prefisso comune" {
            $res.Fragment.containers[0].name | Should -Be 'Client.Web'
        }
    }

    Context "Schema dello scenario: caso Angular non riconosciuto — <elemento>" -ForEach @(
        @{
            elemento = 'ui-kit'
            Build    = { $f = New-ClientRepository; $f['source/angular.json'] = '{ "projects": { "aidea-dxp-client-web": { "projectType": "application", "sourceRoot": "src" }, "ui-kit": { "projectType": "library", "sourceRoot": "projects/ui-kit/src" } } }'; $f }
        }
        @{
            elemento = 'angular.json'
            Build    = { $f = New-ClientRepository; $f['source/angular.json'] = '{ "projects": { "client": { "projectType": "application", "sourceRoot": "src" }, "operator": { "projectType": "application", "sourceRoot": "projects/operator/src" } } }'; $f }
        }
        @{
            elemento = 'operator/angular.json'
            Build    = { $f = New-ClientRepository; $f['source/operator/angular.json'] = '{ "projects": { "operator": { "projectType": "application", "sourceRoot": "src" } } }'; $f }
        }
    ) {
        BeforeAll {
            $res = Invoke-C4Reader (& $Build) 'Aidea.Dxp.Client.Web' 'angular'
        }

        It "Allora la lettura fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina il repository e l'elemento" {
            Get-Issues $res.Output | Where-Object { $_ -match 'Aidea\.Dxp\.Client\.Web' -and $_.Contains($elemento) } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E non lascia il frammento" {
            $res.Fragment | Should -BeNullOrEmpty
        }
    }
}
