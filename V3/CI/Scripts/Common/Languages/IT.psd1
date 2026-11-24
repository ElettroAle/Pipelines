# SPDX-License-Identifier: Apache-2.0

@{
    ViewMarker     = 'vista'
    ApplicationTag = 'Applicazione'
    TechnicalTag   = 'Tecnico'
    GeneratedTag   = 'Generato'
    CodeNameProperty = 'codice'
    ExternalTag    = 'Esterno'
    DataAccessViewSuffix = 'accesso-dati'
    ViewTitles     = @{
        Allocation = 'Allocazione · {0}'; ApplicationAllocation = 'Allocazione · {0} · {1}'; Network = 'Rete · {0}'; NetworkPart = 'Rete · {0} · {1}'
        Containers = 'Container di {0}'; Logic = 'logica'; DataAccess = 'accesso ai dati'
    }
    ViewPurposes   = @{
        Allocation            = 'Dove gira ogni applicazione dell''ambiente: i piani di calcolo, le applicazioni che ospitano e le chiamate fra le applicazioni.'
        ApplicationAllocation = 'Su che cosa si appoggia un''applicazione nell''ambiente: il suo piano di calcolo, i servizi gestiti e le altre applicazioni con cui comunica.'
        Network               = 'Come si collegano le reti dell''ambiente: l''ingresso del traffico, le reti virtuali e i peering fra loro.'
        NetworkPart           = 'Che cosa sta in una rete virtuale: le subnet, le applicazioni che vi si integrano, i private endpoint e il percorso del traffico in ingresso.'
        Containers            = 'I container con cui un''applicazione comunica e che cosa passa fra loro.'
        Logic                 = 'I componenti della logica di un container e come dipendono l''uno dall''altro.'
        DataAccess            = 'I componenti di un container che leggono e scrivono i dati, e chi li usa.'
    }
    CommunicatesWith = 'Comunica con:'
    SummaryTag     = 'Riassunto'
    NetworkTag     = 'Rete'
    NetworkRelationships = @{ Peering = 'Collega le due reti con un peering'; Origin = 'Inoltra le richieste all''origine'; Backend = 'Inoltra le richieste al backend' }
    NetworkViewSuffix = 'rete'
    NetworkEnvironmentSuffix = 'rete'
    ResourceGroupTable = @{ Group = 'Gruppo di risorse'; Content = 'Contenuto'; Module = 'Modulo' }
    TextLanguage   = 'italiano'
    AdrSections    = @('Contesto e problema', 'Opzioni considerate', 'Esito della decisione')
    StyleRuleParts = @{ Common = 'Regole'; Sections = 'Regole delle sezioni'; Decisions = 'Regole delle decisioni' }
    AdrVersionsSection = 'Versioni'
    AdrSupersedesLabel = 'Sostituisce'
    AdrCodeStructureSection = 'Struttura nel codice'
    AdrCodeFlowSection = 'Flusso nel codice'
    WikiRoot       = 'Architettura'
    DocumentLang   = 'it'
    DocumentVersion = 'Versione {0}'
    TableOfContents = 'Indice'
    StatusColumn   = 'Stato'
    StatusLabels   = @{ proposed = 'proposta'; accepted = 'accettata'; rejected = 'respinta'; deprecated = 'deprecata'; superseded = 'sostituita' }
    StatusNotices  = @{ superseded = 'DECISIONE SOSTITUITA. Al suo posto vale la'; deprecated = 'DECISIONE DEPRECATA. Non vale piu'' e nessuna decisione la sostituisce.'; rejected = 'DECISIONE RESPINTA. Resta come traccia della discussione.' }
    DraftSuffix    = ' (bozza)'
    DraftNotice    = 'BOZZA. La pagina descrive il lavoro arrivato in {0} e non ancora in produzione.'
    DraftNoticeColor = 'darkorange'
    DraftLink      = 'Il lavoro arrivato in {0} e non ancora in produzione cambia questa pagina:'
    UpdateOriginPullRequest = 'PR {0} di {1}'
    UpdateOriginCommit = 'commit {0} di {1}'
    Reference      = @{
        WikiRoot = 'Reference'; ModulesPage = 'Moduli Terraform'; ApisPage = 'API'; TasksPage = 'Comandi'; ReleaseNotes = 'Release notes'
        Generated = 'Pagina generata dal codice: una modifica fatta qui si perde alla generazione successiva.'
        Variables = 'Variabili'; Outputs = 'Output'; Resources = 'Risorse'; Parameters = 'Parametri'; Responses = 'Risposte'
        Name = 'Nome'; Type = 'Tipo'; Default = 'Default'; Description = 'Descrizione'; Location = 'Posizione'; Code = 'Codice'; Task = 'Task'
        Required = 'obbligatorio'
        MissingVariable = 'la variabile `{0}` del modulo `{1}`'; MissingOutput = 'l''output `{0}` del modulo `{1}`'
        MissingEndpoint = 'l''endpoint `{0}` dell''API `{1}`'; MissingTask = 'il task `{0}`'
        BugTitle = 'Reference di {0}: voci senza descrizione'
        BugText = 'La reference generata dal codice di {0} ha voci senza descrizione. Si descrivono nel codice: il Bug si aggiorna a ogni generazione finche'' l''elenco non e'' vuoto.'
    }
}