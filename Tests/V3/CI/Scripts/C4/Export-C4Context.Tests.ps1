#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/C4/Export-C4Context.ps1

.DESCRIPTION
    Ogni scenario scrive i testi del modello di alcuni repository sorgente in una cartella delle parti
    generate ed esegue lo script come in pipeline, poi legge il contesto scritto.
#>

BeforeAll {
    . "$PSScriptRoot/Fixtures/C4CodeFixture.ps1"

    function New-ModelText([hashtable]$People = @{}, [hashtable]$ExternalSystems = @{}) {
        return @{ units = @{}; people = $People; externalSystems = $ExternalSystems } | ConvertTo-Json -Depth 10
    }

    function Invoke-Context([System.Collections.IDictionary]$Texts) {
        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-context-$(New-Guid)"
        $generated = Join-Path $root 'generated'
        New-Item -ItemType Directory -Force -Path $generated | Out-Null
        $Texts.Keys | ForEach-Object { [IO.File]::WriteAllText((Join-Path $generated $_), $Texts[$_]) }
        $contextFile = Join-Path $root 'model/context.dsl'
        try {
            $result = Invoke-C4Script 'C4/Export-C4Context.ps1' @{ GENERATED_DIRECTORY = $generated; CONTEXT_FILE = $contextFile; DOCUMENT_LANGUAGE = ''; GATE_MODE = '' }
            $result.Context = if (Test-Path $contextFile) { [IO.File]::ReadAllText($contextFile) } else { $null }
            return $result
        }
        finally { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    }
}


Describe "Funzionalità: Contesto del modello C4 composto dai testi dei repository" {

    Context "Scenario: persone e sistemi esterni dichiarati da piu' repository" {
        BeforeAll {
            $res = Invoke-Context ([ordered]@{
                    'aidea.dxp.ai.text.json'      = New-ModelText @{ cittadino = @{ name = 'Cittadino'; description = 'Scrive all''ente.'; technical = $false } }
                    'aidea.dxp.bff.web.text.json' = New-ModelText @{ cittadino = @{ name = 'Cittadina'; description = 'Apre la chat.'; technical = $false } } @{ entra = @{ name = 'Entra ID'; description = 'Autentica.'; technical = $true } }
                })
        }

        It "Allora il contesto si scrive" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E un identificativo dichiarato da due testi vale una volta, con il testo che viene prima per nome" {
            @($res.Context -split "`n" | Where-Object { $_ -match '^cittadino = ' }) | Should -Be @('cittadino = person "Cittadino" "Scrive all''ente." ""')
        }

        It "E il sistema esterno tecnico porta i tag degli esterni e dei tecnici" {
            $res.Context | Should -Match 'entra = softwareSystem "Entra ID" "Autentica\." "Esterno,Tecnico"'
        }
    }

    Context "Scenario: un testo che non si legge" {
        BeforeAll {
            $res = Invoke-Context ([ordered]@{ 'aidea.dxp.ai.text.json' = '{ non json' })
        }

        It "Allora lo script fallisce nominando il testo" {
            $res.ExitCode | Should -Not -Be 0
            $res.Output | Should -Match "testo del modello non leggibile \(aidea\.dxp\.ai\.text\.json\)"
        }

        It "E il contesto non si scrive" {
            $res.Context | Should -BeNullOrEmpty
        }
    }
}
