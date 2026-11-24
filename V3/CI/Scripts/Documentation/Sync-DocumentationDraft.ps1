# SPDX-License-Identifier: Apache-2.0

# Dopo un aggiornamento del ramo principale del documento, il ramo di bozza lo riceve con una PR in auto-complete
# (DocumentationDraft.ps1), cosi' la bozza riparte dal documento ufficiale.

. "$PSScriptRoot/DocumentationDraft.ps1"

try { Write-Host (Invoke-DraftSync (Get-DraftSettings)) }
catch {
    Write-Host "##vso[task.logissue type=error]allineamento della bozza: $($_.Exception.Message)"
    exit 1
}
exit 0
