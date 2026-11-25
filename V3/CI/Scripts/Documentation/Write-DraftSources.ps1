# SPDX-License-Identifier: Apache-2.0

# Registra nel documento, in DRAFT_SOURCES_FILE, il ramo, il commit e l'albero git di ogni repository sorgente che
# la run sul ramo di bozza documenta (DocumentationDraft.ps1): la promozione confronta questi alberi con quelli
# del ramo principale. Una run sul ramo principale non scrive nulla.

. "$PSScriptRoot/DocumentationDraft.ps1"

try { $sources = Write-DraftSources (Get-DraftSettings) }
catch {
    Write-Host "##vso[task.logissue type=error]sorgenti della bozza: $($_.Exception.Message)"
    exit 1
}
if ($null -eq $sources) { Write-Host 'Ramo di destinazione principale: nessuna bozza da registrare'; exit 0 }
$sources | ForEach-Object { Write-Host "$($_.repository): $($_.branch) @ $($_.commit), albero $($_.tree)" }
exit 0
