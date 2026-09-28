# Riconoscimento dei titoli Conventional Commits, condiviso da Verify-SemVer.ps1 e
# Set-Versioning.ps1: la validazione del titolo e il calcolo dell'incremento non
# possono divergere. Il match di -match e' case-insensitive: 'FEAT:' e' valido.

$ConventionalCommitPattern = '^(?:(?<type>feat|fix)(?:\([^()\r\n]+\))?(?<breaking>!)?|(?<breakingChange>BREAKING CHANGE)):'

function Get-ConventionalCommitIncrement {
    param([string]$Subject)

    if ($Subject -notmatch $ConventionalCommitPattern) { return $null }
    if ($Matches['breaking'] -or $Matches['breakingChange']) { return 'major' }
    if ($Matches['type'] -eq 'feat') { return 'minor' }
    return 'patch'
}
