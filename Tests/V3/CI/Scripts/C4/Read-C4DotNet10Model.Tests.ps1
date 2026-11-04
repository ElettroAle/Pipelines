#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/C4/Read-C4DotNet10Model.ps1

.DESCRIPTION
    Ogni scenario costruisce un repository .NET finto, esegue il solo lettore .NET e legge il
    frammento che lascia per lo scrittore.
#>

BeforeDiscovery {
    . "$PSScriptRoot/Fixtures/C4CodeFixture.ps1"
}

BeforeAll {
    . "$PSScriptRoot/Fixtures/C4CodeFixture.ps1"

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

    Context "Schema dello scenario: direzione della relazione fra due progetti — <caso>" -ForEach @(
        @{ caso = "un adattatore che implementa la porta del core"; Sorgente = 'Contoso.Shop.Core'; Destinazione = 'Contoso.Shop.Adapter' }
        @{ caso = "un adattatore che implementa una porta generica del core"; Sorgente = 'Contoso.Shop.Core'; Destinazione = 'Contoso.Shop.Handlers' }
        @{ caso = "un progetto che usa il core senza implementarne le interfacce"; Sorgente = 'Contoso.Shop.Library'; Destinazione = 'Contoso.Shop.Core' }
        @{ caso = "l'host che implementa una porta del core"; Sorgente = 'Contoso.Shop.Host'; Destinazione = 'Contoso.Shop.Core' }
        @{ caso = "un progetto che implementa una propria interfaccia con il nome di una del core"; Sorgente = 'Contoso.Shop.Other'; Destinazione = 'Contoso.Shop.Core' }
    ) {
        BeforeAll {
            $files = [ordered]@{}
            Add-Project $files 'Contoso.Shop.Host' (New-Project 'Microsoft.NET.Sdk.Web' @('Contoso.Shop.Core', 'Contoso.Shop.Adapter', 'Contoso.Shop.Handlers', 'Contoso.Shop.Library', 'Contoso.Shop.Other'))
            Add-Project $files 'Contoso.Shop.Core' (New-Project)
            Add-Project $files 'Contoso.Shop.Adapter' (New-Project 'Microsoft.NET.Sdk' @('Contoso.Shop.Core'))
            Add-Project $files 'Contoso.Shop.Handlers' (New-Project 'Microsoft.NET.Sdk' @('Contoso.Shop.Core'))
            Add-Project $files 'Contoso.Shop.Library' (New-Project 'Microsoft.NET.Sdk' @('Contoso.Shop.Core'))
            Add-Project $files 'Contoso.Shop.Other' (New-Project 'Microsoft.NET.Sdk' @('Contoso.Shop.Core'))
            $files['source/Contoso.Shop.Core/Ports/IOrderStore.cs'] = "namespace Contoso.Shop.Core.Ports;`n`npublic interface IOrderStore`n{`n    Task SaveAsync(Order order);`n}`n`npublic interface IHandler<in TMessage> where TMessage : class`n{`n}`n`npublic interface IClock { }`n"
            $files['source/Contoso.Shop.Adapter/SqlOrderStore.cs'] = "using Contoso.Shop.Core.Ports;`n`nnamespace Contoso.Shop.Adapter;`n`n// class Fake : IClock`ninternal sealed class SqlOrderStore(Func<string, IDisposable> connect)`n    : IOrderStore`n{`n}`n"
            $files['source/Contoso.Shop.Handlers/OrderHandler.cs'] = "namespace Contoso.Shop.Handlers;`n`npublic class OrderHandler<TOrder> : Base<TOrder>, IHandler<TOrder> where TOrder : class`n{`n}`n"
            $files['source/Contoso.Shop.Library/Pricing.cs'] = "namespace Contoso.Shop.Library;`n`n/* class Fake : IOrderStore */`npublic static class Pricing`n{`n    public const string Example = `"class Fake : IOrderStore { }`";`n    public static decimal Total(Order order) => order.Lines.Sum(line => line.Price);`n}`n"
            $files['source/Contoso.Shop.Other/LocalStore.cs'] = "namespace Contoso.Shop.Other;`n`npublic interface IOrderStore { }`n`npublic record LocalStore(string Name) : IOrderStore;`n"
            $files['source/Contoso.Shop.Host/SystemClock.cs'] = "namespace Contoso.Shop.Host;`n`npublic class SystemClock : IClock { }`n"
            $res = Invoke-C4Reader $files 'Contoso.Shop' 'dotnet10'
            $relations = @($res.Fragment.relationships | ForEach-Object { "$($_.source) -> $($_.target)" })
            $container = 'contoso_shop_host'
            $expected = "${container}__$(($Sorgente.ToLowerInvariant() -replace '[^a-z0-9]+', '_')) -> ${container}__$(($Destinazione.ToLowerInvariant() -replace '[^a-z0-9]+', '_'))"
            $reversed = "${container}__$(($Destinazione.ToLowerInvariant() -replace '[^a-z0-9]+', '_')) -> ${container}__$(($Sorgente.ToLowerInvariant() -replace '[^a-z0-9]+', '_'))"
        }

        It "Allora la lettura riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E la relazione va da <Sorgente> a <Destinazione>" {
            $relations | Should -Contain $expected -Because ($relations -join "`n")
        }

        It "E non va nel verso opposto" {
            $relations | Should -Not -Contain $reversed -Because ($relations -join "`n")
        }
    }

    Context "Scenario: un progetto che implementa una porta del core e ne usa un'altra interfaccia" {
        BeforeAll {
            $files = [ordered]@{}
            Add-Project $files 'Contoso.Shop.Host' (New-Project 'Microsoft.NET.Sdk.Web' @('Contoso.Shop.Mixed'))
            Add-Project $files 'Contoso.Shop.Core' (New-Project)
            Add-Project $files 'Contoso.Shop.Mixed' (New-Project 'Microsoft.NET.Sdk' @('Contoso.Shop.Core'))
            $files['source/Contoso.Shop.Core/Ports.cs'] = "namespace Contoso.Shop.Core;`n`npublic interface IClock { }`n`npublic interface IOrderStore { }`n"
            $files['source/Contoso.Shop.Mixed/Checkout.cs'] = "namespace Contoso.Shop.Mixed;`n`npublic class Checkout(IOrderStore store) : IClock { }`n"
            $res = Invoke-C4Reader $files 'Contoso.Shop' 'dotnet10'
            $relations = @($res.Fragment.relationships | ForEach-Object { "$($_.source) -> $($_.target)" })
        }

        It "Allora la relazione va dal core al progetto, che ne implementa la porta" {
            $relations | Should -Contain 'contoso_shop_host__contoso_shop_core -> contoso_shop_host__contoso_shop_mixed' -Because ($relations -join "`n")
        }

        It "E dal progetto al core, di cui usa l'altra interfaccia" {
            $relations | Should -Contain 'contoso_shop_host__contoso_shop_mixed -> contoso_shop_host__contoso_shop_core' -Because ($relations -join "`n")
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

    Context "Scenario: gli indirizzi a cui un'applicazione si avvia in locale" {
        BeforeAll {
            $files = Add-LaunchSettings (New-BffRepository) 'Contoso.Shop.Bff.Web' @('https://localhost:5001;http://localhost:5000', 'http://localhost:5000')
            $res = Invoke-C4Reader $files 'Contoso.Shop.Bff.Web' 'dotnet10'
        }

        It "Allora la lettura riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il frammento dichiara ogni indirizzo dell'applicazione una volta sola" {
            @($res.Fragment.addresses | ForEach-Object { "$($_.container) $($_.address)" }) | Should -Be @('contoso_shop_bff_web http://localhost:5000', 'contoso_shop_bff_web https://localhost:5001')
        }

        It "E ogni indirizzo nomina il file che lo dichiara" {
            @($res.Fragment.addresses.source | Select-Object -Unique) | Should -Be @('Contoso.Shop.Bff.Web/Properties/launchSettings.json')
        }

        It "E il file degli indirizzi non e' un file di progetto letto" {
            $res.Fragment.manifests | Should -Not -Contain 'Contoso.Shop.Bff.Web/Properties/launchSettings.json'
        }
    }

    Context "Scenario: il profilo di avvio di un progetto che non e' un'applicazione" {
        BeforeAll {
            $files = Add-LaunchSettings (New-BffRepository) 'Contoso.Shop.Bff.Web.BusinessLogic' @('https://localhost:5003')
            $res = Invoke-C4Reader $files 'Contoso.Shop.Bff.Web' 'dotnet10'
        }

        It "Allora la lettura riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il frammento non dichiara indirizzi" {
            @($res.Fragment.addresses) | Should -BeNullOrEmpty
        }
    }

    Context "Schema dello scenario: profili di avvio che il lettore non legge — <caso>" -ForEach @(
        @{ caso = 'JSON non valido'; Build = { $f = New-BffRepository; $f['source/Contoso.Shop.Bff.Web/Properties/launchSettings.json'] = '{ non e'' json'; $f }; elemento = 'Contoso.Shop.Bff.Web/Properties/launchSettings.json' }
        @{ caso = 'indirizzo senza schema'; Build = { Add-LaunchSettings (New-BffRepository) 'Contoso.Shop.Bff.Web' @('localhost:5001') }; elemento = 'Contoso.Shop.Bff.Web/Properties/launchSettings.json: localhost:5001' }
        @{ caso = 'schema che non e'' http'; Build = { Add-LaunchSettings (New-BffRepository) 'Contoso.Shop.Bff.Web' @('ftp://localhost:5001') }; elemento = 'Contoso.Shop.Bff.Web/Properties/launchSettings.json: ftp://localhost:5001' }
    ) {
        BeforeAll {
            $res = Invoke-C4Reader (& $Build) 'Contoso.Shop.Bff.Web' 'dotnet10'
        }

        It "Allora la lettura fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina il repository e il file" {
            Get-Issues $res.Output | Where-Object { $_ -match 'Contoso\.Shop\.Bff\.Web' -and $_.Contains($elemento) } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }
}
