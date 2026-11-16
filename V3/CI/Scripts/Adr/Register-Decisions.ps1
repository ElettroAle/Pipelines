# SPDX-License-Identifier: Apache-2.0

# Registra nel corpus le decisioni dei Task arrivati nel ramo principale dei repository sorgente
# (DecisionRegistration.ps1). Una decisione che non puo' entrare chiude il passo con un avviso, perche'
# il suo work item e' gia' aperto; fallisce solo una configurazione sbagliata o un errore del repository o
# dell'API, e la run successiva riprende dallo stesso punto di partenza.

. "$PSScriptRoot/DecisionRegistration.ps1"

try { $outcome = Invoke-DecisionRegistration (Get-RegistrationSettings) }
catch {
    Write-Host "##vso[task.logissue type=error]registrazione delle decisioni: $($_.Exception.Message)"
    exit 1
}

# Senza decisioni ne' work item il punto di partenza resta dov'e': una PR per ogni integrazione senza
# Task costerebbe una Quality Gate senza portare nulla.
Write-Host "##vso[task.setvariable variable=decisionRegistrationChanged]$($outcome.Publish)"
$outcome.Lines | ForEach-Object { Write-Host $_ }
if ($outcome.Status -eq 'rejected') {
    Write-Host "##vso[task.logissue type=warning]Decisioni non registrate, work item $($outcome.WorkItems -join ', ')"
    Write-Host '##vso[task.complete result=SucceededWithIssues;]'
}
exit 0
