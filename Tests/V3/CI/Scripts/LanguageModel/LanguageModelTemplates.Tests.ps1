#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester della scelta del fornitore del modello nei template dei passi di documentazione.

.DESCRIPTION
    I template documentation-style, c4-describe, flows-verify e documentation-update passano il fornitore agli script del
    modello linguistico (V3/CI/Scripts/LanguageModel). I test leggono il testo dei template: con
    foundry il passo e' un AzureCLI@2 sulla service connection, con anthropic un PowerShell@2 che mappa
    la chiave in ANTHROPIC_API_KEY; le due varianti passano allo script le stesse variabili.
#>

BeforeAll {
    $script:Root = Resolve-Path "$PSScriptRoot/../../../../.."

    function Get-TemplateText([string]$Path) {
        return [IO.File]::ReadAllText((Join-Path $Root $Path)) -replace "`r`n", "`n"
    }

    # I rami di primo livello di steps: la condizione del blocco ${{ if }} e il suo testo.
    function Get-StepBranches([string]$Path) {
        $steps = ((Get-TemplateText $Path) -split "`nsteps:`n", 2)[1]
        $branches = @()
        $current = $null
        foreach ($line in ($steps -split "`n")) {
            if ($line -match '^  - (?:\$\{\{ if (.+) \}\}:|task:)') {
                if ($current) { $branches += [pscustomobject]$current }
                $current = @{ Condition = "$($Matches[1])"; Lines = [Collections.Generic.List[string]]::new() }
            }
            if ($current) { $current.Lines.Add($line) }
        }
        if ($current) { $branches += [pscustomobject]$current }
        return @($branches | ForEach-Object { [pscustomobject]@{ Condition = $_.Condition; Text = ($_.Lines -join "`n") } })
    }

    function Get-ProviderBranch([string]$Path, [string]$Provider, [string]$Script) {
        return @(Get-StepBranches $Path | Where-Object { $_.Condition -match "eq\(parameters\.provider, '$Provider'\)" -and $_.Text.Contains($Script) }) | Select-Object -First 1
    }

    function Get-EnvNames([string]$Text) {
        return @([regex]::Matches($Text, '(?m)^ {8}([A-Z][A-Z0-9_]*):') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    }

    function Get-ParameterDefault([string]$Path, [string]$Name) {
        $match = [regex]::Match((Get-TemplateText $Path), "(?m)^  - name: $Name\n    type: \w+\n    default: (.+)$")
        return $match.Groups[1].Value
    }
}

Describe "Scelta del fornitore nel template <Template>" -ForEach @(
    @{ Template = 'V3/CI/Common/Steps/documentation-style.yaml'; Script = 'Test-DocumentationStyle.ps1'; Prefix = 'STYLE_JUDGE' }
    @{ Template = 'V3/CI/Common/Steps/c4-describe.yaml'; Script = 'Write-C4ModelText.ps1'; Prefix = 'C4_TEXT' }
    @{ Template = 'V3/CI/Common/Steps/flows-verify.yaml'; Script = 'Repair-DiagramFlows.ps1'; Prefix = 'FLOWS_REPAIR' }
    @{ Template = 'V3/CI/Common/Steps/documentation-update.yaml'; Script = 'Update-Documentation.ps1'; Prefix = 'DOCS_UPDATE' }
) {
    BeforeAll {
        $foundry = Get-ProviderBranch $Template 'foundry' $Script
        $anthropic = Get-ProviderBranch $Template 'anthropic' $Script
    }

    It "Senza fornitore dichiarato il passo usa Foundry" {
        Get-ParameterDefault $Template 'provider' | Should -Be "'foundry'"
    }

    It "La chiave Anthropic è di default la variabile segreta anthropicApiKey del consumer" {
        Get-ParameterDefault $Template 'anthropicApiKey' | Should -Be "'`$(anthropicApiKey)'"
    }

    It "Con Foundry il passo è un AzureCLI@2 sulla service connection, senza chiave Anthropic" {
        $foundry | Should -Not -BeNullOrEmpty
        $foundry.Text | Should -Match 'task: AzureCLI@2'
        $foundry.Text | Should -Match 'template: ensure-azure-cli\.yaml'
        $foundry.Text | Should -Match 'azureSubscription: \$\{\{ parameters\.serviceConnection \}\}'
        $foundry.Text | Should -Not -Match 'ANTHROPIC_API_KEY'
    }

    It "Con Anthropic il passo è un PowerShell@2 senza service connection né Azure CLI" {
        $anthropic | Should -Not -BeNullOrEmpty
        $anthropic.Text | Should -Match 'task: PowerShell@2'
        $anthropic.Text | Should -Match 'pwsh: true'
        $anthropic.Text | Should -Not -Match 'azureSubscription|ensure-azure-cli|AzureCLI@2'
    }

    It "Con Anthropic la chiave arriva allo script in ANTHROPIC_API_KEY" {
        $anthropic.Text | Should -Match '(?m)^ {8}ANTHROPIC_API_KEY: \$\{\{ parameters\.anthropicApiKey \}\}$'
    }

    It "Lo script riceve il fornitore scelto" {
        foreach ($branch in $foundry, $anthropic) { $branch.Text | Should -Match "(?m)^ {8}$($Prefix)_PROVIDER: \`$\{\{ parameters\.provider \}\}$" }
    }

    It "Le due varianti passano allo script le stesse variabili, oltre alla chiave" {
        $foundryNames = Get-EnvNames $foundry.Text
        $anthropicNames = Get-EnvNames $anthropic.Text | Where-Object { $_ -ne 'ANTHROPIC_API_KEY' }
        ($anthropicNames -join ', ') | Should -Be ($foundryNames -join ', ')
    }
}

Describe "Scelta del fornitore negli entry point <Template>" -ForEach @(
    @{ Template = 'V3/CI/Agnostic/quality-arc42.yaml' }
    @{ Template = 'V3/CI/Agnostic/quality-docs.yaml' }
) {
    It "Il giudizio dello stile riceve fornitore e chiave dai parametri styleProvider e styleAnthropicApiKey" {
        $text = Get-TemplateText $Template
        $text | Should -Match '(?m)^ {12}provider: \$\{\{ parameters\.styleProvider \}\}$'
        $text | Should -Match '(?m)^ {12}anthropicApiKey: \$\{\{ parameters\.styleAnthropicApiKey \}\}$'
        Get-ParameterDefault $Template 'styleProvider' | Should -Be "'foundry'"
        Get-ParameterDefault $Template 'styleAnthropicApiKey' | Should -Be "'`$(anthropicApiKey)'"
    }
}

Describe "Riparazione dei diagrammi con Anthropic" {
    It "In modalità fix parte con il fornitore anthropic anche senza endpoint" {
        $branch = Get-ProviderBranch 'V3/CI/Common/Steps/flows-verify.yaml' 'anthropic' 'Repair-DiagramFlows.ps1'
        $branch.Condition | Should -Be "and(eq(parameters.mode, 'fix'), eq(parameters.provider, 'anthropic'))"
    }
}
