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
        $variables = @{ GATE_MODE = ''; DOCUMENT_LANGUAGE = '' }
        foreach ($name in $Environment.Keys) { $variables[$name] = $Environment[$name] }
        return Invoke-DocsScript $ScriptPath $Docs $variables
    }

    function Add-TechnicalSystem([System.Collections.IDictionary]$Docs) {
        Edit-Docs $Docs 'docs/architecture/model/workspace.dsl' '        utente -> client "usa"' "        ricerca = softwareSystem `"Ricerca web`" `"Motori di ricerca`" `"Tecnico`"`n        utente -> client `"usa`"`n        motore -> ricerca `"cerca`""
    }

    function Add-GeneratedPart([System.Collections.IDictionary]$Docs) {
        $Docs['docs/architecture/model/generated/aidea.dxp.ai.dsl'] = @"
aidea_dxp_ai_api = container "Api" "" "ASP.NET Core" "Applicazione,Generato" {
    properties {
        "codice" "Aidea.Dxp.AI.Api"
    }
    aidea_dxp_ai_api__engine = component "Engine" "" ".NET" "Generato" {
        properties {
            "codice" "Aidea.Dxp.AI.Engine"
        }
    }
    aidea_dxp_ai_api__usecase = component "UseCase" "" ".NET" "Generato" {
        properties {
            "codice" "Aidea.Dxp.AI.UseCase"
        }
    }
    aidea_dxp_ai_api__usecase -> aidea_dxp_ai_api__engine "" "" "Generato"
}
"@
        Edit-Docs $Docs 'docs/architecture/model/workspace.dsl' "                coda = component `"Coda`"`n            }" "                coda = component `"Coda`"`n            }`n            !include generated/aidea.dxp.ai.dsl"
        Edit-Docs $Docs 'docs/architecture/model/workspace.dsl' '        motore -> worker "accoda"' "        motore -> worker `"accoda`"`n        bff -> aidea_dxp_ai_api `"inoltra`"`n        !element aidea_dxp_ai_api {`n            description `"Riceve le richieste`"`n        }`n        !element aidea_dxp_ai_api__engine {`n            description `"Il dominio`"`n        }`n        !element aidea_dxp_ai_api__usecase {`n            description `"I casi d'uso`"`n        }"
        Edit-Docs $Docs 'docs/architecture/model/workspace.dsl' "        component worker `"componenti-worker`" {" "        component aidea_dxp_ai_api `"componenti-api`" {`n            include *`n        }`n        component worker `"componenti-worker`" {"
        Edit-Docs $Docs 'docs/architecture/05_building_block_view.md' '<!-- vista: componenti-worker -->' "<!-- vista: componenti-worker -->`n`n<!-- vista: componenti-api -->"
        return $Docs
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

    Context "Scenario: elemento tecnico escluso dalla vista di contesto" {
        BeforeAll {
            $docs = New-ValidDocs
            Add-TechnicalSystem $docs
            Edit-Docs $docs 'docs/architecture/model/workspace.dsl' "systemContext sistema `"contesto`" {`n            include *" "systemContext sistema `"contesto`" {`n            include *`n            exclude `"element.tag==Tecnico`""
            $res = Invoke-ModelCheck $docs
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
                Edit-Docs $d 'docs/architecture/model/workspace.dsl' "        deployment sistema produzione `"deployment-produzione`" {`n            include *`n        }`n" ''
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
            difetto  = 'il sistema "Ricerca web" con il tag tecnico nella vista di contesto'
            elemento = '^modello C4: elemento tecnico nella vista di contesto \(Ricerca web\)'
            Mutate   = { param($d) Add-TechnicalSystem $d }
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

Describe "Test-C4Model — lingua del documento" {

    It "In inglese riconosce il marcatore view e il tag Application" {
        $res = Invoke-ModelCheck (ConvertTo-EnglishConventions (New-ValidDocs)) @{ DOCUMENT_LANGUAGE = 'EN' }
        $res.ExitCode | Should -Be 0 -Because $res.Output
        Get-Issues $res.Output | Should -BeNullOrEmpty
    }

    It "In inglese un container Application senza vista dei componenti si segnala" {
        $docs = New-ValidDocs
        Edit-Docs $docs 'docs/architecture/model/workspace.dsl' "        component worker `"componenti-worker`" {`n            include *`n        }`n" ''
        Edit-Docs $docs 'docs/architecture/05_building_block_view.md' "<!-- vista: componenti-worker -->`n" ''
        $res = Invoke-ModelCheck (ConvertTo-EnglishConventions $docs) @{ DOCUMENT_LANGUAGE = 'EN' }
        $res.ExitCode | Should -Be 1
        Get-Issues $res.Output | Where-Object { $_ -match 'container senza vista dei componenti \(Worker\)' } | Should -Not -BeNullOrEmpty -Because $res.Output
    }

    It "In inglese un sistema con il tag Technical nella vista di contesto si segnala" {
        $docs = New-ValidDocs
        Add-TechnicalSystem $docs
        $res = Invoke-ModelCheck (ConvertTo-EnglishConventions $docs) @{ DOCUMENT_LANGUAGE = 'EN' }
        $res.ExitCode | Should -Be 1
        Get-Issues $res.Output | Where-Object { $_ -match 'elemento tecnico nella vista di contesto \(Ricerca web\)' } | Should -Not -BeNullOrEmpty -Because $res.Output
    }

    It "In inglese un marcatore italiano non mostra la vista" {
        $res = Invoke-ModelCheck (New-ValidDocs) @{ DOCUMENT_LANGUAGE = 'EN' }
        $res.ExitCode | Should -Be 1
        Get-Issues $res.Output | Where-Object { $_ -match 'vista non mostrata in nessuna sezione \(contesto\)' } | Should -Not -BeNullOrEmpty
    }

    It "Una lingua senza il suo file fallisce e la nomina" {
        $res = Invoke-ModelCheck (New-ValidDocs) @{ DOCUMENT_LANGUAGE = 'XX' }
        $res.ExitCode | Should -Not -Be 0
        $res.Output | Should -Match 'lingua del documento non supportata: XX'
    }
}

Describe "Funzionalità: Parte del modello scritta a mano sopra la parte generata" {

    Context "Scenario: modello generato e completato" {
        BeforeAll {
            $res = Invoke-ModelCheck (Add-GeneratedPart (New-ValidDocs))
        }

        It "Allora la verifica passa" {
            Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
            $res.ExitCode | Should -Be 0
        }
    }

    Context "Schema dello scenario: parte scritta a mano non coerente con il modello generato — <difetto>" -ForEach @(
        @{
            difetto  = 'il componente generato "UseCase" senza descrizione nella parte scritta a mano'
            elemento = '^modello C4: elemento generato senza descrizione \(UseCase\)'
            Mutate   = { param($d) Edit-Docs $d 'docs/architecture/model/workspace.dsl' "        !element aidea_dxp_ai_api__usecase {`n            description `"I casi d'uso`"`n        }" '' }
        }
        @{
            difetto  = 'il container generato "Api" senza descrizione nella parte scritta a mano'
            elemento = '^modello C4: elemento generato senza descrizione \(Api\)'
            Mutate   = { param($d) Edit-Docs $d 'docs/architecture/model/workspace.dsl' "        !element aidea_dxp_ai_api {`n            description `"Riceve le richieste`"`n        }" '' }
        }
        @{
            difetto  = 'la relazione scritta a mano da "UseCase" a "Engine", gia'' generata'
            elemento = '^modello C4: relazione generata ripetuta a mano \(UseCase -> Engine\)'
            Mutate   = { param($d) Edit-Docs $d 'docs/architecture/model/workspace.dsl' '        bff -> aidea_dxp_ai_api "inoltra"' "        bff -> aidea_dxp_ai_api `"inoltra`"`n        aidea_dxp_ai_api__usecase -> aidea_dxp_ai_api__engine `"usa`"" }
        }
        @{
            difetto  = 'la parte scritta a mano che descrive "DataAccess.Twilio", assente dal modello generato'
            elemento = '^modello C4: non valido \(.*aidea_dxp_ai_api__dataaccess_twilio'
            Mutate   = { param($d) Edit-Docs $d 'docs/architecture/model/workspace.dsl' '        bff -> aidea_dxp_ai_api "inoltra"' "        bff -> aidea_dxp_ai_api `"inoltra`"`n        !element aidea_dxp_ai_api__dataaccess_twilio {`n            description `"Invia gli SMS`"`n        }" }
        }
        @{
            difetto  = 'la relazione scritta a mano dalla persona "Utente" al container "Aidea.Dxp.Portal", assente dal modello'
            elemento = '^modello C4: non valido \(.*aidea_dxp_portal'
            Mutate   = { param($d) Edit-Docs $d 'docs/architecture/model/workspace.dsl' '        bff -> aidea_dxp_ai_api "inoltra"' "        bff -> aidea_dxp_ai_api `"inoltra`"`n        utente -> aidea_dxp_portal `"usa`"" }
        }
    ) {
        BeforeAll {
            $docs = Add-GeneratedPart (New-ValidDocs)
            & $Mutate $docs
            $res = Invoke-ModelCheck $docs
        }

        It "Allora la verifica fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina l'elemento" {
            Get-Issues $res.Output | Where-Object { $_ -match $elemento } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }
}
