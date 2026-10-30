#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/C4/Read-C4Angular18Model.ps1

.DESCRIPTION
    Ogni scenario costruisce un repository Angular finto, esegue il solo lettore Angular e legge il
    frammento che lascia per lo scrittore.
#>

BeforeAll {
    . "$PSScriptRoot/Fixtures/C4CodeFixture.ps1"
}

Describe "Lettore Angular 18 del modello C4" {

    Context "Scenario: il frammento dell'applicazione Angular" {
        BeforeAll {
            $res = Invoke-C4Reader (New-ClientRepository) 'Aidea.Dxp.Client.Web' 'angular18'
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

    Context "Schema dello scenario: caso Angular che il lettore Angular 18 non legge — <elemento>" -ForEach @(
        @{
            elemento = 'ui-kit'
            Build    = { $f = New-ClientRepository; $f['source/angular.json'] = '{ "projects": { "aidea-dxp-client-web": { "projectType": "application", "sourceRoot": "src" }, "ui-kit": { "projectType": "library", "sourceRoot": "projects/ui-kit/src" } } }'; $f }
        }
        @{
            elemento = 'angular.json'
            Build    = { $f = New-ClientRepository; $f['source/angular.json'] = '{ "projects": { "client": { "projectType": "application", "sourceRoot": "src" }, "operator": { "projectType": "application", "sourceRoot": "projects/operator/src" } } }'; $f }
        }
        @{
            elemento = 'angular.json (^17.3.0)'
            Build    = { $f = New-ClientRepository; $f['source/package.json'] = '{ "dependencies": { "@angular/core": "^17.3.0" } }'; $f }
        }
        @{
            elemento = 'angular.json (>=18.0.0 <20.0.0)'
            Build    = { $f = New-ClientRepository; $f['source/package.json'] = '{ "dependencies": { "@angular/core": ">=18.0.0 <20.0.0" } }'; $f }
        }
        @{
            elemento = 'angular.json (^18.2.0 || ^19.0.0)'
            Build    = { $f = New-ClientRepository; $f['source/package.json'] = '{ "dependencies": { "@angular/core": "^18.2.0 || ^19.0.0" } }'; $f }
        }
        @{
            elemento = 'angular.json'
            Build    = { $f = New-ClientRepository; $f.Remove('source/package.json'); $f }
        }
        @{
            elemento = 'operator/angular.json'
            Build    = { $f = New-ClientRepository; $f['source/operator/angular.json'] = '{ "projects": { "operator": { "projectType": "application", "sourceRoot": "src" } } }'; $f }
        }
    ) {
        BeforeAll {
            $res = Invoke-C4Reader (& $Build) 'Aidea.Dxp.Client.Web' 'angular18'
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
