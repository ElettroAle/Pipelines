#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Export-C4CodeModel.ps1

.DESCRIPTION
    Ogni scenario costruisce un repository sorgente finto (progetti .NET o un'applicazione Angular)
    e genera la sua parte del modello C4 come in pipeline. Lo scenario che controlla la validita'
    del DSL richiede Java 17 o successivo (STRUCTURIZR_JAVA, JAVA_HOME_17_X64 o JAVA_HOME).
#>

BeforeAll {
    . "$PSScriptRoot/../fixtures/documentation/DocumentationFixture.ps1"
    . "$PSScriptRoot/../../V3/CI/Scripts/Structurizr.ps1"
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../V3/CI/Scripts/Export-C4CodeModel.ps1"
    $previousToolsDirectory = $env:AGENT_TOOLSDIRECTORY
    $env:AGENT_TOOLSDIRECTORY = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-code-$(New-Guid)"
    $SourceRepositories = 'Aidea.Dxp.AI,Aidea.Dxp.Bff.Web,Aidea.Dxp.Client.Web'

    function New-Project([string]$Sdk = 'Microsoft.NET.Sdk', [string[]]$References = @(), [string]$Properties = '', [string]$Items = '') {
        $refs = ($References | ForEach-Object { "    <ProjectReference Include=`"..\$_\$_.csproj`" />" }) -join "`n"
        return "<Project Sdk=`"$Sdk`">`n  <PropertyGroup>`n    <TargetFramework>net10.0</TargetFramework>`n$Properties`n  </PropertyGroup>`n  <ItemGroup>`n$refs`n$Items`n  </ItemGroup>`n</Project>`n"
    }

    function Add-Project([System.Collections.IDictionary]$Files, [string]$Name, [string]$Content) {
        $Files["source/$Name/$Name.csproj"] = $Content
    }

    function New-EngineRepository {
        $files = [ordered]@{}
        Add-Project $files 'Aidea.Dxp.AI.Api' (New-Project 'Microsoft.NET.Sdk.Web' @('Aidea.Dxp.AI.UseCase.WrittenConversations', 'Aidea.Dxp.AI.Utils', 'Aidea.Dxp.AI.DataAccess.AzureServiceBus', 'Aidea.Dxp.AI.DataAccess.AzureStorageAccount'))
        Add-Project $files 'Aidea.Dxp.AI.Worker' (New-Project 'Microsoft.NET.Sdk' @('Aidea.Dxp.AI.UseCase.WrittenConversations', 'Aidea.Dxp.AI.UnitTest.Engine') "    <OutputType>Exe</OutputType>`n    <AzureFunctionsVersion>v4</AzureFunctionsVersion>")
        Add-Project $files 'Aidea.Dxp.AI.Evals' (New-Project 'Microsoft.NET.Sdk' @('Aidea.Dxp.AI.Api') '    <OutputType>Exe</OutputType>')
        Add-Project $files 'Aidea.Dxp.AI.UseCase.WrittenConversations' (New-Project)
        Add-Project $files 'Aidea.Dxp.AI.Utils' (New-Project)
        Add-Project $files 'Aidea.Dxp.AI.Utils.Reflection' (New-Project)
        Add-Project $files 'Aidea.Dxp.AI.DataAccess.AzureServiceBus' (New-Project 'Microsoft.NET.Sdk' @('Aidea.Dxp.AI.UseCase.WrittenConversations') '' "    <PackageReference Include=`"Azure.Messaging.ServiceBus`" />`n    <PackageReference Include=`"Azure.Identity`" />")
        Add-Project $files 'Aidea.Dxp.AI.DataAccess.AzureStorageAccount' (New-Project 'Microsoft.NET.Sdk' @() '' "    <PackageReference Include=`"Azure.Storage.Blobs`" />`n    <PackageReference Include=`"Azure.Data.Tables`" />")
        Add-Project $files 'Aidea.Dxp.AI.UnitTest.Engine' (New-Project 'Microsoft.NET.Sdk' @('Aidea.Dxp.AI.Utils.Reflection', 'Aidea.Dxp.AI.UseCase.WrittenConversations') '' '    <PackageReference Include="Microsoft.NET.Test.Sdk" />')
        return $files
    }

    function New-BffRepository {
        $files = [ordered]@{}
        Add-Project $files 'Aidea.Dxp.Bff.Web' (New-Project 'Microsoft.NET.Sdk.Web' @('Aidea.Dxp.Bff.Web.BusinessLogic'))
        Add-Project $files 'Aidea.Dxp.Bff.Web.BusinessLogic' (New-Project)
        return $files
    }

    function New-ClientRepository {
        $files = [ordered]@{}
        $files['source/angular.json'] = '{ "projects": { "aidea-dxp-client-web": { "projectType": "application", "sourceRoot": "src" } } }'
        $files['source/package.json'] = '{ "name": "aidea-dxp-client-web", "dependencies": { "@angular/core": "^18.2.0" } }'
        $files['source/src/app/features/settings/settings.providers.ts'] = "export const provideSettings = () => [];`n"
        $files['source/src/app/features/chat/pages/chat.page.ts'] = "import { SUGGESTIONS } from '../../ai-suggestions/tokens/ai-suggestions.tokens';`nimport { HUB } from '../../../core/realtime/tokens/realtime.tokens';`nimport { guard } from '../../../core/guards/auth.guard';`n"
        $files['source/src/app/features/ai-suggestions/tokens/ai-suggestions.tokens.ts'] = "export const SUGGESTIONS = 'x';`n"
        $files['source/src/app/core/realtime/realtime.providers.ts'] = "export const provideRealtime = () => [];`n"
        $files['source/src/app/core/realtime/tokens/realtime.tokens.ts'] = "export const HUB = 'x';`n"
        $files['source/src/app/core/guards/auth.guard.ts'] = "export const guard = () => true;`n"
        return $files
    }

    function Invoke-Generation([System.Collections.IDictionary]$Files, [string]$Repository, [string]$Mode = 'write') {
        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-code-$(New-Guid)"
        foreach ($path in $Files.Keys) {
            if ($null -eq $Files[$path]) { continue }
            $file = Join-Path $root $path
            New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
            [IO.File]::WriteAllText($file, ($Files[$path] -replace "`r`n", "`n"))
        }
        $variables = @{ SOURCE_DIRECTORY = 'source'; SOURCE_REPOSITORY = $Repository; SOURCE_REPOSITORIES = $SourceRepositories; GENERATED_DIRECTORY = 'docs/architecture/model/generated'; GENERATION_MODE = $Mode; DOCUMENT_LANGUAGE = '' }
        $previous = @{}
        foreach ($name in $variables.Keys) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $variables[$name])
        }
        Push-Location $root
        try {
            $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $ScriptPath 2>&1
            $exitCode = $LASTEXITCODE
            $generated = [ordered]@{}
            Get-ChildItem -Path (Join-Path $root 'docs/architecture/model/generated') -Filter '*.dsl' -ErrorAction SilentlyContinue | ForEach-Object { $generated[$_.Name] = [IO.File]::ReadAllText($_.FullName) }
            return @{ ExitCode = $exitCode; Output = ($output -join "`n"); Generated = $generated }
        }
        finally {
            Pop-Location
            foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
            Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
        }
    }

    function Get-ElementLine([string]$Dsl, [string]$Kind, [string]$Name) {
        return @($Dsl -split "`n" | Where-Object { $_ -match "=\s*$Kind\s+`"$([regex]::Escape($Name))`"" })
    }

    function Get-Block([string]$Dsl, [string]$OpeningPattern) {
        $lines = $Dsl -split "`n"
        $start = [Array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match $OpeningPattern })
        if ($start -lt 0) { return '' }
        $depth = 0
        $block = foreach ($line in $lines[$start..($lines.Count - 1)]) {
            $line
            $depth += ([regex]::Matches($line, '\{')).Count - ([regex]::Matches($line, '\}')).Count
            if ($depth -le 0) { break }
        }
        return $block -join "`n"
    }

    function Get-ContainerBlock([string]$Dsl, [string]$Name) {
        return Get-Block $Dsl "=\s*container\s+`"$([regex]::Escape($Name))`""
    }
}

AfterAll {
    Remove-Item -Recurse -Force $env:AGENT_TOOLSDIRECTORY -ErrorAction SilentlyContinue
    $env:AGENT_TOOLSDIRECTORY = $previousToolsDirectory
}


Describe "Funzionalità: Modello C4 generato dal codice" {

    Context "Schema dello scenario: elementi e relazioni nati dal codice .NET" {
        BeforeAll {
            $res = Invoke-Generation (New-EngineRepository) 'Aidea.Dxp.AI'
            $dsl = $res.Generated['aidea.dxp.ai.dsl']
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il modello contiene il container ""Api"" nel gruppo di ""Aidea.Dxp.AI""" {
            Get-Block $dsl 'group\s+"AI"' | Should -Match 'container\s+"Api"'
        }

        It "E il modello contiene il container ""Worker"" nel gruppo di ""Aidea.Dxp.AI""" {
            Get-Block $dsl 'group\s+"AI"' | Should -Match 'container\s+"Worker"'
        }

        It "E il modello contiene il componente ""UseCase.WrittenConversations"" in entrambi i container" {
            Get-ContainerBlock $dsl 'Api' | Should -Match 'component\s+"UseCase\.WrittenConversations"'
            Get-ContainerBlock $dsl 'Worker' | Should -Match 'component\s+"UseCase\.WrittenConversations"'
        }

        It "E il modello contiene il componente ""Utils"" nel container ""Api""" {
            Get-ContainerBlock $dsl 'Api' | Should -Match 'component\s+"Utils"'
        }

        It "E il modello contiene la relazione fra i componenti di ""DataAccess.AzureServiceBus"" e ""UseCase.WrittenConversations""" {
            Get-ContainerBlock $dsl 'Api' | Should -Match 'aidea_dxp_ai_api__aidea_dxp_ai_dataaccess_azureservicebus\s+->\s+aidea_dxp_ai_api__aidea_dxp_ai_usecase_writtenconversations'
        }

        It "E un'applicazione e' componente di se stessa" {
            Get-ContainerBlock $dsl 'Api' | Should -Match 'component\s+"Api"'
        }
    }

    Context "Schema dello scenario: servizi Azure delle librerie di un componente — <progetto>" -ForEach @(
        @{ progetto = 'Aidea.Dxp.AI.DataAccess.AzureServiceBus'; nome = 'DataAccess.AzureServiceBus'; servizi = 'Service Bus' }
        @{ progetto = 'Aidea.Dxp.AI.DataAccess.AzureStorageAccount'; nome = 'DataAccess.AzureStorageAccount'; servizi = 'Storage' }
    ) {
        BeforeAll {
            $res = Invoke-Generation (New-EngineRepository) 'Aidea.Dxp.AI'
            $component = Get-Block (Get-ContainerBlock $res.Generated['aidea.dxp.ai.dsl'] 'Api') "=\s*component\s+`"$([regex]::Escape($nome))`""
        }

        It "Allora il componente <nome> dichiara i servizi <servizi>" {
            $component | Should -Match "`"servizi`"\s+`"$([regex]::Escape($servizi))`""
        }
    }

    Context "Scenario: un componente senza librerie di servizi Azure" {
        BeforeAll {
            $res = Invoke-Generation (New-EngineRepository) 'Aidea.Dxp.AI'
            $component = Get-Block (Get-ContainerBlock $res.Generated['aidea.dxp.ai.dsl'] 'Api') '=\s*component\s+"Utils"'
        }

        It "Allora il componente non dichiara servizi" {
            $component | Should -Not -Match '"servizi"'
        }
    }

    Context "Scenario: test e strumenti non entrano nel modello" {
        BeforeAll {
            $res = Invoke-Generation (New-EngineRepository) 'Aidea.Dxp.AI'
            $dsl = $res.Generated['aidea.dxp.ai.dsl']
        }

        It "Allora il modello non contiene ""Aidea.Dxp.AI.UnitTest.Engine""" {
            $dsl | Should -Not -Match 'UnitTest\.Engine'
        }

        It "E il modello non contiene ""Aidea.Dxp.AI.Utils.Reflection""" {
            $dsl | Should -Not -Match 'Utils\.Reflection'
        }

        It "E il modello non contiene ""Aidea.Dxp.AI.Evals""" {
            $dsl | Should -Not -Match 'Evals'
        }
    }

    Context "Schema dello scenario: nome senza il prefisso comune del repository — <progetto>" -ForEach @(
        @{ repository = 'Aidea.Dxp.AI'; progetto = 'Aidea.Dxp.AI.UseCase.WrittenConversations'; nome = 'UseCase.WrittenConversations'; kind = 'component' }
        @{ repository = 'Aidea.Dxp.AI'; progetto = 'Aidea.Dxp.AI.Api'; nome = 'Api'; kind = 'container' }
        @{ repository = 'Aidea.Dxp.Bff.Web'; progetto = 'Aidea.Dxp.Bff.Web'; nome = 'Web'; kind = 'container' }
        @{ repository = 'Aidea.Dxp.Bff.Web'; progetto = 'Aidea.Dxp.Bff.Web.BusinessLogic'; nome = 'Web.BusinessLogic'; kind = 'component' }
    ) {
        BeforeAll {
            $files = if ($repository -eq 'Aidea.Dxp.AI') { New-EngineRepository } else { New-BffRepository }
            $res = Invoke-Generation $files $repository
            $dsl = @($res.Generated.Values)[0]
        }

        It "Allora l'elemento del progetto si chiama <nome>" {
            Get-ElementLine $dsl $kind $nome | Should -Not -BeNullOrEmpty -Because $dsl
        }

        It "E l'elemento porta <progetto> come nome completo" {
            $dsl | Should -Match ([regex]::Escape("`"codice`" `"$progetto`""))
        }
    }

    Context "Schema dello scenario: elementi nati dall'applicazione Angular" {
        BeforeAll {
            $res = Invoke-Generation (New-ClientRepository) 'Aidea.Dxp.Client.Web'
            $dsl = $res.Generated['aidea.dxp.client.web.dsl']
            $client = Get-ContainerBlock $dsl 'Client.Web'
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il modello contiene il container ""Client.Web""" {
            Get-ElementLine $dsl 'container' 'Client.Web' | Should -Not -BeNullOrEmpty -Because $dsl
        }

        It "E il modello contiene il componente ""settings"" nel container ""Client.Web""" {
            $client | Should -Match 'component\s+"settings"'
        }

        It "E il modello contiene il componente ""realtime"" nel container ""Client.Web""" {
            $client | Should -Match 'component\s+"realtime"'
        }

        It "E un modulo di base senza registrazione dei servizi non e' un componente" {
            $client | Should -Not -Match 'component\s+"guards"'
        }

        It "E il modello contiene la relazione da ""chat"" a ""ai-suggestions""" {
            $client | Should -Match '__features_chat\s+->\s+\S+__features_ai_suggestions'
        }

        It "E il modello contiene la relazione da ""chat"" a ""realtime""" {
            $client | Should -Match '__features_chat\s+->\s+\S+__core_realtime'
        }
    }

    Context "Scenario: un elemento sparisce dal codice" {
        BeforeAll {
            $files = New-EngineRepository
            $files['docs/architecture/model/generated/aidea.dxp.ai.dsl'] = 'container "DataAccess.Twilio"'
            $res = Invoke-Generation $files 'Aidea.Dxp.AI'
        }

        It "Allora il modello non contiene ""Aidea.Dxp.AI.DataAccess.Twilio""" {
            $res.Generated['aidea.dxp.ai.dsl'] | Should -Not -Match 'Twilio'
        }
    }

    Context "Scenario: la generazione cambia solo la parte del repository integrato" {
        BeforeAll {
            $files = New-BffRepository
            $files['docs/architecture/model/generated/aidea.dxp.ai.dsl'] = "# parte del Motore`n"
            $res = Invoke-Generation $files 'Aidea.Dxp.Bff.Web'
        }

        It "Allora cambia la parte generata di ""Aidea.Dxp.Bff.Web""" {
            $res.Generated['aidea.dxp.bff.web.dsl'] | Should -Match 'container\s+"Web"'
        }

        It "E la parte generata di ""Aidea.Dxp.AI"" resta com'era" {
            $res.Generated['aidea.dxp.ai.dsl'] | Should -Be "# parte del Motore`n"
        }
    }

    Context "Schema dello scenario: caso non riconosciuto — <elemento>" -ForEach @(
        @{
            repository = 'Aidea.Dxp.Client.Web'; elemento = 'portal'
            Build      = { $f = [ordered]@{}; $f['source/portal/package.json'] = '{ "name": "portal", "dependencies": { "react": "^18.0.0" } }'; $f }
        }
        @{
            repository = 'Aidea.Dxp.AI'; elemento = 'Aidea.Dxp.AI.Console'
            Build      = { $f = New-EngineRepository; Add-Project $f 'Aidea.Dxp.AI.Console' (New-Project 'Microsoft.NET.Sdk.BlazorWebAssembly'); $f }
        }
        @{
            repository = 'Aidea.Dxp.AI'; elemento = 'Azure.Mystery.Things'
            Build      = { $f = New-EngineRepository; Add-Project $f 'Aidea.Dxp.AI.Utils' (New-Project 'Microsoft.NET.Sdk' @() '' '    <PackageReference Include="Azure.Mystery.Things" />'); $f }
        }
        @{
            repository = 'Aidea.Dxp.Client.Web'; elemento = 'ui-kit'
            Build      = { $f = New-ClientRepository; $f['source/angular.json'] = '{ "projects": { "aidea-dxp-client-web": { "projectType": "application", "sourceRoot": "src" }, "ui-kit": { "projectType": "library", "sourceRoot": "projects/ui-kit/src" } } }'; $f }
        }
    ) {
        BeforeAll {
            $files = & $Build
            $files['docs/architecture/model/generated/x.dsl'] = $null
            $previousFile = "# parte precedente`n"
            $files["docs/architecture/model/generated/$($repository.ToLower()).dsl"] = $previousFile
            $res = Invoke-Generation $files $repository
        }

        It "Allora la generazione fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina il repository e l'elemento" {
            Get-Issues $res.Output | Where-Object { $_ -match ([regex]::Escape($repository)) -and $_ -match ([regex]::Escape($elemento)) } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E il modello non cambia" {
            $res.Generated["$($repository.ToLower()).dsl"] | Should -Be $previousFile
        }
    }

    Context "Scenario: parte generata modificata a mano" {
        BeforeAll {
            $files = New-BffRepository
            $first = Invoke-Generation $files 'Aidea.Dxp.Bff.Web'
            $files['docs/architecture/model/generated/aidea.dxp.bff.web.dsl'] = $first.Generated['aidea.dxp.bff.web.dsl'] -replace '"Web.BusinessLogic"', '"Logica"'
            $res = Invoke-Generation $files 'Aidea.Dxp.Bff.Web' 'check'
        }

        It "Allora la verifica fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina la parte generata di ""Aidea.Dxp.Bff.Web""" {
            Get-Issues $res.Output | Where-Object { $_ -match 'aidea\.dxp\.bff\.web\.dsl' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    Context "Scenario: parte generata allineata al codice" {
        BeforeAll {
            $files = New-BffRepository
            $first = Invoke-Generation $files 'Aidea.Dxp.Bff.Web'
            $files['docs/architecture/model/generated/aidea.dxp.bff.web.dsl'] = $first.Generated['aidea.dxp.bff.web.dsl']
            $res = Invoke-Generation $files 'Aidea.Dxp.Bff.Web' 'check'
        }

        It "Allora la verifica passa" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }
    }

    Context "Scenario: la parte generata e' un modello Structurizr valido" {
        BeforeAll {
            $engine = (Invoke-Generation (New-EngineRepository) 'Aidea.Dxp.AI').Generated['aidea.dxp.ai.dsl']
            $client = (Invoke-Generation (New-ClientRepository) 'Aidea.Dxp.Client.Web').Generated['aidea.dxp.client.web.dsl']
            $dir = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-code-dsl-$(New-Guid)"
            New-Item -ItemType Directory -Force -Path (Join-Path $dir 'generated') | Out-Null
            [IO.File]::WriteAllText((Join-Path $dir 'generated/aidea.dxp.ai.dsl'), $engine)
            [IO.File]::WriteAllText((Join-Path $dir 'generated/aidea.dxp.client.web.dsl'), $client)
            [IO.File]::WriteAllText((Join-Path $dir 'workspace.dsl'), "workspace {`n    model {`n        sistema = softwareSystem `"Aidea.Dxp`" {`n            !include generated/aidea.dxp.ai.dsl`n            !include generated/aidea.dxp.client.web.dsl`n        }`n    }`n}`n")
            $export = Export-StructurizrWorkspace (Join-Path $dir 'workspace.dsl')
            Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        }

        It "Allora il workspace che la include si esporta senza errori" {
            $export.Error | Should -BeNullOrEmpty
        }

        It "E i componenti generati portano il tag dei generati" {
            $components = @($export.Workspace.model.softwareSystems[0].containers | ForEach-Object { @($_.components) })
            $components | Where-Object { ($_.tags -split ',') -notcontains 'Generato' } | Should -BeNullOrEmpty
        }
    }
}
