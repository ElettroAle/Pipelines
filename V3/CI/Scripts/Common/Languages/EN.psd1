# SPDX-License-Identifier: Apache-2.0

@{
    ViewMarker     = 'view'
    ApplicationTag = 'Application'
    TechnicalTag   = 'Technical'
    GeneratedTag   = 'Generated'
    CodeNameProperty = 'code'
    ExternalTag    = 'External'
    TextLanguage   = 'English'
    AdrSections    = @('Context and Problem Statement', 'Considered Options', 'Decision Outcome')
    StyleRuleParts = @{ Common = 'Rules'; Sections = 'Section rules'; Decisions = 'Decision rules' }
    AdrVersionsSection = 'Versions'
    AdrCodeStructureSection = 'Code structure'
    AdrCodeFlowSection = 'Code flow'
    WikiRoot       = 'Architecture'
    StatusColumn   = 'Status'
    StatusLabels   = @{ proposed = 'proposed'; accepted = 'accepted'; rejected = 'rejected'; deprecated = 'deprecated'; superseded = 'superseded' }
    StatusNotices  = @{ superseded = 'SUPERSEDED DECISION. It is replaced by'; deprecated = 'DEPRECATED DECISION. It no longer applies and no decision replaces it.'; rejected = 'REJECTED DECISION. It stays as a record of the discussion.' }
}
