<#
.SYNOPSIS
    Enhanced Filtering for Connectors is configured for inbound connectors that route through a third-party email solution.

.NOTES
    Test ID: 41028
    Workshop Task: SECOPS-028
    Pillar: SecOps
    Category: Email and collaboration security
    Required Module: ExchangeOnlineManagement
#>

function Test-Assessment-41028 {
    [ZtTest(
        Category           = 'Email and collaboration security',
        CompatibleLicense  = ('EXCHANGE_S_ENTERPRISE'), # update all aplicable SPs here
        ImplementationCost = 'Low',
        Pillar             = 'SecOps',
        RiskLevel          = 'High',
        Service            = ('ExchangeOnline'),
        SfiPillar          = 'Protect tenants and isolate production systems',
        TenantType         = ('Workforce'),
        TestId             = 41028,
        Title              = 'Enhanced Filtering for Connectors is configured for inbound connectors that route through a third-party email solution',
        UserImpact         = 'Low'
    )]
    [CmdletBinding()]
    param()

    $testId = '41028'
    $title  = 'Enhanced Filtering for Connectors is configured for inbound connectors that route through a third-party email solution'

    #region Data Collection
    Write-PSFMessage '🟦 Start' -Tag Test -Level VeryVerbose

    $activity = 'Checking Enhanced Filtering for Connectors configuration'
    Write-ZtProgress -Activity $activity -Status 'Retrieving inbound connectors'

    $connectors = $null
    try {
        $connectors = @(Get-InboundConnector -ErrorAction Stop |
            Select-Object Identity, ConnectorType, Enabled, EFSkipLastIP, EFSkipIPs,
                          EFSkipMailGateway, EFUsers, EFTestMode)
    }
    catch {
        Write-PSFMessage "Failed to retrieve inbound connectors: $_" -Tag Test -Level Warning
        $params = @{
            TestId       = $testId
            Title        = $title
            Status       = $false
            Result       = '⚠️ Inbound connectors could not be retrieved; verify Exchange Online permissions and re-run.'
            CustomStatus = 'Investigate'
        }
        Add-ZtTestResultDetail @params
        return
    }
    #endregion Data Collection

    #region Assessment Logic
    if ($connectors.Count -eq 0) {
        $params = @{
            TestId         = $testId
            Title          = $title
            Status         = $true
            Result         = 'The tenant has no third-party email path declared.'
            SkippedBecause = 'NotApplicable'
        }
        Add-ZtTestResultDetail @params
        return
    }

    $evaluatedConnectors = @($connectors | Where-Object {
        $_.Enabled -eq $true -and $_.ConnectorType -in @('OnPremises', 'Partner')
    })

    if ($evaluatedConnectors.Count -eq 0) {
        $params = @{
            TestId         = $testId
            Title          = $title
            Status         = $true
            Result         = 'The tenant has no third-party email path declared.'
            SkippedBecause = 'NotApplicable'
        }
        Add-ZtTestResultDetail @params
        return
    }

    $rows = foreach ($connector in $evaluatedConnectors) {
        $skipIps = @($connector.EFSkipIPs | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_)
        })
        $skipMailGateways = @($connector.EFSkipMailGateway | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_)
        })
        $restrictedUsers = @($connector.EFUsers | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_)
        })

        $hasEnhancedFiltering = ($connector.EFSkipLastIP -eq $true) -or
            ($skipIps.Count -gt 0) -or
            ($skipMailGateways.Count -gt 0)

        $rowResult = if (-not $hasEnhancedFiltering -or $connector.EFTestMode -ne $false) {
            'Fail'
        }
        elseif ($restrictedUsers.Count -gt 0) {
            'Investigate'
        }
        else {
            'Pass'
        }

        [PSCustomObject]@{
            Identity             = $connector.Identity
            ConnectorType        = $connector.ConnectorType
            Enabled              = $connector.Enabled
            SkipLastIP           = $connector.EFSkipLastIP
            SkipIPsCount         = $skipIps.Count
            SkipMailGatewayCount = $skipMailGateways.Count
            TestMode             = $connector.EFTestMode
            RestrictedUsersCount = $restrictedUsers.Count
            RowResult            = $rowResult
        }
    }
    $rows = @($rows)

    $failedRows      = @($rows | Where-Object RowResult -eq 'Fail')
    $investigateRows = @($rows | Where-Object RowResult -eq 'Investigate')

    if ($failedRows.Count -gt 0) {
        $passed             = $false
        $customStatus       = $null
        $testResultMarkdown = @'
❌ One or more enabled inbound connectors lack Enhanced Filtering, are in test mode, or are restricted to a subset of users; Defender for Office 365 IP-based filtering is bypassed for traffic on those connectors.

%TestResult%
'@
    }
    elseif ($investigateRows.Count -gt 0) {
        $passed             = $false
        $customStatus       = 'Investigate'
        $testResultMarkdown = @'
⚠️ Enhanced Filtering is partially configured (for example, `EFUsers` restricts the scope) — confirm whether this is intentional pilot scope.

%TestResult%
'@
    }
    else {
        $passed             = $true
        $customStatus       = $null
        $testResultMarkdown = @'
✅ Enhanced Filtering for Connectors is configured on all enabled inbound connectors that receive mail from a third-party email gateway, and is enforcing (not in test mode) for all recipients.

%TestResult%
'@
    }
    #endregion Assessment Logic

    #region Report Generation
    $maxDisplay = 10
    $tableRows  = [System.Text.StringBuilder]::new()
    foreach ($row in ($rows | Select-Object -First $maxDisplay)) {
        $identity = Get-SafeMarkdown -Text ([string]$row.Identity)
        $result   = switch ($row.RowResult) {
            'Pass'        { '✅ Pass' }
            'Fail'        { '❌ Fail' }
            'Investigate' { '⚠️ Investigate' }
        }
        [void]$tableRows.AppendLine("| $identity | $($row.ConnectorType) | $($row.Enabled) | $($row.SkipLastIP) | $($row.SkipIPsCount) | $($row.SkipMailGatewayCount) | $($row.TestMode) | $($row.RestrictedUsersCount) | $result |")
    }

    if ($rows.Count -gt $maxDisplay) {
        [void]$tableRows.AppendLine('| ... | ... | ... | ... | ... | ... | ... | ... | ... |')
    }

    $connectorsUrl = 'https://admin.exchange.microsoft.com/#/connectors'
    $tableIntro = if ($rows.Count -gt $maxDisplay) {
        "Showing the first $maxDisplay of $($rows.Count) evaluated connectors. [View all connectors in the Exchange admin center]($connectorsUrl)`n`n"
    }
    else {
        ''
    }

    $table = @"
${tableIntro}| Identity | Connector type | Enabled | Skip last IP | Skip IPs (count) | Skip mail gateway (count) | Test mode | Restricted users (count) | Result |
| :-------- | :------------- | :------ | :------------ | :---------------- | :------------------------ | :--------- | :------------------------ | :----- |
$($tableRows.ToString())
"@

    $params = @{
        TestId = $testId
        Title  = $title
        Status = $passed
        Result = $testResultMarkdown -replace '%TestResult%', $table
    }
    if ($customStatus) {
        $params.CustomStatus = $customStatus
    }
    Add-ZtTestResultDetail @params
    #endregion Report Generation
}
