# SPDX-License-Identifier: Apache-2.0

# Verifica delle fonti di una PR (PullRequestSources.ps1), bloccante in modalita' enforce. La verifica si
# ripete rilanciando la build: legge la board ogni volta, quindi un work item completato la fa passare.

. "$PSScriptRoot/../Common/VerificationGate.ps1"
. "$PSScriptRoot/PullRequestSources.ps1"

Invoke-Verification {
    try { Get-SourceIssues (Get-SourcesSettings) }
    catch { "fonti della PR $($env:PULL_REQUEST_ID): $($_.Exception.Message)" }
} 'Fonti della PR complete: Task con la decisione tecnica, padre con criteri di accettazione o passi di riproduzione' 'Verifica delle fonti della PR disattivata (mode: off)'
