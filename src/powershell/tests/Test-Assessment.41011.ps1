<#
.SYNOPSIS
    Non-administrative accounts do not have DC-Sync (Directory Replication) permissions

.NOTES
    Test ID: 41011
    Workshop Task: SECOPS-011
    Pillar: SecOps
    Category: Identity threat protection
    Required permission: SecurityEvents.Read.All
#>

function Test-Assessment-41011 {
    [ZtTest(
        Category           = 'Identity threat protection',
        CompatibleLicense  = ('ATA'),
        ImplementationCost = 'Low',
        Pillar             = 'SecOps',
        RiskLevel          = 'High',
        Service            = ('Graph'),
        SfiPillar          = 'Protect identities and secrets',
        TenantType         = ('Workforce'),
        TestId             = 41011,
        Title              = 'Non-administrative accounts do not have DC-Sync (Directory Replication) permissions',
        UserImpact         = 'Low'
    )]
    [CmdletBinding()]
    param()

    #region Data Collection
    Write-PSFMessage '🟦 Start' -Tag Test -Level VeryVerbose

    $activity = 'Checking non-admin DC-Sync permissions'
    $title    = 'Non-administrative accounts do not have DC-Sync (Directory Replication) permissions'

    $investigateParams = @{
        TestId       = '41011'
        Title        = $title
        Status       = $false
        CustomStatus = 'Investigate'
        Result       = '⚠️ The Secure Score control profile or latest Secure Score snapshot could not be read due to a permission or connectivity error. Verify the caller has SecurityEvents.Read.All (Entra role: Security Reader) and re-run.'
    }

    # Q1: Retrieve the MDI posture control profile for non-admin DC-Sync accounts.
    # The service filter must use the legacy literal 'Azure ATP', not the human-readable display name.
    Write-ZtProgress -Activity $activity -Status 'Retrieving Secure Score control profile'

    $controlProfile = $null
    try {
        $q1Filter = "service eq 'Azure ATP' and id eq 'AATP_NonAdminDCSyncAccounts'"
        $profileResults = @(Invoke-ZtGraphRequest -RelativeUri 'security/secureScoreControlProfiles' -Filter $q1Filter -ApiVersion beta -ErrorAction Stop)
        $controlProfile = $profileResults | Select-Object -First 1
    }
    catch {
        $statusCode = Get-ZtHttpStatusCode -ErrorRecord $_
        if ($statusCode -in (401, 403)) {
            $investigateParams.Result = '⚠️ The Secure Score control profile could not be read because the request was not authorized. Verify the caller has the SecurityEvents.Read.All permission (Entra role: Security Reader) and re-run.'
            Add-ZtTestResultDetail @investigateParams
            return
        }
        Add-ZtTestResultDetail @investigateParams
        return
    }

    $latestScore = $null

    if ($null -ne $controlProfile) {
        # Q2: Retrieve the latest Secure Score snapshot to read per-control scores.
        # -DisablePaging returns the raw Graph response wrapper; unwrap .value to get the snapshot.
        Write-ZtProgress -Activity $activity -Status 'Retrieving latest Secure Score'

        try {
            $scoreResponse = Invoke-ZtGraphRequest -RelativeUri 'security/secureScores' -ApiVersion beta -Top 1 -DisablePaging -ErrorAction Stop
            $latestScore = $scoreResponse.value | Select-Object -First 1
        }
        catch {
            Add-ZtTestResultDetail @investigateParams
            return
        }
    }
    #endregion Data Collection

    #region Assessment Logic
    $passed = $false

    # Investigate: MDI posture assessment not surfaced in this tenant's Secure Score.
    if ($null -eq $controlProfile) {
        $investigateParams.Result = 'The Microsoft Defender for Identity posture recommendation for non-admin Directory Replication permissions was not found in the tenant''s Microsoft Secure Score.'
        Add-ZtTestResultDetail @investigateParams
        return
    }

    $controlId    = $controlProfile.id
    $controlTitle = $controlProfile.title
    $maxScore     = $controlProfile.maxScore
    $actionUrl    = $controlProfile.actionUrl

    # Determine the most recent control state. An empty controlStateUpdates array means Default.
    $latestStateUpdate = @(
        $controlProfile.controlStateUpdates |
            Sort-Object {
                if ($_.updatedDateTime) {
                    [datetime]$_.updatedDateTime
                }
                else {
                    [datetime]::MinValue
                }
            } -Descending |
            Select-Object -First 1
    )[0]
    $latestState = if ($null -ne $latestStateUpdate -and $null -ne $latestStateUpdate.state) {
        $latestStateUpdate.state
    }
    else {
        'Default'
    }

    # Investigate: admin has explicitly accepted risk; human confirmation is required before treating this as pass or fail.
    if ($latestState -eq 'Ignored') {
        $investigateParams.Result = 'The Microsoft Defender for Identity posture recommendation for non-admin Directory Replication permissions has been marked **Ignored** in Secure Score (risk explicitly accepted — confirm the exposed-account list in the Defender XDR portal).'
        Add-ZtTestResultDetail @investigateParams
        return
    }

    # Investigate: Secure Score snapshot unavailable after successful Q1.
    if ($null -eq $latestScore) {
        $investigateParams.Result = '⚠️ No Microsoft Secure Score snapshot was returned. Re-run after 5-10 minutes.'
        Add-ZtTestResultDetail @investigateParams
        return
    }

    # Locate the per-control score entry by matching controlName to the profile ID from Q1.
    $controlScoreEntry = @($latestScore.controlScores) | Where-Object { $_.controlName -eq $controlId } | Select-Object -First 1

    if ($null -eq $controlScoreEntry) {
        $investigateParams.Result = 'The Microsoft Defender for Identity posture recommendation for non-admin Directory Replication permissions was not found in the tenant''s Microsoft Secure Score.'
        Add-ZtTestResultDetail @investigateParams
        return
    }

    $currentScore = $controlScoreEntry.score

    if ($null -eq $currentScore -or $null -eq $maxScore) {
        $investigateParams.Result = '⚠️ The Secure Score control returned incomplete score data. Re-run the assessment and investigate if the issue persists.'
        Add-ZtTestResultDetail @investigateParams
        return
    }

    if ($currentScore -eq $maxScore) {
        $passed             = $true
        $testResultMarkdown = "✅ No non-administrative accounts hold Directory Replication permissions in monitored domains.`n`n%TestResult%"
    }
    else {
        $passed             = $false
        $testResultMarkdown = "❌ One or more non-administrative accounts hold Directory Replication permissions and can replicate domain credentials.`n`n%TestResult%"
    }
    #endregion Assessment Logic

    #region Report Generation
    $scoreDisplay        = "$currentScore / $maxScore"
    $controlStateDisplay = $latestState
    $statusDisplay       = if ($passed) { '✅ Pass' } else { '❌ Fail' }

    $defenderLink = 'https://security.microsoft.com/securescore?viewid=actions'
    $portalLine = ''
    if (-not $passed) {
        $portalLine = "`n## [Defender XDR > Secure Score > Recommendations]($defenderLink)`n"
    }

    $actionUrlMarkdown = if (-not [string]::IsNullOrWhiteSpace($actionUrl)) {
        "[Defender XDR]($actionUrl)"
    }
    else {
        '—'
    }

    $formatTemplate = @'

{0}
| Recommendation title | Current score | Maximum score | Control state | Defender XDR recommendation link | Status |
| :------------------- | :-----------: | :-----------: | :------------ | :-------------------------------- | :----: |
{1}
'@

    $tableRows = "| $(Get-SafeMarkdown $controlTitle) | $currentScore | $maxScore | $controlStateDisplay | $actionUrlMarkdown | $statusDisplay |`n"
    $mdInfo = $formatTemplate -f $portalLine, $tableRows
    $testResultMarkdown = $testResultMarkdown -replace '%TestResult%', $mdInfo
    #endregion Report Generation

    Add-ZtTestResultDetail -TestId '41011' -Title $title -Status $passed -Result $testResultMarkdown
}
