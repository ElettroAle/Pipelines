# SPDX-License-Identifier: Apache-2.0

# Verifica dei flussi dei diagrammi del documento e delle decisioni (DiagramFlows.ps1).

. "$PSScriptRoot/DiagramFlows.ps1"

Invoke-Verification { Get-FlowFindings | ForEach-Object Text } "Flussi dei diagrammi in $docsDirectory e $decisionsDirectory coerenti con la struttura" 'Verifica dei flussi dei diagrammi disattivata'
