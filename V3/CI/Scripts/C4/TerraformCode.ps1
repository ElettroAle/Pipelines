# SPDX-License-Identifier: Apache-2.0

# Lettura del codice Terraform per nome: i blocchi di un file .tf e i riferimenti delle loro
# espressioni, seguiti attraverso locals, variabili dei moduli, output e remote state fino alle
# risorse, senza valutare le espressioni. Un riferimento che non si sa seguire ferma la lettura.

$IgnoredRoots = @('each', 'count', 'path', 'self', 'terraform', 'null', 'true', 'false')

class TerraformText {
    [string]$Text
    [int]$Position
    [string]$File

    TerraformText([string]$Text, [string]$File) { $this.Text = $Text; $this.Position = 0; $this.File = $File }

    [bool] AtEnd() { return $this.Position -ge $this.Text.Length }
    [char] Current() { return $this.Text[$this.Position] }
    [char] Next() { if ($this.Position + 1 -lt $this.Text.Length) { return $this.Text[$this.Position + 1] } return [char]0 }
    [int] Line() { return ($this.Text.Substring(0, [math]::Min($this.Position, $this.Text.Length)) -split "`n").Count }
}

function Skip-Comment([TerraformText]$Source) {
    $character = $Source.Current()
    if ($character -eq '#' -or ($character -eq '/' -and $Source.Next() -eq '/')) {
        while (-not $Source.AtEnd() -and $Source.Current() -ne "`n") { $Source.Position++ }
        return $true
    }
    if ($character -eq '/' -and $Source.Next() -eq '*') {
        $end = $Source.Text.IndexOf('*/', $Source.Position + 2)
        $Source.Position = if ($end -lt 0) { $Source.Text.Length } else { $end + 2 }
        return $true
    }
    return $false
}

function Skip-Blank([TerraformText]$Source, [bool]$Newlines) {
    while (-not $Source.AtEnd()) {
        $character = $Source.Current()
        if ($character -eq ' ' -or $character -eq "`t" -or $character -eq "`r" -or ($Newlines -and $character -eq "`n")) { $Source.Position++ }
        elseif (-not (Skip-Comment $Source)) { return }
    }
}

# Una stringa fra virgolette, con le interpolazioni ${...} e %{...} che possono contenere altre stringhe.
function Skip-QuotedString([TerraformText]$Source) {
    $Source.Position++
    while (-not $Source.AtEnd()) {
        $character = $Source.Current()
        if ($character -eq '\') { $Source.Position += 2; continue }
        if ($character -eq '"') { $Source.Position++; return }
        if (($character -eq '$' -or $character -eq '%') -and $Source.Next() -eq '{') {
            $Source.Position += 2
            Skip-Nested $Source '}'
            continue
        }
        $Source.Position++
    }
}

function Skip-Heredoc([TerraformText]$Source) {
    $match = [regex]::new('<<-?([A-Za-z_]\w*)\r?\n').Match($Source.Text, $Source.Position)
    if (-not $match.Success -or $match.Index -ne $Source.Position) { $Source.Position += 2; return }
    $closing = [regex]::new("(?m)^[ \t]*$([regex]::Escape($match.Groups[1].Value))[ \t]*\r?$").Match($Source.Text, $match.Index + $match.Length)
    $Source.Position = if ($closing.Success) { $closing.Index + $closing.Length } else { $Source.Text.Length }
}

function Skip-Nested([TerraformText]$Source, [char]$Closing) {
    while (-not $Source.AtEnd()) {
        if (Skip-Comment $Source) { continue }
        $character = $Source.Current()
        if ($character -eq $Closing) { $Source.Position++; return }
        switch ($character) {
            '"' { Skip-QuotedString $Source; continue }
            '{' { $Source.Position++; Skip-Nested $Source '}'; continue }
            '[' { $Source.Position++; Skip-Nested $Source ']'; continue }
            '(' { $Source.Position++; Skip-Nested $Source ')'; continue }
            '<' { if ($Source.Next() -eq '<') { Skip-Heredoc $Source } else { $Source.Position++ }; continue }
            default { $Source.Position++ }
        }
    }
}

# Un'espressione finisce a fine riga fuori dalle parentesi.
function Read-Expression([TerraformText]$Source) {
    $start = $Source.Position
    while (-not $Source.AtEnd()) {
        $character = $Source.Current()
        if ($character -eq "`n" -or $character -eq '}') { break }
        if (($character -eq '#') -or ($character -eq '/' -and ($Source.Next() -eq '/' -or $Source.Next() -eq '*'))) { break }
        switch ($character) {
            '"' { Skip-QuotedString $Source; continue }
            '{' { $Source.Position++; Skip-Nested $Source '}'; continue }
            '[' { $Source.Position++; Skip-Nested $Source ']'; continue }
            '(' { $Source.Position++; Skip-Nested $Source ')'; continue }
            '<' { if ($Source.Next() -eq '<') { Skip-Heredoc $Source } else { $Source.Position++ }; continue }
            default { $Source.Position++ }
        }
    }
    return $Source.Text.Substring($start, $Source.Position - $start).Trim()
}

function Read-HeaderToken([TerraformText]$Source) {
    if ($Source.Current() -eq '"') {
        $start = $Source.Position
        Skip-QuotedString $Source
        return $Source.Text.Substring($start + 1, $Source.Position - $start - 2)
    }
    $match = [regex]::new('[A-Za-z_][\w-]*').Match($Source.Text, $Source.Position)
    if (-not $match.Success -or $match.Index -ne $Source.Position) { throw "$($Source.File):$($Source.Line()): sintassi Terraform non riconosciuta" }
    $Source.Position += $match.Length
    return $match.Value
}

function New-TerraformBlock([string]$Type, [string[]]$Labels, [string]$File, [int]$Line) {
    return [pscustomobject]@{ Type = $Type; Labels = $Labels; Attributes = [ordered]@{}; Blocks = [System.Collections.Generic.List[object]]::new(); File = $File; Line = $Line }
}

function Read-Body([TerraformText]$Source, $Block) {
    while ($true) {
        Skip-Blank $Source $true
        if ($Source.AtEnd()) { return }
        if ($Source.Current() -eq '}') { $Source.Position++; return }
        $line = $Source.Line()
        $tokens = @()
        while ($true) {
            $tokens += Read-HeaderToken $Source
            Skip-Blank $Source $false
            $character = $Source.Current()
            if ($character -eq '=' -and $tokens.Count -eq 1) {
                $Source.Position++
                Skip-Blank $Source $false
                $Block.Attributes[$tokens[0]] = [pscustomobject]@{ Text = (Read-Expression $Source); File = $Source.File; Line = $line }
                break
            }
            if ($character -eq '{') {
                $Source.Position++
                $child = New-TerraformBlock $tokens[0] @($tokens | Select-Object -Skip 1) $Source.File $line
                Read-Body $Source $child
                $Block.Blocks.Add($child)
                break
            }
        }
    }
}

function Read-TerraformFile([string]$Path, [string]$DisplayPath) {
    $source = [TerraformText]::new([IO.File]::ReadAllText($Path), $DisplayPath)
    $root = New-TerraformBlock 'file' @() $DisplayPath 1
    Read-Body $source $root
    return $root
}

# Il codice di un'espressione senza il testo letterale delle stringhe: restano solo le interpolazioni.
function Get-ExpressionCode([string]$Text) {
    $code = [Text.StringBuilder]::new()
    $depth = [System.Collections.Generic.Stack[string]]::new()
    $inString = $false
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        $next = if ($index + 1 -lt $Text.Length) { $Text[$index + 1] } else { [char]0 }
        if ($inString) {
            if ($character -eq '\') { $index++; [void]$code.Append('  '); continue }
            if ($character -eq '"') { $inString = $false; [void]$code.Append(' '); continue }
            if (($character -eq '$' -or $character -eq '%') -and $next -eq '{') { $depth.Push('string'); $inString = $false; $index++; [void]$code.Append('  '); continue }
            [void]$code.Append(' ')
            continue
        }
        if ($character -eq '"') { $inString = $true; [void]$code.Append(' '); continue }
        if ($character -eq '{') { $depth.Push('code') }
        if ($character -eq '}' -and $depth.Count) {
            if ($depth.Pop() -eq 'string') { $inString = $true; [void]$code.Append(' '); continue }
        }
        [void]$code.Append($character)
    }
    return $code.ToString()
}

function Get-ExpressionReferences([string]$Text) {
    $code = Get-ExpressionCode $Text
    $iterators = @([regex]::Matches($code, '\bfor\s+(\w+)(?:\s*,\s*(\w+))?\s+in\b') | ForEach-Object { $_.Groups[1].Value; $_.Groups[2].Value } | Where-Object { $_ })
    foreach ($match in [regex]::Matches($code, '(?<![\w.)\]])([A-Za-z_][\w-]*)((?:\s*(?:\.[A-Za-z_][\w-]*|\.\d+|\[[^\]]*\]))+)')) {
        $root = $match.Groups[1].Value
        if ($IgnoredRoots -contains $root -or $iterators -contains $root) { continue }
        [regex]::Matches($match.Groups[2].Value, '\[([^\]]*)\]') | ForEach-Object { Get-ExpressionReferences $_.Groups[1].Value }
        $traversal = $match.Groups[2].Value -replace '\[[^\]]*\]', ''
        $segments = @($root) + @([regex]::Matches($traversal, '\.([A-Za-z_][\w-]*)') | ForEach-Object { $_.Groups[1].Value })
        $segments -join '.'
    }
}

# Il codice di un repository Terraform: una directory per modulo, con i blocchi dei suoi file.
function Read-TerraformRepository([string]$Root) {
    $directories = @{}
    foreach ($file in (Get-ChildItem -Path $Root -Recurse -File -Filter '*.tf' | Where-Object { $_.FullName -notmatch '[\\/](\.terraform|\.git)[\\/]' } | Sort-Object FullName)) {
        $relative = [IO.Path]::GetRelativePath($Root, $file.FullName) -replace '\\', '/'
        $directory = [IO.Path]::GetDirectoryName($relative) -replace '\\', '/'
        if (-not $directories.ContainsKey($directory)) { $directories[$directory] = [System.Collections.Generic.List[object]]::new() }
        foreach ($block in (Read-TerraformFile $file.FullName $relative).Blocks) { $directories[$directory].Add($block) }
    }
    return [pscustomobject]@{ Root = $Root; Directories = $directories }
}

function Get-TerraformBlocks($Code, [string]$Directory, [string]$Type) {
    return @($Code.Directories[$Directory] | Where-Object Type -EQ $Type)
}

function Find-TerraformBlock($Code, [string]$Directory, [string]$Type, [string[]]$Labels) {
    return Get-TerraformBlocks $Code $Directory $Type | Where-Object { (@($_.Labels) -join '|') -eq ($Labels -join '|') } | Select-Object -First 1
}

function Find-LocalValue($Code, [string]$Directory, [string]$Name) {
    return Get-TerraformBlocks $Code $Directory 'locals' | ForEach-Object { $_.Attributes[$Name] } | Where-Object { $_ } | Select-Object -First 1
}

function Get-StringLiteral($Expression) {
    if ($Expression -and $Expression.Text -match '^"([^"$%]*)"$') { return $Matches[1] }
}

# Il valore di una variabile di un modulo radice nell'ambiente letto: values.tfvars, altrimenti il default.
function Get-RootVariableValue($Code, [string]$Root, [string]$Name, [string]$Environment) {
    $values = Join-Path $Code.Root "$Root/environments/$Environment/values.tfvars"
    if (Test-Path $values) {
        $value = (Read-TerraformFile $values "$Root/environments/$Environment/values.tfvars").Attributes[$Name]
        if ($value) { return Get-StringLiteral $value }
    }
    $variable = Find-TerraformBlock $Code $Root 'variable' @($Name)
    if ($variable -and $variable.Attributes['default']) { return Get-StringLiteral $variable.Attributes['default'] }
}

function Resolve-StringTemplate($Code, [string]$Root, $Expression, [string]$Environment) {
    if (-not $Expression) { return }
    $text = $Expression.Text
    if ($text -match '^var\.([\w-]+)$') { return Get-RootVariableValue $Code $Root $Matches[1] $Environment }
    if ($text -notmatch '^"(.*)"$') { return }
    $resolved = [regex]::Replace($Matches[1], '\$\{\s*var\.([\w-]+)\s*\}', { param($match) Get-RootVariableValue $Code $Root $match.Groups[1].Value $Environment })
    if ($resolved -notmatch '[$%]\{') { return $resolved }
}

function Find-WorkspaceRoot($Code, [string]$Workspace, [string]$Environment) {
    foreach ($directory in $Code.Directories.Keys) {
        if ($directory -notmatch "^([^/]+)/environments/$([regex]::Escape($Environment))$") { continue }
        $root = $Matches[1]
        $names = Get-TerraformBlocks $Code $directory 'terraform' | ForEach-Object Blocks | Where-Object Type -EQ 'cloud' |
            ForEach-Object Blocks | Where-Object Type -EQ 'workspaces' | ForEach-Object { Get-StringLiteral $_.Attributes['name'] }
        if (@($names) -contains $Workspace) { return $root }
    }
}

function Get-RemoteStateWorkspace($Block) {
    $config = $Block.Attributes['config']
    if ($config -and $config.Text -match '(?s)workspaces\s*=\s*\{\s*name\s*=\s*("[^"]*"|[\w.-]+)') {
        return [pscustomobject]@{ Text = $Matches[1].Trim(); File = $config.File; Line = $config.Line }
    }
}

function New-TerraformFrame([string]$Directory, [string]$Root, [string]$Path, $Call, $Parent) {
    return [pscustomobject]@{ Directory = $Directory; Root = $Root; Path = $Path; Call = $Call; Parent = $Parent }
}

# Il codice di un modulo radice gira dalla directory dell'ambiente, dove i suoi file sono hard link:
# i source relativi partono da li'.
function Get-ModuleDirectory($Code, [string]$Directory, $Call, [string]$Environment) {
    $source = Get-StringLiteral $Call.Attributes['source']
    if (-not $source -or $source -notmatch '^\.\.?/') { return }
    $base = Join-Path $Code.Root $Directory
    if (Test-Path (Join-Path $base "environments/$Environment")) { $base = Join-Path $base "environments/$Environment" }
    $resolved = [IO.Path]::GetFullPath((Join-Path $base $source))
    $relative = [IO.Path]::GetRelativePath($Code.Root, $resolved) -replace '\\', '/'
    if ($Code.Directories.ContainsKey($relative)) { return $relative }
}

function New-UnfollowableReference($Expression, [string]$Reference) {
    return [pscustomobject]@{ Kind = 'unfollowable'; Location = "$($Expression.File):$($Expression.Line)"; Reference = $Reference }
}

function New-ResourceNode($Frame, [string]$Type, [string]$Name) {
    return [pscustomobject]@{ Kind = 'resource'; Key = "$($Frame.Root)$($Frame.Path)/$Type.$Name"; Frame = $Frame; Type = $Type; Name = $Name }
}

function New-PendingExpression($Frame, $Expression) {
    return [pscustomobject]@{ Kind = 'expression'; Frame = $Frame; Expression = $Expression }
}

# Le risorse a cui arrivano i riferimenti di un'espressione, e i riferimenti che non si sanno seguire.
function Get-ReferencedResources($Code, $Frame, $Expression, [string]$Environment) {
    $visited = [System.Collections.Generic.HashSet[string]]::new()
    $pending = [System.Collections.Generic.Queue[object]]::new()
    $pending.Enqueue((New-PendingExpression $Frame $Expression))
    while ($pending.Count) {
        $item = $pending.Dequeue()
        if (-not $item.Expression -or -not $visited.Add("$($item.Frame.Root)$($item.Frame.Path)|$($item.Expression.File):$($item.Expression.Line)|$($item.Expression.Text)")) { continue }
        foreach ($reference in @(Get-ExpressionReferences $item.Expression.Text)) {
            foreach ($next in @(Resolve-Reference $Code $item.Frame $item.Expression ($reference -split '\.') $Environment)) {
                if ($next.Kind -eq 'expression') { $pending.Enqueue($next) } else { $next }
            }
        }
    }
}

function Resolve-LocalReference($Code, $Frame, $Expression, [string[]]$Reference) {
    $value = Find-LocalValue $Code $Frame.Directory $Reference[1]
    if (-not $value) { return New-UnfollowableReference $Expression ($Reference -join '.') }
    return New-PendingExpression $Frame $value
}

# Una variabile di un modulo figlio prende l'argomento della chiamata; quella di un modulo radice
# viene dai values.tfvars e non porta riferimenti.
function Resolve-VariableReference($Code, $Frame, $Expression, [string[]]$Reference) {
    if (-not (Find-TerraformBlock $Code $Frame.Directory 'variable' @($Reference[1]))) { return New-UnfollowableReference $Expression ($Reference -join '.') }
    if (-not $Frame.Call) { return }
    $argument = $Frame.Call.Attributes[$Reference[1]]
    if ($argument) { return New-PendingExpression $Frame.Parent $argument }
}

function Resolve-ModuleReference($Code, $Frame, $Expression, [string[]]$Reference, [string]$Environment) {
    $call = Find-TerraformBlock $Code $Frame.Directory 'module' @($Reference[1])
    $child = if ($call) { Get-ModuleDirectory $Code $Frame.Directory $call $Environment }
    if (-not $child) { return New-UnfollowableReference $Expression ($Reference -join '.') }
    $childFrame = New-TerraformFrame $child $Frame.Root "$($Frame.Path)/module.$($Reference[1])" $call $Frame
    $outputs = @(Get-TerraformBlocks $Code $child 'output' | Where-Object { $Reference.Count -lt 3 -or $_.Labels[0] -eq $Reference[2] })
    if (-not $outputs) { return New-UnfollowableReference $Expression ($Reference -join '.') }
    return $outputs | ForEach-Object { New-PendingExpression $childFrame $_.Attributes['value'] }
}

# Il remote state porta all'output del modulo radice il cui backend di quell'ambiente dichiara il workspace.
function Resolve-RemoteStateReference($Code, $Frame, $Expression, [string[]]$Reference, [string]$Environment) {
    $block = Find-TerraformBlock $Code $Frame.Directory 'data' @('terraform_remote_state', $Reference[2])
    $workspace = if ($block) { Resolve-StringTemplate $Code $Frame.Root (Get-RemoteStateWorkspace $block) $Environment }
    $root = if ($workspace) { Find-WorkspaceRoot $Code $workspace $Environment }
    $output = if ($root -and $Reference[3] -eq 'outputs' -and $Reference.Count -ge 5) { Find-TerraformBlock $Code $root 'output' @($Reference[4]) }
    if (-not $output) { return New-UnfollowableReference $Expression ($Reference -join '.') }
    return New-PendingExpression (New-TerraformFrame $root $root '' $null $null) $output.Attributes['value']
}

function Resolve-Reference($Code, $Frame, $Expression, [string[]]$Reference, [string]$Environment) {
    if ($Reference[0] -eq 'resource') { $Reference = @($Reference | Select-Object -Skip 1) }
    switch ($Reference[0]) {
        'local' { return Resolve-LocalReference $Code $Frame $Expression $Reference }
        'var' { return Resolve-VariableReference $Code $Frame $Expression $Reference }
        'module' { return Resolve-ModuleReference $Code $Frame $Expression $Reference $Environment }
        'data' {
            if ($Reference[1] -eq 'terraform_remote_state') { return Resolve-RemoteStateReference $Code $Frame $Expression $Reference $Environment }
            if (-not (Find-TerraformBlock $Code $Frame.Directory 'data' @($Reference[1], $Reference[2]))) { return New-UnfollowableReference $Expression ($Reference -join '.') }
            return
        }
        default {
            if ($Reference.Count -ge 2 -and (Find-TerraformBlock $Code $Frame.Directory 'resource' @($Reference[0], $Reference[1]))) {
                return New-ResourceNode $Frame $Reference[0] $Reference[1]
            }
            return New-UnfollowableReference $Expression ($Reference -join '.')
        }
    }
}
