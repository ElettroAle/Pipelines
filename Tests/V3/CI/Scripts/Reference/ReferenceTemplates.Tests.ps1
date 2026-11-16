#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester dei template della reference: dotnet-openapi-publish, reference-publish e il collegamento
    alla reference nella pubblicazione arc42.

.DESCRIPTION
    Lo script in linea di dotnet-openapi-publish.yaml gira in un processo separato con le variabili che il
    template gli passa; gli altri test leggono il testo dei template.
#>

BeforeAll {
    $script:Root = Resolve-Path "$PSScriptRoot/../../../../.."

    function Get-TemplateText([string]$Path) {
        return [IO.File]::ReadAllText((Join-Path $Root $Path)) -replace "`r`n", "`n"
    }

    function Get-InlineScript([string]$Path) {
        $lines = (Get-TemplateText $Path) -split "`n"
        $start = [array]::IndexOf($lines, '  - pwsh: |')
        $end = [array]::IndexOf($lines, "    displayName: 'Collect the OpenAPI documents'")
        return ($lines[($start + 1)..($end - 1)] | ForEach-Object { if ($_.Length -ge 6) { $_.Substring(6) } else { '' } }) -join "`n"
    }

    function Invoke-CollectStep([string[]]$Documents) {
        $script = Join-Path $TestDrive 'collect.ps1'
        [IO.File]::WriteAllText($script, (Get-InlineScript 'V3/CI/Common/Steps/dotnet-openapi-publish.yaml'))
        $settings = @{ AGENT_TEMPDIRECTORY = (Join-Path $TestDrive 'temp'); OPENAPI_ARTIFACT = 'openapi'; OPENAPI_SOURCE_DIRECTORY = (Join-Path $TestDrive 'app'); OPENAPI_DOCUMENTS = ($Documents -join ';') }
        $previous = @{}
        foreach ($name in $settings.Keys) { $previous[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $settings[$name]) }
        try {
            $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $script 2>&1
            return @{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
        }
        finally { foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) } }
    }

    function Get-EnvNames([string]$Text) {
        return @([regex]::Matches($Text, '(?m)^ {6}([A-Z][A-Z0-9_]*):') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    }
}

Describe 'dotnet-openapi-publish.yaml' {
    BeforeEach {
        Remove-Item -Recurse -Force (Join-Path $TestDrive 'temp'), (Join-Path $TestDrive 'app') -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path (Join-Path $TestDrive 'app/Api/obj/openapi') | Out-Null
        '{"openapi":"3.0.1"}' | Set-Content (Join-Path $TestDrive 'app/Api/obj/openapi/Api_v1.json')
        '{"openapi":"3.0.1"}' | Set-Content (Join-Path $TestDrive 'app/Api/obj/openapi/Api_v2.json')
    }

    It "raccoglie le specifiche indicate nella cartella dell'artefatto" {
        $result = Invoke-CollectStep @('Api/obj/openapi/Api_v1.json', 'Api/obj/openapi/Api_v2.json')
        "$($result.ExitCode) $(@(Get-ChildItem (Join-Path $TestDrive 'temp/openapi') | ForEach-Object Name) -join ',')" | Should -Be '0 Api_v1.json,Api_v2.json' -Because $result.Output
    }

    It "una specifica assente fa fallire il passo e la nomina" {
        $result = Invoke-CollectStep @('Api/obj/openapi/Api_v1.json', 'Api/obj/openapi/Api_v3.json')
        "$($result.ExitCode) $($result.Output -match 'specifiche OpenAPI assenti dopo la build: Api/obj/openapi/Api_v3.json')" | Should -Be '1 True'
    }

    It "pubblica l'artefatto dalla cartella raccolta" {
        Get-TemplateText 'V3/CI/Common/Steps/dotnet-openapi-publish.yaml' | Should -Match "(?s)PublishPipelineArtifact@1.*targetPath: '\`$\(openApiDirectory\)'.*artifact: '\`$\{\{ parameters.artifactName \}\}'"
    }
}

Describe 'openApiDocuments in GitFlow/publish-dotNet.yaml' {
    It 'il passo delle specifiche entra nel job di compilazione solo con openApiDocuments' {
        Get-TemplateText 'V3/CI/GitFlow/publish-dotNet.yaml' | Should -Match "(?s)  - name: openApiDocuments\n    type: object\n    default: \[\].*- \`$\{\{ if ne\(length\(parameters.openApiDocuments\), 0\) \}\}:\n          - template: ../Common/Steps/dotnet-openapi-publish.yaml\n            parameters:\n              documents: \`$\{\{ parameters.openApiDocuments \}\}\n              sourceDirectory: '\`$\(Agent.BuildDirectory\)/s/\`$\{\{ parameters.projectName \}\}'\n\n      publishSteps:"
    }
}

Describe 'reference-publish.yaml' {
    It 'passa allo script tutte e sole le variabili che lo script legge' {
        $script = [IO.File]::ReadAllText((Join-Path $Root 'V3/CI/Scripts/Reference/Publish-Reference.ps1'))
        $read = @([regex]::Matches($script, '\$env:([A-Z][A-Z0-9_]*)') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch '^(SYSTEM_COLLECTIONURI|SYSTEM_TEAMPROJECT|BUILD_.*)$' }) + 'DOCUMENT_LANGUAGE' | Sort-Object -Unique
        Get-EnvNames (Get-TemplateText 'V3/CI/Common/Steps/reference-publish.yaml') | Should -Be $read
    }
}

Describe 'referenceRoot nella pubblicazione arc42' {
    It "l'entry point passa la radice della reference allo step, che la passa allo script" {
        "$((Get-TemplateText 'V3/CI/Agnostic/publish-arc42-wiki.yaml') -match 'referenceRoot: \$\{\{ parameters.referenceRoot \}\}') $((Get-TemplateText 'V3/CI/Common/Steps/arc42-wiki-publish.yaml') -match 'REFERENCE_ROOT: \$\{\{ parameters.referenceRoot \}\}')" | Should -Be 'True True'
    }
}
