# SPDX-License-Identifier: Apache-2.0

# Le guide di un documento, ordinate per tipo: i tutorial in <guide>/tutorials, le procedure in
# <guide>/procedures e la home della wiki in <guide>/home.md. Le leggono le verifiche, l'aggiornamento e
# la pubblicazione nella wiki; GUIDES_DIRECTORY vuota vuol dire nessuna guida.

$GuideFolders = [ordered]@{ tutorial = 'tutorials'; procedure = 'procedures' }
$GuideHomeFile = 'home.md'

# Una variabile della pipeline non definita arriva come la sua macro, $(nome), non come stringa vuota.
function Get-GuidesDirectory {
    return "$env:GUIDES_DIRECTORY".Trim() -replace '^\$\(.*\)$', ''
}

function Get-GuideFiles([string]$Directory) {
    if (-not $Directory -or -not (Test-Path $Directory -PathType Container)) { return @() }
    $guides = [Collections.Generic.List[object]]::new()
    foreach ($type in $GuideFolders.Keys) {
        $folder = Join-Path $Directory $GuideFolders[$type]
        Get-ChildItem $folder -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $guides.Add([pscustomobject]@{ Type = $type; File = $_ }) }
    }
    $homePage = Join-Path $Directory $GuideHomeFile
    if (Test-Path $homePage -PathType Leaf) { $guides.Add([pscustomobject]@{ Type = 'home'; File = Get-Item $homePage }) }
    return $guides.ToArray()
}
