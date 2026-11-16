# SPDX-License-Identifier: Apache-2.0

#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester dei checkout aggiuntivi del job di quality.

.DESCRIPTION
    Il checkout di checkoutRepository in s cancella le cartelle di default che l'agente crea in s per gli altri
    repository: un checkout che arriva dopo riclona con un avviso. I test leggono il testo dei template: i checkout
    aggiuntivi vengono prima di quello di checkoutRepository e gli entry point li passano fino al job.
#>

BeforeAll {
    $script:Root = Resolve-Path "$PSScriptRoot/../../../../.."

    function Get-TemplateText([string]$Path) {
        return [IO.File]::ReadAllText((Join-Path $Root $Path)) -replace "`r`n", "`n"
    }
}

Describe 'Checkout aggiuntivi nel job di quality' {
    BeforeAll {
        $script:Job = Get-TemplateText 'V3/CI/Common/Jobs/quality-build-and-test.yaml'
    }

    It 'dichiara checkoutSteps come stepList vuota di default' {
        $Job | Should -Match "(?m)^  - name: checkoutSteps\n    type: stepList\n    default: \[\]$"
    }

    It 'fa i checkout aggiuntivi prima di quello di checkoutRepository' {
        $additional = $Job.IndexOf('- ${{ parameters.checkoutSteps }}')
        $repository = $Job.IndexOf('- checkout: ${{ parameters.checkoutRepository }}')
        $additional | Should -BeGreaterThan -1
        $additional | Should -BeLessThan $repository
    }

    It 'mette checkoutRepository in s quando ci sono checkout aggiuntivi' {
        $Job | Should -Match '\$\{\{ if or\(eq\(parameters\.checkoutPipelineTemplates, true\), ne\(length\(parameters\.checkoutSteps\), 0\)\) \}\}:\n          path: s'
    }
}

Describe 'checkoutSteps passato dal template <Template>' -ForEach @(
    @{ Template = 'V3/CI/Common/quality.yaml' }
    @{ Template = 'V3/CI/Agnostic/quality-arc42.yaml' }
) {
    BeforeAll {
        $script:Text = Get-TemplateText $Template
    }

    It 'dichiara checkoutSteps' { $Text | Should -Match "(?m)^  - name: checkoutSteps\n    type: stepList\n    default: \[\]$" }

    It 'lo passa al template che chiama' { $Text | Should -Match '(?m)^ +checkoutSteps: \$\{\{ parameters\.checkoutSteps \}\}$' }
}
