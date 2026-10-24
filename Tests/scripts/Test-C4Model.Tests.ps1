#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Test-C4Model.ps1

.DESCRIPTION
    Ogni scenario parte dal documento valido della fixture condivisa e vi introduce un solo
    difetto del modello C4 o dei marcatori di vista. Lo script gira come in pipeline: richiede
    Java 17 o successivo (STRUCTURIZR_JAVA, JAVA_HOME_17_X64 o JAVA_HOME); la Structurizr CLI si
    installa in una cache condivisa da tutti gli scenari.
#>

BeforeAll {
    . "$PSScriptRoot/../fixtures/documentation/DocumentationFixture.ps1"
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../V3/CI/Scripts/Test-C4Model.ps1"
    $previousToolsDirectory = $env:AGENT_TOOLSDIRECTORY
    $env:AGENT_TOOLSDIRECTORY = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-model-$(New-Guid)"

    function Invoke-ModelCheck([System.Collections.IDictionary]$Docs, [hashtable]$Environment = @{}) {
        $variables = @{ GATE_MODE = '' }
        foreach ($name in $Environment.Keys) { $variables[$name] = $Environment[$name] }
        return Invoke-DocsScript $ScriptPath $Docs $variables
    }
}

AfterAll {
    Remove-Item -Recurse -Force $env:AGENT_TOOLSDIRECTORY -ErrorAction SilentlyContinue
    $env:AGENT_TOOLSDIRECTORY = $previousToolsDirectory
}


Describe "Funzionalità: Verifica del modello C4" {

    Context "Scenario: modello completo e mostrato nelle sezioni" {
        BeforeAll {
            $res = Invoke-ModelCheck (New-ValidDocs)
        }

        It "Allora la verifica passa" {
            Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
            $res.ExitCode | Should -Be 0
        }
    }

    Context "Schema dello scenario: modello non ben formato — <difetto>" -ForEach @(
        @{
            difetto  = 'una relazione da "BFF" verso "Motore v3", che il modello non dichiara'
            elemento = '^modello C4: non valido \(.*"Motore v3"'
            Mutate   = { param($d) Edit-Docs $d 'docs/architecture/model/workspace.dsl' 'motore -> worker "accoda"' "motore -> worker `"accoda`"`n        bff -> `"Motore v3`" `"chiama`"" }
        }
        @{
            difetto  = 'il container "Worker" senza vista dei componenti'
            elemento = '^modello C4: container senza vista dei componenti \(Worker\)'
            Mutate   = {
                param($d)
                Edit-Docs $d 'docs/architecture/model/workspace.dsl' "        component worker `"componenti-worker`" {`n            include *`n        }`n" ''
                Edit-Docs $d 'docs/architecture/05_building_block_view.md' "<!-- vista: componenti-worker -->`n" ''
            }
        }
        @{
            difetto  = 'un modello senza vista di deployment'
            elemento = '^modello C4: livello mancante \(vista di deployment\)'
            Mutate   = {
                param($d)
                Edit-Docs $d 'docs/architecture/model/workspace.dsl' "        deployment dxp produzione `"deployment-produzione`" {`n            include *`n        }`n" ''
                Edit-Docs $d 'docs/architecture/07_deployment_view.md' "<!-- vista: deployment-produzione -->`n" ''
            }
        }
        @{
            difetto  = 'una vista che nessuna sezione mostra'
            elemento = '^modello C4: vista non mostrata in nessuna sezione \(contesto\)'
            Mutate   = { param($d) Edit-Docs $d 'docs/architecture/03_context_and_scope.md' "<!-- vista: contesto -->`n" '' }
        }
        @{
            difetto  = 'un marcatore verso una vista inesistente'
            elemento = '^Ambito e contesto del sistema: vista inesistente \(nessuna\)'
            Mutate   = { param($d) Edit-Docs $d 'docs/architecture/03_context_and_scope.md' 'vista: contesto' "vista: contesto -->`n<!-- vista: nessuna" }
        }
        @{
            difetto  = 'un documento senza modello'
            elemento = '^modello C4: modello mancante \(docs[\\/]architecture[\\/]model[\\/]workspace\.dsl\)'
            Mutate   = { param($d) $d['docs/architecture/model/workspace.dsl'] = $null }
        }
    ) {
        BeforeAll {
            $docs = New-ValidDocs
            & $Mutate $docs
            $res = Invoke-ModelCheck $docs
        }

        It "Allora la verifica fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina l'elemento difettoso" {
            Get-Issues $res.Output | Where-Object { $_ -match $elemento } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }
}

Describe "Test-C4Model — strumenti e modalità" {

    It "Senza un Java 17 fallisce nominando il modello C4 e il motivo" {
        $res = Invoke-ModelCheck (New-ValidDocs) @{ STRUCTURIZR_JAVA = (Join-Path ([IO.Path]::GetTempPath()) 'java-assente') }
        $res.ExitCode | Should -Be 1
        Get-Issues $res.Output | Where-Object { $_ -match '^modello C4: verifica non eseguita \(.*Java 17' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
    }

    It "In modalità off non verifica" {
        $docs = New-ValidDocs
        $docs['docs/architecture/model/workspace.dsl'] = $null
        $res = Invoke-ModelCheck $docs @{ GATE_MODE = 'off' }
        $res.ExitCode | Should -Be 0
        Get-Issues $res.Output | Should -BeNullOrEmpty
    }
}
