# SPDX-License-Identifier: Apache-2.0

# Lettore finto scritto nel repository di un consumer (c4-read-script.yaml): ogni file *.tf dichiara
# un servizio di dati, che diventa un container con il nome del file.

. "$env:C4_SCRIPTS_DIRECTORY/VerificationGate.ps1"
. "$env:C4_SCRIPTS_DIRECTORY/C4CodeModel.ps1"

function Get-ReadIssues {
    $files = Get-SourceFiles '*.tf'
    $containers = $files | ForEach-Object {
        [ordered]@{
            id         = ConvertTo-Identifier "$Repository.$($_.BaseName)"
            name       = $_.BaseName
            codeName   = Get-RelativePath $_.FullName
            technology = 'Terraform'
            tags       = @('Servizio')
            properties = [ordered]@{}
            components = @()
        }
    }
    Write-C4Fragment 'consumer' @($files | ForEach-Object { Get-RelativePath $_.FullName }) $containers @()
}

Invoke-Verification { Get-ReadIssues } "Servizi di $Repository letti" 'Lettura dei servizi disattivata'
