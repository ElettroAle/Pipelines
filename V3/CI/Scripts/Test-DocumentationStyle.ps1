# Giudica lo stile delle sezioni di un documento con un modello linguistico: la guida di
# stile del repository e' l'istruzione del modello, e la pipeline non conosce nessuna regola.
# In una PR si giudicano le sezioni cambiate, tutte se cambia la guida. Ogni rilievo nomina
# la sezione e la regola violata.

. "$PSScriptRoot/VerificationGate.ps1"
. "$PSScriptRoot/MarkdownText.ps1"

$docsDirectory = if ($env:DOCS_DIRECTORY) { $env:DOCS_DIRECTORY } else { 'docs/architecture' }
$guidePath = if ($env:STYLE_GUIDE) { $env:STYLE_GUIDE } else { 'docs/STYLE.md' }
$glossaryFileName = $env:DOCS_GLOSSARY
$targetBranch = $env:TARGET_BRANCH -replace '^refs/heads/', '' -replace '^\$\(.*\)$', ''
$endpoint = "$env:STYLE_JUDGE_ENDPOINT".TrimEnd('/')
$model = $env:STYLE_JUDGE_MODEL

$SectionFilePattern = '^\d+[_-].+\.md$'
$JudgeScope = 'giudizio dello stile'
$MaxAttempts = 3
$RequestTimeoutSeconds = 300

$FindingsSchema = @{
    type                 = 'object'
    additionalProperties = $false
    required             = @('findings')
    properties           = @{
        findings = @{
            type  = 'array'
            items = @{
                type                 = 'object'
                additionalProperties = $false
                required             = @('rule', 'excerpt', 'explanation')
                properties           = @{
                    rule        = @{ type = 'string'; description = 'Titolo esatto della regola della guida violata' }
                    excerpt     = @{ type = 'string'; description = 'La frase della sezione che viola la regola, copiata alla lettera' }
                    explanation = @{ type = 'string'; description = 'Perche'' la frase viola la regola, in una frase' }
                }
            }
        }
    }
}

$Instructions = @'
Sei il revisore della documentazione di una piattaforma software. Giudichi una sezione del
documento applicando soltanto le regole della guida di stile che segue: nessun'altra regola,
nessuna preferenza personale. Per ogni violazione restituisci il titolo esatto della regola
violata, la frase della sezione copiata alla lettera e il motivo in una frase. Se la sezione
rispetta tutte le regole restituisci un elenco vuoto. Il glossario del documento ti serve per
sapere quali termini sono gia' raccolti li'; non giudichi il glossario.

GUIDA DI STILE

'@

function Read-JudgeSetup {
    if (-not (Test-Path $guidePath -PathType Leaf)) { return @{ Issue = New-Issue $JudgeScope 'guida mancante' $guidePath } }
    if (-not $endpoint -or -not $model) { return @{ Issue = New-Issue $JudgeScope 'verifica non eseguita' 'endpoint o modello non configurati' } }
    return @{ Guide = [IO.File]::ReadAllText($guidePath) }
}

function Get-SectionFiles {
    return @(Get-ChildItem -Path $docsDirectory -File -ErrorAction SilentlyContinue | Where-Object Name -Match $SectionFilePattern | Sort-Object Name)
}

function ConvertTo-RepositoryPath([string]$Path) {
    return ([IO.Path]::GetRelativePath((Get-Location).Path, $Path) -replace '\\', '/')
}

# Fuori da una PR, o con il ramo di destinazione illeggibile, si giudica tutto.
function Get-ChangedPaths([string[]]$Paths) {
    if (-not $targetBranch) { return $null }
    git rev-parse --verify --quiet "origin/$targetBranch^{commit}" > $null
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; return $null }
    return , @(git diff --name-only "origin/$targetBranch...HEAD" -- $Paths | ForEach-Object { $_ -replace '\\', '/' })
}

function Select-SectionsToJudge($Sections) {
    $changed = Get-ChangedPaths @($docsDirectory, $guidePath)
    if ($null -eq $changed) { return $Sections }
    if ($changed -contains (ConvertTo-RepositoryPath (Resolve-Path $guidePath).Path)) { return $Sections }
    return @($Sections | Where-Object { $changed -contains (ConvertTo-RepositoryPath $_.FullName) })
}

function Get-AccessToken {
    if ($env:STYLE_JUDGE_TOKEN) { return $env:STYLE_JUDGE_TOKEN }
    $token = az account get-access-token --resource 'https://cognitiveservices.azure.com' --query accessToken -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) { throw "token Entra ID non ottenuto: $token" }
    return $token
}

function Invoke-Judge([string]$System, [string]$User, [string]$Token) {
    $body = @{
        model           = $model
        messages        = @(@{ role = 'system'; content = $System }, @{ role = 'user'; content = $User })
        response_format = @{ type = 'json_schema'; json_schema = @{ name = 'style_findings'; strict = $true; schema = $FindingsSchema } }
    } | ConvertTo-Json -Depth 20

    for ($attempt = 1; ; $attempt++) {
        try {
            $response = Invoke-RestMethod -Method Post -Uri "$endpoint/openai/v1/chat/completions" -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
                -ContentType 'application/json; charset=utf-8' -Headers @{ Authorization = "Bearer $Token" } -TimeoutSec $RequestTimeoutSeconds
            return @(($response.choices[0].message.content | ConvertFrom-Json).findings)
        }
        catch {
            $status = [int]$_.Exception.Response.StatusCode
            $transient = $status -eq 429 -or $status -ge 500
            if (-not $transient -or $attempt -ge $MaxAttempts) { throw }
            Start-Sleep -Seconds ([math]::Pow(2, $attempt))
        }
    }
}

function Get-StyleIssues {
    $setup = Read-JudgeSetup
    if ($setup.Issue) { return $setup.Issue }

    $sections = Get-SectionFiles
    $glossaryFile = $sections | Where-Object { $glossaryFileName -and $_.Name -eq $glossaryFileName } | Select-Object -First 1
    $glossary = if ($glossaryFile) { [IO.File]::ReadAllText($glossaryFile.FullName) } else { '' }
    $toJudge = @(Select-SectionsToJudge $sections | Where-Object { -not $glossaryFile -or $_.FullName -ne $glossaryFile.FullName })
    if (-not $toJudge) { return }

    try { $token = Get-AccessToken }
    catch { return New-Issue $JudgeScope 'verifica non eseguita' $_.Exception.Message }

    $system = $Instructions + $setup.Guide
    foreach ($file in $toJudge) {
        $content = [IO.File]::ReadAllText($file.FullName)
        $title = (ConvertFrom-MarkdownSection $content).Title
        $user = "GLOSSARIO DEL DOCUMENTO`n`n$glossary`n`nSEZIONE DA GIUDICARE ($($file.Name))`n`n$content"
        try { $findings = Invoke-Judge $system $user $token }
        catch { return New-Issue $JudgeScope 'verifica non eseguita' "$($file.Name): $($_.Exception.Message)" }
        $findings | ForEach-Object { New-Issue $title $_.rule "«$($_.excerpt)»: $($_.explanation)" }
    }
}

Invoke-Verification { Get-StyleIssues } "Stile del documento in $docsDirectory conforme alla guida" 'Giudizio dello stile disattivato'
