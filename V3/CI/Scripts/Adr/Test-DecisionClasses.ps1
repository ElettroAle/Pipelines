# SPDX-License-Identifier: Apache-2.0

# Verifica delle classi governate dalle decisioni (DecisionClasses.ps1).

. "$PSScriptRoot/DecisionClasses.ps1"

Invoke-Verification { Get-DecisionClassesIssues } "Diagrammi delle classi delle decisioni in $decisionsDirectory coerenti con il codice in $SourceDirectory" 'Verifica delle classi delle decisioni disattivata'
