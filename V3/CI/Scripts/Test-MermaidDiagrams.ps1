# Diagrammi Mermaid delle sezioni di un documento: ogni diagramma passa dal parser di Mermaid e
# uno non valido si segnala con la sezione, il file e la riga dell'errore.

. "$PSScriptRoot/VerificationGate.ps1"
. "$PSScriptRoot/MarkdownText.ps1"
. "$PSScriptRoot/Mermaid.ps1"

$docsDirectory = if ($env:DOCS_DIRECTORY) { $env:DOCS_DIRECTORY } else { 'docs/architecture' }

$MermaidScope = 'diagrammi Mermaid'

function Get-Diagrams($Sections) {
    return @(foreach ($section in $Sections) {
            foreach ($diagram in $section.Content.Diagrams) { [pscustomobject]@{ Id = "$($section.File.Name):$($diagram.Line)"; Text = $diagram.Text; Section = $section; Line = $diagram.Line } }
        })
}

function Get-DiagramIssues {
    $diagrams = Get-Diagrams (Get-DocumentSections $docsDirectory)
    $results = @{}
    try { Invoke-MermaidParser $diagrams | ForEach-Object { $results[$_.id] = $_ } }
    catch { return New-Issue $MermaidScope 'verifica non eseguita' $_.Exception.Message }

    foreach ($diagram in $diagrams) {
        $result = $results[$diagram.Id]
        if ($result.error) { New-Issue $diagram.Section.Title 'diagramma non valido' "$($diagram.Section.File.Name):$($diagram.Line + $result.line) $($result.error)" }
    }
}

Invoke-Verification { Get-DiagramIssues } "Diagrammi Mermaid in $docsDirectory validi" 'Verifica dei diagrammi Mermaid disattivata'
