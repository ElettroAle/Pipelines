# SPDX-License-Identifier: Apache-2.0

# Registra nel documento, in DRAFT_SOURCES_FILE, il ramo, il commit e l'albero git di ogni repository sorgente che
# la run sul ramo di bozza documenta, e il repository, il commit e l'albero git dei passi in DRAFT_TEMPLATES_DIRECTORY
# che la scrivono (DocumentationDraft.ps1): la promozione confronta questi alberi con quelli della run del ramo
# principale. Una run sul ramo principale non scrive nulla.

. "$PSScriptRoot/DocumentationDraft.ps1"

try { $draft = Write-DraftSources (Get-DraftSettings) }
catch {
    Write-Host "##vso[task.logissue type=error]sorgenti della bozza: $($_.Exception.Message)"
    exit 1
}
if ($null -eq $draft) { Write-Host 'Ramo di destinazione principale: nessuna bozza da registrare'; exit 0 }
$draft.sources | ForEach-Object { Write-Host "$($_.repository): $($_.branch) @ $($_.commit), albero $($_.tree)" }
Write-Host "$($draft.templates.repository) (passi della documentazione): $($draft.templates.commit), albero $($draft.templates.tree)"
exit 0
