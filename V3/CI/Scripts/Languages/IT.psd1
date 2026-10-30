# SPDX-License-Identifier: Apache-2.0

@{
    ViewMarker     = 'vista'
    ApplicationTag = 'Applicazione'
    TechnicalTag   = 'Tecnico'
    GeneratedTag   = 'Generato'
    CodeNameProperty = 'codice'
    ServicesProperty = 'servizi'
    ExternalTag    = 'Esterno'
    TextLanguage   = 'italiano'
    AdrSections    = @('Contesto e problema', 'Opzioni considerate', 'Esito della decisione')
    StyleRuleParts = @{ Common = 'Regole'; Sections = 'Regole delle sezioni'; Decisions = 'Regole delle decisioni' }
    AdrVersionsSection = 'Versioni'
    AdrCodeStructureSection = 'Struttura nel codice'
    AdrCodeFlowSection = 'Flusso nel codice'
    WikiRoot       = 'Architettura'
    StatusColumn   = 'Stato'
    StatusLabels   = @{ proposed = 'proposta'; accepted = 'accettata'; rejected = 'respinta'; deprecated = 'deprecata'; superseded = 'sostituita' }
    StatusNotices  = @{ superseded = 'DECISIONE SOSTITUITA. Al suo posto vale la'; deprecated = 'DECISIONE DEPRECATA. Non vale piu'' e nessuna decisione la sostituisce.'; rejected = 'DECISIONE RESPINTA. Resta come traccia della discussione.' }
}
