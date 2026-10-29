# SPDX-License-Identifier: Apache-2.0

# Servizi Azure riconosciuti dal modello C4 generato. Packages lega una libreria .NET al servizio con
# cui parla; IgnoredPackages sono librerie Azure che non parlano con un servizio (identita',
# telemetria, hosting delle Function). Una libreria Azure.* o Microsoft.Azure.* fuori da entrambe
# ferma la generazione.
@{
    Packages        = @{
        'Azure.AI.DocumentIntelligence'                           = 'Document Intelligence'
        'Azure.AI.FormRecognizer'                                 = 'Document Intelligence'
        'Azure.AI.OpenAI'                                         = 'Azure OpenAI'
        'Azure.AI.Projects'                                       = 'AI Foundry'
        'Azure.AI.TextAnalytics'                                  = 'Language'
        'Azure.AI.Translation.Text'                               = 'Translator'
        'Azure.Communication.Email'                               = 'Communication Services'
        'Azure.Communication.Sms'                                 = 'Communication Services'
        'Azure.Data.Tables'                                       = 'Storage'
        'Azure.Extensions.AspNetCore.Configuration.Secrets'       = 'Key Vault'
        'Azure.Messaging.ServiceBus'                              = 'Service Bus'
        'Azure.Search.Documents'                                  = 'AI Search'
        'Azure.Security.KeyVault.Certificates'                    = 'Key Vault'
        'Azure.Security.KeyVault.Keys'                            = 'Key Vault'
        'Azure.Security.KeyVault.Secrets'                         = 'Key Vault'
        'Azure.Storage.Blobs'                                     = 'Storage'
        'Azure.Storage.Files.Shares'                              = 'Storage'
        'Azure.Storage.Queues'                                    = 'Storage'
        'Microsoft.Azure.Cosmos'                                  = 'Cosmos DB'
        'Microsoft.Azure.Functions.Worker.Extensions.ServiceBus'  = 'Service Bus'
        'Microsoft.Azure.Functions.Worker.Extensions.Storage'     = 'Storage'
        'Microsoft.Azure.Functions.Worker.Extensions.Storage.Blobs' = 'Storage'
        'Microsoft.Azure.Functions.Worker.Extensions.Storage.Queues' = 'Storage'
        'Microsoft.Azure.Functions.Worker.Extensions.Tables'      = 'Storage'
        'Microsoft.Azure.SignalR'                                 = 'SignalR'
    }
    IgnoredPackages = @(
        'Azure.Core'
        'Azure.Identity'
        'Azure.Monitor.OpenTelemetry.AspNetCore'
        'Azure.Monitor.OpenTelemetry.Exporter'
        'Microsoft.Azure.Functions.Worker'
        'Microsoft.Azure.Functions.Worker.Extensions.Http'
        'Microsoft.Azure.Functions.Worker.Extensions.Http.AspNetCore'
        'Microsoft.Azure.Functions.Worker.Extensions.Timer'
        'Microsoft.Azure.Functions.Worker.OpenTelemetry'
        'Microsoft.Azure.Functions.Worker.Sdk'
        'Microsoft.Extensions.Azure'
    )
}
