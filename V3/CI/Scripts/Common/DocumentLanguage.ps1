# SPDX-License-Identifier: Apache-2.0

# Le convenzioni di un documento che dipendono dalla sua lingua (marcatore di vista, tag dei
# container, sezioni degli ADR, etichette della wiki) stanno in Languages/<lingua>.psd1. Senza
# DOCUMENT_LANGUAGE vale l'italiano, la lingua dei consumer nati prima del parametro.

function Get-DocumentLanguage([string]$Code) {
    $language = if ($Code.Trim()) { $Code.Trim().ToUpperInvariant() } else { 'IT' }
    $path = Join-Path $PSScriptRoot "Languages/$language.psd1"
    if (-not (Test-Path $path -PathType Leaf)) {
        $available = (Get-ChildItem (Join-Path $PSScriptRoot 'Languages') -Filter '*.psd1' | ForEach-Object BaseName) -join ', '
        throw "lingua del documento non supportata: $language (disponibili: $available; una lingua nuova e' il file Languages/$language.psd1)"
    }
    return Import-PowerShellDataFile $path
}

# Un testo composto dalle frasi della lingua: ogni frase ha un segnaposto per elenco, e chi compone da' i nomi
# di ogni elenco con la funzione Names. Una frase con un elenco vuoto non si scrive.
function Format-LanguagePhrases($Phrases, [scriptblock]$Names) {
    $sentences = foreach ($phrase in @($Phrases)) {
        $lists = @(@($phrase.Lists) | ForEach-Object { Join-LanguageList @(& $Names $_) })
        if ($lists -contains '') { continue }
        $phrase.Text -f $lists
    }
    return @($sentences) -join ' '
}

# Un elenco si chiude con la congiunzione della lingua prima dell'ultimo elemento.
function Join-LanguageList([string[]]$Items) {
    $named = @($Items | Where-Object { $_ })
    if ($named.Count -lt 2) { return "$($named)" }
    return "$(@($named | Select-Object -SkipLast 1) -join ', ') $($DocumentLanguage.ListConjunction) $($named[-1])"
}

$DocumentLanguage = Get-DocumentLanguage "$env:DOCUMENT_LANGUAGE"
