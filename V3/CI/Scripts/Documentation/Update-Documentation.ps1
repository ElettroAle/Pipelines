# SPDX-License-Identifier: Apache-2.0

# Aggiorna la documentazione con il cambiamento arrivato nel ramo principale (DocumentationUpdate.ps1).
# Un aggiornamento respinto a ogni stesura o un modello non disponibile chiudono il passo con un avviso: il
# primo ha aperto un work item, il secondo si recupera alla run successiva. Fallisce solo una configurazione
# sbagliata o un errore del repository.

. "$PSScriptRoot/DocumentationUpdate.ps1"

try { $outcome = Invoke-DocumentationUpdate (Get-UpdateSettings) }
catch {
    Write-Host "##vso[task.logissue type=error]aggiornamento della documentazione: $($_.Exception.Message)"
    exit 1
}

# La PR parte solo se il passo ha scritto qualcosa: con il ramo di un aggiornamento ancora aperto, una
# copia del ramo principale lo riporterebbe indietro.
Write-Host "##vso[task.setvariable variable=documentationUpdateChanged]$($outcome.Publish)"
Write-Host "##vso[task.setvariable variable=documentationUpdatePaths]$($outcome.Paths -join ';')"
if ($outcome.Status -in 'unavailable', 'rejected') {
    Write-Host "##vso[task.logissue type=warning]$($outcome.Message)"
    Write-Host '##vso[task.complete result=SucceededWithIssues;]'
    exit 0
}
Write-Host "##[section]$($outcome.Message)"
exit 0
