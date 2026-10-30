#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Read-C4DotNet10Model.ps1

.DESCRIPTION
    Ogni scenario costruisce un repository .NET finto, esegue il solo lettore .NET e legge il
    frammento che lascia per lo scrittore.
#>

BeforeDiscovery {
    . "$PSScriptRoot/../Fixtures/C4/C4CodeFixture.ps1"
}

BeforeAll {
    . "$PSScriptRoot/../Fixtures/C4/C4CodeFixture.ps1"

    function New-HostedRepository([string]$Subject) {
        $files = [ordered]@{}
        Add-Project $files 'Contoso.Shop.Host' (New-Project 'Microsoft.NET.Sdk.Web' @('Contoso.Shop.Subject'))
        $files['source/Contoso.Shop.Subject/Contoso.Shop.Subject.csproj'] = $Subject
        return $files
    }

    function Get-FragmentContainer($Fragment, [string]$CodeName) {
        return @($Fragment.containers | Where-Object codeName -EQ $CodeName)
    }

    function Get-FragmentComponents($Fragment, [string]$CodeName) {
        return @($Fragment.containers.components | Where-Object codeName -EQ $CodeName)
    }
}

Describe "Lettore .NET 10 del modello C4" {

    Context "Schema dello scenario: tipo del progetto dalle regole di .NET 10 — <caso>" -ForEach @(
        @{ caso = 'SDK Web'; Subject = (New-Project 'Microsoft.NET.Sdk.Web'); container = 'ASP.NET Core'; componente = $true }
        @{ caso = 'SDK Functions'; Subject = (New-Project 'Microsoft.NET.Sdk.Functions'); container = 'Azure Functions'; componente = $true }
        @{ caso = 'Function App isolata'; Subject = (New-Project 'Microsoft.NET.Sdk' @() "    <OutputType>Exe</OutputType>`n    <AzureFunctionsVersion>v4</AzureFunctionsVersion>"); container = 'Azure Functions'; componente = $true }
        @{ caso = 'strumento'; Subject = (New-Project 'Microsoft.NET.Sdk' @() '    <OutputType>Exe</OutputType>'); container = $null; componente = $true }
        @{ caso = 'libreria'; Subject = (New-Project); container = $null; componente = $true }
        @{ caso = 'libreria dichiarata'; Subject = (New-Project 'Microsoft.NET.Sdk' @() '    <OutputType>Library</OutputType>'); container = $null; componente = $true }
        @{ caso = 'SDK MSTest'; Subject = (New-Project 'MSTest.Sdk'); container = $null; componente = $false }
        @{ caso = 'IsTestProject'; Subject = (New-Project 'Microsoft.NET.Sdk' @() '    <IsTestProject>true</IsTestProject>'); container = $null; componente = $false }
        @{ caso = 'libreria di test'; Subject = (New-Project 'Microsoft.NET.Sdk' @() '' '    <PackageReference Include="Microsoft.NET.Test.Sdk" />'); container = $null; componente = $false }
    ) {
        BeforeAll {
            $res = Invoke-C4Reader (New-HostedRepository $Subject) 'Contoso.Shop' 'dotnet10'
        }

        It "Allora la lettura riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il progetto e' un container con la tecnologia attesa, o non lo e'" {
            (Get-FragmentContainer $res.Fragment 'Contoso.Shop.Subject').technology | Should -Be $container
        }

        It "E il progetto e' un componente dell'applicazione che lo usa, o non lo e'" {
            [bool](Get-FragmentComponents $res.Fragment 'Contoso.Shop.Subject').Count | Should -Be $componente
        }

        It "E il frammento dichiara letto il file del progetto" {
            $res.Fragment.manifests | Should -Contain 'Contoso.Shop.Subject/Contoso.Shop.Subject.csproj'
        }
    }

    Context "Scenario: una libreria Azure in un progetto" {
        BeforeAll {
            $res = Invoke-C4Reader (New-HostedRepository (New-Project 'Microsoft.NET.Sdk' @() '' '    <PackageReference Include="Azure.Mystery.Things" />')) 'Contoso.Shop' 'dotnet10'
        }

        It "Allora la lettura riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il componente non dichiara servizi" {
            (Get-FragmentComponents $res.Fragment 'Contoso.Shop.Subject').properties.PSObject.Properties | Should -BeNullOrEmpty
        }
    }

    Context "Schema dello scenario: versione ereditata da Directory.Build.props — <caso>" -ForEach @(
        @{ caso = 'net10.0'; versione = 'net10.0'; uscita = 0 }
        @{ caso = 'net8.0'; versione = 'net8.0'; uscita = 1 }
    ) {
        BeforeAll {
            $files = New-HostedRepository ((New-Project) -replace '\s*<TargetFramework>net10\.0</TargetFramework>', '')
            $files['source/Directory.Build.props'] = "<Project>`n  <PropertyGroup>`n    <TargetFramework>$versione</TargetFramework>`n  </PropertyGroup>`n</Project>`n"
            $res = Invoke-C4Reader $files 'Contoso.Shop' 'dotnet10'
        }

        It "Allora la lettura termina con il codice <uscita>" {
            $res.ExitCode | Should -Be $uscita -Because ($res.Output)
        }
    }

    Context "Schema dello scenario: caso .NET che il lettore .NET 10 non legge — <elemento>" -ForEach @(
        @{ elemento = 'Contoso.Shop.Subject'; Subject = (New-Project 'Microsoft.NET.Sdk.BlazorWebAssembly') }
        @{ elemento = 'Contoso.Shop.Subject (net8.0)'; Subject = ((New-Project) -replace 'net10\.0', 'net8.0') }
        @{ elemento = 'Contoso.Shop.Subject (net9.0)'; Subject = ((New-Project) -replace '<TargetFramework>net10\.0</TargetFramework>', '<TargetFrameworks>net10.0;net9.0</TargetFrameworks>') }
        @{ elemento = 'Contoso.Shop.Subject'; Subject = ((New-Project) -replace '\s*<TargetFramework>net10\.0</TargetFramework>', '') }
    ) {
        BeforeAll {
            $res = Invoke-C4Reader (New-HostedRepository $Subject) 'Contoso.Shop' 'dotnet10'
        }

        It "Allora la lettura fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina il repository e l'elemento" {
            Get-Issues $res.Output | Where-Object { $_ -match 'Contoso\.Shop' -and $_.Contains($elemento) } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E non lascia il frammento" {
            $res.Fragment | Should -BeNullOrEmpty
        }
    }
}
