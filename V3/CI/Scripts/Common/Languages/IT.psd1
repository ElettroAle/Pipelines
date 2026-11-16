# SPDX-License-Identifier: Apache-2.0

@{
    ViewMarker     = 'vista'
    ApplicationTag = 'Applicazione'
    TechnicalTag   = 'Tecnico'
    GeneratedTag   = 'Generato'
    CodeNameProperty = 'codice'
    ExternalTag    = 'Esterno'
    DataAccessViewSuffix = 'accesso-dati'
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