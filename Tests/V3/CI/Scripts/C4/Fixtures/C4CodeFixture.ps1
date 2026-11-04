# SPDX-License-Identifier: Apache-2.0

# Repository sorgente finti e composizione dei passi del modello C4 generato come in pipeline: i
# lettori delle tecnologie scelte, poi lo scrittore. Un passo che fallisce ferma la composizione.

. "$PSScriptRoot/../../Common/Fixtures/Documentation/DocumentationFixture.ps1"

$C4ScriptsDirectory = Resolve-Path "$PSScriptRoot/../../../../../../V3/CI/Scripts"
$C4Readers = @{ dotnet10 = 'C4/Read-C4DotNet10Model.ps1'; angular18 = 'C4/Read-C4Angular18Model.ps1'; consumer = "$PSScriptRoot/Read-C4ConsumerModel.ps1" }
$C4SourceRepositories = 'Contoso.Shop.AI,Contoso.Shop.Bff.Web,Contoso.Shop.Client.Web'

function New-Project([string]$Sdk = 'Microsoft.NET.Sdk', [string[]]$References = @(), [string]$Properties = '', [string]$Items = '') {
    $refs = ($References | ForEach-Object { "    <ProjectReference Include=`"..\$_\$_.csproj`" />" }) -join "`n"
    return "<Project Sdk=`"$Sdk`">`n  <PropertyGroup>`n    <TargetFramework>net10.0</TargetFramework>`n$Properties`n  </PropertyGroup>`n  <ItemGroup>`n$refs`n$Items`n  </ItemGroup>`n</Project>`n"
}

function Add-Project([System.Collections.IDictionary]$Files, [string]$Name, [string]$Content) {
    $Files["source/$Name/$Name.csproj"] = $Content
}

function New-EngineRepository {
    $files = [ordered]@{}
    Add-Project $files 'Contoso.Shop.AI.Api' (New-Project 'Microsoft.NET.Sdk.Web' @('Contoso.Shop.AI.UseCase.WrittenConversations', 'Contoso.Shop.AI.Utils', 'Contoso.Shop.AI.DataAccess.AzureServiceBus', 'Contoso.Shop.AI.DataAccess.AzureStorageAccount'))
    Add-Project $files 'Contoso.Shop.AI.Worker' (New-Project 'Microsoft.NET.Sdk' @('Contoso.Shop.AI.UseCase.WrittenConversations', 'Contoso.Shop.AI.UnitTest.Engine') "    <OutputType>Exe</OutputType>`n    <AzureFunctionsVersion>v4</AzureFunctionsVersion>")
    Add-Project $files 'Contoso.Shop.AI.Evals' (New-Project 'Microsoft.NET.Sdk' @('Contoso.Shop.AI.Api') '    <OutputType>Exe</OutputType>')
    Add-Project $files 'Contoso.Shop.AI.UseCase.WrittenConversations' (New-Project)
    Add-Project $files 'Contoso.Shop.AI.Utils' (New-Project)
    Add-Project $files 'Contoso.Shop.AI.Utils.Reflection' (New-Project)
    Add-Project $files 'Contoso.Shop.AI.DataAccess.AzureServiceBus' (New-Project 'Microsoft.NET.Sdk' @('Contoso.Shop.AI.UseCase.WrittenConversations') '' "    <PackageReference Include=`"Azure.Messaging.ServiceBus`" />`n    <PackageReference Include=`"Azure.Identity`" />")
    Add-Project $files 'Contoso.Shop.AI.DataAccess.AzureStorageAccount' (New-Project 'Microsoft.NET.Sdk' @() '' "    <PackageReference Include=`"Azure.Storage.Blobs`" />`n    <PackageReference Include=`"Azure.Data.Tables`" />")
    Add-Project $files 'Contoso.Shop.AI.UnitTest.Engine' (New-Project 'Microsoft.NET.Sdk' @('Contoso.Shop.AI.Utils.Reflection', 'Contoso.Shop.AI.UseCase.WrittenConversations') '' '    <PackageReference Include="Microsoft.NET.Test.Sdk" />')
    return $files
}

function New-BffRepository {
    $files = [ordered]@{}
    Add-Project $files 'Contoso.Shop.Bff.Web' (New-Project 'Microsoft.NET.Sdk.Web' @('Contoso.Shop.Bff.Web.BusinessLogic'))
    Add-Project $files 'Contoso.Shop.Bff.Web.BusinessLogic' (New-Project)
    return $files
}

function New-ClientRepository {
    $files = [ordered]@{}
    $files['source/angular.json'] = '{ "projects": { "contoso-shop-client-web": { "projectType": "application", "sourceRoot": "src" } } }'
    $files['source/package.json'] = '{ "name": "contoso-shop-client-web", "dependencies": { "@angular/core": "^18.2.0" } }'
    $files['source/src/app/features/settings/settings.providers.ts'] = "export const provideSettings = () => [];`n"
    $files['source/src/app/features/chat/pages/chat.page.ts'] = "import { SUGGESTIONS } from '../../ai-suggestions/tokens/ai-suggestions.tokens';`nimport { HUB } from '../../../core/realtime/tokens/realtime.tokens';`nimport { guard } from '../../../core/guards/auth.guard';`n"
    $files['source/src/app/features/ai-suggestions/tokens/ai-suggestions.tokens.ts'] = "export const SUGGESTIONS = 'x';`n"
    $files['source/src/app/core/realtime/realtime.providers.ts'] = "export const provideRealtime = () => [];`n"
    $files['source/src/app/core/realtime/tokens/realtime.tokens.ts'] = "export const HUB = 'x';`n"
    $files['source/src/app/core/guards/auth.guard.ts'] = "export const guard = () => true;`n"
    return $files
}

# L'indirizzo a cui un'applicazione si avvia in locale: un profilo per URL e uno senza, come quello di IIS Express.
function Add-LaunchSettings([System.Collections.IDictionary]$Files, [string]$Project, [string[]]$Urls) {
    $profiles = [ordered]@{ IISExpress = [ordered]@{ commandName = 'IISExpress' } }
    $index = 0
    $Urls | ForEach-Object { $profiles["profilo$index"] = [ordered]@{ commandName = 'Project'; applicationUrl = $_ }; $index++ }
    $Files["source/$Project/Properties/launchSettings.json"] = [ordered]@{ profiles = $profiles } | ConvertTo-Json -Depth 5
    return $Files
}

# Il proxy del dev server di un'applicazione Angular, dichiarato nelle opzioni di serve di angular.json.
function Add-DevProxy([System.Collections.IDictionary]$Files, [hashtable]$Targets, [string]$File = 'proxy.conf.json') {
    $Files['source/angular.json'] = "{ ""projects"": { ""contoso-shop-client-web"": { ""projectType"": ""application"", ""sourceRoot"": ""src"", ""architect"": { ""serve"": { ""options"": { ""proxyConfig"": ""$File"" } } } } } }"
    $proxy = [ordered]@{}
    $Targets.Keys | Sort-Object | ForEach-Object { $proxy[$_] = [ordered]@{ target = $Targets[$_]; secure = $false } }
    $Files["source/$File"] = $proxy | ConvertTo-Json -Depth 5
    return $Files
}

function Write-SourceFiles([string]$Root, [System.Collections.IDictionary]$Files) {
    foreach ($path in ($Files.Keys | Where-Object { $null -ne $Files[$_] })) {
        $file = Join-Path $Root $path
        New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
        [IO.File]::WriteAllText($file, ($Files[$path] -replace "`r`n", "`n"))
    }
}

function Invoke-C4Script([string]$Script, [hashtable]$Variables) {
    $previous = @{}
    foreach ($name in $Variables.Keys) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $Variables[$name])
    }
    try {
        $path = if ([IO.Path]::IsPathRooted($Script)) { $Script } else { Join-Path $C4ScriptsDirectory $Script }
        # PowerShell@2 e AzureCLI@2 eseguono gli script con ErrorActionPreference Stop: un errore che in
        # Continue scorrerebbe su stderr, in pipeline ferma il passo.
        $command = "`$ErrorActionPreference = 'Stop'; & '$($path -replace "'", "''")'; exit `$LASTEXITCODE"
        $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -Command $command 2>&1
        return @{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    }
    finally {
        foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
    }
}

function Read-Directory([string]$Directory, [string]$Filter) {
    $content = [ordered]@{}
    $root = if (Test-Path $Directory) { (Resolve-Path $Directory).Path } else { $Directory }
    Get-ChildItem -Path $Directory -Filter $Filter -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName |
        ForEach-Object { $content[[IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/')] = [IO.File]::ReadAllText($_.FullName) }
    return $content
}

function Invoke-C4Steps([System.Collections.IDictionary]$Files, [string]$Repository, [string[]]$Steps, [string]$Mode, [hashtable]$Fragments) {
    $root = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-code-$(New-Guid)"
    Write-SourceFiles $root $Files
    $fragmentFiles = [ordered]@{}
    $Fragments.Keys | ForEach-Object { $fragmentFiles["fragments/$_"] = $Fragments[$_] }
    Write-SourceFiles $root $fragmentFiles
    $variables = @{
        SOURCE_DIRECTORY = 'source'; SOURCE_REPOSITORY = $Repository; SOURCE_REPOSITORIES = $C4SourceRepositories
        FRAGMENT_DIRECTORY = 'fragments'; C4_SCRIPTS_DIRECTORY = "$C4ScriptsDirectory"; GENERATED_DIRECTORY = 'docs/architecture/c4/generated'; GENERATION_MODE = $Mode; DOCUMENT_LANGUAGE = ''
    }
    Push-Location $root
    try {
        $outputs = @()
        $exitCode = 0
        foreach ($step in $Steps) {
            $result = Invoke-C4Script $step $variables
            $outputs += $result.Output
            $exitCode = $result.ExitCode
            if ($exitCode) { break }
        }
        return @{
            ExitCode  = $exitCode
            Output    = $outputs -join "`n"
            Generated = Read-Directory (Join-Path $root 'docs/architecture/c4/generated') '*.dsl'
            Fragments = Read-Directory (Join-Path $root 'fragments') '*.json'
        }
    }
    finally {
        Pop-Location
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }
}

# Readers sono i lettori della composizione, nell'ordine; Fragments i frammenti gia' presenti, per
# provare lo scrittore senza un lettore.
function Invoke-C4Generation([System.Collections.IDictionary]$Files, [string]$Repository, [string[]]$Readers, [string]$Mode = 'write', [hashtable]$Fragments = @{}) {
    $steps = @($Readers | ForEach-Object { $C4Readers[$_] }) + 'C4/Export-C4CodeModel.ps1'
    return Invoke-C4Steps $Files $Repository $steps $Mode $Fragments
}

function Invoke-C4Reader([System.Collections.IDictionary]$Files, [string]$Repository, [string]$Reader) {
    $result = Invoke-C4Steps $Files $Repository @($C4Readers[$Reader]) 'write' @{}
    $result.Fragment = @($result.Fragments.Values | ForEach-Object { $_ | ConvertFrom-Json }) | Select-Object -First 1
    return $result
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
