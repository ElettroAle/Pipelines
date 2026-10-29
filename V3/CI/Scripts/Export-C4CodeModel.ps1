# SPDX-License-Identifier: Apache-2.0

# Parte del modello C4 che nasce da un repository sorgente, in Structurizr DSL da includere nel
# sistema del documento: un file per repository in GENERATED_DIRECTORY, che si legge e non si scrive
# a mano. Le applicazioni (progetti .NET con SDK Web o Function App, applicazioni Angular) sono
# container; i progetti di produzione che un'applicazione .NET usa, e le cartelle di funzionalita' e
# i moduli di base con i propri provider di un'applicazione Angular, sono i suoi componenti, legati
# dai riferimenti fra progetti e dagli import fra cartelle. Un elemento si chiama come nel codice,
# senza il prefisso comune del repository; il nome completo resta nella proprieta' del codice.
# Un tipo di applicazione o di progetto che queste regole non riconoscono ferma la generazione.
# GENERATION_MODE=check confronta il file del repository con quello che la generazione produce.

. "$PSScriptRoot/VerificationGate.ps1"
. "$PSScriptRoot/DocumentLanguage.ps1"

$SourceDirectory = if ($env:SOURCE_DIRECTORY) { $env:SOURCE_DIRECTORY } else { '.' }
$Repository = "$env:SOURCE_REPOSITORY".Trim()
$SourceRepositories = @("$env:SOURCE_REPOSITORIES" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$GeneratedDirectory = if ($env:GENERATED_DIRECTORY) { $env:GENERATED_DIRECTORY } else { 'docs/architecture/model/generated' }
$Mode = if ($env:GENERATION_MODE) { $env:GENERATION_MODE.ToLower() } else { 'write' }
$FeatureDirectories = @(if ($env:ANGULAR_FEATURE_DIRECTORIES) { $env:ANGULAR_FEATURE_DIRECTORIES -split ',' } else { 'app/features' })
$ModuleDirectories = @(if ($env:ANGULAR_MODULE_DIRECTORIES) { $env:ANGULAR_MODULE_DIRECTORIES -split ',' } else { 'app/core' })

$GeneratedTag = $DocumentLanguage.GeneratedTag
$ApplicationTag = $DocumentLanguage.ApplicationTag
$CodeNameProperty = $DocumentLanguage.CodeNameProperty
$IgnoredDirectories = @('node_modules', 'bin', 'obj', '.git', 'dist', '.angular')
$UnrecognizedProjectFiles = @('*.fsproj', '*.vbproj', '*.sqlproj', '*.esproj', '*.njsproj', '*.shproj', 'pom.xml', 'build.gradle', 'go.mod', 'pyproject.toml', 'Cargo.toml')

function Get-SourceFiles([string]$Filter) {
    $root = (Resolve-Path $SourceDirectory).Path
    return @(Get-ChildItem -Path $root -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue |
            Where-Object { -not ($_.FullName.Substring($root.Length) -split '[\\/]' | Where-Object { $IgnoredDirectories -contains $_ }) } |
            Sort-Object FullName)
}

function Get-RelativePath([string]$Path) {
    return [IO.Path]::GetRelativePath((Resolve-Path $SourceDirectory).Path, $Path) -replace '\\', '/'
}

function ConvertTo-Identifier([string]$Text) {
    return ($Text.ToLowerInvariant() -replace '[^a-z0-9]+', '_').Trim('_')
}

# Il prefisso si conta a segmenti interi e resta piu' corto di ogni nome.
function Get-CommonPrefixLength([string[]]$Names) {
    $segments = @($Names | ForEach-Object { , ($_ -split '\.') })
    $shortest = ($segments | ForEach-Object { $_.Count } | Measure-Object -Minimum).Minimum
    $length = 0
    while ($length -lt $shortest - 1 -and @($segments | ForEach-Object { $_[$length] } | Select-Object -Unique).Count -eq 1) { $length++ }
    return $length
}

function Remove-CommonPrefix([string]$Name, [string[]]$Names) {
    return (($Name -split '\.') | Select-Object -Skip (Get-CommonPrefixLength $Names)) -join '.'
}

function Get-RepositoryShortName {
    $names = @($SourceRepositories + $Repository | Select-Object -Unique)
    return Remove-CommonPrefix $Repository $names
}

function Get-ProjectKind([xml]$Project) {
    $sdk = "$($Project.Project.Sdk)"
    if (-not $sdk) { $sdk = "$($Project.Project.Sdk.Name)" }
    $properties = $Project.Project.PropertyGroup
    $isTest = $sdk -eq 'MSTest.Sdk' -or "$($properties.IsTestProject)" -match 'true' -or
        @($Project.Project.ItemGroup.PackageReference | Where-Object { $_.Include -eq 'Microsoft.NET.Test.Sdk' }).Count
    if ($isTest) { return 'test' }
    $outputType = "$($properties.OutputType)".Trim()
    $isFunctionApp = "$($properties.AzureFunctionsVersion)".Trim() -or $sdk -eq 'Microsoft.NET.Sdk.Functions'
    if ($sdk -eq 'Microsoft.NET.Sdk.Web') { return 'web' }
    if ($sdk -eq 'Microsoft.NET.Sdk' -and $isFunctionApp) { return 'functions' }
    if ($sdk -eq 'Microsoft.NET.Sdk' -and $outputType -eq 'Exe') { return 'tool' }
    if ($sdk -eq 'Microsoft.NET.Sdk' -and $outputType -in @('', 'Library')) { return 'library' }
    return $null
}

function Read-DotNetProjects {
    $projects = [ordered]@{}
    foreach ($file in (Get-SourceFiles '*.csproj')) {
        [xml]$xml = Get-Content -Raw $file.FullName
        $assembly = "$($xml.Project.PropertyGroup.AssemblyName)".Trim()
        $name = if ($assembly) { $assembly } else { $file.BaseName }
        $references = @($xml.Project.ItemGroup.ProjectReference | Where-Object { $_ } | ForEach-Object {
                [IO.Path]::GetFullPath((Join-Path $file.DirectoryName ($_.Include -replace '\\', '/')))
            })
        $projects[$file.FullName] = [pscustomobject]@{ Name = $name; Path = $file.FullName; Kind = (Get-ProjectKind $xml); References = $references }
    }
    return $projects
}

function Get-ProjectClosure($Application, $Projects) {
    $visited = [ordered]@{}
    $pending = [Collections.Generic.Queue[object]]::new()
    $pending.Enqueue($Application)
    while ($pending.Count) {
        $project = $pending.Dequeue()
        if ($visited.Contains($project.Path)) { continue }
        $visited[$project.Path] = $project
        $project.References | Where-Object { $Projects.Contains($_) -and $Projects[$_].Kind -ne 'test' } | ForEach-Object { $pending.Enqueue($Projects[$_]) }
    }
    return @($visited.Values)
}

function Get-DotNetApplications($Projects) {
    $allNames = @($Projects.Values | ForEach-Object Name)
    foreach ($application in ($Projects.Values | Where-Object { $_.Kind -in @('web', 'functions') } | Sort-Object Name)) {
        $containerId = ConvertTo-Identifier $application.Name
        $members = Get-ProjectClosure $application $Projects
        $components = foreach ($project in ($members | Sort-Object Name)) {
            [pscustomobject]@{
                Id         = "${containerId}__$(ConvertTo-Identifier $project.Name)"
                Name       = Remove-CommonPrefix $project.Name $allNames
                CodeName   = $project.Name
                Technology = '.NET'
                Targets    = @($project.References | Where-Object { $Projects.Contains($_) -and $Projects[$_].Kind -ne 'test' } |
                        ForEach-Object { "${containerId}__$(ConvertTo-Identifier $Projects[$_].Name)" } | Sort-Object -Unique)
            }
        }
        [pscustomobject]@{
            Id         = $containerId
            Name       = Remove-CommonPrefix $application.Name $allNames
            CodeName   = $application.Name
            Technology = if ($application.Kind -eq 'web') { 'ASP.NET Core' } else { 'Azure Functions' }
            Components = @($components)
        }
    }
}

function Get-AngularModules([string]$SourceRoot) {
    foreach ($directory in $FeatureDirectories) {
        Get-ChildItem -Path (Join-Path $SourceRoot $directory) -Directory -ErrorAction SilentlyContinue | Sort-Object Name
    }
    foreach ($directory in $ModuleDirectories) {
        Get-ChildItem -Path (Join-Path $SourceRoot $directory) -Directory -ErrorAction SilentlyContinue | Sort-Object Name |
            Where-Object { Get-ChildItem -Path $_.FullName -Recurse -File -Filter '*.providers.ts' | Select-Object -First 1 }
    }
}

function Get-ImportedModules($Module, $Modules) {
    $imports = foreach ($file in (Get-ChildItem -Path $Module.FullName -Recurse -File -Filter '*.ts' | Where-Object { $_.Name -notlike '*.spec.ts' })) {
        foreach ($match in [regex]::Matches((Get-Content -Raw $file.FullName), "(?:from|import)\s*\(?\s*['""](\.[^'""]+)['""]")) {
            [IO.Path]::GetFullPath((Join-Path $file.DirectoryName $match.Groups[1].Value))
        }
    }
    return @($Modules | Where-Object { $_.FullName -ne $Module.FullName } | Where-Object {
            $prefix = $_.FullName + [IO.Path]::DirectorySeparatorChar
            $imports | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        })
}

function Get-AngularApplications($Workspace, [string]$WorkspaceDirectory) {
    $applications = @($Workspace.projects.PSObject.Properties | Where-Object { $_.Value.projectType -eq 'application' } | Sort-Object Name)
    foreach ($application in $applications) {
        $codeName = if ($applications.Count -eq 1) { $Repository } else { "$Repository.$($application.Name)" }
        $containerId = ConvertTo-Identifier $codeName
        $sourceRoot = Join-Path $WorkspaceDirectory $application.Value.sourceRoot
        $modules = @(Get-AngularModules $sourceRoot)
        $components = foreach ($module in $modules) {
            $path = [IO.Path]::GetRelativePath($sourceRoot, $module.FullName) -replace '\\', '/'
            [pscustomobject]@{
                Id         = "${containerId}__$(ConvertTo-Identifier ($path -replace '^app/', ''))"
                Name       = $module.Name
                CodeName   = Get-RelativePath $module.FullName
                Technology = 'Angular'
                Path       = $module.FullName
                Targets    = @()
            }
        }
        foreach ($component in $components) {
            $component.Targets = @(Get-ImportedModules (Get-Item $component.Path) $modules | ForEach-Object {
                    $target = $_.FullName
                    ($components | Where-Object { $_.Path -eq $target }).Id
                } | Sort-Object -Unique)
        }
        [pscustomobject]@{
            Id         = $containerId
            Name       = if ($applications.Count -eq 1) { Get-RepositoryShortName } else { $application.Name }
            CodeName   = $codeName
            Technology = 'Angular'
            Components = @($components)
        }
    }
}

function Get-UnrecognizedIssues($Projects, $AngularWorkspaces) {
    foreach ($pattern in $UnrecognizedProjectFiles) {
        Get-SourceFiles $pattern | ForEach-Object { New-Issue $Repository 'progetto di un tipo non riconosciuto' (Get-RelativePath $_.FullName) }
    }
    $Projects.Values | Where-Object { -not $_.Kind } | ForEach-Object { New-Issue $Repository 'progetto .NET di un tipo non riconosciuto' $_.Name }
    $angularDirectories = @($AngularWorkspaces | ForEach-Object { $_.DirectoryName })
    Get-SourceFiles 'package.json' | Where-Object { $angularDirectories -notcontains $_.DirectoryName } | ForEach-Object {
        $package = Get-Content -Raw $_.FullName | ConvertFrom-Json
        $name = if ($package.name) { $package.name } else { Get-RelativePath $_.DirectoryName }
        New-Issue $Repository 'applicazione di un tipo non riconosciuto' $name
    }
    foreach ($workspace in $AngularWorkspaces) {
        (Get-Content -Raw $workspace.FullName | ConvertFrom-Json).projects.PSObject.Properties |
            Where-Object { $_.Value.projectType -ne 'application' } |
            ForEach-Object { New-Issue $Repository 'progetto Angular di un tipo non riconosciuto' $_.Name }
    }
}

function Format-Text([string]$Text) {
    return '"' + ($Text -replace '"', '\"') + '"'
}

function Format-Container($Container, [string]$Indent) {
    $lines = @("$Indent$($Container.Id) = container $(Format-Text $Container.Name) `"`" $(Format-Text $Container.Technology) $(Format-Text "$ApplicationTag,$GeneratedTag") {")
    $lines += "$Indent    properties {", "$Indent        $(Format-Text $CodeNameProperty) $(Format-Text $Container.CodeName)", "$Indent    }"
    foreach ($component in $Container.Components) {
        $lines += "$Indent    $($component.Id) = component $(Format-Text $component.Name) `"`" $(Format-Text $component.Technology) $(Format-Text $GeneratedTag) {"
        $lines += "$Indent        properties {", "$Indent            $(Format-Text $CodeNameProperty) $(Format-Text $component.CodeName)", "$Indent        }", "$Indent    }"
    }
    foreach ($component in $Container.Components) {
        $component.Targets | Where-Object { $_ -ne $component.Id } | ForEach-Object { $lines += "$Indent    $($component.Id) -> $_ `"`" `"`" $(Format-Text $GeneratedTag)" }
    }
    $lines += "$Indent}"
    return $lines
}

function Format-Model($Containers) {
    $lines = @("// Parte del modello C4 generata da $Repository con Export-C4CodeModel.ps1: non si modifica a mano.")
    if ($Containers.Count -gt 1) {
        $lines += "group $(Format-Text (Get-RepositoryShortName)) {"
        $Containers | ForEach-Object { $lines += Format-Container $_ '    ' }
        $lines += '}'
    }
    else {
        $Containers | ForEach-Object { $lines += Format-Container $_ '' }
    }
    return ($lines -join "`n") + "`n"
}

function Get-GenerationIssues {
    if (-not $Repository) { return New-Issue 'generazione del modello C4' 'repository sorgente non dichiarato' 'SOURCE_REPOSITORY' }
    if (-not (Test-Path $SourceDirectory -PathType Container)) { return New-Issue $Repository 'repository sorgente assente' $SourceDirectory }

    $projects = Read-DotNetProjects
    $angularWorkspaces = @(Get-SourceFiles 'angular.json')
    $unrecognized = @(Get-UnrecognizedIssues $projects $angularWorkspaces)
    if ($unrecognized) { return $unrecognized }

    $containers = @(Get-DotNetApplications $projects)
    foreach ($workspace in $angularWorkspaces) {
        $containers += @(Get-AngularApplications (Get-Content -Raw $workspace.FullName | ConvertFrom-Json) $workspace.DirectoryName)
    }
    if (-not $containers) { return New-Issue $Repository 'nessuna applicazione riconosciuta' $SourceDirectory }

    $model = Format-Model $containers
    $target = Join-Path $GeneratedDirectory "$($Repository.ToLowerInvariant()).dsl"
    if ($Mode -eq 'check') {
        $current = if (Test-Path $target -PathType Leaf) { (Get-Content -Raw $target) -replace "`r`n", "`n" } else { $null }
        if ($current -ne $model) { return New-Issue $Repository 'parte generata diversa da quella che il codice produce' ($target -replace '\\', '/') }
        return
    }
    New-Item -ItemType Directory -Force -Path $GeneratedDirectory | Out-Null
    [IO.File]::WriteAllText((Join-Path (Resolve-Path $GeneratedDirectory).Path (Split-Path $target -Leaf)), $model)
}

Invoke-Verification { Get-GenerationIssues } "Parte del modello C4 di $Repository allineata al codice" 'Generazione del modello C4 disattivata'
