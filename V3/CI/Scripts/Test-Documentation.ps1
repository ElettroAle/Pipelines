# SPDX-License-Identifier: Apache-2.0

# Controlli oggettivi che valgono per ogni documento, qualunque sia il suo formato: rimandi a
# file, ancore e decisioni esistenti e soglie numeriche di leggibilita'. La struttura la
# verifica il modulo del formato, lo stile lo giudica Test-DocumentationStyle.ps1.

. "$PSScriptRoot/VerificationGate.ps1"
. "$PSScriptRoot/MarkdownText.ps1"

$docsDirectory = if ($env:DOCS_DIRECTORY) { $env:DOCS_DIRECTORY } else { 'docs/architecture' }
$decisionsDirectory = if ($env:DECISIONS_DIRECTORY) { $env:DECISIONS_DIRECTORY } else { 'docs/decisions' }
$minimumGulpease = [int]$env:READABILITY_GULPEASE
$maximumWords = [int]$env:READABILITY_MAX_WORDS
$abbreviations = @("$env:READABILITY_ABBREVIATIONS" -split ';' | ForEach-Object Trim | Where-Object { $_ })

$ProseKinds = @('opening', 'quote', 'paragraph', 'list')
$LinkPattern = '(?<!!)\[[^\]]*\]\(([^)\s]+)\)'
$DecisionIdPattern = '(?<![\p{L}\p{N}/-])(\d{4}-[a-z][a-z0-9-]*[a-z0-9])'

function Test-Readability($Section) {
    $prose = @($Section.Content.Blocks | Where-Object Kind -In $ProseKinds | ForEach-Object Text)
    if (-not $prose) { return }

    $index = Get-GulpeaseIndex $prose $abbreviations
    if ($minimumGulpease -and $null -ne $index -and $index -lt $minimumGulpease) { New-Issue $Section.Title 'leggibilità' "Gulpease $index, minimo $minimumGulpease" }

    if (-not $maximumWords) { return }
    $prose | ForEach-Object { Get-Sentences $_ $abbreviations } | ForEach-Object {
        $words = Get-WordCount $_
        if ($words -gt $maximumWords) {
            $start = (($_ -split '\s+') | Select-Object -First 8) -join ' '
            New-Issue $Section.Title 'frase troppo lunga' "$words parole, massimo ${maximumWords}: «$start…»"
        }
    }
}

function Test-LinkTarget($Section, [string]$Target) {
    $path, $anchor = $Target -split '#', 2
    $targetFile = if ($path) { Join-Path $Section.File.DirectoryName ([uri]::UnescapeDataString($path)) } else { $Section.File.FullName }
    if (-not (Test-Path $targetFile -PathType Leaf)) { return $false }
    if (-not $anchor) { return $true }
    $anchors = (ConvertFrom-MarkdownSection ([IO.File]::ReadAllText($targetFile))).Anchors
    return $anchors -contains [uri]::UnescapeDataString($anchor).ToLowerInvariant()
}

function Test-References($Section) {
    foreach ($block in $Section.Content.Blocks) {
        [regex]::Matches($block.Raw, $LinkPattern) | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch '^[a-z][a-z0-9+.-]*:' } |
            Where-Object { -not (Test-LinkTarget $Section $_) } | ForEach-Object { New-Issue $Section.Title 'rimando inesistente' $_ }
        [regex]::Matches($block.Text, $DecisionIdPattern) | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique |
            Where-Object { -not (Test-Path (Join-Path $decisionsDirectory "$_.md")) } | ForEach-Object { New-Issue $Section.Title 'rimando inesistente' $_ }
    }
}

function Get-DocumentationIssues {
    $sections = Get-DocumentSections $docsDirectory
    $sections | ForEach-Object { Test-References $_ }
    $sections | ForEach-Object { Test-Readability $_ }
}

Invoke-Verification { Get-DocumentationIssues } "Documento in $docsDirectory valido" 'Verifica del documento disattivata'
