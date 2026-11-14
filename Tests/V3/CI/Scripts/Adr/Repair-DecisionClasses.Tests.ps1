#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Adr/Repair-DecisionClasses.ps1

.DESCRIPTION
    Come la generazione dopo l'integrazione in main: la copia della documentazione ha un origin locale,
    dove vive il ramo di avanzamento, e il codice dei repository sorgente e' un repository .NET finto. Il
    modello linguistico e' un endpoint locale (LanguageModel/Fixtures/ModelEndpointStub.ps1) che risponde
    come Azure OpenAI con le stesure registrate, una per richiesta (l'ultima si ripete), e conserva le
    richieste. Le prove verificano cosa lo script manda al modello e come accetta, scarta e salva le
    stesure. Lo script gira come in pipeline, in un processo separato; richiede Node.js per il parser
    Mermaid.
#>

BeforeAll {
    . "$PSScriptRoot/../C4/Fixtures/C4CodeFixture.ps1"
    . "$PSScriptRoot/../LanguageModel/Fixtures/ModelEndpointStub.ps1"
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts/Adr/Repair-DecisionClasses.ps1"
    $ModulePath = $ScriptPath
    $previousToolsDirectory = $env:AGENT_TOOLSDIRECTORY
    $env:AGENT_TOOLSDIRECTORY = Join-Path ([IO.Path]::GetTempPath()) "pester-decision-classes-repair-$(New-Guid)"
    $Stub = Start-ModelEndpoint

    $DecisionPath = 'docs/decisions/0036-biglietti-dopo-il-turno.md'
    $CandidatesPath = 'docs/architecture/c4/generated/decisions.classes.json'
    $ProgressBranch = 'c4/model'
    $Governs = @('Contoso.Shop.Core.Queue.QueueTicketIssuer', 'Contoso.Shop.Core.Queue.IQueueTicketIssuer')

    function New-Structure([string[]]$Classes) {
        $lines = @('```mermaid', 'classDiagram') + @($Classes | ForEach-Object { "    class $_" }) + @('```', '', 'Le classi emettono il biglietto.')
        return $lines -join "`n"
    }

    $Structure = New-Structure @('IQueueTicketIssuer', 'QueueTicketIssuer')
    $Decision = @(
        '---', 'status: accepted', 'governs:', '  - Contoso.Shop.Core.Queue.QueueTicketIssuer', '  - Contoso.Shop.Core.Queue.IQueueTicketIssuer', '---', '',
        '# Biglietti emessi dopo il turno', '', '## Contesto e problema', '', 'Il biglietto si emette a turno finito.', '',
        '## Opzioni considerate', '', "- Un emettitore dopo il turno.", '', '## Esito della decisione', '', "Si sceglie l'emettitore.", '',
        '## Struttura nel codice', '', $Structure, '',
        '## Flusso nel codice', '', '```mermaid', 'sequenceDiagram', '    participant QueueTicketIssuer', '    participant IQueueTicketIssuer', '    QueueTicketIssuer->>IQueueTicketIssuer: emette', '```', ''
    ) -join "`n"

    function New-ShopFiles([hashtable]$Extra = @{}) {
        $files = [ordered]@{}
        Add-Project $files 'Contoso.Shop.Core' (New-Project)
        $files['source/Contoso.Shop.Core/Queue/QueueTicketIssuer.cs'] = "namespace Contoso.Shop.Core.Queue;`n`npublic interface IQueueTicketIssuer { }`n`npublic sealed class QueueTicketIssuer : IQueueTicketIssuer { }`n"
        foreach ($name in $Extra.Keys) { $files["source/Contoso.Shop.Core/Queue/$name.cs"] = "namespace Contoso.Shop.Core.Queue;`n`n$($Extra[$name])`n" }
        return $files
    }

    function New-Draft([string[]]$Additions = @(), [string]$Structure = '', [string]$Version = 'classi del biglietto allineate al codice') {
        $content = @{ governs = @($Additions); structure = $Structure; version = $Version } | ConvertTo-Json -Depth 5 -Compress
        return New-ModelResponse 200 @{ choices = @(@{ message = @{ role = 'assistant'; content = $content } }); usage = @{ prompt_tokens = 100; completion_tokens = 10 } }
    }

    function Invoke-Git([string]$Directory) {
        $output = & git -C $Directory @args 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' '): $output" }
        return $output
    }

    # La documentazione su un origin locale, il codice in una cartella accanto; Progress e' il testo della
    # decisione e il registro gia' salvati sul ramo di avanzamento da una run interrotta.
    function New-Workspace([System.Collections.IDictionary]$Files, [string]$DecisionText = $Decision, [string]$Candidates, [hashtable]$Progress) {
        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-decision-classes-repair-$(New-Guid)"
        $origin = Join-Path $root 'origin.git'
        $docs = Join-Path $root 'docs'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        Invoke-Git $root init -q --bare -b main $origin | Out-Null
        Invoke-Git $root clone -q $origin $docs | Out-Null
        Write-SourceFiles $docs ([ordered]@{ $DecisionPath = $DecisionText })
        if ($Candidates) { Write-SourceFiles $docs ([ordered]@{ $CandidatesPath = $Candidates }) }
        Invoke-Git $docs add -A | Out-Null
        Invoke-Git $docs -c user.name=Test -c user.email=test@local commit -q -m 'docs: decisions' | Out-Null
        Invoke-Git $docs push -q origin HEAD:main | Out-Null
        if ($Progress) {
            Invoke-Git $docs checkout -q -b $ProgressBranch | Out-Null
            Write-SourceFiles $docs $Progress
            Invoke-Git $docs add -A | Out-Null
            Invoke-Git $docs -c user.name=Test -c user.email=test@local commit -q -m 'docs: progress' | Out-Null
            Invoke-Git $docs push -q origin "HEAD:$ProgressBranch" | Out-Null
            Invoke-Git $docs checkout -q main | Out-Null
            Invoke-Git $docs branch -q --delete --force $ProgressBranch | Out-Null
        }
        Write-SourceFiles (Join-Path $root 'sources') $Files
        return @{ Root = $root; Origin = $origin; Docs = $docs; Sources = (Join-Path $root 'sources/source') }
    }

    function Invoke-Repair($Workspace, [object[]]$Responses, [hashtable]$Environment = @{}) {
        Reset-ModelEndpoint $Stub $Responses
        $variables = [ordered]@{
            GATE_MODE = ''; DOCUMENT_LANGUAGE = ''; DECISIONS_DIRECTORY = ''; SOURCE_DIRECTORY = $Workspace.Sources
            CLASSES_REPAIR_PROVIDER = 'foundry'; CLASSES_REPAIR_ENDPOINT = $Stub.Endpoint; CLASSES_REPAIR_MODEL = 'documentazione'
            CLASSES_REPAIR_TOKEN = 'token-di-prova'; CLASSES_REPAIR_MAX_DRAFTS = '2'; CANDIDATES_FILE = $CandidatesPath; PROGRESS_BRANCH = $ProgressBranch
            SYSTEM_ACCESSTOKEN = ''; STYLE_GUIDE = ''
        }
        foreach ($name in $Environment.Keys) { $variables[$name] = $Environment[$name] }
        $previous = @{}
        foreach ($name in $variables.Keys) { $previous[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $variables[$name]) }
        Push-Location $Workspace.Docs
        try {
            $command = "`$ErrorActionPreference = 'Stop'; & '$($ScriptPath -replace "'", "''")'; exit `$LASTEXITCODE"
            $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -Command $command 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            Pop-Location
            foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
        }
        $progress = git -C $Workspace.Origin show "refs/heads/${ProgressBranch}:$DecisionPath" 2>$null
        $global:LASTEXITCODE = 0
        $candidatesFile = Join-Path $Workspace.Docs $CandidatesPath
        return @{
            ExitCode   = $exitCode
            Output     = ($output -join "`n")
            Decision   = [IO.File]::ReadAllText((Join-Path $Workspace.Docs $DecisionPath))
            Candidates = if (Test-Path $candidatesFile) { Get-Content -Raw $candidatesFile | ConvertFrom-Json } else { $null }
            Progress   = ($progress -join "`n")
            Requests   = @(Get-ModelEndpointRequests $Stub)
        }
    }

    function Remove-Workspace($Workspace) {
        Remove-Item -Recurse -Force $Workspace.Root -ErrorAction SilentlyContinue
    }

    function Get-UserMessage($Request) {
        return @($Request.Body.messages | Where-Object role -EQ 'user')[0].content
    }
}

AfterAll {
    Stop-ModelEndpoint $Stub
    Remove-Item -Recurse -Force $env:AGENT_TOOLSDIRECTORY -ErrorAction SilentlyContinue
    $env:AGENT_TOOLSDIRECTORY = $previousToolsDirectory
}

Describe "Funzionalità: Il modello propone pattern e diagramma delle classi delle decisioni" {

    Context "Scenario: decisione che la verifica respinge per una classe governata assente dal diagramma" {
        BeforeAll {
            $files = New-ShopFiles @{ QueueTicketCanceller = 'public class QueueTicketCanceller { }' }
            $text = $Decision -replace '(?m)^  - Contoso\.Shop\.Core\.Queue\.QueueTicketIssuer$', '  - Contoso.Shop.Core.Queue.QueueTicket*'
            $workspace = New-Workspace $files $text
            $res = Invoke-Repair $workspace @(New-Draft -Structure (New-Structure @('IQueueTicketIssuer', 'QueueTicketIssuer', 'QueueTicketCanceller')))
        }

        AfterAll { Remove-Workspace $workspace }

        It "Allora il modello riceve il rilievo con la classe e la decisione" {
            $res.Requests.Count | Should -Be 1 -Because ($res.Output)
            Get-UserMessage $res.Requests[0] | Should -Match 'classe governata assente dal diagramma delle classi \(Contoso\.Shop\.Core\.Queue\.QueueTicketCanceller\)'
        }

        It "E riceve il codice della classe" {
            Get-UserMessage $res.Requests[0] | Should -Match 'public class QueueTicketCanceller'
        }

        It "E il diagramma delle classi della decisione contiene la classe" {
            $res.Decision | Should -Match '(?m)^    class QueueTicketCanceller$'
        }

        It "E la decisione ha una versione nuova con la sua voce" {
            $res.Decision | Should -Match '(?m)^version: 2$'
            $res.Decision | Should -Match "(?m)^## Versioni`n`n- 2: classi del biglietto allineate al codice$"
        }

        It "E il resto della decisione non cambia" {
            $res.Decision | Should -Match "(?m)^## Esito della decisione`n`nSi sceglie l'emettitore\.$"
            $res.Decision | Should -Match '(?m)^    QueueTicketIssuer->>IQueueTicketIssuer: emette$'
        }

        It "E la decisione e' salvata sul ramo di avanzamento" {
            $res.Progress | Should -Match '(?m)^    class QueueTicketCanceller$'
        }

        It "E il passo non fallisce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }
    }

    Context "Scenario: classe nuova che nessun pattern copre ma che appartiene alla decisione" {
        BeforeAll {
            $workspace = New-Workspace (New-ShopFiles @{ QueueTicketRefunder = 'public sealed class QueueTicketRefunder : IQueueTicketIssuer { }' })
            $res = Invoke-Repair $workspace @(New-Draft @('Contoso.Shop.Core.Queue.QueueTicketRefunder') (New-Structure @('IQueueTicketIssuer', 'QueueTicketIssuer', 'QueueTicketRefunder')) 'emettitore del rimborso governato')
        }

        AfterAll { Remove-Workspace $workspace }

        It "Allora il modello riceve la classe come candidata" {
            Get-UserMessage $res.Requests[0] | Should -Match "CLASSI CANDIDATE`n- Contoso\.Shop\.Core\.Queue\.QueueTicketRefunder"
        }

        It "E la lista governs si allarga alla classe" {
            $res.Decision | Should -Match "(?m)^  - Contoso\.Shop\.Core\.Queue\.IQueueTicketIssuer`n  - Contoso\.Shop\.Core\.Queue\.QueueTicketRefunder$"
        }

        It "E il registro delle candidate ricorda la classe" {
            @($res.Candidates.'0036-biglietti-dopo-il-turno') | Should -Contain 'Contoso.Shop.Core.Queue.QueueTicketRefunder'
        }
    }

    Context "Scenario: classe candidata che non appartiene alla decisione" {
        BeforeAll {
            $workspace = New-Workspace (New-ShopFiles @{ QueueMetrics = 'public static class QueueMetrics { }' })
            $res = Invoke-Repair $workspace @(New-Draft)
            $again = Invoke-Repair $workspace @(New-Draft)
        }

        AfterAll { Remove-Workspace $workspace }

        It "Allora la decisione non cambia" {
            $res.Decision | Should -Be $Decision
        }

        It "E il registro ricorda la classe vista" {
            @($res.Candidates.'0036-biglietti-dopo-il-turno') | Should -Be @('Contoso.Shop.Core.Queue.QueueMetrics')
        }

        It "E la run successiva non richiama il modello per la stessa classe" {
            $res.Requests.Count | Should -Be 1
            $again.Requests.Count | Should -Be 0 -Because ($again.Output)
        }
    }

    Context "Scenario: stesura respinta dalla verifica" {
        BeforeAll {
            $files = New-ShopFiles @{ QueueTicketCanceller = 'public class QueueTicketCanceller { }' }
            $workspace = New-Workspace $files ($Decision -replace '(?m)^  - Contoso\.Shop\.Core\.Queue\.QueueTicketIssuer$', '  - Contoso.Shop.Core.Queue.QueueTicket*')
            $res = Invoke-Repair $workspace @(
                (New-Draft -Structure (New-Structure @('IQueueTicketIssuer', 'QueueTicketIssuer'))),
                (New-Draft -Structure (New-Structure @('IQueueTicketIssuer', 'QueueTicketIssuer', 'QueueTicketCanceller')))
            )
        }

        AfterAll { Remove-Workspace $workspace }

        It "Allora la stesura torna al modello con il motivo dello scarto" {
            $res.Requests.Count | Should -Be 2
            Get-UserMessage $res.Requests[1] | Should -Match "STESURA SCARTATA[\s\S]*classe governata assente dal diagramma delle classi \(Contoso\.Shop\.Core\.Queue\.QueueTicketCanceller\)"
        }

        It "E la seconda stesura entra nella decisione" {
            $res.Decision | Should -Match '(?m)^    class QueueTicketCanceller$'
        }
    }

    Context "Scenario: stesure tutte respinte" {
        BeforeAll {
            $files = New-ShopFiles @{ QueueTicketCanceller = 'public class QueueTicketCanceller { }' }
            $text = $Decision -replace '(?m)^  - Contoso\.Shop\.Core\.Queue\.QueueTicketIssuer$', '  - Contoso.Shop.Core.Queue.QueueTicket*'
            $workspace = New-Workspace $files $text
            $res = Invoke-Repair $workspace @(New-Draft -Structure (New-Structure @('QueueTicketIssuer')))
        }

        AfterAll { Remove-Workspace $workspace }

        It "Allora la decisione resta com'era" {
            $res.Decision | Should -Be $text
        }

        It "E il passo segnala la decisione senza fallire" {
            $res.ExitCode | Should -Be 0
            Get-Issues $res.Output 'warning' | Should -Match '0036-biglietti-dopo-il-turno non aggiornata'
        }

        It "E il modello ha ricevuto al massimo le stesure ammesse" {
            $res.Requests.Count | Should -Be 2
        }
    }

    Context "Scenario: modello linguistico non disponibile" {
        BeforeAll {
            $files = New-ShopFiles @{ QueueTicketCanceller = 'public class QueueTicketCanceller { }' }
            $text = $Decision -replace '(?m)^  - Contoso\.Shop\.Core\.Queue\.QueueTicketIssuer$', '  - Contoso.Shop.Core.Queue.QueueTicket*'
            $workspace = New-Workspace $files $text
            $res = Invoke-Repair $workspace @(New-ModelResponse 401 @{ error = @{ message = 'non autorizzato' } })
        }

        AfterAll { Remove-Workspace $workspace }

        It "Allora il passo fallisce" {
            $res.ExitCode | Should -Be 1
            Get-Issues $res.Output | Should -Match '^proposta delle classi delle decisioni: proposta interrotta \(0036-biglietti-dopo-il-turno: '
        }

        It "E la decisione non cambia" {
            $res.Decision | Should -Be $text
        }
    }

    Context "Scenario: run rilanciata dopo una decisione accettata" {
        BeforeAll {
            $files = New-ShopFiles @{ QueueTicketCanceller = 'public class QueueTicketCanceller { }' }
            $text = $Decision -replace '(?m)^  - Contoso\.Shop\.Core\.Queue\.QueueTicketIssuer$', '  - Contoso.Shop.Core.Queue.QueueTicket*'
            $accepted = ($text -replace '(?m)^    class QueueTicketIssuer$', "    class QueueTicketIssuer`n    class QueueTicketCanceller") -replace 'status: accepted', "status: accepted`nversion: 2"
            $accepted += "`n## Versioni`n`n- 2: classi del biglietto allineate al codice`n"
            $workspace = New-Workspace $files $text -Progress ([ordered]@{ $DecisionPath = $accepted })
            $res = Invoke-Repair $workspace @(New-Draft)
        }

        AfterAll { Remove-Workspace $workspace }

        It "Allora il testo gia' accettato non si riscrive" {
            $res.Requests.Count | Should -Be 0 -Because ($res.Output)
        }

        It "E la decisione riprende dal ramo di avanzamento" {
            $res.Decision | Should -Match '(?m)^    class QueueTicketCanceller$'
            $res.ExitCode | Should -Be 0
        }
    }

    Context "Scenario: decisioni in pari con il codice" {
        BeforeAll {
            $workspace = New-Workspace (New-ShopFiles)
            $res = Invoke-Repair $workspace @(New-Draft) @{ CLASSES_REPAIR_ENDPOINT = '' }
        }

        AfterAll { Remove-Workspace $workspace }

        It "Allora il modello non si chiama, nemmeno configurato" {
            $res.Requests.Count | Should -Be 0
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }
    }
}

Describe "Repair-DecisionClasses.ps1" {
    BeforeAll {
        . (Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts/Common/VerificationGate.ps1")
        # Il mock e' un alias, che vince sulla funzione ridefinita dallo script: lo script si legge senza eseguirsi.
        Mock Invoke-Verification { }
        . $ModulePath
    }

    Context "Get-DraftText" {
        It "aggiunge le voci di governs, riscrive la struttura e versiona la decisione" {
            $draft = [pscustomobject]@{ governs = @('Contoso.Shop.Core.Queue.QueueTicketRefunder', 'Contoso.Shop.Core.Queue.QueueTicketIssuer'); structure = 'Testo nuovo.'; version = 'rimborso' }
            $text = Get-DraftText $Decision $draft $Governs
            $text | Should -Match "(?m)^  - Contoso\.Shop\.Core\.Queue\.IQueueTicketIssuer`n  - Contoso\.Shop\.Core\.Queue\.QueueTicketRefunder`nversion: 2`n---$"
            $text | Should -Match "## Struttura nel codice`n`nTesto nuovo\.`n`n## Flusso nel codice"
            $text | Should -Match "## Versioni`n`n- 2: rimborso`n?$"
        }

        It "aggiunge la voce in fondo alle versioni che ci sono gia'" {
            $versioned = ($Decision -replace 'status: accepted', "status: accepted`nversion: 3") + "`n## Versioni`n`n- 2: prima`n- 3: seconda`n"
            $text = Get-DraftText $versioned ([pscustomobject]@{ governs = @(); structure = 'Altro.'; version = 'terza' }) $Governs
            $text | Should -Match "(?m)^version: 4$"
            $text | Should -Match "- 3: seconda`n- 4: terza"
        }

        It "non cambia nulla senza voci nuove e senza struttura" {
            Get-DraftText $Decision ([pscustomobject]@{ governs = @('Contoso.Shop.Core.Queue.QueueTicketIssuer'); structure = ' '; version = 'x' }) $Governs | Should -BeNullOrEmpty
        }
    }

    Context "Read-Candidates e Get-Candidates" {
        It "legge il registro per decisione" {
            $ledger = Read-Candidates '{ "0036-a": ["A.B.C"], "0037-b": [] }'
            $ledger['0036-a'] | Should -Be @('A.B.C')
            @($ledger['0037-b']).Count | Should -Be 0
            (Read-Candidates '').Count | Should -Be 0
        }

        It "propone le classi dei namespace governati che nessun pattern copre e che il registro non ha" {
            $types = @(
                [pscustomobject]@{ FullName = 'A.Queue.Issuer'; Name = 'Issuer' }
                [pscustomobject]@{ FullName = 'A.Queue.Refunder'; Name = 'Refunder' }
                [pscustomobject]@{ FullName = 'A.Queue.Metrics'; Name = 'Metrics' }
                [pscustomobject]@{ FullName = 'A.Billing.Invoice'; Name = 'Invoice' }
            )
            $decision = [pscustomobject]@{ Id = '0036-a'; Governs = @('A.Queue.Issuer') }
            @(Get-Candidates $decision $types @{ '0036-a' = @('A.Queue.Metrics') }).FullName | Should -Be @('A.Queue.Refunder')
        }
    }

    Context "Repair-DecisionClasses nel processo dei test" {
        BeforeAll {
            function Invoke-InProcess($Workspace, [object[]]$Responses) {
                Reset-ModelEndpoint $Stub $Responses
                $script:Usage = @{ Requests = 0; Input = 0; Output = 0 }
                $SourceDirectory = $Workspace.Sources
                $decisionsDirectory = Join-Path $Workspace.Docs 'docs/decisions'
                $CandidatesFile = Join-Path $Workspace.Docs $CandidatesPath
                $Provider = 'foundry'
                $Endpoint = $Stub.Endpoint
                $ModelName = 'documentazione'
                $MaxDrafts = 2
                $ProgressBranch = 'c4/model'
                $env:CLASSES_REPAIR_TOKEN = 'token-di-prova'
                Push-Location $Workspace.Docs
                try { $issues = @(Repair-DecisionClasses 6>$null) }
                finally { Pop-Location; $env:CLASSES_REPAIR_TOKEN = $null }
                $progress = git -C $Workspace.Origin show "refs/heads/${ProgressBranch}:$DecisionPath" 2>$null
                $global:LASTEXITCODE = 0
                return @{
                    Issues   = $issues
                    Decision = [IO.File]::ReadAllText((Join-Path $Workspace.Docs $DecisionPath))
                    Progress = ($progress -join "`n")
                    Requests = @(Get-ModelEndpointRequests $Stub)
                }
            }

            $text = $Decision -replace '(?m)^  - Contoso\.Shop\.Core\.Queue\.QueueTicketIssuer$', '  - Contoso.Shop.Core.Queue.QueueTicket*'
            $files = New-ShopFiles @{ QueueTicketCanceller = 'public class QueueTicketCanceller { }' }
            $repaired = New-Draft -Structure (New-Structure @('IQueueTicketIssuer', 'QueueTicketIssuer', 'QueueTicketCanceller'))
        }

        It "accetta la stesura e la salva sul ramo di avanzamento, che una run rilanciata riprende" {
            $workspace = New-Workspace $files $text
            try {
                $res = Invoke-InProcess $workspace @($repaired)
                $res.Issues.Count | Should -Be 0
                $res.Decision | Should -Match '(?m)^    class QueueTicketCanceller$'
                $res.Progress | Should -Match '(?m)^    class QueueTicketCanceller$'

                [IO.File]::WriteAllText((Join-Path $workspace.Docs $DecisionPath), $text)
                $again = Invoke-InProcess $workspace @($repaired)
                $again.Requests.Count | Should -Be 0
                $again.Decision | Should -Match '(?m)^    class QueueTicketCanceller$'
            }
            finally { Remove-Workspace $workspace }
        }

        It "lascia la decisione com'era quando ogni stesura e' respinta" {
            $workspace = New-Workspace $files $text
            try {
                $res = Invoke-InProcess $workspace @((New-Draft -Structure (New-Structure @('QueueTicketIssuer'))))
                $res.Requests.Count | Should -Be 2
                $res.Issues.Count | Should -Be 0
                $res.Decision | Should -Be $text
            }
            finally { Remove-Workspace $workspace }
        }

        It "nomina la decisione quando il modello non risponde" {
            $workspace = New-Workspace $files $text
            try {
                $res = Invoke-InProcess $workspace @(New-ModelResponse 401 @{ error = @{ message = 'non autorizzato' } })
                "$($res.Issues)" | Should -Match 'proposta interrotta'
                "$($res.Issues)" | Should -Match '0036-biglietti-dopo-il-turno'
            }
            finally { Remove-Workspace $workspace }
        }

        It "non chiama il modello quando il codice sorgente manca" {
            $workspace = New-Workspace $files $text
            try {
                Remove-Item -Recurse -Force $workspace.Sources
                $res = Invoke-InProcess $workspace @($repaired)
                "$($res.Issues)" | Should -Match 'codice sorgente assente'
                $res.Requests.Count | Should -Be 0
            }
            finally { Remove-Workspace $workspace }
        }
    }
}
