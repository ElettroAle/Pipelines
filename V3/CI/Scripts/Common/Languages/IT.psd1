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
    ViewDescriptions = @{
        Allocation = @(
            @{ Text = 'Applicazioni dell''ambiente {0}: {1}.'; Lists = @('Environment', 'Shown.containerInstance') }
            @{ Text = 'Piani di calcolo e risorse che le ospitano: {0}.'; Lists = @('Shown.hostingPlan,Shown.application') }
            @{ Text = 'Chiamate fra le applicazioni: {0}.'; Lists = @('Relationships') }
        )
        ApplicationAllocation = @(
            @{ Text = 'Nell''ambiente {0}, {1} gira su {2}.'; Lists = @('Environment', 'Subject', 'Host') }
            @{ Text = 'Si rivolge a {0}.'; Lists = @('Outgoing') }
            @{ Text = 'Riceve le richieste di {0}.'; Lists = @('Incoming') }
            @{ Text = 'Scambia richieste con {0}.'; Lists = @('Mutual') }
            @{ Text = 'Non ha relazioni con altri elementi dell''ambiente.'; Lists = @('Unrelated') }
        )
        Network = @(
            @{ Text = 'Reti virtuali dell''ambiente {0}: {1}.'; Lists = @('Environment', 'Shown.virtualNetwork') }
            @{ Text = 'Ingresso del traffico pubblico: {0}.'; Lists = @('Shown.ingress') }
            @{ Text = 'Collegamenti fra le reti: {0}.'; Lists = @('Relationships') }
        )
        NetworkPart = @(
            @{ Text = 'Subnet della rete {1} nell''ambiente {0}: {2}.'; Lists = @('Environment', 'Subject', 'Shown.subnet') }
            @{ Text = 'Applicazioni integrate nella rete: {0}.'; Lists = @('Shown.containerInstance') }
            @{ Text = 'Risorse raggiunte in privato dalla rete: {0}.'; Lists = @('Shown.privateEndpoint') }
            @{ Text = 'Riceve il traffico da {0}.'; Lists = @('Incoming') }
            @{ Text = 'Si collega a {0}.'; Lists = @('Outgoing') }
            @{ Text = 'Scambia traffico con {0}.'; Lists = @('Mutual') }
            @{ Text = 'Non ha collegamenti con altre reti.'; Lists = @('Unrelated') }
        )
        Containers = @(
            @{ Text = '{0} si rivolge a {1}.'; Lists = @('Subject', 'Outgoing') }
            @{ Text = '{0} riceve le richieste di {1}.'; Lists = @('Subject', 'Incoming') }
            @{ Text = '{0} scambia richieste con {1}.'; Lists = @('Subject', 'Mutual') }
            @{ Text = '{0} non ha relazioni con altri sistemi.'; Lists = @('Unrelated') }
        )
        Logic = @(
            @{ Text = 'Componenti della logica di {0}: {1}.'; Lists = @('Subject', 'Shown.logic') }
            @{ Text = 'Si rivolgono a {0}.'; Lists = @('Outgoing') }
            @{ Text = 'Ricevono le richieste di {0}.'; Lists = @('Incoming') }
            @{ Text = 'Si scambiano richieste con {0}.'; Lists = @('Mutual') }
            @{ Text = 'Non si rivolgono ad altri elementi e non ne ricevono richieste.'; Lists = @('Unrelated') }
        )
        DataAccess = @(
            @{ Text = 'Componenti dell''accesso ai dati di {0}: {1}.'; Lists = @('Subject', 'Shown.dataAccess') }
            @{ Text = 'Si rivolgono a {0}.'; Lists = @('Outgoing') }
            @{ Text = 'Usati da {0}.'; Lists = @('Incoming') }
            @{ Text = 'Si scambiano richieste con {0}.'; Lists = @('Mutual') }
            @{ Text = 'Non si rivolgono ad altri elementi e non ne ricevono richieste.'; Lists = @('Unrelated') }
        )
    }
    LevelSummaries = @{
        person = @{ Count = '{0} persone' }
        softwareSystem = @{ Count = '{0} sistemi esterni' }
        container = @{ Count = '{0} container' }
        logic = @{ Count = '{0} componenti della logica'; InView = '{0} componenti della logica descritti nella vista {1}' }
        dataAccess = @{ Count = '{0} componenti dell''accesso ai dati'; InView = '{0} componenti dell''accesso ai dati descritti nella vista {1}' }
        containerInstance = @{ Count = '{0} istanze di container' }
        region = @{ Count = '{0} regioni' }
        hostingPlan = @{ Count = '{0} piani di calcolo' }
        application = @{ Count = '{0} risorse che ospitano applicazioni' }
        virtualNetwork = @{ Count = '{0} reti virtuali' }
        subnet = @{ Count = '{0} subnet' }
        privateEndpoint = @{ Count = '{0} accessi privati' }
        gateway = @{ Count = '{0} gateway' }
        ingress = @{ Count = '{0} ingressi pubblici' }
        ingressEndpoint = @{ Count = '{0} punti d''ingresso pubblici' }
    }
    ViewGroupIntroduction = @(
        @{ Text = 'La vista {0} mostra l''insieme; le viste che seguono ne riprendono una alla volta le parti: {1}.'; Lists = @('First', 'Following') }
    )
    ViewGroupPeers = @(
        @{ Text = 'Le sezioni che seguono mostrano, per {0}, una vista per ciascuno di questi livelli: {1}.'; Lists = @('FirstSubjects', 'SeveralLevels') }
        @{ Text = 'Le sezioni che seguono mostrano, per {0}, una sola vista: {1}.'; Lists = @('FirstSubjects', 'OneLevel') }
        @{ Text = 'Per {0} mostrano una vista per ciascuno di questi livelli: {1}.'; Lists = @('NextSubjects', 'SeveralLevels') }
        @{ Text = 'Per {0} mostrano una sola vista: {1}.'; Lists = @('NextSubjects', 'OneLevel') }
        @{ Text = 'Le sezioni che seguono mostrano una vista per ciascuno di questi elementi: {0}.'; Lists = @('UnleveledSubjects') }
    )
    ViewGroupLevels = @{ logic = 'la logica'; dataAccess = 'l''accesso ai dati' }
    ListConjunction = 'e'
    ViewNameFormat = '«{0}»'
    SummaryTag     = 'Riassunto'
    NetworkTag     = 'Rete'
    NetworkRelationships = @{ Peering = 'Collega le due reti con un peering'; Origin = 'Inoltra le richieste all''origine'; Backend = 'Inoltra le richieste al backend' }
    NetworkViewSuffix = 'rete'
    NetworkEnvironmentSuffix = 'rete'
    NodeDescriptions = @{
        region = @(
            @{ Text = 'Ospita {0}.'; Lists = @('Children') }
        )
        hostingPlan = @(
            @{ Text = 'Piano di calcolo di {0}.'; Lists = @('Children') }
        )
        application = @(
            @{ Text = 'Ospita {0}.'; Lists = @('Children') }
            @{ Text = 'Riceve le richieste da {0}.'; Lists = @('Incoming.Backend,Incoming.Origin') }
            @{ Text = 'Si trova in {0}.'; Lists = @('Parent') }
        )
        virtualNetwork = @(
            @{ Text = 'Contiene le subnet {0}.'; Lists = @('Children') }
            @{ Text = 'Collegata in peering a {0}.'; Lists = @('Outgoing.Peering,Incoming.Peering') }
        )
        subnet = @(
            @{ Text = 'Ospita {0}.'; Lists = @('Children') }
            @{ Text = 'Si trova in {0}.'; Lists = @('Parent') }
        )
        privateEndpoint = @(
            @{ Text = 'Accesso privato a {0}.'; Lists = @('Exposes') }
        )
        gateway = @(
            @{ Text = 'Riceve le richieste da {0} e le inoltra a {1}.'; Lists = @('Incoming.Origin', 'Outgoing.Backend') }
        )
        ingress = @(
            @{ Text = 'Ingresso pubblico verso {0}.'; Lists = @('Outgoing.Origin') }
        )
        ingressEndpoint = @(
            @{ Text = 'Riceve il traffico pubblico e lo inoltra a {0}.'; Lists = @('Outgoing.Origin') }
        )
    }
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