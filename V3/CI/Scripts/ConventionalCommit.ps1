# Riconoscimento dei titoli Conventional Commits, condiviso da Verify-SemVer.ps1 e
# Set-Versioning.ps1: la validazione del titolo e il calcolo dell'incremento non
# possono divergere. Il match di -match e' case-insensitive: 'FEAT:' e' valido.
# 'Merged PR <id>: ' e' il messaggio di default di Azure DevOps al completamento di
# una PR, anche in squash: il titolo convenzionale segue il prefisso.

$ConventionalCommitPattern = '^(?:Merged PR \d+: )?(?:(?<type>feat|fix)(?:\([^()\r\n]+\))?(?<breaking>!)?|(?<breakingChange>BREAKING CHANGE)):'

function Get-ConventionalCommitIncrement {
    param([string]$Subject)

    if ($Subject -notmatch $ConventionalCommitPattern) { return $null }
    if ($Matches['breaking'] -or $Matches['breakingChange']) { return 'major' }
    if ($Matches['type'] -eq 'feat') { return 'minor' }
    return 'patch'
}

# La release contiene tutti i commit dall'ultimo tag: conta il piu' alto, non il piu'
# recente. Senza commit convenzionali resta patch.
function Get-HighestConventionalIncrement {
    param([string[]]$Subjects)

    $rank = @{ patch = 1; minor = 2; major = 3 }
    $highest = 'patch'
    foreach ($subject in $Subjects) {
        $increment = Get-ConventionalCommitIncrement $subject.Trim()
        if ($increment -and $rank[$increment] -gt $rank[$highest]) { $highest = $increment }
    }
    return $highest
}
