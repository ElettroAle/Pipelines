# SPDX-License-Identifier: Apache-2.0

# Verifica del tipo delle guide di GUIDES_DIRECTORY (GuideChecks.ps1), bloccante in modalita' enforce.

. "$PSScriptRoot/../Common/VerificationGate.ps1"
. "$PSScriptRoot/GuideChecks.ps1"

$guidesDirectory = Get-GuidesDirectory
Invoke-Verification { Get-GuideIssues $guidesDirectory } "Guide in $guidesDirectory conformi al loro tipo" 'Verifica delle guide disattivata'
