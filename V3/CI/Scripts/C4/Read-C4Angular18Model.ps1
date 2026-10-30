# SPDX-License-Identifier: Apache-2.0

# Lettore Angular 18 del modello C4 generato (contratto in C4CodeModel.ps1). L'applicazione di un
# workspace Angular e' un container che prende il nome del repository senza il prefisso comune ai
# repository sorgente (SOURCE_REPOSITORIES); le cartelle di funzionalita' e i moduli di base con un
# file *.providers.ts sono i suoi componenti, legati dagli import fra cartelle. Un workspace con un
# progetto che non e' l'unica applicazione, o un secondo workspace, ferma la lettura. Le regole sono
# provate solo su Angular 18: un workspace che dipende da un'altra versione di @angular/core ferma la
# lettura invece di essere letto con regole non sue.

. "$PSScriptRoot/../Common/VerificationGate.ps1"
. "$PSScriptRoot/../Common/DocumentLanguage.ps1"
. "$PSScriptRoot/C4CodeModel.ps1"

$SourceRepositories = @("$env:SOURCE_REPOSITORIES" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$FeatureDirectories = @(if ($env:ANGULAR_FEATURE_DIRECTORIES) { $env:ANGULAR_FEATURE_DIRECTORIES -split ',' } else { 'app/features' })
$ModuleDirectories = @(if ($env:ANGULAR_MODULE_DIRECTORIES) { $env:ANGULAR_MODULE_DIRECTORIES -split ',' } else { 'app/core' })
$SupportedAngularMajor = 18
$ApplicationTag = $DocumentLanguage.ApplicationTag

function Get-RepositoryShortName {
    return Remove-CommonPrefix $Repository @($SourceRepositories + $Repository | Select-Object -Unique)
}

function Read-AngularVersion($File) {
    $package = Join-Path $File.DirectoryName 'package.json'
    if (-not (Test-Path $package -PathType Leaf)) { return '' }
    return "$((Get-Content -Raw $package | ConvertFrom-Json).dependencies.'@angular/core')".Trim()
}

function Read-Workspace($File) {
    return [pscustomobject]@{
        File     = $File
        Projects = @((Get-Content -Raw $File.FullName | ConvertFrom-Json).projects.PSObject.Properties)
        Version  = Read-AngularVersion $File
    }
}

function Get-MajorVersion([string]$Range) {
    if ($Range -match '^[\^~=v]*(\d+)(\.\d+){0,2}$') { return [int]$Matches[1] }
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

function Get-ComponentId([string]$ContainerId, [string]$SourceRoot, $Module) {
    $path = [IO.Path]::GetRelativePath($SourceRoot, $Module.FullName) -replace '\\', '/'
    return "${ContainerId}__$(ConvertTo-Identifier ($path -replace '^app/', ''))"
}

function Get-SourceRoot($Workspace) {
    return Join-Path $Workspace.File.DirectoryName $Workspace.Projects[0].Value.sourceRoot
}

function New-ApplicationContainer($Workspace) {
    $containerId = ConvertTo-Identifier $Repository
    $sourceRoot = Get-SourceRoot $Workspace
    $components = foreach ($module in (Get-AngularModules $sourceRoot)) {
        [ordered]@{
            id         = Get-ComponentId $containerId $sourceRoot $module
            name       = $module.Name
            codeName   = Get-RelativePath $module.FullName
            technology = 'Angular'
            properties = [ordered]@{}
        }
    }
    return [ordered]@{
        id         = $containerId
        name       = Get-RepositoryShortName
        codeName   = $Repository
        technology = 'Angular'
        tags       = @($ApplicationTag)
        properties = [ordered]@{}
        components = @($components)
    }
}

function Get-ApplicationRelationships($Workspace) {
    $containerId = ConvertTo-Identifier $Repository
    $sourceRoot = Get-SourceRoot $Workspace
    $modules = @(Get-AngularModules $sourceRoot)
    foreach ($module in $modules) {
        Get-ImportedModules $module $modules | ForEach-Object {
            New-C4Relationship (Get-ComponentId $containerId $sourceRoot $module) (Get-ComponentId $containerId $sourceRoot $_)
        }
    }
}

function Get-Manifests($Workspace) {
    return @($Workspace.File, (Join-Path $Workspace.File.DirectoryName 'package.json') | Where-Object { Test-Path $_ -PathType Leaf } | ForEach-Object { Get-RelativePath "$_" })
}

function Get-UnsupportedVersionIssues($Workspaces) {
    foreach ($workspace in $Workspaces) {
        $workspacePath = Get-RelativePath $workspace.File.FullName
        if (-not $workspace.Version) { New-Issue $Repository 'workspace Angular senza versione di @angular/core in package.json' $workspacePath; continue }
        if ((Get-MajorVersion $workspace.Version) -ne $SupportedAngularMajor) {
            New-Issue $Repository 'workspace Angular di una versione che il lettore Angular 18 non legge' "$workspacePath ($($workspace.Version))"
        }
    }
}

function Get-UnrecognizedIssues($Workspaces) {
    $Workspaces | ForEach-Object { $_.Projects | Where-Object { $_.Value.projectType -ne 'application' } } |
        ForEach-Object { New-Issue $Repository 'progetto Angular di un tipo non riconosciuto' $_.Name }
    $Workspaces | Where-Object { $_.Projects.Count -gt 1 } |
        ForEach-Object { New-Issue $Repository 'workspace Angular con piu'' di un progetto' (Get-RelativePath $_.File.FullName) }
    $Workspaces | Select-Object -Skip 1 |
        ForEach-Object { New-Issue $Repository 'piu'' di un workspace Angular nello stesso repository' (Get-RelativePath $_.File.FullName) }
}

function Get-ReadIssues {
    $sourceIssues = @(Get-SourceIssues)
    if ($sourceIssues) { return $sourceIssues }

    $workspaces = @(Get-SourceFiles 'angular.json' | ForEach-Object { Read-Workspace $_ })
    $unrecognized = @(Get-UnsupportedVersionIssues $workspaces) + @(Get-UnrecognizedIssues $workspaces)
    if ($unrecognized) { return $unrecognized }

    $containers = $workspaces | ForEach-Object { New-ApplicationContainer $_ }
    $relationships = $workspaces | ForEach-Object { Get-ApplicationRelationships $_ }
    Write-C4Fragment 'angular18' @($workspaces | ForEach-Object { Get-Manifests $_ }) $containers $relationships
}

Invoke-Verification { Get-ReadIssues } "Applicazioni Angular 18 di $Repository lette" 'Lettura delle applicazioni Angular 18 disattivata'
