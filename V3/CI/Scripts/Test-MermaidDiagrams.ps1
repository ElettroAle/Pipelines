# SPDX-License-Identifier: Apache-2.0

# Diagrammi Mermaid delle sezioni di un documento e delle sue decisioni: ogni diagramma passa dal
# parser di Mermaid e uno non valido si segnala con la sezione, il file e la riga dell'errore.

. "$PSScriptRoot/Common/Documentation/VerificationGate.ps1"
. "$PSScriptRoot/Common/Documentation/MarkdownText.ps1"
. "$PSScriptRoot/Common/Diagrams/Mermaid.ps1"

$docsDirectory = if ($env:DOCS_DIRECTORY) { $env:DOCS_DIRECTORY } else { 'docs/architecture' }
$decisionsDirectory = if ($env:DECISIONS_DIRECTORY) { $env:DECISIONS_DIRECTORY } else { 'docs/decisions' }

$MermaidScope = 'diagrammi Mermaid'

function Get-Diagrams($Sections) {
    return @(foreach ($section in $Sections) {
            foreach ($diagram in $section.Content.Diagrams) { [pscustomobject]@{ Id = "$($section.File.Name):$($diagram.Line)"; Text = $diagram.Text; Section = $section; Line = $diagram.Line } }
        })
}

function Get-DiagramIssues {
    $diagrams = Get-Diagrams (@(Get-DocumentSections $docsDirectory) + @(Get-DocumentSections $decisionsDirectory))
    $results = @{}
    try { Invoke-MermaidParser $diagrams | ForEach-Object { $results[$_.id] = $_ } }
    catch { return New-Issue $MermaidScope 'verifica non eseguita' $_.Exception.Message }

    foreach ($diagram in $diagrams) {
        $result = $results[$diagram.Id]
        if ($result.error) { New-Issue $diagram.Section.Title 'diagramma non valido' "$($diagram.Section.File.Name):$($diagram.Line + $result.line) $($result.error)" }
    }
}

Invoke-Verification { Get-DiagramIssues } "Diagrammi Mermaid in $docsDirectory e $decisionsDirectory validi" 'Verifica dei diagrammi Mermaid disattivata'
