# SPDX-License-Identifier: Apache-2.0

# All'inizio della documentazione del ramo principale, la bozza diventa il documento ufficiale se i repository
# sorgente vi arrivano con gli alberi che la bozza documenta e i passi sono quelli che l'hanno scritta
# (DocumentationDraft.ps1): la PR dal ramo di bozza e' in auto-complete e la variabile documentationPromoted ferma
# la nuova stesura nei passi successivi della run.

. "$PSScriptRoot/DocumentationDraft.ps1"

try { $outcome = Invoke-DocumentationPromotion (Get-DraftSettings) }
catch {
    Write-Host "##vso[task.logissue type=error]promozione della bozza: $($_.Exception.Message)"
    exit 1
}
if ($outcome.Promoted) { Write-Host '##vso[task.setvariable variable=documentationPromoted]True' }
Write-Host $outcome.Message
exit 0
