#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/C4/DotNet10Code.ps1

.DESCRIPTION
    I tipi che un file .NET dichiara, con il nome completo, letti nel processo dei test; i progetti di
    un repository finto per i tipi dei progetti che non sono di test.
#>

BeforeAll {
    . "$PSScriptRoot/Fixtures/C4CodeFixture.ps1"
    . (Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts/C4/DotNet10Code.ps1")
}

Describe "DotNet10Code.ps1" {

    Context "Get-DeclaredTypes" {
        It "nomina i tipi di primo livello con il namespace del file" {
            $code = "namespace Contoso.Shop.Core;`n`npublic sealed class Issuer<T>(int x) : Base`n{`n}`npublic record Ticket(string Code);`ninternal enum State { Open, Closed }`npublic interface IIssuer { }`npublic readonly record struct Slot(int Number);`n"
            Get-DeclaredTypes $code | Should -Be @('Contoso.Shop.Core.Issuer', 'Contoso.Shop.Core.Ticket', 'Contoso.Shop.Core.State', 'Contoso.Shop.Core.IIssuer', 'Contoso.Shop.Core.Slot')
        }

        It "non nomina i tipi annidati" {
            $code = "namespace Contoso.Shop.Core;`n`npublic class Issuer`n{`n    private sealed record Pending(string Code);`n    public class Nested`n    {`n        public enum Kind { A }`n    }`n}`npublic class After { }`n"
            Get-DeclaredTypes $code | Should -Be @('Contoso.Shop.Core.Issuer', 'Contoso.Shop.Core.After')
        }

        It "segue i namespace a blocchi, anche annidati" {
            $code = "namespace Contoso`n{`n    namespace Shop.Core`n    {`n        public class Issuer { }`n    }`n`n    public static class Extensions { }`n}`n"
            Get-DeclaredTypes $code | Should -Be @('Contoso.Shop.Core.Issuer', 'Contoso.Extensions')
        }

        It "non conta le graffe dentro stringhe e caratteri" {
            $code = "namespace Contoso.Shop.Core;`n`npublic class Issuer`n{`n    private const string Open = `"{`";`n    private const string Raw = `"`"`"`n        }`n        `"`"`";`n    private const char Close = '}';`n    private const string Verbatim = @`"}`"`"`";`n}`npublic class After { }`n"
            Get-DeclaredTypes $code | Should -Be @('Contoso.Shop.Core.Issuer', 'Contoso.Shop.Core.After')
        }

        It "nomina un tipo senza namespace con il solo nome" {
            Get-DeclaredTypes "public class Program { }`n" | Should -Be @('Program')
        }
    }

    Context "Get-ProductionTypes" {
        BeforeAll {
            $root = Join-Path ([IO.Path]::GetTempPath()) "pester-dotnet10-code-$(New-Guid)"
            $files = [ordered]@{}
            Add-Project $files 'Contoso.Shop.Core' (New-Project)
            Add-Project $files 'Contoso.Shop.Core.Tests' (New-Project 'MSTest.Sdk' @('Contoso.Shop.Core'))
            $files['source/Contoso.Shop.Core/Issuer.cs'] = "namespace Contoso.Shop.Core;`n`npublic class Issuer { }`n"
            $files['source/Contoso.Shop.Core.Tests/IssuerTests.cs'] = "namespace Contoso.Shop.Core;`n`npublic class IssuerTests { }`n"
            Write-SourceFiles $root $files
            $SourceDirectory = Join-Path $root 'source'
            $types = @(Get-ProductionTypes (Read-DotNetProjects))
        }

        AfterAll {
            Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
        }

        It "legge i tipi dei progetti che non sono di test, con il nome della classe, il progetto e il file" {
            $types.Count | Should -Be 1
            $types[0].FullName | Should -Be 'Contoso.Shop.Core.Issuer'
            $types[0].Name | Should -Be 'Issuer'
            $types[0].Project | Should -Be 'Contoso.Shop.Core'
            $types[0].File | Should -Be (Join-Path $SourceDirectory 'Contoso.Shop.Core/Issuer.cs' | Resolve-Path).Path
        }
    }
}
