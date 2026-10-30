#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Common/PlantUml.ps1

.DESCRIPTION
    Disegna con il jar vero: richiede Java 17 o successivo (STRUCTURIZR_JAVA, JAVA_HOME_17_X64 o
    JAVA_HOME). PLANTUML_JAR evita lo scaricamento; senza, il jar si scarica e se ne verifica il
    checksum. Graphviz si toglie dal PATH: il disegno non deve dipenderne.
#>

BeforeAll {
    . "$PSScriptRoot/../../V3/CI/Scripts/Common/Structurizr.ps1"
    . "$PSScriptRoot/../../V3/CI/Scripts/Common/PlantUml.ps1"
    $previousToolsDirectory = $env:AGENT_TOOLSDIRECTORY
    $previousPath = $env:PATH
    $env:AGENT_TOOLSDIRECTORY = Join-Path ([IO.Path]::GetTempPath()) "pester-plantuml-$(New-Guid)"
    $env:PATH = ($env:PATH -split [IO.Path]::PathSeparator | Where-Object { -not (Test-Path (Join-Path $_ 'dot*')) }) -join [IO.Path]::PathSeparator
    $Java = Get-StructurizrJava
    $PngSignature = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

    $ContextDiagram = @'
@startuml
!include <C4/C4_Context>
Person(utente, "Utente", $descr="Usa il sistema.")
System(sistema, "Sistema", $descr="Il sistema descritto.")
System_Ext(identita, "Provider di identita'", $descr="Autentica gli utenti.")
Rel(utente, sistema, "Usa")
Rel(sistema, identita, "Autentica", $techn="OIDC")
SHOW_LEGEND()
@enduml
'@
}

AfterAll {
    Remove-Item -Recurse -Force $env:AGENT_TOOLSDIRECTORY -ErrorAction SilentlyContinue
    $env:AGENT_TOOLSDIRECTORY = $previousToolsDirectory
    $env:PATH = $previousPath
}

Describe "PlantUml — disegno dei diagrammi C4" {

    Context "Un diagramma C4 valido" {
        BeforeAll { $images = ConvertTo-PlantUmlPng @{ contesto = $ContextDiagram; secondo = $ContextDiagram } $Java }

        It "Si disegna in PNG con le librerie C4 interne, senza Graphviz e senza rete" {
            $bytes = $images['contesto']
            $bytes.Count | Should -BeGreaterThan $PngSignature.Count
            Compare-Object ($bytes | Select-Object -First $PngSignature.Count) $PngSignature | Should -BeNullOrEmpty
        }

        It "Ogni diagramma ha la sua immagine, con una sola esecuzione" {
            $images.Keys | Sort-Object | Should -Be @('contesto', 'secondo')
        }

        It "Lo stesso diagramma da' gli stessi byte" {
            $again = ConvertTo-PlantUmlPng @{ contesto = $ContextDiagram } $Java
            [Convert]::ToBase64String($again['contesto']) | Should -Be ([Convert]::ToBase64String($images['contesto']))
        }
    }

    Context "Un diagramma non valido" {
        It "Il disegno fallisce e lo dice" {
            { ConvertTo-PlantUmlPng @{ rotto = "@startuml`nPerson(`n@enduml`n" } $Java } | Should -Throw '*PlantUML*'
        }
    }

    Context "Il jar scaricato non ha il checksum atteso" {
        BeforeAll {
            Mock Invoke-WebRequest { param($Uri, $OutFile) [IO.File]::WriteAllText($OutFile, 'non e'' PlantUML') }
            $previousJar = $env:PLANTUML_JAR
            $env:PLANTUML_JAR = ''
            $env:AGENT_TOOLSDIRECTORY = Join-Path ([IO.Path]::GetTempPath()) "pester-plantuml-$(New-Guid)"
        }
        AfterAll { $env:PLANTUML_JAR = $previousJar }

        It "Lo scaricamento fallisce nominando il checksum" {
            { Get-PlantUmlJar } | Should -Throw '*Checksum*'
        }

        It "E nessun jar resta installato" {
            Get-ChildItem -Recurse -File $env:AGENT_TOOLSDIRECTORY -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }
}
