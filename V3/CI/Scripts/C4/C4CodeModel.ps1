# SPDX-License-Identifier: Apache-2.0

# Contratto fra i lettori di una tecnologia e Export-C4CodeModel.ps1. Un lettore legge solo il
# checkout del repository sorgente (SOURCE_DIRECTORY) e scrive in FRAGMENT_DIRECTORY il frammento
# <repository in minuscolo>.<tecnologia>.json: i file manifest che ha letto, i container con i loro
# componenti e le relazioni. Ogni elemento dichiara in sources le cartelle del suo codice, che il
# generatore del testo del modello legge. Lo scrittore unisce i frammenti di un repository senza conoscere le
# tecnologie che li hanno prodotti.
# Un frammento puo' dichiarare anche gli indirizzi a cui un container si avvia in locale (addresses) e
# quelli che chiama in locale (calls), ciascuno con il file che lo dichiara: un indirizzo chiamato a cui si
# avvia un solo container di qualunque repository e' la relazione fra i due.

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

# Un lettore vede un solo repository e toglie il prefisso comune ai suoi progetti: nel sistema
# un'applicazione si chiama con il nome nel codice senza il prefisso comune a tutte le applicazioni,
# e cosi' ogni componente il cui nome nel codice comincia con quel prefisso.
function Get-C4ApplicationNames($Containers) {
    $names = @{}
    $applications = @($Containers | Where-Object { $_ -and $_.codeName -and @($_.tags) -contains $DocumentLanguage.ApplicationTag })
    if ($applications.Count -lt 2) { return $names }
    $codeNames = @($applications | ForEach-Object { "$($_.codeName)" })
    $length = Get-CommonPrefixLength $codeNames
    $prefix = if ($length) { ((("$($codeNames[0])" -split '\.') | Select-Object -First $length) -join '.') + '.' } else { '' }
    $applications | ForEach-Object { $names["$($_.id)"] = "$($_.codeName)".Substring($prefix.Length) }
    @($applications | ForEach-Object { @($_.components) }) | Where-Object { $_ -and $prefix -and "$($_.codeName)".StartsWith($prefix) } |
        ForEach-Object { $names["$($_.id)"] = "$($_.codeName)".Substring($prefix.Length) }
    return $names
}

function Get-SourceIssues {
    if (-not $Repository) { return New-Issue 'generazione del modello C4' 'repository sorgente non dichiarato' 'SOURCE_REPOSITORY' }
    if (-not (Test-Path $SourceDirectory -PathType Container)) { return New-Issue $Repository 'repository sorgente assente' $SourceDirectory }
}

function Get-FragmentPath([string]$Technology) {
    return Join-Path $FragmentDirectory "$($Repository.ToLowerInvariant()).$Technology.json"
}

function Write-C4Fragment([string]$Technology, [string[]]$Manifests, $Containers, $Relationships, $Addresses = @(), $Calls = @()) {
    New-Item -ItemType Directory -Force -Path $FragmentDirectory | Out-Null
    $fragment = [ordered]@{
        manifests     = @($Manifests | Where-Object { $_ })
        containers    = @($Containers | Where-Object { $_ })
        relationships = @($Relationships | Where-Object { $_ })
        addresses     = @($Addresses | Where-Object { $_ })
        calls         = @($Calls | Where-Object { $_ })
    }
    [IO.File]::WriteAllText((Join-Path (Resolve-Path $FragmentDirectory).Path (Split-Path (Get-FragmentPath $Technology) -Leaf)), (ConvertTo-Json $fragment -Depth 10))
}

function New-C4Relationship([string]$Source, [string]$Target) {
    return [ordered]@{ source = $Source; target = $Target }
}

# Schema, host e porta, che Uri da' in minuscolo: la forma in cui un indirizzo chiamato e uno di avvio
# si confrontano.
function ConvertTo-Address([string]$Url) {
    $uri = $null
    if (-not [Uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https') -or -not $uri.Host) { return $null }
    return "$($uri.Scheme)://$($uri.Host):$($uri.Port)"
}

function New-C4Address([string]$Element, [string]$Address, [string]$Source) {
    return [ordered]@{ element = $Element; address = $Address; source = $Source }
}

# Un frammento che non si legge lo segnala la generazione del suo repository.
function Read-FragmentContents {
    Get-ChildItem -Path $FragmentDirectory -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        try { Get-Content -Raw $_.FullName | ConvertFrom-Json -ErrorAction Stop } catch { $null }
    }
}

# Ogni indirizzo chiamato con gli elementi che vi si avviano.
function Resolve-C4Calls($Contents) {
    $addresses = @($Contents | ForEach-Object { @($_.addresses) } | Where-Object { $_ })
    foreach ($call in @($Contents | ForEach-Object { @($_.calls) } | Where-Object { $_ })) {
        $targets = @($addresses | Where-Object address -EQ $call.address | ForEach-Object element | Sort-Object -Unique)
        [pscustomobject]@{ Call = $call; Targets = $targets }
    }
}

function Get-C4CallRelationships($ResolvedCalls) {
    return @($ResolvedCalls | Where-Object { $_.Targets.Count -eq 1 } | ForEach-Object { New-C4Relationship $_.Call.element $_.Targets[0] } |
            Sort-Object { "$($_.source) -> $($_.target)" } -Unique)
}
