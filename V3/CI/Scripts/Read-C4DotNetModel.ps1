# SPDX-License-Identifier: Apache-2.0

# Lettore .NET del modello C4 generato (contratto in C4CodeModel.ps1). Le applicazioni sono
# container; i progetti di produzione che un'applicazione raggiunge con i riferimenti sono i suoi
# componenti, legati da quei riferimenti, con i servizi Azure delle loro librerie. Il tipo di un
# progetto e i servizi delle librerie vengono dalle tabelle di DotNetModel.psd1: un progetto o una
# libreria Azure che le tabelle non riconoscono ferma la lettura.

. "$PSScriptRoot/VerificationGate.ps1"
. "$PSScriptRoot/DocumentLanguage.ps1"
. "$PSScriptRoot/C4CodeModel.ps1"

$Rules = Import-PowerShellDataFile "$PSScriptRoot/DotNetModel.psd1"
$ApplicationTag = $DocumentLanguage.ApplicationTag
$ServicesProperty = $DocumentLanguage.ServicesProperty

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

function Test-RuleMatches([hashtable]$Rule, [hashtable]$Facts) {
    $conditions = @($Rule.Keys | Where-Object { $_ -ne 'Kind' })
    return -not ($conditions | Where-Object { -not @(@($Facts[$_]) -like $Rule[$_]).Count })
}

function Get-ProjectKind([hashtable]$Facts) {
    return ($Rules.ProjectKinds | Where-Object { Test-RuleMatches $_ $Facts } | Select-Object -First 1).Kind
}

function Read-DotNetProjects {
    $projects = [ordered]@{}
    foreach ($file in (Get-SourceFiles '*.csproj')) {
        [xml]$xml = Get-Content -Raw $file.FullName
        $facts = Get-ProjectFacts $xml
        $assembly = "$($xml.Project.PropertyGroup.AssemblyName)".Trim()
        $references = @($xml.Project.ItemGroup.ProjectReference | Where-Object { $_ } | ForEach-Object {
                [IO.Path]::GetFullPath((Join-Path $file.DirectoryName ($_.Include -replace '\\', '/')))
            })
        $projects[$file.FullName] = [pscustomobject]@{
            Name       = @($assembly, $file.BaseName) | Where-Object { $_ } | Select-Object -First 1
            Path       = $file.FullName
            Kind       = Get-ProjectKind $facts
            References = $references
            Packages   = $facts.Package
        }
    }
    return $projects
}

function Get-ProductionReferences($Project, $Projects) {
    return @($Project.References | Where-Object { $Projects.Contains($_) -and $Projects[$_].Kind -ne $Rules.TestKind } | ForEach-Object { $Projects[$_] })
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

function Get-AzureServices($Project) {
    return @($Project.Packages | Where-Object { $Rules.Packages.ContainsKey($_) } | ForEach-Object { $Rules.Packages[$_] } | Sort-Object -Unique)
}

function Get-ComponentId([string]$ContainerId, $Project) {
    return "${ContainerId}__$(ConvertTo-Identifier $Project.Name)"
}

function Get-Applications($Projects) {
    return @($Projects.Values | Where-Object { $Rules.Applications.ContainsKey("$($_.Kind)") } | Sort-Object Name)
}

function New-ApplicationContainer($Application, $Projects, [string[]]$AllNames) {
    $containerId = ConvertTo-Identifier $Application.Name
    $components = foreach ($project in (Get-ProjectClosure $Application $Projects | Sort-Object Name)) {
        [ordered]@{
            id         = Get-ComponentId $containerId $project
            name       = Remove-CommonPrefix $project.Name $AllNames
            codeName   = $project.Name
            technology = '.NET'
            properties = [ordered]@{ $ServicesProperty = (Get-AzureServices $project) -join ',' }
        }
    }
    return [ordered]@{
        id         = $containerId
        name       = Remove-CommonPrefix $Application.Name $AllNames
        codeName   = $Application.Name
        technology = $Rules.Applications[$Application.Kind]
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

function Get-UnrecognizedIssues($Projects) {
    $Projects.Values | Where-Object { -not $_.Kind } | ForEach-Object { New-Issue $Repository 'progetto .NET di un tipo non riconosciuto' $_.Name }
    foreach ($project in ($Projects.Values | Where-Object { $_.Kind -ne $Rules.TestKind })) {
        $project.Packages |
            Where-Object { $_ -match $Rules.AzurePackage -and -not $Rules.Packages.ContainsKey($_) -and $Rules.IgnoredPackages -notcontains $_ } |
            ForEach-Object { New-Issue $Repository 'libreria Azure non riconosciuta' "$_ in $($project.Name)" }
    }
}

function Get-ReadIssues {
    $sourceIssues = @(Get-SourceIssues)
    if ($sourceIssues) { return $sourceIssues }

    $projects = Read-DotNetProjects
    $unrecognized = @(Get-UnrecognizedIssues $projects)
    if ($unrecognized) { return $unrecognized }

    $allNames = @($projects.Values | ForEach-Object Name)
    $applications = Get-Applications $projects
    $containers = $applications | ForEach-Object { New-ApplicationContainer $_ $projects $allNames }
    $relationships = $applications | ForEach-Object { Get-ApplicationRelationships $_ $projects }
    Write-C4Fragment 'dotnet' @($projects.Keys | ForEach-Object { Get-RelativePath $_ }) $containers $relationships
}

Invoke-Verification { Get-ReadIssues } "Progetti .NET di $Repository letti" 'Lettura dei progetti .NET disattivata'
