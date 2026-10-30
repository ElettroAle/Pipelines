# SPDX-License-Identifier: Apache-2.0

# Struttura di un documento arc42: un file per sezione, con il nome e il titolo di primo livello
# del template ufficiale nella lingua del documento. Le sottosezioni e il testo li giudica il
# modello con la guida di stile del repository (Test-DocumentationStyle.ps1).

. "$PSScriptRoot/Common/VerificationGate.ps1"
. "$PSScriptRoot/Common/MarkdownText.ps1"

$docsDirectory = if ($env:DOCS_DIRECTORY) { $env:DOCS_DIRECTORY } else { 'docs/architecture' }
$language = "$env:ARC42_LANGUAGE".Trim().ToUpperInvariant()
# Le prove servono il template da un server locale: in pipeline vale sempre GitHub.
$releasesUrl = if ($env:ARC42_RELEASES_URL) { $env:ARC42_RELEASES_URL.TrimEnd('/') } else { 'https://github.com/arc42/arc42-template/releases/download' }

$Arc42Release = '2026.10.19'
# Variante plain-markdownMP: un file Markdown per sezione, senza i testi di aiuto.
$Arc42TemplateSha256 = [ordered]@{
    AZ      = '17221a80089514e5d9f899b10b982ecad04d9955d90cc8f86c4be9da49a50beb'
    CZ      = 'f904d171c9cd26ecff4dc8ef712cf1be1cfbfb09f9b4e228751202eeefa00db9'
    DE      = 'c17cdee43c06b5c0d206dd92631fa4aefbc09989dafb646c7cfb26fb1ef758aa'
    EN      = '3ad9a704273069c265c74a0f5cec19334aeb0803b9ff37d874cfb9adf9489daf'
    ES      = 'e1c799f962f08a2262e27fc45a36d5f158a2c03410df6783ecab319de9a18696'
    FR      = '4dbff364ba8959c57be678418242edfc682d530d34d51af601d0db41b66f095e'
    HU      = 'c0ebe47d28de0a9d904bd64154f31802e7af3746001eee95e4b6b3466b9b2d13'
    IT      = 'bdcf1cefe5402fa15bb981a2e178c8714f1137992a38b267ad2de4ff09029d5a'
    NL      = 'ebc3bda29a83644440f0ad908c8577f178e2d9d8d15e779510b08ec479a37923'
    PT      = 'e296fca045eb86872579b265898eeb1f01b9b7dd155cf862af92bd3dbee90923'
    RU      = '183711cfdc0c66f3c5dc181d1a759a5f2ba22e4e3426f4e4187fbbfa049a278d'
    TR      = 'ea8760f882b502b6efa9d9dbe3c7ca5880fceb75b29bd0c0bcd4cabee77762de'
    UKR     = '60a2655dad1e13f93ea7718e6abf36b4b2bdd8204e09c7d0dfa713476de564aa'
    ZH      = 'cb504dada5a5b147be41bcc6d609975e20ce1465c94864191aecdce8bdccce94'
    'ZH-TW' = '12cba1b423c5af1377366fe3105ff2d220987c92bd467da45c44703f2f7aa300'
}

$SectionFilePattern = '^\d+[_-].+\.md$'
$DocumentScope = 'documento'
$TemplateScope = 'template arc42'

function New-TemplateError([string]$Reason, [string]$Detail) {
    return [InvalidOperationException]::new((New-Issue $TemplateScope $Reason $Detail))
}

function Get-TemplateArchiveUrl {
    if (-not $Arc42TemplateSha256.Contains($language)) {
        throw (New-TemplateError 'lingua non supportata' "«$language», ammesse: $($Arc42TemplateSha256.Keys -join ', ')")
    }
    return "$releasesUrl/$Arc42Release/arc42-template-$language-plain-markdownMP.zip"
}

function Expand-Arc42Template {
    $url = Get-TemplateArchiveUrl
    $workDirectory = Join-Path ([IO.Path]::GetTempPath()) "arc42-template-$(New-Guid)"
    New-Item -ItemType Directory -Path $workDirectory | Out-Null
    $archive = Join-Path $workDirectory 'template.zip'
    try { Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing }
    catch { throw (New-TemplateError 'download non riuscito' "${url}: $($_.Exception.Message)") }

    $expected = $Arc42TemplateSha256[$language]
    $actual = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw (New-TemplateError 'SHA-256 diverso' "$url, atteso $expected, ricevuto $actual") }

    $expanded = Join-Path $workDirectory 'template'
    Expand-Archive -Path $archive -DestinationPath $expanded
    return $expanded
}

function Get-NumberedSections([string]$Directory) {
    $sections = [ordered]@{}
    Get-DocumentSections $Directory | Where-Object { $_.File.Name -match $SectionFilePattern } | ForEach-Object { $sections[$_.File.Name] = $_.Title }
    return $sections
}

function Test-SectionStructure($Sections, $TemplateSections) {
    $Sections.Keys | Where-Object { -not $TemplateSections.Contains($_) } | ForEach-Object { New-Issue $DocumentScope 'sezione fuori template' "${_}: $($Sections[$_])" }
    $TemplateSections.Keys | Where-Object { -not $Sections.Contains($_) } | ForEach-Object { New-Issue $DocumentScope 'sezione mancante' "${_}: $($TemplateSections[$_])" }
    $TemplateSections.Keys | Where-Object { $Sections.Contains($_) -and $Sections[$_] -ne $TemplateSections[$_] } |
        ForEach-Object { New-Issue $DocumentScope 'titolo diverso dal template' "${_}: $($Sections[$_]), atteso «$($TemplateSections[$_])»" }
}

function Get-Arc42Issues {
    try { $templateSections = Get-NumberedSections (Expand-Arc42Template) }
    catch [InvalidOperationException] { return $_.Exception.Message }
    Test-SectionStructure (Get-NumberedSections $docsDirectory) $templateSections
}

Invoke-Verification { Get-Arc42Issues } "Documento arc42 in $docsDirectory conforme al template $Arc42Release ($language)" 'Verifica della struttura arc42 disattivata'
