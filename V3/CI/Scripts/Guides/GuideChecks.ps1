# SPDX-License-Identifier: Apache-2.0

# Ogni guida fa una cosa sola, secondo il suo tipo (Test-Guides.ps1): un tutorial porta a un risultato con
# passi numerati e chiude con la sezione del risultato; una procedura apre con compito, prerequisiti e
# risultato atteso; una frase di procedura che introduce un perche' rimanda con un link al documento che lo
# spiega. Nomi delle parti e segnali della spiegazione vengono dalla lingua del documento.

. "$PSScriptRoot/../Common/MarkdownText.ps1"
. "$PSScriptRoot/../Common/Guides.ps1"

$GuideLanguage = $DocumentLanguage.Guides
$OrderedStepPattern = '^\s*\d+\.\s+\S'
$MarkdownLinkPattern = '(?<!!)\[[^\]]*\]\([^)\s]+\)'

function Get-GuideParts([string]$Content) {
    $parts = [Collections.Generic.List[object]]::new()
    $fence = $false
    foreach ($line in ($Content -split "`r?`n")) {
        if ($line -match $FencePattern) { $fence = -not $fence }
        elseif (-not $fence -and $line -match '^##\s+(.+?)\s*#*\s*$') {
            $parts.Add([pscustomobject]@{ Name = ConvertTo-PlainText $Matches[1]; Lines = [Collections.Generic.List[string]]::new() })
            continue
        }
        if ($parts.Count) { $parts[$parts.Count - 1].Lines.Add($line) }
    }
    return $parts.ToArray()
}

function Test-PartFilled($Part) {
    return [bool]@($Part.Lines | Where-Object { $_.Trim() }).Count
}

# Le righe di testo fuori dai blocchi di codice e dai titoli.
function Get-ProseLines([string]$Content) {
    $fence = $false
    foreach ($line in ($Content -split "`r?`n")) {
        if ($line -match $FencePattern) { $fence = -not $fence; continue }
        if ($fence -or -not $line.Trim() -or $line -match '^#{1,6}\s') { continue }
        $line
    }
}

function Test-TutorialResult([string]$Content) {
    $steps = @(Get-ProseLines $Content | Where-Object { $_ -match $OrderedStepPattern })
    $last = @(Get-GuideParts $Content) | Select-Object -Last 1
    return $steps.Count -gt 0 -and $last -and $last.Name -eq $GuideLanguage.TutorialResult -and (Test-PartFilled $last)
}

function Test-ProcedureOpening([string]$Content) {
    $parts = @(Get-GuideParts $Content)
    $opening = @($GuideLanguage.ProcedureOpening)
    if ($parts.Count -lt $opening.Count) { return $false }
    for ($i = 0; $i -lt $opening.Count; $i++) {
        if ($parts[$i].Name -ne $opening[$i] -or -not (Test-PartFilled $parts[$i])) { return $false }
    }
    return $true
}

function Get-MisplacedExplanations([string]$Content) {
    $markers = @($GuideLanguage.ExplanationMarkers | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $pattern = "(?i)(?<![\p{L}\p{N}])(?:$markers)(?![\p{L}\p{N}])"
    foreach ($line in (Get-ProseLines $Content)) {
        foreach ($sentence in ($line.Trim() -split '(?<=[.!?])\s+')) {
            if ($sentence -match $pattern -and $sentence -notmatch $MarkdownLinkPattern) { $sentence }
        }
    }
}

function Get-Excerpt([string]$Sentence) {
    $plain = ConvertTo-PlainText ($Sentence -replace $ListItemPattern, '$1')
    return ((($plain -split '\s+') | Select-Object -First 8) -join ' ') + '…'
}

function Get-GuideIssues([string]$Directory) {
    foreach ($guide in (Get-GuideFiles $Directory)) {
        $name = [IO.Path]::GetRelativePath((Get-Location).Path, $guide.File.FullName) -replace '\\', '/'
        $content = [IO.File]::ReadAllText($guide.File.FullName)
        if ($guide.Type -eq 'tutorial' -and -not (Test-TutorialResult $content)) {
            New-Issue $name $GuideLanguage.MissingResult "passi numerati e sezione finale «$($GuideLanguage.TutorialResult)» non vuota"
        }
        if ($guide.Type -ne 'procedure') { continue }
        if (-not (Test-ProcedureOpening $content)) {
            New-Issue $name $GuideLanguage.ProcedureOpeningIssue "prime sezioni «$($GuideLanguage.ProcedureOpening -join '», «')», non vuote"
        }
        Get-MisplacedExplanations $content | ForEach-Object { New-Issue $name $GuideLanguage.ExplanationIssue "«$(Get-Excerpt $_)» senza rimando al documento che spiega il perché" }
    }
}
