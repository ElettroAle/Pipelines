# SPDX-License-Identifier: Apache-2.0

# Valori della dichiarazione Terraform di un ambiente, senza eseguire Terraform e senza leggere lo stato:
# le espressioni di TerraformCode.ps1 si valutano con i values.tfvars dell'ambiente, i default delle
# variabili, i locals, gli argomenti e gli output dei moduli e gli output del remote state di un altro
# workspace del repository. Cio' che il repository non dichiara (una variabile del workspace, un attributo
# che Azure calcola) e' un valore sconosciuto, che si propaga e si scrive come {riferimento}. Un costrutto
# che il valutatore non conosce e' un errore che nomina file e riga.

class TfUnknown {
    [string]$Text
    TfUnknown([string]$Text) { $this.Text = $Text }
    [string] ToString() { return $this.Text }
}

class TfList {
    [System.Collections.Generic.List[object]]$Items
    TfList() { $this.Items = [System.Collections.Generic.List[object]]::new() }
    TfList([object[]]$Values) { $this.Items = [System.Collections.Generic.List[object]]::new(); foreach ($value in $Values) { $this.Items.Add($value) } }
}

# Un oggetto i cui attributi si valutano quando si leggono (Get-TfLazyAttribute): una risorsa, un modulo,
# un remote state. Niente closure: in uno script invocato con & non vedono le funzioni dello script.
class TfLazy {
    [string]$Text
    [string]$Kind
    [object[]]$Arguments
    [hashtable]$Cache = @{}
    TfLazy([string]$Text, [string]$Kind, [object[]]$Arguments) { $this.Text = $Text; $this.Kind = $Kind; $this.Arguments = $Arguments }
}

class TfError : System.Exception {
    TfError([string]$Message) : base($Message) {}
}

# ── Sintassi delle espressioni ───────────────────────────────────────────────

class TfLexer {
    [string]$Text
    [int]$Position
    [string]$Where
    TfLexer([string]$Text, [string]$Where) { $this.Text = $Text; $this.Position = 0; $this.Where = $Where }
    [bool] AtEnd() { return $this.Position -ge $this.Text.Length }
    [char] Peek([int]$Offset) { $index = $this.Position + $Offset; if ($index -lt $this.Text.Length) { return $this.Text[$index] } return [char]0 }
    [void] Fail([string]$What) { throw [TfError]::new("$($this.Where): $What") }
}

function Skip-TfSpace([TfLexer]$Lexer) {
    while (-not $Lexer.AtEnd()) {
        $character = $Lexer.Peek(0)
        if ([char]::IsWhiteSpace($character)) { $Lexer.Position++; continue }
        if ($character -eq '#' -or ($character -eq '/' -and $Lexer.Peek(1) -eq '/')) {
            while (-not $Lexer.AtEnd() -and $Lexer.Peek(0) -ne "`n") { $Lexer.Position++ }
            continue
        }
        if ($character -eq '/' -and $Lexer.Peek(1) -eq '*') {
            $end = $Lexer.Text.IndexOf('*/', $Lexer.Position + 2)
            $Lexer.Position = if ($end -lt 0) { $Lexer.Text.Length } else { $end + 2 }
            continue
        }
        return
    }
}

function Test-TfToken([TfLexer]$Lexer, [string]$Token) {
    Skip-TfSpace $Lexer
    if ($Lexer.Text.Length - $Lexer.Position -lt $Token.Length) { return $false }
    if ($Lexer.Text.Substring($Lexer.Position, $Token.Length) -ne $Token) { return $false }
    if ($Token -match '^\w+$' -and $Lexer.Peek($Token.Length) -match '[\w-]') { return $false }
    return $true
}

function Read-TfToken([TfLexer]$Lexer, [string]$Token) {
    if (Test-TfToken $Lexer $Token) { $Lexer.Position += $Token.Length; return $true }
    return $false
}

function Assert-TfToken([TfLexer]$Lexer, [string]$Token) {
    if (-not (Read-TfToken $Lexer $Token)) { $Lexer.Fail("atteso '$Token'") }
}

function Read-TfIdentifier([TfLexer]$Lexer) {
    Skip-TfSpace $Lexer
    $match = [regex]::new('\G[A-Za-z_][\w-]*').Match($Lexer.Text, $Lexer.Position)
    if (-not $match.Success) { return $null }
    $Lexer.Position += $match.Length
    return $match.Value
}

# Il testo di un template fra virgolette o di un heredoc: parti letterali e interpolazioni.
function Read-TfTemplateParts([TfLexer]$Lexer, [string]$Text, [bool]$Quoted) {
    $parts = [System.Collections.Generic.List[object]]::new()
    $literal = [Text.StringBuilder]::new()
    $index = 0
    while ($index -lt $Text.Length) {
        $character = $Text[$index]
        $next = if ($index + 1 -lt $Text.Length) { $Text[$index + 1] } else { [char]0 }
        if ($Quoted -and $character -eq '\') {
            switch ($next) {
                'n' { [void]$literal.Append("`n") } 't' { [void]$literal.Append("`t") } 'r' { [void]$literal.Append("`r") }
                '"' { [void]$literal.Append('"') } '\' { [void]$literal.Append('\') }
                'u' { [void]$literal.Append([char][Convert]::ToInt32($Text.Substring($index + 2, 4), 16)); $index += 4 }
                default { [void]$literal.Append($next) }
            }
            $index += 2
            continue
        }
        if (($character -eq '$' -or $character -eq '%') -and $next -eq '{') {
            $inner = [TfLexer]::new($Text, $Lexer.Where)
            $inner.Position = $index + 2
            if ($character -eq '%') { $Lexer.Fail('direttiva di template %{...} non supportata') }
            $expression = Read-TfExpression $inner
            Skip-TfSpace $inner
            if ($inner.Peek(0) -eq '~') { $inner.Position++ }
            Assert-TfToken $inner '}'
            if ($literal.Length) { $parts.Add($literal.ToString()); [void]$literal.Clear() }
            $parts.Add($expression)
            $index = $inner.Position
            continue
        }
        if (($character -eq '$' -or $character -eq '%') -and $next -eq $character -and $index + 2 -lt $Text.Length -and $Text[$index + 2] -eq '{') {
            [void]$literal.Append("$character{")
            $index += 3
            continue
        }
        [void]$literal.Append($character)
        $index++
    }
    if ($literal.Length) { $parts.Add($literal.ToString()) }
    return @{ Kind = 'template'; Parts = $parts.ToArray() }
}

function Read-TfQuoted([TfLexer]$Lexer) {
    $start = $Lexer.Position + 1
    $index = $start
    $depth = 0
    while ($index -lt $Lexer.Text.Length) {
        $character = $Lexer.Text[$index]
        if ($character -eq '\') { $index += 2; continue }
        if ($depth -eq 0 -and $character -eq '"') { break }
        if (($character -eq '$' -or $character -eq '%') -and $index + 1 -lt $Lexer.Text.Length -and $Lexer.Text[$index + 1] -eq '{') { $depth++; $index += 2; continue }
        if ($depth -gt 0 -and $character -eq '"') {
            $inner = [TfLexer]::new($Lexer.Text, $Lexer.Where); $inner.Position = $index
            [void](Read-TfQuoted $inner); $index = $inner.Position; continue
        }
        if ($depth -gt 0 -and $character -eq '{') { $depth++ }
        if ($depth -gt 0 -and $character -eq '}') { $depth-- }
        $index++
    }
    if ($index -ge $Lexer.Text.Length) { $Lexer.Fail('stringa non chiusa') }
    $Lexer.Position = $index + 1
    return Read-TfTemplateParts $Lexer $Lexer.Text.Substring($start, $index - $start) $true
}

function Read-TfHeredoc([TfLexer]$Lexer) {
    $match = [regex]::new('\G<<(-?)([A-Za-z_]\w*)\r?\n').Match($Lexer.Text, $Lexer.Position)
    if (-not $match.Success) { $Lexer.Fail('heredoc non riconosciuto') }
    $closing = [regex]::new("(?m)^[ \t]*$([regex]::Escape($match.Groups[2].Value))[ \t]*\r?$").Match($Lexer.Text, $match.Index + $match.Length)
    if (-not $closing.Success) { $Lexer.Fail('heredoc non chiuso') }
    $body = $Lexer.Text.Substring($match.Index + $match.Length, $closing.Index - $match.Index - $match.Length)
    if ($match.Groups[1].Value) {
        $lines = @($body -split "`n")
        $indent = ($lines | Where-Object { $_.Trim() } | ForEach-Object { $_.Length - $_.TrimStart().Length } | Measure-Object -Minimum).Minimum
        $body = ($lines | ForEach-Object { if ($_.Length -ge $indent) { $_.Substring($indent) } else { $_.TrimStart() } }) -join "`n"
    }
    $Lexer.Position = $closing.Index + $closing.Length
    return Read-TfTemplateParts $Lexer $body $false
}

function Read-TfForExpression([TfLexer]$Lexer, [string]$Closing) {
    $first = Read-TfIdentifier $Lexer
    $second = if (Read-TfToken $Lexer ',') { Read-TfIdentifier $Lexer } else { $null }
    Assert-TfToken $Lexer 'in'
    $collection = Read-TfExpression $Lexer
    Assert-TfToken $Lexer ':'
    $key = $null
    $value = Read-TfExpression $Lexer
    if ($Closing -eq '}') {
        Assert-TfToken $Lexer '=>'
        $key = $value
        $value = Read-TfExpression $Lexer
        [void](Read-TfToken $Lexer '...')
    }
    $condition = if (Read-TfToken $Lexer 'if') { Read-TfExpression $Lexer } else { $null }
    Assert-TfToken $Lexer $Closing
    $keyName = if ($second) { $first } else { $null }
    $valueName = if ($second) { $second } else { $first }
    return @{ Kind = 'for'; Object = ($Closing -eq '}'); KeyName = $keyName; ValueName = $valueName; Collection = $collection; Key = $key; Value = $value; Condition = $condition }
}

function Read-TfPrimary([TfLexer]$Lexer) {
    Skip-TfSpace $Lexer
    if ($Lexer.AtEnd()) { $Lexer.Fail('espressione incompleta') }
    $character = $Lexer.Peek(0)
    if ($character -eq '"') { return Read-TfQuoted $Lexer }
    if ($character -eq '<' -and $Lexer.Peek(1) -eq '<') { return Read-TfHeredoc $Lexer }
    $number = [regex]::new('\G\d+(\.\d+)?([eE][+-]?\d+)?').Match($Lexer.Text, $Lexer.Position)
    if ($number.Success) { $Lexer.Position += $number.Length; return @{ Kind = 'literal'; Value = [double]::Parse($number.Value, [Globalization.CultureInfo]::InvariantCulture) } }
    if (Read-TfToken $Lexer '(') { $inner = Read-TfExpression $Lexer; Assert-TfToken $Lexer ')'; return $inner }
    if (Read-TfToken $Lexer '[') {
        if (Test-TfToken $Lexer 'for') { [void](Read-TfToken $Lexer 'for'); return Read-TfForExpression $Lexer ']' }
        $items = [System.Collections.Generic.List[object]]::new()
        while (-not (Read-TfToken $Lexer ']')) {
            $items.Add((Read-TfExpression $Lexer))
            [void](Read-TfToken $Lexer ',')
        }
        return @{ Kind = 'tuple'; Items = $items.ToArray() }
    }
    if (Read-TfToken $Lexer '{') {
        if (Test-TfToken $Lexer 'for') { [void](Read-TfToken $Lexer 'for'); return Read-TfForExpression $Lexer '}' }
        $entries = [System.Collections.Generic.List[object]]::new()
        while (-not (Read-TfToken $Lexer '}')) {
            $key = Read-TfExpression $Lexer
            if (-not (Read-TfToken $Lexer '=')) { Assert-TfToken $Lexer ':' }
            $entries.Add(@{ Key = $key; Value = (Read-TfExpression $Lexer) })
            [void](Read-TfToken $Lexer ',')
        }
        return @{ Kind = 'object'; Entries = $entries.ToArray() }
    }
    $name = Read-TfIdentifier $Lexer
    if (-not $name) { $Lexer.Fail("sintassi non riconosciuta vicino a '$($Lexer.Text.Substring($Lexer.Position, [math]::Min(20, $Lexer.Text.Length - $Lexer.Position)))'") }
    switch ($name) {
        'true' { return @{ Kind = 'literal'; Value = $true } }
        'false' { return @{ Kind = 'literal'; Value = $false } }
        'null' { return @{ Kind = 'literal'; Value = $null } }
    }
    if (Read-TfToken $Lexer '(') {
        $arguments = [System.Collections.Generic.List[object]]::new()
        $expand = $false
        while (-not (Read-TfToken $Lexer ')')) {
            $arguments.Add((Read-TfExpression $Lexer))
            if (Read-TfToken $Lexer '...') { $expand = $true }
            [void](Read-TfToken $Lexer ',')
        }
        return @{ Kind = 'call'; Name = $name; Arguments = $arguments.ToArray(); Expand = $expand }
    }
    return @{ Kind = 'variable'; Name = $name }
}

function Read-TfPostfix([TfLexer]$Lexer) {
    $expression = Read-TfPrimary $Lexer
    while ($true) {
        Skip-TfSpace $Lexer
        if ($Lexer.Peek(0) -eq '.' -and $Lexer.Peek(1) -ne '.') {
            $Lexer.Position++
            if (Read-TfToken $Lexer '*') { $expression = @{ Kind = 'splat'; Source = $expression; Steps = @(Read-TfSplatSteps $Lexer) }; continue }
            $index = [regex]::new('\G\d+').Match($Lexer.Text, $Lexer.Position)
            if ($index.Success) { $Lexer.Position += $index.Length; $expression = @{ Kind = 'index'; Source = $expression; Index = @{ Kind = 'literal'; Value = [double]$index.Value } }; continue }
            $name = Read-TfIdentifier $Lexer
            if (-not $name) { $Lexer.Fail('attributo atteso dopo il punto') }
            $expression = @{ Kind = 'attribute'; Source = $expression; Name = $name }
            continue
        }
        if ($Lexer.Peek(0) -eq '[') {
            $Lexer.Position++
            if (Read-TfToken $Lexer '*') { Assert-TfToken $Lexer ']'; $expression = @{ Kind = 'splat'; Source = $expression; Steps = @(Read-TfSplatSteps $Lexer) }; continue }
            $index = Read-TfExpression $Lexer
            Assert-TfToken $Lexer ']'
            $expression = @{ Kind = 'index'; Source = $expression; Index = $index }
            continue
        }
        return $expression
    }
}

function Read-TfSplatSteps([TfLexer]$Lexer) {
    while ($true) {
        Skip-TfSpace $Lexer
        if ($Lexer.Peek(0) -eq '.' -and $Lexer.Peek(1) -ne '.') { $Lexer.Position++; @{ Kind = 'attribute'; Name = (Read-TfIdentifier $Lexer) }; continue }
        if ($Lexer.Peek(0) -eq '[') { $Lexer.Position++; $index = Read-TfExpression $Lexer; Assert-TfToken $Lexer ']'; @{ Kind = 'index'; Index = $index }; continue }
        return
    }
}

function Read-TfUnary([TfLexer]$Lexer) {
    if (Read-TfToken $Lexer '!') { return @{ Kind = 'not'; Operand = (Read-TfUnary $Lexer) } }
    Skip-TfSpace $Lexer
    if ($Lexer.Peek(0) -eq '-' -and $Lexer.Peek(1) -ne '>') { $Lexer.Position++; return @{ Kind = 'negate'; Operand = (Read-TfUnary $Lexer) } }
    return Read-TfPostfix $Lexer
}

$TfBinaryLevels = @(
    , @('||')
    , @('&&')
    , @('==', '!=')
    , @('>=', '<=', '>', '<')
    , @('+', '-')
    , @('*', '/', '%')
)

function Read-TfBinary([TfLexer]$Lexer, [int]$Level) {
    if ($Level -ge $TfBinaryLevels.Count) { return Read-TfUnary $Lexer }
    $left = Read-TfBinary $Lexer ($Level + 1)
    while ($true) {
        $operator = $TfBinaryLevels[$Level] | Where-Object { (Test-TfToken $Lexer $_) -and -not ($_ -eq '=' ) } | Select-Object -First 1
        if ($operator -eq '=' -or ($operator -in @('>', '<') -and $Lexer.Peek(1) -eq '=')) { $operator = $null }
        if (-not $operator) { return $left }
        $Lexer.Position += $operator.Length
        $left = @{ Kind = 'binary'; Operator = $operator; Left = $left; Right = (Read-TfBinary $Lexer ($Level + 1)) }
    }
}

function Read-TfExpression([TfLexer]$Lexer) {
    $condition = Read-TfBinary $Lexer 0
    if (Read-TfToken $Lexer '?') {
        $whenTrue = Read-TfExpression $Lexer
        Assert-TfToken $Lexer ':'
        return @{ Kind = 'conditional'; Condition = $condition; True = $whenTrue; False = (Read-TfExpression $Lexer) }
    }
    return $condition
}

$script:TfParsed = @{}

function ConvertTo-TfSyntax([string]$Text, [string]$Where) {
    $key = "$Where|$Text"
    if (-not $script:TfParsed.ContainsKey($key)) {
        $lexer = [TfLexer]::new($Text, $Where)
        $syntax = Read-TfExpression $lexer
        Skip-TfSpace $lexer
        if (-not $lexer.AtEnd()) { $lexer.Fail("testo dopo l'espressione: '$($Text.Substring($lexer.Position))'") }
        $script:TfParsed[$key] = $syntax
    }
    return $script:TfParsed[$key]
}

# ── Valori ───────────────────────────────────────────────────────────────────

function Test-TfUnknown($Value) {
    if ($Value -is [TfUnknown]) { return $true }
    if ($Value -is [TfList]) { return @($Value.Items | Where-Object { Test-TfUnknown $_ }).Count -gt 0 }
    return $false
}

function Format-TfValue($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [TfUnknown]) { return "{$($Value.Text)}" }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [double]) { return $Value.ToString([Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [TfLazy]) { return "{$($Value.Text)}" }
    return "$Value"
}

function ConvertTo-TfString($Value) {
    if ($Value -is [TfUnknown] -or $Value -is [TfLazy]) { return [TfUnknown]::new((Format-TfValue $Value).Trim('{', '}')) }
    return Format-TfValue $Value
}

function Get-TfItems($Value) {
    if ($Value -is [TfList]) { return , @($Value.Items) }
    if ($Value -is [System.Collections.IDictionary]) { return , @($Value.Values) }
    if ($null -eq $Value) { return , @() }
    return , @($Value)
}

function Get-TfPairs($Value) {
    if ($Value -is [System.Collections.IDictionary]) { return , @($Value.Keys | ForEach-Object { [pscustomobject]@{ Key = $_; Value = $Value[$_] } }) }
    $items = Get-TfItems $Value
    return , @(for ($index = 0; $index -lt $items.Count; $index++) { [pscustomobject]@{ Key = [double]$index; Value = $items[$index] } })
}

function Test-TfEqual($Left, $Right) {
    if ($null -eq $Left -or $null -eq $Right) { return ($null -eq $Left) -and ($null -eq $Right) }
    if ($Left -is [TfList] -and $Right -is [TfList]) {
        if ($Left.Items.Count -ne $Right.Items.Count) { return $false }
        for ($index = 0; $index -lt $Left.Items.Count; $index++) { if (-not (Test-TfEqual $Left.Items[$index] $Right.Items[$index])) { return $false } }
        return $true
    }
    if ($Left -is [System.Collections.IDictionary] -or $Right -is [System.Collections.IDictionary]) { return [object]::ReferenceEquals($Left, $Right) }
    if ($Left.GetType() -ne $Right.GetType()) { return $false }
    return $Left -ceq $Right
}

function ConvertTo-TfKey($Value) {
    if ($Value -is [double]) { return Format-TfValue $Value }
    return "$Value"
}

function Get-TfIndex($Collection, $Index, [string]$Where) {
    if ($Collection -is [TfUnknown] -or $Index -is [TfUnknown]) { return [TfUnknown]::new("$(Format-TfValue $Collection)[$(Format-TfValue $Index)]".Trim()) }
    if ($Collection -is [TfLazy]) { return Get-TfLazyAttribute $Collection "[$(ConvertTo-TfKey $Index)]" }
    if ($Collection -is [System.Collections.IDictionary]) {
        $key = ConvertTo-TfKey $Index
        if ($Collection.Contains($key)) { return $Collection[$key] }
        throw [TfError]::new("${Where}: chiave '$key' assente")
    }
    if ($Collection -is [TfList]) {
        $position = [int]$Index
        if ($position -lt 0 -or $position -ge $Collection.Items.Count) { throw [TfError]::new("${Where}: indice $position fuori dalla lista") }
        return $Collection.Items[$position]
    }
    throw [TfError]::new("${Where}: indice su un valore che non e' una collezione")
}

function Get-TfAttribute($Value, [string]$Name, [string]$Where) {
    if ($Value -is [TfUnknown]) { return [TfUnknown]::new("$($Value.Text).$Name") }
    if ($Value -is [TfLazy]) { return Get-TfLazyAttribute $Value $Name }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        throw [TfError]::new("${Where}: attributo '$Name' assente")
    }
    throw [TfError]::new("${Where}: attributo '$Name' su un valore che non e' un oggetto")
}

function Invoke-TfArithmetic([string]$Operator, $Left, $Right, [string]$Where) {
    if ($Left -isnot [double] -or $Right -isnot [double]) { throw [TfError]::new("${Where}: '$Operator' su valori che non sono numeri") }
    switch ($Operator) {
        '+' { return $Left + $Right } '-' { return $Left - $Right } '*' { return $Left * $Right }
        '/' { return $Left / $Right } '%' { return $Left % $Right }
        '>' { return $Left -gt $Right } '>=' { return $Left -ge $Right } '<' { return $Left -lt $Right } '<=' { return $Left -le $Right }
    }
}

function ConvertTo-TfBool($Value, [string]$Where) {
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string] -and $Value -in @('true', 'false')) { return $Value -eq 'true' }
    throw [TfError]::new("${Where}: condizione che non e' un booleano")
}

function Invoke-TfBinary($Syntax, $Scope) {
    $operator = $Syntax.Operator
    $left = Invoke-TfExpression $Syntax.Left $Scope
    if ($operator -eq '&&' -and $left -is [bool] -and -not $left) { return $false }
    if ($operator -eq '||' -and $left -is [bool] -and $left) { return $true }
    $right = Invoke-TfExpression $Syntax.Right $Scope
    if ((Test-TfUnknown $left) -or (Test-TfUnknown $right) -or $left -is [TfLazy] -or $right -is [TfLazy]) {
        return [TfUnknown]::new("$(Format-TfValue $left) $operator $(Format-TfValue $right)")
    }
    switch ($operator) {
        '==' { return Test-TfEqual $left $right }
        '!=' { return -not (Test-TfEqual $left $right) }
        '&&' { return (ConvertTo-TfBool $left $Scope.Where) -and (ConvertTo-TfBool $right $Scope.Where) }
        '||' { return (ConvertTo-TfBool $left $Scope.Where) -or (ConvertTo-TfBool $right $Scope.Where) }
    }
    return Invoke-TfArithmetic $operator (ConvertTo-TfNumber $left) (ConvertTo-TfNumber $right) $Scope.Where
}

function ConvertTo-TfNumber($Value) {
    if ($Value -is [string] -and $Value -match '^-?\d+(\.\d+)?$') { return [double]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture) }
    return $Value
}

function Invoke-TfTemplate($Syntax, $Scope) {
    $unknown = $false
    $text = [Text.StringBuilder]::new()
    foreach ($part in $Syntax.Parts) {
        if ($part -is [string]) { [void]$text.Append($part); continue }
        $value = Invoke-TfExpression $part $Scope
        if ((Test-TfUnknown $value) -or $value -is [TfLazy]) { $unknown = $true }
        if ($Syntax.Parts.Count -eq 1) { return $value }
        [void]$text.Append((Format-TfValue $value))
    }
    if ($unknown) { return [TfUnknown]::new($text.ToString()) }
    return $text.ToString()
}

function New-TfScope($Scope, [hashtable]$Names) {
    $locals = @{}
    if ($Scope.Names) { $Scope.Names.Keys | ForEach-Object { $locals[$_] = $Scope.Names[$_] } }
    $Names.Keys | ForEach-Object { $locals[$_] = $Names[$_] }
    return @{ Module = $Scope.Module; Each = $Scope['Each']; Count = $Scope['Count']; Where = $Scope.Where; Names = $locals }
}

function Invoke-TfFor($Syntax, $Scope) {
    $collection = Invoke-TfExpression $Syntax.Collection $Scope
    if ((Test-TfUnknown $collection) -or $collection -is [TfLazy]) { return [TfUnknown]::new("for in $(Format-TfValue $collection)") }
    $result = if ($Syntax.Object) { [ordered]@{} } else { [TfList]::new() }
    foreach ($pair in (Get-TfPairs $collection)) {
        $names = @{ $Syntax.ValueName = $pair.Value }
        if ($Syntax.KeyName) { $names[$Syntax.KeyName] = $pair.Key }
        $inner = New-TfScope $Scope $names
        if ($Syntax.Condition) {
            $keep = Invoke-TfExpression $Syntax.Condition $inner
            if (Test-TfUnknown $keep) { return [TfUnknown]::new("for if $(Format-TfValue $keep)") }
            if (-not (ConvertTo-TfBool $keep $Scope.Where)) { continue }
        }
        $value = Invoke-TfExpression $Syntax.Value $inner
        if ($Syntax.Object) {
            $key = Invoke-TfExpression $Syntax.Key $inner
            if (Test-TfUnknown $key) { return [TfUnknown]::new("for key $(Format-TfValue $key)") }
            $result[(ConvertTo-TfKey $key)] = $value
        }
        else { $result.Items.Add($value) }
    }
    return $result
}

function Invoke-TfSplat($Syntax, $Scope) {
    $source = Invoke-TfExpression $Syntax.Source $Scope
    if ($source -is [TfUnknown]) { return $source }
    $items = if ($source -is [TfList]) { $source.Items } elseif ($null -eq $source) { @() } else { @($source) }
    $result = [TfList]::new()
    foreach ($item in $items) {
        $value = $item
        foreach ($step in $Syntax.Steps) {
            $value = if ($step.Kind -eq 'attribute') { Get-TfAttribute $value $step.Name $Scope.Where } else { Get-TfIndex $value (Invoke-TfExpression $step.Index $Scope) $Scope.Where }
        }
        $result.Items.Add($value)
    }
    return $result
}

function Invoke-TfExpression($Syntax, $Scope) {
    switch ($Syntax.Kind) {
        'literal' { return $Syntax.Value }
        'template' { return Invoke-TfTemplate $Syntax $Scope }
        'tuple' { return [TfList]::new(@($Syntax.Items | ForEach-Object { , (Invoke-TfExpression $_ $Scope) })) }
        'object' {
            $result = [ordered]@{}
            foreach ($entry in $Syntax.Entries) {
                $key = if ($entry.Key.Kind -eq 'variable') { $entry.Key.Name } else { ConvertTo-TfKey (Invoke-TfExpression $entry.Key $Scope) }
                $result[$key] = Invoke-TfExpression $entry.Value $Scope
            }
            return $result
        }
        'for' { return Invoke-TfFor $Syntax $Scope }
        'variable' { return Resolve-TfName $Syntax.Name $Scope }
        'attribute' {
            $source = Invoke-TfExpression $Syntax.Source $Scope
            return Get-TfAttribute $source $Syntax.Name $Scope.Where
        }
        'index' { return Get-TfIndex (Invoke-TfExpression $Syntax.Source $Scope) (Invoke-TfExpression $Syntax.Index $Scope) $Scope.Where }
        'splat' { return Invoke-TfSplat $Syntax $Scope }
        'not' {
            $value = Invoke-TfExpression $Syntax.Operand $Scope
            if (Test-TfUnknown $value) { return [TfUnknown]::new("!$(Format-TfValue $value)") }
            return -not (ConvertTo-TfBool $value $Scope.Where)
        }
        'negate' {
            $value = Invoke-TfExpression $Syntax.Operand $Scope
            if (Test-TfUnknown $value) { return [TfUnknown]::new("-$(Format-TfValue $value)") }
            return - (ConvertTo-TfNumber $value)
        }
        'binary' { return Invoke-TfBinary $Syntax $Scope }
        'conditional' {
            $condition = Invoke-TfExpression $Syntax.Condition $Scope
            if (Test-TfUnknown $condition) {
                $whenTrue = Invoke-TfExpression $Syntax.True $Scope
                $whenFalse = Invoke-TfExpression $Syntax.False $Scope
                if (-not (Test-TfUnknown $whenTrue) -and -not (Test-TfUnknown $whenFalse) -and (Test-TfEqual $whenTrue $whenFalse)) { return $whenTrue }
                return [TfUnknown]::new("$(Format-TfValue $condition) ? $(Format-TfValue $whenTrue) : $(Format-TfValue $whenFalse)")
            }
            if (ConvertTo-TfBool $condition $Scope.Where) { return Invoke-TfExpression $Syntax.True $Scope }
            return Invoke-TfExpression $Syntax.False $Scope
        }
        'call' { return Invoke-TfFunction $Syntax $Scope }
    }
    throw [TfError]::new("$($Scope.Where): espressione non riconosciuta")
}

# ── Funzioni ─────────────────────────────────────────────────────────────────

function ConvertFrom-TfJsonValue($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) { $map = [ordered]@{}; $Value.Keys | ForEach-Object { $map["$_"] = ConvertFrom-TfJsonValue $Value[$_] }; return $map }
    if ($Value -is [System.Collections.IList] -and $Value -isnot [string]) { return [TfList]::new(@($Value | ForEach-Object { , (ConvertFrom-TfJsonValue $_) })) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [double]) { return [double]$Value }
    return $Value
}

function ConvertTo-TfJsonValue($Value) {
    if ($Value -is [TfList]) { return , @($Value.Items | ForEach-Object { , (ConvertTo-TfJsonValue $_) }) }
    if ($Value -is [System.Collections.IDictionary]) { $map = [ordered]@{}; $Value.Keys | ForEach-Object { $map[$_] = ConvertTo-TfJsonValue $Value[$_] }; return $map }
    return $Value
}

function Get-TfFilePath($Scope, $Path) {
    $base = $Scope.Module.WorkingDirectory
    return [IO.Path]::GetFullPath((Join-Path $base "$Path"))
}

function Format-TfString([string]$Format, [object[]]$Values) {
    $text = [Text.StringBuilder]::new()
    $last = 0
    $next = 0
    foreach ($match in [regex]::Matches($Format, '%[sdv%]')) {
        [void]$text.Append($Format.Substring($last, $match.Index - $last))
        if ($match.Value -eq '%%') { [void]$text.Append('%') } else { [void]$text.Append((Format-TfValue $Values[$next])); $next++ }
        $last = $match.Index + $match.Length
    }
    return $text.Append($Format.Substring($last)).ToString()
}

$TfFunctions = @{
    lower      = { param($a) $a[0].ToLowerInvariant() }
    upper      = { param($a) $a[0].ToUpperInvariant() }
    title      = { param($a) [Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase($a[0]) }
    trimspace  = { param($a) $a[0].Trim() }
    trimsuffix = { param($a) if ($a[0].EndsWith($a[1])) { $a[0].Substring(0, $a[0].Length - $a[1].Length) } else { $a[0] } }
    trimprefix = { param($a) if ($a[0].StartsWith($a[1])) { $a[0].Substring($a[1].Length) } else { $a[0] } }
    startswith = { param($a) $a[0].StartsWith($a[1]) }
    endswith   = { param($a) $a[0].EndsWith($a[1]) }
    replace    = { param($a) if ($a[1] -match '^/(.*)/$') { [regex]::Replace($a[0], $Matches[1], ($a[2] -replace '\$\{(\d+)\}', '$$$1')) } else { $a[0].Replace($a[1], $a[2]) } }
    substr     = { param($a) $length = if ($a[2] -lt 0) { $a[0].Length - $a[1] } else { [math]::Min($a[2], $a[0].Length - $a[1]) }; $a[0].Substring($a[1], $length) }
    format     = { param($a) Format-TfString $a[0] @($a | Select-Object -Skip 1) }
    join       = { param($a) (@($a[1].Items | ForEach-Object { Format-TfValue $_ })) -join $a[0] }
    split      = { param($a) [TfList]::new([string[]]($a[1] -split [regex]::Escape($a[0]))) }
    strcat     = { param($a) ($a | ForEach-Object { Format-TfValue $_ }) -join '' }
    length     = { param($a) if ($a[0] -is [string]) { [double]$a[0].Length } elseif ($a[0] -is [System.Collections.IDictionary]) { [double]$a[0].Count } else { [double]$a[0].Items.Count } }
    keys       = { param($a) [TfList]::new(@($a[0].Keys | Sort-Object)) }
    values     = { param($a) [TfList]::new(@($a[0].Keys | Sort-Object | ForEach-Object { , $a[0][$_] })) }
    lookup     = { param($a) if ($a[0].Contains((ConvertTo-TfKey $a[1]))) { $a[0][(ConvertTo-TfKey $a[1])] } elseif ($a.Count -gt 2) { $a[2] } else { throw [TfError]::new("chiave $($a[1]) assente") } }
    contains   = { param($a) [bool]@($a[0].Items | Where-Object { Test-TfEqual $_ $a[1] }).Count }
    merge      = { param($a) $map = [ordered]@{}; foreach ($m in $a) { if ($m) { $m.Keys | ForEach-Object { $map[$_] = $m[$_] } } }; $map }
    concat     = { param($a) [TfList]::new(@($a | ForEach-Object { $_.Items } | ForEach-Object { , $_ })) }
    flatten    = { param($a) $out = [TfList]::new(); $stack = { param($l) foreach ($i in $l.Items) { if ($i -is [TfList]) { & $stack $i } else { $out.Items.Add($i) } } }; & $stack $a[0]; $out }
    distinct   = { param($a) $out = [TfList]::new(); foreach ($i in $a[0].Items) { if (-not @($out.Items | Where-Object { Test-TfEqual $_ $i }).Count) { $out.Items.Add($i) } }; $out }
    toset      = { param($a) $out = [TfList]::new(); foreach ($i in $a[0].Items) { if (-not @($out.Items | Where-Object { Test-TfEqual $_ $i }).Count) { $out.Items.Add($i) } }; $out }
    tolist     = { param($a) $a[0] }
    tomap      = { param($a) $a[0] }
    sort       = { param($a) [TfList]::new(@($a[0].Items | Sort-Object)) }
    reverse    = { param($a) $items = @($a[0].Items); [array]::Reverse($items); [TfList]::new($items) }
    range      = { param($a) $start = if ($a.Count -gt 1) { $a[0] } else { 0 }; $end = if ($a.Count -gt 1) { $a[1] } else { $a[0] }; [TfList]::new(@(for ($i = $start; $i -lt $end; $i++) { [double]$i })) }
    one        = { param($a) if ($a[0].Items.Count -eq 0) { $null } else { $a[0].Items[0] } }
    alltrue    = { param($a) -not @($a[0].Items | Where-Object { -not (ConvertTo-TfBool $_ '') }).Count }
    anytrue    = { param($a) [bool]@($a[0].Items | Where-Object { ConvertTo-TfBool $_ '' }).Count }
    sum        = { param($a) [double](($a[0].Items | Measure-Object -Sum).Sum) }
    min        = { param($a) [double](($a | Measure-Object -Minimum).Minimum) }
    max        = { param($a) [double](($a | Measure-Object -Maximum).Maximum) }
    tostring   = { param($a) Format-TfValue $a[0] }
    tonumber   = { param($a) ConvertTo-TfNumber $a[0] }
    toint      = { param($a) ConvertTo-TfNumber $a[0] }
    tobool     = { param($a) ConvertTo-TfBool $a[0] '' }
    coalesce   = { param($a) $a | Where-Object { $null -ne $_ -and "$_" -ne '' } | Select-Object -First 1 }
    jsondecode = { param($a) ConvertFrom-TfJsonValue ($a[0] | ConvertFrom-Json -AsHashtable -NoEnumerate) }
    jsonencode = { param($a) ConvertTo-Json (ConvertTo-TfJsonValue $a[0]) -Depth 20 -Compress }
    yamldecode = { param($a) throw [TfError]::new('yamldecode non supportata') }
    sha256     = { param($a) [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($a[0]))).ToLowerInvariant() }
    regex      = { param($a) $m = [regex]::Match($a[1], $a[0]); if (-not $m.Success) { throw [TfError]::new("regex senza corrispondenza") }; if ($m.Groups.Count -gt 1) { [TfList]::new(@($m.Groups | Select-Object -Skip 1 | ForEach-Object Value)) } else { $m.Value } }
    regexall   = { param($a) [TfList]::new(@([regex]::Matches($a[1], $a[0]) | ForEach-Object Value)) }
    setproduct = { param($a) $out = [TfList]::new(); foreach ($x in $a[0].Items) { foreach ($y in $a[1].Items) { $out.Items.Add([TfList]::new(@($x, $y))) } }; $out }
    setsubtract = { param($a) [TfList]::new(@($a[0].Items | Where-Object { $i = $_; -not @($a[1].Items | Where-Object { Test-TfEqual $_ $i }).Count })) }
    sensitive  = { param($a) $a[0] }
    nonsensitive = { param($a) $a[0] }
    dirname    = { param($a) ([IO.Path]::GetDirectoryName($a[0]) -replace '\\', '/') }
    abspath    = { param($a) ([IO.Path]::GetFullPath($a[0]) -replace '\\', '/') }
}

$TfUnknownFunctions = @('timestamp', 'plantimestamp', 'timeadd', 'uuid', 'filesha256', 'filebase64', 'templatefile', 'base64encode', 'md5', 'cidrsubnet', 'cidrhost', 'formatdate')

function Invoke-TfFunction($Syntax, $Scope) {
    $name = $Syntax.Name
    if ($name -eq 'try') {
        foreach ($argument in $Syntax.Arguments) {
            try { return Invoke-TfExpression $argument $Scope } catch [TfError] { continue }
        }
        throw [TfError]::new("$($Scope.Where): try senza alternative valide")
    }
    if ($name -eq 'can') {
        try { $value = Invoke-TfExpression $Syntax.Arguments[0] $Scope; if (Test-TfUnknown $value) { return [TfUnknown]::new('can') }; return $true } catch [TfError] { return $false }
    }
    $arguments = @($Syntax.Arguments | ForEach-Object { , (Invoke-TfExpression $_ $Scope) })
    if ($Syntax.Expand -and $arguments.Count) { $last = $arguments[-1]; $arguments = @($arguments | Select-Object -SkipLast 1) + @($last.Items) }
    if ($name -in @('file', 'fileexists', 'fileset')) { return Invoke-TfFileFunction $name $arguments $Scope }
    $unknown = @($arguments | Where-Object { (Test-TfUnknown $_) -or $_ -is [TfLazy] } | Select-Object -First 1)
    if ($unknown) { return [TfUnknown]::new((Format-TfValue $unknown[0]).Trim('{', '}')) }
    if ($TfUnknownFunctions -contains $name) { return [TfUnknown]::new("$name(...)") }
    if (-not $TfFunctions.ContainsKey($name)) { throw [TfError]::new("$($Scope.Where): funzione $name non supportata") }
    try { return & $TfFunctions[$name] $arguments }
    catch [TfError] { throw [TfError]::new("$($Scope.Where): ${name}: $($_.Exception.Message)") }
    catch { throw [TfError]::new("$($Scope.Where): $name non valutata ($($_.Exception.Message))") }
}

function Invoke-TfFileFunction([string]$Name, $Arguments, $Scope) {
    if (Test-TfUnknown $Arguments[0]) { return [TfUnknown]::new("$Name(...)") }
    switch ($Name) {
        'file' {
            $path = Get-TfFilePath $Scope $Arguments[0]
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw [TfError]::new("$($Scope.Where): file assente $($Arguments[0])") }
            return [IO.File]::ReadAllText($path)
        }
        'fileexists' { return Test-Path -LiteralPath (Get-TfFilePath $Scope $Arguments[0]) -PathType Leaf }
        'fileset' {
            $base = Get-TfFilePath $Scope $Arguments[0]
            if (-not (Test-Path -LiteralPath $base -PathType Container)) { return [TfList]::new() }
            $pattern = '^' + ([regex]::Escape($Arguments[1]) -replace '\\\*\\\*/', '(.*/)?' -replace '\\\*', '[^/]*' -replace '\\\?', '[^/]') + '$'
            $files = Get-ChildItem -LiteralPath $base -Recurse -File | ForEach-Object { [IO.Path]::GetRelativePath($base, $_.FullName) -replace '\\', '/' } | Where-Object { $_ -match $pattern } | Sort-Object
            return [TfList]::new(@($files))
        }
    }
}

# ── Ambienti e moduli ────────────────────────────────────────────────────────

# Un ambiente e' una directory sotto <modulo radice>/environments/ che dichiara il backend: il codice e'
# quello del modulo radice (nell'ambiente ci sono i suoi hard link, che il repository non contiene), con i
# values.tfvars e i file *_override.tf dell'ambiente.
function Get-TfEnvironments($Code) {
    $script:TfCode = $Code
    if ($script:TfEnvironmentList) { return $script:TfEnvironmentList }
    $environments = foreach ($directory in ($Code.Directories.Keys | Sort-Object)) {
        if ($directory -notmatch '^(.+?)/environments/([^/]+)(/.*)?$') { continue }
        $root = $Matches[1]
        $name = $Matches[2]
        $backend = Get-TerraformBlocks $Code $directory 'terraform' | ForEach-Object Blocks | Where-Object { $_.Type -in @('cloud', 'backend') }
        if (-not $backend) { continue }
        $workspace = $backend | ForEach-Object Blocks | Where-Object Type -EQ 'workspaces' | ForEach-Object { Get-StringLiteral $_.Attributes['name'] } | Select-Object -First 1
        $valuesPath = Join-Path $Code.Root "$directory/values.tfvars"
        $values = if (Test-Path -LiteralPath $valuesPath) { (Read-TerraformFile $valuesPath "$directory/values.tfvars").Attributes } else { [ordered]@{} }
        [pscustomobject]@{ Root = $root; Directory = $directory; Name = $name; Workspace = $workspace; Values = $values; RootInstance = $null }
    }
    $script:TfEnvironmentList = @($environments)
    return $script:TfEnvironmentList
}

function Reset-TfEvaluation {
    $script:TfEnvironmentList = $null
    $script:TfParsed = @{}
}

# I blocchi di un modulo radice in un ambiente: i file del modulo, i blocchi dei file dell'ambiente che non
# sono hard link di un file del modulo, gli attributi dei file *_override.tf sopra quelli del blocco.
function Get-TfRootBlocks($Code, $Environment) {
    $rootFiles = @($Code.Directories[$Environment.Root] | ForEach-Object { [IO.Path]::GetFileName($_.File) } | Sort-Object -Unique)
    $blocks = [System.Collections.Generic.List[object]]::new()
    foreach ($block in @($Code.Directories[$Environment.Root])) { $blocks.Add((Copy-TfBlock $block)) }
    foreach ($block in @($Code.Directories[$Environment.Directory])) {
        $file = [IO.Path]::GetFileName($block.File)
        if ($rootFiles -contains $file) { continue }
        if ($file -match '(^|_)override\.tf$') {
            $target = $blocks | Where-Object { $_.Type -eq $block.Type -and (@($_.Labels) -join '|') -eq (@($block.Labels) -join '|') } | Select-Object -First 1
            if ($target) { foreach ($name in $block.Attributes.Keys) { $target.Attributes[$name] = $block.Attributes[$name] }; continue }
        }
        $blocks.Add($block)
    }
    return , $blocks.ToArray()
}

function Copy-TfBlock($Block) {
    $attributes = [ordered]@{}
    foreach ($name in $Block.Attributes.Keys) { $attributes[$name] = $Block.Attributes[$name] }
    return [pscustomobject]@{ Type = $Block.Type; Labels = $Block.Labels; Attributes = $attributes; Blocks = $Block.Blocks; File = $Block.File; Line = $Block.Line }
}

function New-TfModuleInstance($Environment, [string]$CodeDirectory, $Blocks, [string]$Path, $Call, $CallScope, $Parent) {
    return [pscustomobject]@{
        Environment = $Environment; CodeDirectory = $CodeDirectory; Blocks = $Blocks; Path = $Path; Call = $Call; CallScope = $CallScope; Parent = $Parent
        WorkingDirectory = Join-Path $script:TfCode.Root $Environment.Directory
        ModuleDirectory = if ($Parent) { Join-Path $script:TfCode.Root $CodeDirectory } else { Join-Path $script:TfCode.Root $Environment.Directory }
        Locals = @{}; Children = @{}; Objects = @{}
    }
}

function Get-TfRootInstance($Environment) {
    if (-not $Environment.RootInstance) {
        $Environment.RootInstance = New-TfModuleInstance $Environment $Environment.Root (Get-TfRootBlocks $script:TfCode $Environment) '' $null $null $null
    }
    return $Environment.RootInstance
}

function New-TfScopeFor($Instance, $Block, $Each, $Count) {
    return @{ Module = $Instance; Each = $Each; Count = $Count; Where = "$($Block.File):$($Block.Line)"; Names = @{} }
}

function Invoke-TfAttribute($Instance, $Block, [string]$Name, $Each = $null, $Count = $null) {
    $attribute = $Block.Attributes[$Name]
    if (-not $attribute) { return $null }
    $scope = @{ Module = $Instance; Each = $Each; Count = $Count; Where = "$($attribute.File):$($attribute.Line)"; Names = @{} }
    return Invoke-TfExpression (ConvertTo-TfSyntax $attribute.Text $scope.Where) $scope
}

function Find-TfBlock($Instance, [string]$Type, [string[]]$Labels) {
    return $Instance.Blocks | Where-Object { $_.Type -eq $Type -and (@($_.Labels) -join '|') -eq ($Labels -join '|') } | Select-Object -First 1
}

function Get-TfVariable($Instance, [string]$Name) {
    $declaration = Find-TfBlock $Instance 'variable' @($Name)
    if (-not $Instance.Call) {
        $value = $Instance.Environment.Values[$Name]
        if ($value) {
            $scope = @{ Module = $Instance; Where = "$($value.File):$($value.Line)"; Names = @{} }
            return Set-TfTypeDefaults (Invoke-TfExpression (ConvertTo-TfSyntax $value.Text $scope.Where) $scope) $declaration $Instance
        }
        if ($declaration -and $declaration.Attributes['default']) { return Set-TfTypeDefaults (Invoke-TfAttribute $Instance $declaration 'default') $declaration $Instance }
        return [TfUnknown]::new("var.$Name")
    }
    $argument = $Instance.Call.Attributes[$Name]
    if ($argument) {
        $scope = $Instance.CallScope.Clone()
        $scope.Where = "$($argument.File):$($argument.Line)"
        return Set-TfTypeDefaults (Invoke-TfExpression (ConvertTo-TfSyntax $argument.Text $scope.Where) $scope) $declaration $Instance
    }
    if ($declaration -and $declaration.Attributes['default']) { return Set-TfTypeDefaults (Invoke-TfAttribute $Instance $declaration 'default') $declaration $Instance }
    if ($declaration) { return $null }
    throw [TfError]::new("$($Instance.Call.File):$($Instance.Call.Line): variabile $Name assente dal modulo")
}

# Gli attributi optional() di un tipo object che il valore non da' prendono il loro default, o null.
function Set-TfTypeDefaults($Value, $Declaration, $Instance) {
    if (-not $Declaration -or -not $Declaration.Attributes['type']) { return $Value }
    $where = "$($Declaration.File):$($Declaration.Line)"
    return Add-TfTypeDefaults $Value (ConvertTo-TfSyntax $Declaration.Attributes['type'].Text $where) @{ Module = $Instance; Where = $where; Names = @{} }
}

function Add-TfTypeDefaults($Value, $Type, $Scope) {
    if ($null -eq $Value -or $Type.Kind -ne 'call' -or (Test-TfUnknown $Value)) { return $Value }
    switch ($Type.Name) {
        'object' {
            if ($Value -isnot [System.Collections.IDictionary] -or $Type.Arguments[0].Kind -ne 'object') { return $Value }
            $result = [ordered]@{}
            foreach ($key in $Value.Keys) { $result[$key] = $Value[$key] }
            foreach ($entry in $Type.Arguments[0].Entries) {
                $name = $entry.Key.Name
                $attributeType = $entry.Value
                $optional = $attributeType.Kind -eq 'call' -and $attributeType.Name -eq 'optional'
                if ($optional) { $attributeType = $entry.Value.Arguments[0] }
                if (-not $result.Contains($name)) {
                    $result[$name] = if ($optional -and $entry.Value.Arguments.Count -gt 1) { Invoke-TfExpression $entry.Value.Arguments[1] $Scope } else { $null }
                }
                $result[$name] = Add-TfTypeDefaults $result[$name] $attributeType $Scope
            }
            return $result
        }
        { $_ -in @('map') } {
            if ($Value -isnot [System.Collections.IDictionary]) { return $Value }
            $result = [ordered]@{}
            foreach ($key in $Value.Keys) { $result[$key] = Add-TfTypeDefaults $Value[$key] $Type.Arguments[0] $Scope }
            return $result
        }
        { $_ -in @('list', 'set') } {
            if ($Value -isnot [TfList]) { return $Value }
            return [TfList]::new(@($Value.Items | ForEach-Object { , (Add-TfTypeDefaults $_ $Type.Arguments[0] $Scope) }))
        }
    }
    return $Value
}

function Get-TfLocal($Instance, [string]$Name) {
    if (-not $Instance.Locals.ContainsKey($Name)) {
        $block = $Instance.Blocks | Where-Object { $_.Type -eq 'locals' -and $_.Attributes[$Name] } | Select-Object -First 1
        if (-not $block) { throw [TfError]::new("$($Instance.CodeDirectory): local.$Name assente") }
        $Instance.Locals[$Name] = [TfUnknown]::new("local.$Name")
        $Instance.Locals[$Name] = Invoke-TfAttribute $Instance $block $Name
    }
    return $Instance.Locals[$Name]
}

# Le istanze di un blocco con count o for_each: chiave, each e count.index di ognuna. Un count o un
# for_each sconosciuto da' una sola voce con Unknown.
function Get-TfInstances($Instance, $Block) {
    if ($Block.Attributes['count']) {
        $count = Invoke-TfAttribute $Instance $Block 'count'
        if ((Test-TfUnknown $count) -or $count -is [TfLazy]) { return , @([pscustomobject]@{ Key = $null; Each = $null; Count = $null; Unknown = (Format-TfValue $count) }) }
        return , @(for ($index = 0; $index -lt [int]$count; $index++) { [pscustomobject]@{ Key = [double]$index; Each = $null; Count = @{ index = [double]$index }; Unknown = $null } })
    }
    if ($Block.Attributes['for_each']) {
        $collection = Invoke-TfAttribute $Instance $Block 'for_each'
        if ((Test-TfUnknown $collection) -or $collection -is [TfLazy]) { return , @([pscustomobject]@{ Key = $null; Each = $null; Count = $null; Unknown = (Format-TfValue $collection) }) }
        $pairs = if ($collection -is [System.Collections.IDictionary]) { Get-TfPairs $collection } else { , @((Get-TfItems $collection) | ForEach-Object { [pscustomobject]@{ Key = $_; Value = $_ } }) }
        return , @($pairs | ForEach-Object { [pscustomobject]@{ Key = (ConvertTo-TfKey $_.Key); Each = @{ key = (ConvertTo-TfKey $_.Key); value = $_.Value }; Count = $null; Unknown = $null } })
    }
    return , @([pscustomobject]@{ Key = $null; Each = $null; Count = $null; Unknown = $null })
}

function Format-TfKey($Key) {
    if ($null -eq $Key) { return '' }
    if ($Key -is [double]) { return "[$(Format-TfValue $Key)]" }
    return "[`"$Key`"]"
}

# Una collezione di istanze nella forma che Terraform da' al riferimento: oggetto, lista o mappa.
function ConvertTo-TfCollection($Block, $Instances, [scriptblock]$Create, [string]$Text) {
    if ($Instances.Count -eq 1 -and $Instances[0].Unknown) { return [TfUnknown]::new($Text) }
    if ($Block.Attributes['count']) { return [TfList]::new(@($Instances | ForEach-Object { , (& $Create $_) })) }
    if ($Block.Attributes['for_each']) { $map = [ordered]@{}; $Instances | ForEach-Object { $map[$_.Key] = & $Create $_ }; return $map }
    return & $Create $Instances[0]
}

function Get-TfModuleSource($Instance, $Call) {
    $source = Get-StringLiteral $Call.Attributes['source']
    if (-not $source -or $source -notmatch '^\.\.?/') { return $null }
    $resolved = [IO.Path]::GetFullPath((Join-Path $Instance.ModuleDirectory $source))
    $relative = [IO.Path]::GetRelativePath($script:TfCode.Root, $resolved) -replace '\\', '/'
    if ($script:TfCode.Directories.ContainsKey($relative)) { return $relative }
}

function Get-TfChildInstance($Instance, $Call, $Entry) {
    $key = "$($Call.Labels[0])$(Format-TfKey $Entry.Key)"
    if (-not $Instance.Children.ContainsKey($key)) {
        $directory = Get-TfModuleSource $Instance $Call
        if (-not $directory) { throw [TfError]::new("$($Call.File):$($Call.Line): sorgente del modulo $($Call.Labels[0]) non nel repository") }
        $callScope = New-TfScopeFor $Instance $Call $Entry.Each $Entry.Count
        $Instance.Children[$key] = New-TfModuleInstance $Instance.Environment $directory @($script:TfCode.Directories[$directory]) "$($Instance.Path)/module.$key" $Call $callScope $Instance
    }
    return $Instance.Children[$key]
}

function Get-TfModuleValue($Instance, [string]$Name) {
    $call = Find-TfBlock $Instance 'module' @($Name)
    if (-not $call) { throw [TfError]::new("$($Instance.CodeDirectory): module.$Name assente") }
    $instances = Get-TfInstances $Instance $call
    return ConvertTo-TfCollection $call $instances {
        param($entry)
        $child = Get-TfChildInstance $Instance $call $entry
        [TfLazy]::new("module.$Name", 'output', @($child))
    } "module.$Name"
}

function Get-TfOutput($Instance, [string]$Name) {
    $output = Find-TfBlock $Instance 'output' @($Name)
    if (-not $output) { throw [TfError]::new("$($Instance.CodeDirectory): output $Name assente") }
    return Invoke-TfAttribute $Instance $output 'value'
}

# Un oggetto di una risorsa o di un data source: gli attributi dichiarati si valutano, id lo calcola chi
# legge ($TfResourceId), gli altri sono sconosciuti.
function New-TfResourceObject($Instance, $Block, $Entry, [string]$Mode) {
    $address = "$Mode$($Block.Labels[0]).$($Block.Labels[1])$(Format-TfKey $Entry.Key)"
    $resource = [pscustomobject]@{ Module = $Instance; Block = $Block; Entry = $Entry; Address = "$($Instance.Path)/$address".TrimStart('/'); Mode = $Mode }
    return [TfLazy]::new($address, 'resource', @($resource))
}

function Get-TfResourceAttribute($Resource, [string]$Attribute) {
    if ($Attribute -eq 'id') { $id = Get-TfResourceId $Resource; if ($null -ne $id) { return $id } }
    if ($Resource.Block.Attributes[$Attribute]) { return Invoke-TfAttribute $Resource.Module $Resource.Block $Attribute $Resource.Entry.Each $Resource.Entry.Count }
    if ($Resource.Mode -eq 'data.' -and $Resource.Block.Labels[0] -eq 'terraform_remote_state' -and $Attribute -eq 'outputs') { return Get-TfRemoteOutputs $Resource }
    return [TfUnknown]::new("$($Resource.Address).$Attribute")
}

# L'id di una risorsa lo calcola chi legge, con $TfResourceId nel proprio script.
function Get-TfResourceId($Resource) {
    if ($script:TfResourceId) { return & $script:TfResourceId $Resource }
    return $null
}

function Get-TfResourceValue($Instance, [string]$Type, [string]$Name, [string]$Mode) {
    $kind = if ($Mode) { 'data' } else { 'resource' }
    $block = Find-TfBlock $Instance $kind @($Type, $Name)
    if (-not $block) { throw [TfError]::new("$($Instance.CodeDirectory): $Mode$Type.$Name assente") }
    $cacheKey = "$Mode$Type.$Name"
    if (-not $Instance.Objects.ContainsKey($cacheKey)) {
        $instances = Get-TfInstances $Instance $block
        $Instance.Objects[$cacheKey] = ConvertTo-TfCollection $block $instances { param($entry) New-TfResourceObject $Instance $block $entry $Mode } "$Mode$Type.$Name"
    }
    return $Instance.Objects[$cacheKey]
}

function Find-TfEnvironmentByWorkspace([string]$Workspace) {
    return $script:TfEnvironmentList | Where-Object Workspace -EQ $Workspace | Select-Object -First 1
}

function Get-TfRemoteWorkspace($Resource) {
    $config = Invoke-TfAttribute $Resource.Module $Resource.Block 'config' $Resource.Entry.Each $Resource.Entry.Count
    if ($config -isnot [System.Collections.IDictionary] -or -not $config.Contains('workspaces')) { return $null }
    $workspaces = $config['workspaces']
    if ($workspaces -is [System.Collections.IDictionary] -and $workspaces.Contains('name')) { return $workspaces['name'] }
    return $null
}

function Get-TfRemoteOutputs($Resource) {
    $workspace = Get-TfRemoteWorkspace $Resource
    if ((Test-TfUnknown $workspace) -or -not $workspace) { return [TfUnknown]::new("$($Resource.Address).outputs") }
    $environment = Find-TfEnvironmentByWorkspace $workspace
    if (-not $environment) { return [TfUnknown]::new("$workspace.outputs") }
    $root = Get-TfRootInstance $environment
    return [TfLazy]::new("$workspace.outputs", 'output', @($root))
}

function Get-TfLazyAttribute([TfLazy]$Lazy, [string]$Name) {
    if (-not $Lazy.Cache.ContainsKey($Name)) {
        $owner = $Lazy.Arguments[0]
        $Lazy.Cache[$Name] = switch ($Lazy.Kind) {
            'var' { Get-TfVariable $owner $Name }
            'local' { Get-TfLocal $owner $Name }
            'module' { Get-TfModuleValue $owner $Name }
            'output' { Get-TfOutput $owner $Name }
            'data' { [TfLazy]::new("data.$Name", 'dataType', @($owner, $Name)) }
            'dataType' { Get-TfResourceValue $owner $Lazy.Arguments[1] $Name 'data.' }
            'resourceType' { Get-TfResourceValue $owner $Lazy.Arguments[1] $Name '' }
            'resource' { Get-TfResourceAttribute $owner $Name }
        }
    }
    return $Lazy.Cache[$Name]
}

function Resolve-TfName([string]$Name, $Scope) {
    if ($Scope.Names -and $Scope.Names.ContainsKey($Name)) { return $Scope.Names[$Name] }
    $instance = $Scope.Module
    switch ($Name) {
        { $_ -in 'var', 'local', 'module', 'data' } { return [TfLazy]::new($Name, $Name, @($instance)) }
        'each' {
            if (-not $Scope['Each']) { throw [TfError]::new("$($Scope.Where): each fuori da un for_each") }
            return [ordered]@{ key = $Scope['Each'].key; value = $Scope['Each'].value }
        }
        'count' {
            if (-not $Scope['Count']) { throw [TfError]::new("$($Scope.Where): count fuori da un count") }
            return [ordered]@{ index = $Scope['Count'].index }
        }
        'path' { return [ordered]@{ module = ([IO.Path]::GetRelativePath($instance.WorkingDirectory, $instance.ModuleDirectory) -replace '\\', '/'); root = '.'; cwd = '.' } }
        'terraform' { return [ordered]@{ workspace = [TfUnknown]::new('terraform.workspace') } }
        'self' { return [TfUnknown]::new('self') }
    }
    return [TfLazy]::new($Name, 'resourceType', @($instance, $Name))
}

# Tutte le istanze dei moduli di un ambiente, dal modulo radice.
function Get-TfModuleInstances($Environment) {
    $pending = [System.Collections.Generic.Queue[object]]::new()
    $pending.Enqueue((Get-TfRootInstance $Environment))
    while ($pending.Count) {
        $instance = $pending.Dequeue()
        $instance
        foreach ($call in @($instance.Blocks | Where-Object Type -EQ 'module')) {
            if (-not (Get-TfModuleSource $instance $call)) { continue }
            foreach ($entry in (Get-TfInstances $instance $call)) {
                if ($entry.Unknown) { throw [TfError]::new("$($call.File):$($call.Line): istanze del modulo $($call.Labels[0]) sconosciute ($($entry.Unknown))") }
                $pending.Enqueue((Get-TfChildInstance $instance $call $entry))
            }
        }
    }
}
