#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Read-C4DotNetModel.ps1

.DESCRIPTION
    Ogni scenario costruisce un repository .NET finto, esegue il solo lettore .NET e legge il
    frammento che lascia per lo scrittore.
#>

BeforeDiscovery {
    . "$PSScriptRoot/../fixtures/c4/C4CodeFixture.ps1"
}

BeforeAll {
    . "$PSScriptRoot/../fixtures/c4/C4CodeFixture.ps1"

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

Describe "Lettore .NET del modello C4" {

    Context "Schema dello scenario: tipo del progetto dalla tabella delle regole — <caso>" -ForEach @(
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
            $res = Invoke-C4Reader (New-HostedRepository $Subject) 'Contoso.Shop' 'dotnet'
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

    Context "Scenario: una libreria Azure in un progetto di test" {
        BeforeAll {
            $files = New-EngineRepository
            Add-Project $files 'Aidea.Dxp.AI.UnitTest.Engine' (New-Project 'Microsoft.NET.Sdk' @() '' "    <PackageReference Include=`"Microsoft.NET.Test.Sdk`" />`n    <PackageReference Include=`"Azure.Mystery.Things`" />")
            $res = Invoke-C4Reader $files 'Aidea.Dxp.AI' 'dotnet'
        }

        It "Allora la lettura riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }
    }

    Context "Schema dello scenario: caso .NET non riconosciuto — <elemento>" -ForEach @(
        @{ elemento = 'Contoso.Shop.Subject'; Subject = (New-Project 'Microsoft.NET.Sdk.BlazorWebAssembly') }
        @{ elemento = 'Azure.Mystery.Things in Contoso.Shop.Subject'; Subject = (New-Project 'Microsoft.NET.Sdk' @() '' '    <PackageReference Include="Azure.Mystery.Things" />') }
    ) {
        BeforeAll {
            $res = Invoke-C4Reader (New-HostedRepository $Subject) 'Contoso.Shop' 'dotnet'
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
