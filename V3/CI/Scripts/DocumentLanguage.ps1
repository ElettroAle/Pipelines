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

$DocumentLanguage = Get-DocumentLanguage "$env:DOCUMENT_LANGUAGE"
