# SPDX-License-Identifier: Apache-2.0

#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester del gate sulle fonti della PR nel modulo di quality GitFlow.

.DESCRIPTION
    Le condition dei job si leggono dal testo dei template, con i parametri sostituiti come farebbe
    l'espansione, e si valutano con le funzioni di espressione di Azure Pipelines che usano.
#>

BeforeAll {
    $script:Root = Resolve-Path "$PSScriptRoot/../../../../.."

    function Get-TemplateText([string]$Path) {
        return [IO.File]::ReadAllText((Join-Path $Root $Path)) -replace "`r`n", "`n"
    }

    function Get-TemplateDefault([string]$Path, [string]$Parameter) {
        $block = [regex]::Match((Get-TemplateText $Path), "(?s)\n  - name: $Parameter\n(.*?)(?=\n\s*\n|\n  - name:|\n\S)")
        return [regex]::Match($block.Groups[1].Value, "default:\s*'([^']*)'").Groups[1].Value
    }

    function Get-JobCondition([string]$Text, [string]$Anchor) {
        $start = $Text.IndexOf($Anchor)
        if ($start -lt 0) { throw "Manca '$Anchor'" }
        $match = [regex]::Match($Text.Substring($start), '(?m)^( +)condition: (.+)$')
        if ($match.Groups[2].Value -ne '>-') { return $match.Groups[2].Value }
        $indent = $match.Groups[1].Value.Length
        $folded = foreach ($line in $Text.Substring($start + $match.Index + $match.Length + 1) -split "`n") {
            if ($line -notmatch "^ {$($indent + 1),}\S") { break }
            $line.Trim()
        }
        return $folded -join ' '
    }

    function Expand-Parameters([string]$Expression, [hashtable]$Parameters) {
        return [regex]::Replace($Expression, '\$\{\{ parameters\.(\w+) \}\}', { param($m) $Parameters[$m.Groups[1].Value] })
    }

    function Invoke-Condition([string]$Expression, [hashtable]$Variables = @{}, [hashtable]$Results = @{}) {
        $state = @{ Text = $Expression; At = 0 }

        function Skip-Blank { while ($state.At -lt $state.Text.Length -and $state.Text[$state.At] -eq ' ') { $state.At++ } }

        function Read-Expected([string]$Token) {
            Skip-Blank
            if ($state.Text.Substring($state.At, $Token.Length) -ne $Token) { throw "Atteso '$Token' a $($state.At) in: $($state.Text)" }
            $state.At += $Token.Length
        }

        function Read-String {
            Read-Expected "'"
            $end = $state.Text.IndexOf("'", $state.At)
            $value = $state.Text.Substring($state.At, $end - $state.At)
            $state.At = $end + 1
            return $value
        }

        function Read-Value {
            Skip-Blank
            if ($state.Text[$state.At] -eq "'") { return Read-String }
            $name = [regex]::Match($state.Text.Substring($state.At), '^[\w.]+').Value
            $state.At += $name.Length
            if ($name -eq 'variables') {
                Read-Expected '['; $key = Read-String; Read-Expected ']'
                return [string]$Variables[$key]
            }
            if ($name -like 'dependencies.*.result') { return $Results[$name.Split('.')[1]] }
            Read-Expected '('
            $arguments = @()
            Skip-Blank
            while ($state.Text[$state.At] -ne ')') {
                $arguments += , (Read-Value)
                Skip-Blank
                if ($state.Text[$state.At] -eq ',') { $state.At++ }
                Skip-Blank
            }
            $state.At++
            switch ($name) {
                'and' { return @($arguments | Where-Object { -not $_ }).Count -eq 0 }
                'not' { return -not $arguments[0] }
                'canceled' { return $false }
                'eq' { return $arguments[0] -eq $arguments[1] }
                'ne' { return $arguments[0] -ne $arguments[1] }
                'in' { return @($arguments[1..($arguments.Count - 1)]) -contains $arguments[0] }
                'split' { return , ([string]$arguments[0]).Split([string]$arguments[1]) }
                'replace' { return ([string]$arguments[0]).Replace([string]$arguments[1], [string]$arguments[2]) }
                'containsValue' { return @($arguments[0]) -contains $arguments[1] }
                default { throw "Funzione non gestita: $name" }
            }
        }

        $value = Read-Value
        Skip-Blank
        if ($state.At -ne $state.Text.Length) { throw "Espressione non consumata: $($state.Text.Substring($state.At))" }
        return [bool]$value
    }

    $script:Module = 'V3/CI/GitFlow/Modules/quality.yaml'

    function Test-SourcesJobRuns([string]$Template, [hashtable]$Overrides = @{}, [string]$Reason = 'PullRequest', [string]$TargetBranch) {
        $parameters = @{
            sourcesGateMode     = Get-TemplateDefault $Template 'sourcesGateMode'
            sourcesGateBranches = Get-TemplateDefault $Template 'sourcesGateBranches'
        }
        foreach ($name in $Overrides.Keys) { $parameters[$name] = $Overrides[$name] }
        $condition = Expand-Parameters (Get-JobCondition (Get-TemplateText $Module) '- template: ../../Common/Jobs/quality-sources.yaml') $parameters
        $variables = @{ 'Build.Reason' = $Reason }
        if ($TargetBranch) { $variables['System.PullRequest.TargetBranch'] = $TargetBranch }
        return Invoke-Condition $condition $variables
    }
}

Describe 'Funzionalità: Gate sulle fonti della PR nel modulo di quality GitFlow' {

    Context 'Scenario: PR verso dev con il gate bloccante' -ForEach @(
        @{ TargetBranch = 'refs/heads/dev' }
        @{ TargetBranch = 'dev' }
    ) {
        It 'Allora il job ValidatePRSources gira (<TargetBranch>)' {
            Test-SourcesJobRuns $Module @{ sourcesGateMode = 'enforce' } -TargetBranch $TargetBranch | Should -BeTrue
        }
    }

    Context 'Scenario: PR verso un ramo fuori da sourcesGateBranches' -ForEach @(
        @{ TargetBranch = 'refs/heads/main' }
        @{ TargetBranch = 'refs/heads/staging' }
    ) {
        It 'Allora il job ValidatePRSources non gira (<TargetBranch>)' {
            Test-SourcesJobRuns $Module @{ sourcesGateMode = 'enforce' } -TargetBranch $TargetBranch | Should -BeFalse
        }
    }

    It 'Scenario: un consumer che sceglie piu rami li verifica tutti' {
        foreach ($branch in 'refs/heads/dev', 'refs/heads/staging') {
            Test-SourcesJobRuns $Module @{ sourcesGateMode = 'warn'; sourcesGateBranches = 'dev,staging' } -TargetBranch $branch | Should -BeTrue
        }
    }

    It 'Scenario: run che non e una PR non verifica le fonti' {
        Test-SourcesJobRuns $Module @{ sourcesGateMode = 'enforce' } -Reason 'IndividualCI' | Should -BeFalse
    }

    It "Scenario: gate in 'off' non verifica le fonti" {
        Test-SourcesJobRuns $Module @{ sourcesGateMode = 'off' } -TargetBranch 'refs/heads/dev' | Should -BeFalse
    }

    Context 'Scenario: consumer che non passa i parametri (<Template>)' -ForEach @(
        @{ Template = 'V3/CI/GitFlow/Modules/quality.yaml' }
        @{ Template = 'V3/CI/GitFlow/quality-dotNet.yaml' }
        @{ Template = 'V3/CI/GitFlow/quality-angular.yaml' }
    ) {
        It "Allora il gate resta in 'off' sul ramo dev" {
            Get-TemplateDefault $Template 'sourcesGateMode' | Should -Be 'off'
            Get-TemplateDefault $Template 'sourcesGateBranches' | Should -Be 'dev'
            Test-SourcesJobRuns $Template -TargetBranch 'refs/heads/dev' | Should -BeFalse
        }
    }

    Context 'Scenario: entry point che inoltra i parametri al modulo (<Template>)' -ForEach @(
        @{ Template = 'V3/CI/GitFlow/quality-dotNet.yaml' }
        @{ Template = 'V3/CI/GitFlow/quality-angular.yaml' }
    ) {
        It 'Allora sourcesGateMode e sourcesGateBranches arrivano al modulo' {
            $text = Get-TemplateText $Template
            $text | Should -Match '(?m)^      sourcesGateMode: \$\{\{ parameters\.sourcesGateMode \}\}$'
            $text | Should -Match '(?m)^      sourcesGateBranches: \$\{\{ parameters\.sourcesGateBranches \}\}$'
        }
    }

    It 'Scenario: il job delle fonti verifica la board con lo script del repo dei template' {
        $text = Get-TemplateText $Module
        $text | Should -Match "(?m)^      - template: \.\./\.\./Common/Jobs/quality-sources\.yaml\n        parameters:\n          name: ValidatePRSources\n"
        $text | Should -Match '(?m)^          mode: \$\{\{ parameters\.sourcesGateMode \}\}$'
        $job = Get-TemplateText 'V3/CI/Common/Jobs/quality-sources.yaml'
        $job | Should -Match '(?m)^      - checkout: infrastructure\n        path: pipeline-templates$'
        $job | Should -Match '(?m)^      - template: \.\./Steps/azureBoards-sources-verify\.yaml$'
    }

    It 'Scenario: la pipeline agnostica delle fonti riusa lo stesso job' {
        $text = Get-TemplateText 'V3/CI/Agnostic/quality-sources.yaml'
        $text | Should -Match '(?m)^  - template: \.\./Common/Jobs/quality-sources\.yaml$'
        $text | Should -Not -Match '(?m)^\s+- job:'
    }
}

Describe 'Funzionalità: BuildAndTest dopo i gate della PR' {

    BeforeAll {
        $script:Text = Get-TemplateText $Module
        $script:Condition = Get-JobCondition $Text '- template: ../../Common/Jobs/quality-build-and-test.yaml'
    }

    It 'Dipende dal gate sul titolo e da quello sulle fonti' {
        $Text | Should -Match '(?m)^          dependsOn: \[ValidatePRTitle, ValidatePRSources\]$'
    }

    Context 'Scenario: titolo <Title>, fonti <Sources>' -ForEach @(
        @{ Title = 'Succeeded'; Sources = 'Succeeded'; Runs = $true }
        @{ Title = 'Skipped'; Sources = 'Skipped'; Runs = $true }
        @{ Title = 'Succeeded'; Sources = 'SucceededWithIssues'; Runs = $true }
        @{ Title = 'SucceededWithIssues'; Sources = 'Skipped'; Runs = $true }
        @{ Title = 'Succeeded'; Sources = 'Failed'; Runs = $false }
        @{ Title = 'Failed'; Sources = 'Succeeded'; Runs = $false }
    ) {
        It 'Allora BuildAndTest gira: <Runs>' {
            Invoke-Condition $Condition -Results @{ ValidatePRTitle = $Title; ValidatePRSources = $Sources } | Should -Be $Runs
        }
    }
}
