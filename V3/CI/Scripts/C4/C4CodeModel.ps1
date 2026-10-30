# SPDX-License-Identifier: Apache-2.0

# Contratto fra i lettori di una tecnologia e Export-C4CodeModel.ps1. Un lettore legge solo il
# checkout del repository sorgente (SOURCE_DIRECTORY) e scrive in FRAGMENT_DIRECTORY il frammento
# <repository in minuscolo>.<tecnologia>.json: i file manifest che ha letto, i container con i loro
# componenti e le relazioni. Lo scrittore unisce i frammenti di un repository senza conoscere le
# tecnologie che li hanno prodotti.

$SourceDirectory = if ($env:SOURCE_DIRECTORY) { $env:SOURCE_DIRECTORY } else { '.' }
$Repository = "$env:SOURCE_REPOSITORY".Trim()
$FragmentDirectory = if ($env:FRAGMENT_DIRECTORY) { $env:FRAGMENT_DIRECTORY } else { 'c4-fragments' }
$IgnoredDirectories = @('node_modules', 'bin', 'obj', '.git', 'dist', '.angular', '.terraform')

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

function Get-SourceIssues {
    if (-not $Repository) { return New-Issue 'generazione del modello C4' 'repository sorgente non dichiarato' 'SOURCE_REPOSITORY' }
    if (-not (Test-Path $SourceDirectory -PathType Container)) { return New-Issue $Repository 'repository sorgente assente' $SourceDirectory }
}

function Get-FragmentPath([string]$Technology) {
    return Join-Path $FragmentDirectory "$($Repository.ToLowerInvariant()).$Technology.json"
}

function Write-C4Fragment([string]$Technology, [string[]]$Manifests, $Containers, $Relationships) {
    New-Item -ItemType Directory -Force -Path $FragmentDirectory | Out-Null
    $fragment = [ordered]@{
        manifests     = @($Manifests | Where-Object { $_ })
        containers    = @($Containers | Where-Object { $_ })
        relationships = @($Relationships | Where-Object { $_ })
    }
    [IO.File]::WriteAllText((Join-Path (Resolve-Path $FragmentDirectory).Path (Split-Path (Get-FragmentPath $Technology) -Leaf)), (ConvertTo-Json $fragment -Depth 10))
}

function New-C4Relationship([string]$Source, [string]$Target) {
    return [ordered]@{ source = $Source; target = $Target }
}
