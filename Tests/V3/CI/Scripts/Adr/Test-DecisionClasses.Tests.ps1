#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Adr/Test-DecisionClasses.ps1 e DecisionClasses.ps1

.DESCRIPTION
    Ogni scenario scrive un corpus con una decisione che governa le classi di un repository .NET finto,
    con il suo diagramma delle classi, e vi introduce un solo difetto. Lo script gira come in pipeline,
    in un processo separato; gli unit test caricano DecisionClasses.ps1 nel processo dei test. Richiede
    Node.js per il parser Mermaid, installato nella cache degli strumenti del processo.
#>

BeforeDiscovery {
    $Governs = @('Contoso.Shop.Core.Queue.*', 'Contoso.Shop.Core.Handlers.V2.QueueTicket*')
}

BeforeAll {
    . "$PSScriptRoot/../C4/Fixtures/C4CodeFixture.ps1"
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts/Adr/Test-DecisionClasses.ps1"
    $ModulePath = Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts/Adr/DecisionClasses.ps1"

    $Decision = 'docs/decisions/0036-intenzioni-applicate-dopo-il-turno.md'
    $Governs = @('Contoso.Shop.Core.Queue.*', 'Contoso.Shop.Core.Handlers.V2.QueueTicket*')
    $Diagram = @'
classDiagram
    class IQueueTicketIssuer {
        <<interface>>
    }
    class QueueTicketIssuer
    class QueueTicketHandler~TMessage~
    IQueueTicketIssuer <|.. QueueTicketIssuer : realizza
    QueueTicketHandler ..> IQueueTicketIssuer : usa
'@ -replace "`r`n", "`n"

    function New-DecisionText([string]$Status = 'accepted', [string[]]$Patterns = $Governs, [string]$Structure = "``````mermaid`n$Diagram`n``````", [switch]$NoStructure) {
        $frontmatter = @('---', "status: $Status", 'version: 1')
        if ($Patterns) { $frontmatter += @('governs:') + @($Patterns | ForEach-Object { "  - $_" }) }
        $frontmatter += '---'
        $parts = @('', '# Biglietti emessi dopo il turno', '', '## Contesto e problema', '', 'Il biglietto si emette a turno finito.', '',
            '## Opzioni considerate', '', '- Un emettitore dopo il turno.', '', '## Esito della decisione', '', "Si sceglie l'emettitore.", '')
        if (-not $NoStructure) { $parts += @('## Struttura nel codice', '', $Structure, '') }
        return (@($frontmatter) + $parts) -join "`n"
    }

    function New-ShopFiles {
        $files = [ordered]@{}
        Add-Project $files 'Contoso.Shop.Core' (New-Project)
        Add-Project $files 'Contoso.Shop.Core.Tests' (New-Project 'Microsoft.NET.Sdk' @('Contoso.Shop.Core') '' '    <PackageReference Include="Microsoft.NET.Test.Sdk" />')
        $files['source/Contoso.Shop.Core/Queue/QueueTicketIssuer.cs'] = "namespace Contoso.Shop.Core.Queue;`n`npublic interface IQueueTicketIssuer { }`n`npublic sealed class QueueTicketIssuer : IQueueTicketIssuer`n{`n    private sealed record Pending(string Code);`n}`n"
        $files['source/Contoso.Shop.Core/Handlers/V2/QueueTicketHandler.cs'] = "namespace Contoso.Shop.Core.Handlers.V2`n{`n    public class QueueTicketHandler<TMessage> : BackgroundService { }`n`n    public class TextDeliveryHandler { }`n}`n"
        $files['source/Contoso.Shop.Core/Billing/Invoice.cs'] = "namespace Contoso.Shop.Core.Billing;`n`npublic class Invoice { }`n"
        $files['source/Contoso.Shop.Core.Tests/Queue/QueueTicketIssuerTests.cs'] = "namespace Contoso.Shop.Core.Queue;`n`npublic class QueueTicketIssuerTests { }`n"
        return $files
    }

    function New-ClassesCorpus([System.Collections.IDictionary]$Files = (New-ShopFiles), [string]$DecisionText = (New-DecisionText)) {
        $corpus = [ordered]@{ $Decision = $DecisionText }
        foreach ($path in $Files.Keys) { $corpus[($path -replace '^source/', 'sources/Contoso.Shop/')] = $Files[$path] }
        return $corpus
    }

    function Invoke-ClassCheck([System.Collections.IDictionary]$Corpus = (New-ClassesCorpus), [hashtable]$Environment = @{}) {
        $variables = @{ GATE_MODE = ''; DOCUMENT_LANGUAGE = ''; DECISIONS_DIRECTORY = ''; SOURCE_DIRECTORY = 'sources' }
        foreach ($name in $Environment.Keys) { $variables[$name] = $Environment[$name] }
        return Invoke-DocsScript $ScriptPath $Corpus $variables
    }

    function Get-ClassIssue($Result, [string]$Pattern) {
        return Get-Issues $Result.Output | Where-Object { $_ -match $Pattern }
    }
}

Describe "Funzionalità: Diagramma delle classi di una decisione coerente con il codice che governa" {

    Context "Scenario: diagramma delle classi coerente, con le sole classi governate (ADR-2175)" {
        BeforeAll {
            $res = Invoke-ClassCheck
        }

        It "Allora la verifica passa" {
            Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
            $res.ExitCode | Should -Be 0
        }
    }

    Context "Schema dello scenario: classe del diagramma che nessun pattern copre (<Caso>) (ADR-2175)" -ForEach @(
        @{ Caso = 'una classe del codice accanto alle classi governate'; Classe = 'TextDeliveryHandler' }
        @{ Caso = 'una classe che non esiste nel codice di produzione'; Classe = 'BackgroundService' }
    ) {
        BeforeAll {
            $structure = "``````mermaid`n$Diagram`n    class $Classe`n    $Classe <|-- QueueTicketHandler : estende`n``````"
            $res = Invoke-ClassCheck (New-ClassesCorpus -DecisionText (New-DecisionText -Structure $structure))
        }

        It "Allora la verifica fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina la decisione e la classe del diagramma non governata, una volta sola" {
            @(Get-ClassIssue $res "^0036-intenzioni-applicate-dopo-il-turno: classe del diagramma non governata \($Classe\)$").Count | Should -Be 1 -Because ($res.Output)
            @(Get-Issues $res.Output).Count | Should -Be 1 -Because ($res.Output)
        }
    }

    Context "Scenario: due diagrammi delle classi che insieme coprono le classi governate (ADR-2175)" {
        BeforeAll {
            $issuing = "classDiagram`n    class IQueueTicketIssuer`n    class QueueTicketIssuer`n    IQueueTicketIssuer <|.. QueueTicketIssuer : realizza"
            $handling = "classDiagram`n    class IQueueTicketIssuer`n    class QueueTicketHandler~TMessage~`n    QueueTicketHandler ..> IQueueTicketIssuer : usa"
            $structure = "L'emissione del biglietto.`n`n``````mermaid`n$issuing`n```````n`nLa gestione dei messaggi della coda.`n`n``````mermaid`n$handling`n``````"
            $res = Invoke-ClassCheck (New-ClassesCorpus -DecisionText (New-DecisionText -Structure $structure))
        }

        It "Allora la verifica passa" {
            Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
            $res.ExitCode | Should -Be 0
        }
    }

    Context "Scenario: divergenza nel livello del codice" {
        BeforeAll {
            $files = New-ShopFiles
            $files['source/Contoso.Shop.Core/Queue/QueueTicketCanceller.cs'] = "namespace Contoso.Shop.Core.Queue;`n`npublic class QueueTicketCanceller { }`n"
            $res = Invoke-ClassCheck (New-ClassesCorpus $files)
        }

        It "Allora la verifica fallisce nominando la classe e la decisione `"0036`"" {
            $res.ExitCode | Should -Be 1
            Get-ClassIssue $res '^0036-intenzioni-applicate-dopo-il-turno: classe governata assente dal diagramma delle classi \(Contoso\.Shop\.Core\.Queue\.QueueTicketCanceller\)$' | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    Context "Scenario: il livello del codice guarda solo le parti governate" {
        BeforeAll {
            $files = New-ShopFiles
            $files['source/Contoso.Shop.Core/Billing/CreditNote.cs'] = "namespace Contoso.Shop.Core.Billing;`n`npublic class CreditNote { }`n"
            $res = Invoke-ClassCheck (New-ClassesCorpus $files)
        }

        It "Allora la verifica non nomina quella classe" {
            Get-ClassIssue $res 'CreditNote' | Should -BeNullOrEmpty -Because ($res.Output)
            $res.ExitCode | Should -Be 0
        }
    }

    Context "Schema dello scenario: classe che la verifica non controlla (<Caso>)" -ForEach @(
        @{ Caso = 'una classe di un progetto di test nel namespace governato'; Path = 'source/Contoso.Shop.Core.Tests/Queue/QueueTicketIssuerFakes.cs'; Code = "namespace Contoso.Shop.Core.Queue;`n`npublic class QueueTicketIssuerFake { }`n"; Name = 'QueueTicketIssuerFake' }
        @{ Caso = 'un tipo annidato in una classe governata'; Path = 'source/Contoso.Shop.Core/Queue/QueueTicketIssuer.Partial.cs'; Code = "namespace Contoso.Shop.Core.Queue;`n`npublic sealed partial class QueueTicketIssuer`n{`n    public enum Outcome { Issued, Refused }`n}`n"; Name = 'Outcome' }
        @{ Caso = 'una classe accanto al prefisso governato'; Path = 'source/Contoso.Shop.Core/Handlers/V2/QueueReader.cs'; Code = "namespace Contoso.Shop.Core.Handlers.V2;`n`npublic class QueueReader { }`n"; Name = 'QueueReader' }
    ) {
        BeforeAll {
            $files = New-ShopFiles
            $files[$Path] = $Code
            $res = Invoke-ClassCheck (New-ClassesCorpus $files)
        }

        It "Allora la verifica passa senza nominare <Name>" {
            Get-ClassIssue $res $Name | Should -BeNullOrEmpty -Because ($res.Output)
            $res.ExitCode | Should -Be 0
        }
    }

    Context "Schema dello scenario: decisione incoerente con il codice (<Difetto>)" -ForEach @(
        @{ Difetto = 'una voce di governs che non copre nessuna classe'; Patterns = @($Governs + 'Contoso.Shop.Core.Queue.QueueTicketRefund*'); Structure = $null; Issue = '^0036-intenzioni-applicate-dopo-il-turno: voce di governs che non copre classi del codice \(Contoso\.Shop\.Core\.Queue\.QueueTicketRefund\*\)$' }
        @{ Difetto = 'una voce di governs con il nome di una sola classe'; Patterns = @('Contoso.Shop.Core.Queue.QueueTicketIssuer', 'Contoso.Shop.Core.Queue.IQueueTicketIssuer*', 'Contoso.Shop.Core.Handlers.V2.QueueTicket*'); Structure = $null; Issue = '^0036-intenzioni-applicate-dopo-il-turno: voce di governs con il nome di una sola classe \(Contoso\.Shop\.Core\.Queue\.QueueTicketIssuer\)$' }
        @{ Difetto = 'una voce di governs che copre un namespace intero'; Patterns = @('Contoso.Shop.Core.Q*', 'Contoso.Shop.Core.Handlers.V2.QueueTicket*'); Structure = $null; Issue = '^0036-intenzioni-applicate-dopo-il-turno: voce di governs che copre un namespace intero \(Contoso\.Shop\.Core\.Q\*\)$' }
        @{ Difetto = 'la struttura nel codice senza governs'; Patterns = @(); Structure = $null; Issue = "^0036-intenzioni-applicate-dopo-il-turno: parte 'Struttura nel codice' senza la lista governs \(Struttura nel codice\)$" }
        @{ Difetto = 'governs senza la struttura nel codice'; Patterns = $Governs; Structure = 'none'; Issue = "^0036-intenzioni-applicate-dopo-il-turno: lista governs senza la parte 'Struttura nel codice' \(governs\)$" }
        @{ Difetto = 'la struttura nel codice senza diagramma delle classi'; Patterns = $Governs; Structure = 'Le classi sono descritte a parole.'; Issue = '^0036-intenzioni-applicate-dopo-il-turno: struttura nel codice senza diagramma delle classi \(Struttura nel codice\)$' }
    ) {
        BeforeAll {
            $text = switch ($Structure) {
                $null { New-DecisionText -Patterns $Patterns }
                'none' { New-DecisionText -Patterns $Patterns -NoStructure }
                default { New-DecisionText -Patterns $Patterns -Structure $Structure }
            }
            $res = Invoke-ClassCheck (New-ClassesCorpus -DecisionText $text)
        }

        It "Allora la verifica fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina la decisione e il motivo" {
            Get-ClassIssue $res $Issue | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    Context "Schema dello scenario: decisione chiusa (<Stato>)" -ForEach @(
        @{ Stato = 'superseded' }
        @{ Stato = 'deprecated' }
        @{ Stato = 'rejected' }
    ) {
        BeforeAll {
            $files = New-ShopFiles
            $files['source/Contoso.Shop.Core/Queue/QueueTicketCanceller.cs'] = "namespace Contoso.Shop.Core.Queue;`n`npublic class QueueTicketCanceller { }`n"
            $res = Invoke-ClassCheck (New-ClassesCorpus $files (New-DecisionText -Status $Stato))
        }

        It "Allora la verifica non controlla il diagramma della sua epoca" {
            Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
            $res.ExitCode | Should -Be 0
        }
    }

    Context "Scenario: corpus senza decisioni con la struttura nel codice" {
        BeforeAll {
            $res = Invoke-ClassCheck ([ordered]@{ $Decision = (New-DecisionText -Patterns @() -NoStructure) }) @{ SOURCE_DIRECTORY = 'assente' }
        }

        It "Allora la verifica passa senza leggere il codice" {
            Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
            $res.ExitCode | Should -Be 0
        }
    }

    Context "Scenario: codice sorgente assente" {
        BeforeAll {
            $res = Invoke-ClassCheck (New-ClassesCorpus) @{ SOURCE_DIRECTORY = 'assente' }
        }

        It "Allora la verifica fallisce nominando la cartella del codice" {
            $res.ExitCode | Should -Be 1
            Get-ClassIssue $res '^classi delle decisioni: codice sorgente assente \(assente\)$' | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    Context "Schema dello scenario: modalità della verifica (<Modo>)" -ForEach @(
        @{ Modo = 'warn'; Codice = 0; Livello = 'warning' }
        @{ Modo = 'off'; Codice = 0; Livello = $null }
    ) {
        BeforeAll {
            $files = New-ShopFiles
            $files['source/Contoso.Shop.Core/Queue/QueueTicketCanceller.cs'] = "namespace Contoso.Shop.Core.Queue;`n`npublic class QueueTicketCanceller { }`n"
            $res = Invoke-ClassCheck (New-ClassesCorpus $files) @{ GATE_MODE = $Modo }
        }

        It "Allora la verifica non blocca" {
            $res.ExitCode | Should -Be $Codice
        }

        It "E segnala la classe solo come avviso, o non la segnala" {
            $warnings = @(Get-Issues $res.Output 'warning' | Where-Object { $_ -match 'QueueTicketCanceller' })
            [bool]$warnings.Count | Should -Be ([bool]$Livello) -Because ($res.Output)
            Get-Issues $res.Output | Should -BeNullOrEmpty
        }
    }
}

Describe "DecisionClasses.ps1" {
    BeforeAll {
        . $ModulePath
    }

    Context "Get-FrontMatter" {
        It "legge i valori e le liste del frontmatter" {
            $fields = Get-FrontMatter "---`nstatus: accepted`ngoverns:`n  - A.B.*`n  - A.C`nversion: 2`n---`n# Titolo"
            $fields['status'] | Should -Be 'accepted'
            $fields['governs'] | Should -Be @('A.B.*', 'A.C')
            $fields['version'] | Should -Be '2'
        }

        It "non legge nulla senza frontmatter" {
            (Get-FrontMatter "# Titolo`nstatus: accepted").Count | Should -Be 0
        }
    }

    Context "Test-GovernedBy" {
        It "un nome completo copre solo la sua classe" {
            Test-GovernedBy 'A.B.Issuer' 'A.B.Issuer' | Should -BeTrue
            Test-GovernedBy 'A.B.IssuerFactory' 'A.B.Issuer' | Should -BeFalse
        }

        It "un prefisso con l'asterisco copre i nomi che cominciano cosi', con le maiuscole" {
            Test-GovernedBy 'A.B.Queue.Issuer' 'A.B.Queue.*' | Should -BeTrue
            Test-GovernedBy 'A.B.QueueTicketHandler' 'A.B.QueueTicket*' | Should -BeTrue
            Test-GovernedBy 'A.B.queueticketHandler' 'A.B.QueueTicket*' | Should -BeFalse
        }
    }

    Context "Get-GovernsEntryIssues" {
        BeforeAll {
            $types = @(
                [pscustomobject]@{ FullName = 'A.Chat.ChatClientFactory'; Name = 'ChatClientFactory' }
                [pscustomobject]@{ FullName = 'A.Chat.Profiles.IModelFamily'; Name = 'IModelFamily' }
                [pscustomobject]@{ FullName = 'A.Queue.QueueTicketIssuer'; Name = 'QueueTicketIssuer' }
                [pscustomobject]@{ FullName = 'Global'; Name = 'Global' }
            )
        }

        It "accetta i prefissi che contengono il namespace di ogni classe che coprono" {
            @(Get-GovernsEntryIssues ([pscustomobject]@{ Id = 'd'; Governs = @('A.Queue.*', 'A.Chat.Chat*', 'A.Chat.Profiles.*', 'Glo*') }) $types).Count | Should -Be 0
        }

        It "respinge il nome di una sola classe e i prefissi che scendono nei namespace annidati" {
            $issues = @(Get-GovernsEntryIssues ([pscustomobject]@{ Id = 'd'; Governs = @('A.Queue.QueueTicketIssuer', 'A.Chat.*', 'A.Chat.Pro*', 'A.*') }) $types)
            $issues | Should -Be @(
                'd: voce di governs con il nome di una sola classe (A.Queue.QueueTicketIssuer)'
                'd: voce di governs che copre un namespace intero (A.Chat.*)'
                'd: voce di governs che copre un namespace intero (A.Chat.Pro*)'
                'd: voce di governs che copre un namespace intero (A.*)'
            )
        }
    }

    Context "Get-ClassName" {
        It "toglie i parametri generici dall'etichetta della classe" {
            Get-ClassName 'Repository~T~' | Should -Be 'Repository'
            Get-ClassName 'Repository<T>' | Should -Be 'Repository'
            Get-ClassName 'Issuer' | Should -Be 'Issuer'
        }
    }

    Context "Get-UngovernedClassIssues (ADR-2175)" {
        It "nomina una volta sola, in ordine, le classi del diagramma che nessuna classe governata porta per nome" {
            $decision = [pscustomobject]@{ Id = 'd'; Classes = @('Issuer', 'BackgroundService', 'Issuer', 'Clock', 'Clock') }
            $governed = @([pscustomobject]@{ FullName = 'A.Queue.Issuer'; Name = 'Issuer' })
            Get-UngovernedClassIssues $decision $governed | Should -Be @(
                'd: classe del diagramma non governata (BackgroundService)'
                'd: classe del diagramma non governata (Clock)'
            )
        }

        It "non nomina nulla quando ogni classe del diagramma e' governata" {
            $decision = [pscustomobject]@{ Id = 'd'; Classes = @('Issuer') }
            @(Get-UngovernedClassIssues $decision @([pscustomobject]@{ FullName = 'A.Queue.Issuer'; Name = 'Issuer' })).Count | Should -Be 0
        }
    }

    Context "Get-DecisionClassesIssues" {
        BeforeAll {
            $root = Join-Path ([IO.Path]::GetTempPath()) "pester-decision-classes-unit-$(New-Guid)"
            $files = New-ShopFiles
            $files['source/Contoso.Shop.Core/Queue/QueueTicketCanceller.cs'] = "namespace Contoso.Shop.Core.Queue;`n`npublic partial class QueueTicketCanceller { }`n"
            $files['source/Contoso.Shop.Core/Queue/QueueTicketCanceller.Refund.cs'] = "namespace Contoso.Shop.Core.Queue;`n`npublic partial class QueueTicketCanceller { }`n"
            $corpus = New-ClassesCorpus $files
            $corpus['docs/decisions/0037-biglietti-chiusi.md'] = New-DecisionText -Status 'superseded'
            Write-SourceFiles $root $corpus
            $decisionsDirectory = Join-Path $root 'docs/decisions'
            $SourceDirectory = Join-Path $root 'sources'
            $issues = @(Get-DecisionClassesIssues)
        }

        AfterAll {
            Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
        }

        It "nomina una volta sola la classe governata che manca dal diagramma, anche se parziale in due file" {
            $issues | Should -Be @('0036-intenzioni-applicate-dopo-il-turno: classe governata assente dal diagramma delle classi (Contoso.Shop.Core.Queue.QueueTicketCanceller)')
        }
    }
}
