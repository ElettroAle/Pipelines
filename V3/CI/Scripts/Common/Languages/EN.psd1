# SPDX-License-Identifier: Apache-2.0

@{
    ViewMarker     = 'view'
    ApplicationTag = 'Application'
    TechnicalTag   = 'Technical'
    GeneratedTag   = 'Generated'
    CodeNameProperty = 'code'
    ExternalTag    = 'External'
    DataAccessViewSuffix = 'data-access'
    ViewTitles     = @{
        Allocation = 'Allocation · {0}'; ApplicationAllocation = 'Allocation · {0} · {1}'; Network = 'Network · {0}'; NetworkPart = 'Network · {0} · {1}'
        Containers = 'Containers of {0}'; Logic = 'logic'; DataAccess = 'data access'
    }
    ViewDescriptions = @{
        Allocation = @(
            @{ Text = 'Applications of the {0} environment: {1}.'; Lists = @('Environment', 'Shown.containerInstance') }
            @{ Text = 'Compute plans and resources hosting them: {0}.'; Lists = @('Shown.hostingPlan,Shown.application') }
            @{ Text = 'Calls between the applications: {0}.'; Lists = @('Relationships') }
        )
        ApplicationAllocation = @(
            @{ Text = 'In the {0} environment, {1} runs on {2}.'; Lists = @('Environment', 'Subject', 'Host') }
            @{ Text = 'It turns to {0}.'; Lists = @('Outgoing') }
            @{ Text = 'It receives the requests of {0}.'; Lists = @('Incoming') }
            @{ Text = 'It exchanges requests with {0}.'; Lists = @('Mutual') }
            @{ Text = 'It has no relationships with other elements of the environment.'; Lists = @('Unrelated') }
        )
        Network = @(
            @{ Text = 'Virtual networks of the {0} environment: {1}.'; Lists = @('Environment', 'Shown.virtualNetwork') }
            @{ Text = 'Entry of the public traffic: {0}.'; Lists = @('Shown.ingress') }
            @{ Text = 'Connections between the networks: {0}.'; Lists = @('Relationships') }
        )
        NetworkPart = @(
            @{ Text = 'Subnets of the network {1} in the {0} environment: {2}.'; Lists = @('Environment', 'Subject', 'Shown.subnet') }
            @{ Text = 'Applications integrated in the network: {0}.'; Lists = @('Shown.containerInstance') }
            @{ Text = 'Resources reached privately from the network: {0}.'; Lists = @('Shown.privateEndpoint') }
            @{ Text = 'It receives the traffic from {0}.'; Lists = @('Incoming') }
            @{ Text = 'It connects to {0}.'; Lists = @('Outgoing') }
            @{ Text = 'It exchanges traffic with {0}.'; Lists = @('Mutual') }
            @{ Text = 'It has no connections with other networks.'; Lists = @('Unrelated') }
        )
        Containers = @(
            @{ Text = '{0} turns to {1}.'; Lists = @('Subject', 'Outgoing') }
            @{ Text = '{0} receives the requests of {1}.'; Lists = @('Subject', 'Incoming') }
            @{ Text = '{0} exchanges requests with {1}.'; Lists = @('Subject', 'Mutual') }
            @{ Text = '{0} has no relationships with other systems.'; Lists = @('Unrelated') }
        )
        Logic = @(
            @{ Text = 'Logic components of {0}: {1}.'; Lists = @('Subject', 'Shown.logic') }
            @{ Text = 'They turn to {0}.'; Lists = @('Outgoing') }
            @{ Text = 'They receive the requests of {0}.'; Lists = @('Incoming') }
            @{ Text = 'They exchange requests with {0}.'; Lists = @('Mutual') }
            @{ Text = 'They neither turn to other elements nor receive requests from them.'; Lists = @('Unrelated') }
        )
        DataAccess = @(
            @{ Text = 'Data access components of {0}: {1}.'; Lists = @('Subject', 'Shown.dataAccess') }
            @{ Text = 'They turn to {0}.'; Lists = @('Outgoing') }
            @{ Text = 'Used by {0}.'; Lists = @('Incoming') }
            @{ Text = 'They exchange requests with {0}.'; Lists = @('Mutual') }
            @{ Text = 'They neither turn to other elements nor receive requests from them.'; Lists = @('Unrelated') }
        )
    }
    LevelSummaries = @{
        person = @{ Count = '{0} people' }
        softwareSystem = @{ Count = '{0} external systems' }
        container = @{ Count = '{0} containers' }
        logic = @{ Count = '{0} logic components'; InView = '{0} logic components described in the view {1}' }
        dataAccess = @{ Count = '{0} data access components'; InView = '{0} data access components described in the view {1}' }
        containerInstance = @{ Count = '{0} container instances' }
        region = @{ Count = '{0} regions' }
        hostingPlan = @{ Count = '{0} compute plans' }
        application = @{ Count = '{0} resources hosting applications' }
        virtualNetwork = @{ Count = '{0} virtual networks' }
        subnet = @{ Count = '{0} subnets' }
        privateEndpoint = @{ Count = '{0} private accesses' }
        gateway = @{ Count = '{0} gateways' }
        ingress = @{ Count = '{0} public entries' }
        ingressEndpoint = @{ Count = '{0} public entry points' }
    }
    ViewGroupIntroduction = @(
        @{ Text = 'The view {0} shows the whole; the views that follow take up its parts one at a time: {1}.'; Lists = @('First', 'Following') }
    )
    ViewNameFormat = '“{0}”'
    SummaryTag     = 'Summary'
    NetworkTag     = 'Network'
    NetworkRelationships = @{ Peering = 'Connects the two networks with a peering'; Origin = 'Forwards the requests to the origin'; Backend = 'Forwards the requests to the backend' }
    NetworkViewSuffix = 'network'
    NetworkEnvironmentSuffix = 'network'
    NodeDescriptions = @{
        region = @(
            @{ Text = 'Hosts {0}.'; Lists = @('Children') }
        )
        hostingPlan = @(
            @{ Text = 'Compute plan of {0}.'; Lists = @('Children') }
        )
        application = @(
            @{ Text = 'Hosts {0}.'; Lists = @('Children') }
            @{ Text = 'Receives the requests from {0}.'; Lists = @('Incoming.Backend,Incoming.Origin') }
            @{ Text = 'Sits in {0}.'; Lists = @('Parent') }
        )
        virtualNetwork = @(
            @{ Text = 'Holds the subnets {0}.'; Lists = @('Children') }
            @{ Text = 'Peered with {0}.'; Lists = @('Outgoing.Peering,Incoming.Peering') }
        )
        subnet = @(
            @{ Text = 'Hosts {0}.'; Lists = @('Children') }
            @{ Text = 'Sits in {0}.'; Lists = @('Parent') }
        )
        privateEndpoint = @(
            @{ Text = 'Private access to {0}.'; Lists = @('Exposes') }
        )
        gateway = @(
            @{ Text = 'Receives the requests from {0} and forwards them to {1}.'; Lists = @('Incoming.Origin', 'Outgoing.Backend') }
        )
        ingress = @(
            @{ Text = 'Public entry to {0}.'; Lists = @('Outgoing.Origin') }
        )
        ingressEndpoint = @(
            @{ Text = 'Receives the public traffic and forwards it to {0}.'; Lists = @('Outgoing.Origin') }
        )
    }
    ResourceGroupTable = @{ Group = 'Resource group'; Content = 'Content'; Module = 'Module' }
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
    DraftSuffix    = ' (draft)'
    DraftNotice    = 'DRAFT. The page describes the work merged into {0} and not yet in production.'
    DraftNoticeColor = 'darkorange'
    DraftLink      = 'The work merged into {0} and not yet in production changes this page:'
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