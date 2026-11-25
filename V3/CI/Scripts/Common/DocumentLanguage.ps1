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
        $lists = @(@($phrase.Lists) | ForEach-Object { @(& $Names $_) -join ', ' })
        if ($lists -contains '') { continue }
        $phrase.Text -f $lists
    }
    return @($sentences) -join ' '
}

$DocumentLanguage = Get-DocumentLanguage "$env:DOCUMENT_LANGUAGE"
