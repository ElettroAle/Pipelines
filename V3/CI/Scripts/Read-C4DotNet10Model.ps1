# SPDX-License-Identifier: Apache-2.0

# Lettore .NET 10 del modello C4 generato (contratto in Common/C4CodeModel.ps1). Le applicazioni sono
# container; i progetti di produzione che un'applicazione raggiunge con i riferimenti sono i suoi
# componenti, legati da quei riferimenti. Il tipo di un progetto viene dalle regole di .NET 10 qui
# sotto, provate solo su .NET 10: un progetto di un'altra versione, o di un tipo che le regole non
# riconoscono, ferma la lettura invece di essere letto con regole non sue.

. "$PSScriptRoot/Common/VerificationGate.ps1"
. "$PSScriptRoot/Common/DocumentLanguage.ps1"
. "$PSScriptRoot/Common/C4CodeModel.ps1"

$SupportedTargetFramework = '^net10\.0(-[a-z0-9.]+)?$'
$TestKind = 'test'
# Il tipo e' quello della prima regola le cui condizioni valgono tutte (confronto -like; Package vale
# se una delle librerie corrisponde).
$ProjectKinds = @(
    @{ Kind = $TestKind; Sdk = 'MSTest.Sdk' }
    @{ Kind = $TestKind; IsTestProject = 'true' }
    @{ Kind = $TestKind; Package = 'Microsoft.NET.Test.Sdk' }
    @{ Kind = 'web'; Sdk = 'Microsoft.NET.Sdk.Web' }
    @{ Kind = 'functions'; Sdk = 'Microsoft.NET.Sdk.Functions' }
    @{ Kind = 'functions'; Sdk = 'Microsoft.NET.Sdk'; AzureFunctionsVersion = '?*' }
    @{ Kind = 'tool'; Sdk = 'Microsoft.NET.Sdk'; OutputType = 'Exe' }
    @{ Kind = 'library'; Sdk = 'Microsoft.NET.Sdk'; OutputType = '' }
    @{ Kind = 'library'; Sdk = 'Microsoft.NET.Sdk'; OutputType = 'Library' }
)
$ApplicationTechnologies = @{
    web       = 'ASP.NET Core'
    functions = 'Azure Functions'
}
$ApplicationTag = $DocumentLanguage.ApplicationTag

function Get-ProjectFacts([xml]$Project) {
    $properties = $Project.Project.PropertyGroup
    return @{
        Sdk                   = @($Project.Project.Sdk, $Project.Project.Sdk.Name) | Where-Object { $_ -is [string] -and $_ } | Select-Object -First 1
        IsTestProject         = "$($properties.IsTestProject)".Trim()
        OutputType            = "$($properties.OutputType)".Trim()
        AzureFunctionsVersion = "$($properties.AzureFunctionsVersion)".Trim()
        Package               = @($Project.Project.ItemGroup.PackageReference | Where-Object { $_ -and $_.Include } | ForEach-Object Include)
    }
}

function Get-DeclaredTargetFrameworks([xml]$Project) {
    $properties = $Project.Project.PropertyGroup
    return @(@($properties.TargetFramework) + @($properties.TargetFrameworks) |
            Where-Object { $_ -is [string] } | ForEach-Object { $_ -split ';' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Un progetto senza versione la eredita dal Directory.Build.props piu' vicino, come fa MSBuild.
function Get-TargetFrameworks($File, [xml]$Project) {
    $declared = @(Get-DeclaredTargetFrameworks $Project)
    $root = (Resolve-Path $SourceDirectory).Path
    $directory = $File.Directory
    while (-not $declared -and $directory -and $directory.FullName.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        $props = Join-Path $directory.FullName 'Directory.Build.props'
        if (Test-Path $props -PathType Leaf) { $declared = @(Get-DeclaredTargetFrameworks ([xml](Get-Content -Raw $props))) }
        $directory = $directory.Parent
    }
    return $declared
}

function Test-RuleMatches([hashtable]$Rule, [hashtable]$Facts) {
    $conditions = @($Rule.Keys | Where-Object { $_ -ne 'Kind' })
    return -not ($conditions | Where-Object { -not @(@($Facts[$_]) -like $Rule[$_]).Count })
}

function Get-ProjectKind([hashtable]$Facts) {
    return ($ProjectKinds | Where-Object { Test-RuleMatches $_ $Facts } | Select-Object -First 1).Kind
}

function Read-DotNetProjects {
    $projects = [ordered]@{}
    foreach ($file in (Get-SourceFiles '*.csproj')) {
        [xml]$xml = Get-Content -Raw $file.FullName
        $assembly = "$($xml.Project.PropertyGroup.AssemblyName)".Trim()
        $references = @($xml.Project.ItemGroup.ProjectReference | Where-Object { $_ } | ForEach-Object {
                [IO.Path]::GetFullPath((Join-Path $file.DirectoryName ($_.Include -replace '\\', '/')))
            })
        $projects[$file.FullName] = [pscustomobject]@{
            Name             = @($assembly, $file.BaseName) | Where-Object { $_ } | Select-Object -First 1
            Path             = $file.FullName
            Kind             = Get-ProjectKind (Get-ProjectFacts $xml)
            TargetFrameworks = @(Get-TargetFrameworks $file $xml)
            References       = $references
        }
    }
    return $projects
}

function Get-ProductionReferences($Project, $Projects) {
    return @($Project.References | Where-Object { $Projects.Contains($_) -and $Projects[$_].Kind -ne $TestKind } | ForEach-Object { $Projects[$_] })
}

function Get-ProjectClosure($Application, $Projects) {
    $visited = [ordered]@{}
    $pending = [Collections.Generic.Queue[object]]::new()
    $pending.Enqueue($Application)
    while ($pending.Count) {
        $project = $pending.Dequeue()
        if ($visited.Contains($project.Path)) { continue }
        $visited[$project.Path] = $project
        Get-ProductionReferences $project $Projects | ForEach-Object { $pending.Enqueue($_) }
    }
    return @($visited.Values)
}

function Get-ComponentId([string]$ContainerId, $Project) {
    return "${ContainerId}__$(ConvertTo-Identifier $Project.Name)"
}

function Get-Applications($Projects) {
    return @($Projects.Values | Where-Object { $ApplicationTechnologies.ContainsKey("$($_.Kind)") } | Sort-Object Name)
}

function New-ApplicationContainer($Application, $Projects, [string[]]$AllNames) {
    $containerId = ConvertTo-Identifier $Application.Name
    $components = foreach ($project in (Get-ProjectClosure $Application $Projects | Sort-Object Name)) {
        [ordered]@{
            id         = Get-ComponentId $containerId $project
            name       = Remove-CommonPrefix $project.Name $AllNames
            codeName   = $project.Name
            sources    = @(Get-RelativePath (Split-Path $project.Path))
            technology = '.NET'
            properties = [ordered]@{}
        }
    }
    return [ordered]@{
        id         = $containerId
        name       = Remove-CommonPrefix $Application.Name $AllNames
        codeName   = $Application.Name
        sources    = @(Get-RelativePath (Split-Path $Application.Path))
        technology = $ApplicationTechnologies[$Application.Kind]
        tags       = @($ApplicationTag)
        properties = [ordered]@{}
        components = @($components)
    }
}

function Get-ApplicationRelationships($Application, $Projects) {
    $containerId = ConvertTo-Identifier $Application.Name
    foreach ($project in (Get-ProjectClosure $Application $Projects | Sort-Object Name)) {
        Get-ProductionReferences $project $Projects | Sort-Object Name -Unique | ForEach-Object {
            New-C4Relationship (Get-ComponentId $containerId $project) (Get-ComponentId $containerId $_)
        }
    }
}

function Get-UnsupportedVersionIssues($Projects) {
    foreach ($project in $Projects.Values) {
        if (-not $project.TargetFrameworks) { New-Issue $Repository 'progetto .NET senza versione dichiarata' $project.Name; continue }
        $project.TargetFrameworks | Where-Object { $_ -notmatch $SupportedTargetFramework } |
            ForEach-Object { New-Issue $Repository 'progetto .NET di una versione che il lettore .NET 10 non legge' "$($project.Name) ($_)" }
    }
}

function Get-UnrecognizedIssues($Projects) {
    $Projects.Values | Where-Object { -not $_.Kind } | ForEach-Object { New-Issue $Repository 'progetto .NET di un tipo non riconosciuto' $_.Name }
}

function Get-ReadIssues {
    $sourceIssues = @(Get-SourceIssues)
    if ($sourceIssues) { return $sourceIssues }

    $projects = Read-DotNetProjects
    $unsupported = @(Get-UnsupportedVersionIssues $projects) + @(Get-UnrecognizedIssues $projects)
    if ($unsupported) { return $unsupported }

    $allNames = @($projects.Values | ForEach-Object Name)
    $applications = Get-Applications $projects
    $containers = $applications | ForEach-Object { New-ApplicationContainer $_ $projects $allNames }
    $relationships = $applications | ForEach-Object { Get-ApplicationRelationships $_ $projects }
    Write-C4Fragment 'dotnet10' @($projects.Keys | ForEach-Object { Get-RelativePath $_ }) $containers $relationships
}

Invoke-Verification { Get-ReadIssues } "Progetti .NET 10 di $Repository letti" 'Lettura dei progetti .NET 10 disattivata'
