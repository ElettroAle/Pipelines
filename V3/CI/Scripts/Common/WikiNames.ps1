# SPDX-License-Identifier: Apache-2.0

# Nome di file di una pagina della wiki git di Azure DevOps a partire dal suo titolo.

# Il nome di file di una pagina scrive gli spazi come trattini, quindi codifica il trattino stesso
# e i caratteri che un nome di file non ammette; il simbolo di percentuale va per primo.
$EncodedCharacters = @('%', '-', ':', '<', '>', '*', '?', '|', '#', '"', '\', '/')

function ConvertTo-WikiName([string]$Title) {
    $name = $Title
    foreach ($character in $EncodedCharacters) { $name = $name.Replace($character, ('%{0:X2}' -f [int][char]$character)) }
    return $name.Replace(' ', '-')
}