# SPDX-License-Identifier: Apache-2.0

# Lettura del codice .NET 10 di un checkout (SOURCE_DIRECTORY): i progetti con il loro tipo, il codice
# di ogni progetto senza i commenti e i tipi che dichiara. Usato da Read-C4DotNet10Model.ps1 e dalla
# verifica delle classi governate dalle decisioni.

. "$PSScriptRoot/C4CodeModel.ps1"

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

# Una dichiarazione di tipo apre la riga, dopo attributi e modificatori: cosi' le parole class o
# interface dentro una stringa non contano.
$TypeDeclarationStart = '(?m)^[ \t]*(?:\[[^\]\n]*\][ \t]*)*(?:(?:public|internal|private|protected|static|sealed|abstract|partial|readonly|file|unsafe|new|ref)[ \t]+)*'

function Get-CodeWithoutComments($File) {
    return (Get-Content -Raw $File.FullName) -replace '(?s)/\*.*?\*/|//[^\n]*', ''
}

function Test-InOwnProject([string]$File, [string]$Root, [string[]]$NestedRoots) {
    $inIgnored = $File.Substring($Root.Length) -split '[\\/]' | Where-Object { $IgnoredDirectories -contains $_ }
    $inNested = $NestedRoots | Where-Object { $File.StartsWith("$_$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase) }
    return -not ($inIgnored -or $inNested)
}

function Get-ProjectCode($Project) {
    $root = Split-Path $Project.Path
    $nestedRoots = @(Get-ChildItem -Path $root -Recurse -File -Filter '*.csproj' | ForEach-Object { Split-Path $_.FullName } | Where-Object { $_ -ne $root })
    return @(Get-ChildItem -Path $root -Recurse -File -Filter '*.cs' | Where-Object { Test-InOwnProject $_.FullName $root $nestedRoots } | ForEach-Object { Get-CodeWithoutComments $_ })
}

# Stringhe e caratteri tolti prima di contare le graffe: una graffa in un testo non apre un blocco.
$LiteralPattern = '(?s)"""(?:.*?)"""|@"(?:[^"]|"")*"|\$@"(?:[^"]|"")*"|"(?:\.|[^"\\n])*"|''(?:\.|[^''\\n])+'''
$TypeDeclarationPattern = $TypeDeclarationStart + '(?:record\s+(?:class|struct)|class|record|struct|interface|enum)\s+(?<type>\w+)'
$DeclarationScanPattern = "(?<namespace>(?m)^[ \t]*namespace\s+(?<name>[\w.]+)\s*(?<scoped>;)?)|(?<declaration>$TypeDeclarationPattern)|(?<open>\{)|(?<close>\})"

# I nomi completi dei tipi di primo livello di un file: un tipo annidato in un altro e' un dettaglio della
# classe che lo contiene.
function Get-DeclaredTypes([string]$Code) {
    $text = $Code -replace $LiteralPattern, '""'
    $fileNamespace = ''
    $blocks = [Collections.Generic.List[string]]::new()
    $pending = $null
    foreach ($token in [regex]::Matches($text, $DeclarationScanPattern)) {
        if ($token.Groups['namespace'].Success) {
            if ($token.Groups['scoped'].Success) { $fileNamespace = $token.Groups['name'].Value } else { $pending = "namespace:$($token.Groups['name'].Value)" }
        }
        elseif ($token.Groups['declaration'].Success) {
            if (-not @($blocks | Where-Object { -not $_.StartsWith('namespace:') }).Count) {
                $namespace = @($fileNamespace) + @($blocks | ForEach-Object { $_.Substring(10) }) | Where-Object { $_ }
                (@($namespace) + $token.Groups['type'].Value) -join '.'
            }
            $pending = 'type'
        }
        elseif ($token.Groups['open'].Success) {
            $blocks.Add($(if ($pending) { $pending } else { 'block' }))
            $pending = $null
        }
        elseif ($blocks.Count) { $blocks.RemoveAt($blocks.Count - 1) }
    }
}

# I tipi dichiarati dai progetti che non sono di test, con il nome completo e il nome della classe.
function Get-ProductionTypes($Projects) {
    foreach ($project in @($Projects.Values | Where-Object { $_.Kind -ne $TestKind })) {
        foreach ($code in (Get-ProjectCode $project)) {
            Get-DeclaredTypes $code | ForEach-Object { [pscustomobject]@{ FullName = $_; Name = ($_ -split '\.')[-1]; Project = $project.Name } }
        }
    }
}
