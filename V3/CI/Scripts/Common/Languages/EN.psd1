# SPDX-License-Identifier: Apache-2.0

@{
    ViewMarker     = 'view'
    ApplicationTag = 'Application'
    TechnicalTag   = 'Technical'
    GeneratedTag   = 'Generated'
    CodeNameProperty = 'code'
    ExternalTag    = 'External'
    DataAccessViewSuffix = 'data-access'
    ViewTitles     = @{ DeploymentOverview = 'Parts of the {0} environment'; Containers = 'Containers of {0}'; Logic = 'logic'; DataAccess = 'data access' }
    CommunicatesWith = 'Communicates with:'
    SummaryTag     = 'Summary'
    SummaryMore    = 'and {0} more'
    TextLanguage   = 'English'
    AdrSections    = @('Context and Problem Statement', 'Considered Options', 'Decision Outcome')
    StyleRuleParts = @{ Common = 'Rules'; Sections = 'Section rules'; Decisions = 'Decision rules' }
    AdrVersionsSection = 'Versions'
    AdrSupersedesLabel = 'Supersedes'
    AdrCodeStructureSection = 'Code structure'
    AdrCodeFlowSection = 'Code flow'
    WikiRoot       = 'Architecture'
    DocumentLang   = 'en'
    DocumentVersion = 'Version {0}'
    TableOfContents = 'Contents'
    StatusColumn   = 'Status'
    StatusLabels   = @{ proposed = 'proposed'; accepted = 'accepted'; rejected = 'rejected'; deprecated = 'deprecated'; superseded = 'superseded' }
    StatusNotices  = @{ superseded = 'SUPERSEDED DECISION. It is replaced by'; deprecated = 'DEPRECATED DECISION. It no longer applies and no decision replaces it.'; rejected = 'REJECTED DECISION. It stays as a record of the discussion.' }
    UpdateOriginPullRequest = 'PR {0} of {1}'
    UpdateOriginCommit = 'commit {0} of {1}'
    Reference      = @{
        WikiRoot = 'Reference'; ModulesPage = 'Terraform modules'; ApisPage = 'APIs'; TasksPage = 'Commands'; ReleaseNotes = 'Release notes'
        Generated = 'Page generated from the code: a change made here is lost at the next generation.'
        Variables = 'Variables'; Outputs = 'Outputs'; Resources = 'Resources'; Parameters = 'Parameters'; Responses = 'Responses'
        Name = 'Name'; Type = 'Type'; Default = 'Default'; Description = 'Description'; Location = 'Location'; Code = 'Code'; Task = 'Task'
        Required = 'required'
        MissingVariable = 'the variable `{0}` of the module `{1}`'; MissingOutput = 'the output `{0}` of the module `{1}`'
        MissingEndpoint = 'the endpoint `{0}` of the API `{1}`'; MissingTask = 'the task `{0}`'
        BugTitle = 'Reference of {0}: entries without description'
        BugText = 'The reference generated from the code of {0} has entries without description. They are described in the code: the Bug is updated at every generation until the list is empty.'
    }
}