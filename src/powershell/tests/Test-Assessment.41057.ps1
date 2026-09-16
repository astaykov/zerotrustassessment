<#
.SYNOPSIS
    Exploit protection is configured and enforced via Intune.

.DESCRIPTION
    Checks legacy Windows endpoint protection profiles and Settings Catalog or Endpoint Security
    attack surface reduction policies for an assigned exploit protection configuration.

.NOTES
    Test ID: 41057
    Workshop Task ID: SECOPS-057
    Category: Endpoint threat protection
    Pillar: SecOps
    Required Module: Microsoft.Graph.Authentication
    Required Connection: Microsoft Graph
    Required Permission: DeviceManagementConfiguration.Read.All
#>

function Test-Assessment-41057 {
    [ZtTest(
        Category = 'Endpoint threat protection',
        CompatibleLicense = ('INTUNE_A'),
        ImplementationCost = 'Medium',
        Pillar = 'SecOps',
        RiskLevel = 'High',
        Service = ('Graph'),
        SfiPillar = 'Monitor and detect cyberthreats',
        TenantType = ('Workforce'),
        TestId = 41057,
        Title = 'Exploit protection is configured and enforced via Intune',
        UserImpact = 'Medium'
    )]
    [CmdletBinding()]
    param()

    #region Data Collection

    Write-PSFMessage '🟦 Start' -Tag Test -Level VeryVerbose

    $activity = 'Checking Intune exploit protection policies'
    $title = 'Exploit protection is configured and enforced via Intune'
    $evaluationResults = @()
    $hasReadError = $false

    $addSkippedResult = {
        Add-ZtTestResultDetail -SkippedBecause NotApplicable -Result 'Microsoft Graph could not read Intune configuration policies. Verify the tenant has an Intune license, DeviceManagementConfiguration.Read.All is consented, and the assessment identity has an Intune read role.'
    }

    # Q1: Enumerate all device configurations with assignments and filter legacy endpoint protection profiles locally.
    $legacyConfigurations = @()
    try {
        Write-ZtProgress -Activity $activity -Status 'Getting legacy endpoint protection profiles'
        $deviceConfigurations = @(Invoke-ZtGraphRequest -RelativeUri 'deviceManagement/deviceConfigurations?$expand=assignments' -ApiVersion beta -ErrorAction Stop)
        $legacyConfigurations = @($deviceConfigurations | Where-Object {
            [string]$_.PSObject.Properties['@odata.type'].Value -ieq '#microsoft.graph.windows10EndpointProtectionConfiguration'
        })
        Write-PSFMessage "Found $($legacyConfigurations.Count) legacy endpoint protection profiles" -Level Verbose
    }
    catch {
        $statusCode = Get-ZtHttpStatusCode -ErrorRecord $_
        if ($statusCode -in 401, 403, 404) {
            & $addSkippedResult
            return
        }

        $hasReadError = $true
        Write-PSFMessage "Failed to retrieve legacy endpoint protection profiles: $_" -Tag Test -Level Warning
    }

    foreach ($legacyConfiguration in $legacyConfigurations) {
        $xmlValue = $legacyConfiguration.defenderExploitProtectionXml
        $xmlPresent = if ($null -eq $xmlValue) {
            $false
        }
        elseif ($xmlValue -is [string]) {
            -not [string]::IsNullOrWhiteSpace($xmlValue)
        }
        elseif ($xmlValue -is [System.Array]) {
            $xmlValue.Count -gt 0
        }
        else {
            $true
        }
        $overrideBlocked = $legacyConfiguration.defenderSecurityCenterBlockExploitProtectionOverride -eq $true
        $assignmentsProperty = $legacyConfiguration.PSObject.Properties['assignments']
        if ($null -eq $assignmentsProperty -or $null -eq $assignmentsProperty.Value) {
            $hasReadError = $true
            $assignmentCount = 'Unknown'
            $status = 'Investigate'
            Write-PSFMessage "Assignments were not returned for legacy profile '$($legacyConfiguration.displayName)'" -Tag Test -Level Warning
        }
        else {
            $assignmentCount = @($legacyConfiguration.assignments | Where-Object { $null -ne $_ }).Count
            $status = if ($assignmentCount -gt 0 -and $xmlPresent -and $overrideBlocked) { 'Pass' } else { 'Fail' }
        }

        $evaluationResults += [PSCustomObject]@{
            ProfileName                 = $legacyConfiguration.displayName
            Source                      = 'legacy DEP'
            ExploitProtectionXmlPresent = $xmlPresent
            OverrideBlocked             = $overrideBlocked
            AssignmentCount             = $assignmentCount
            Status                      = $status
        }
    }

    $legacyPass = @($evaluationResults | Where-Object Status -eq 'Pass').Count -gt 0

    # Q2: Use Settings Catalog only when no compliant legacy profile was found.
    if (-not $legacyPass) {
        $asrPolicies = @()
        try {
            Write-ZtProgress -Activity $activity -Status 'Getting Settings Catalog attack surface reduction policies'
            $configurationPolicies = @(Invoke-ZtGraphRequest -RelativeUri 'deviceManagement/configurationPolicies?$expand=settings,assignments' -ApiVersion beta -ErrorAction Stop)
            $asrPolicies = @($configurationPolicies | Where-Object {
                [string]$_.templateReference.templateFamily -ieq 'endpointSecurityAttackSurfaceReduction'
            })
            Write-PSFMessage "Found $($asrPolicies.Count) Settings Catalog attack surface reduction policies" -Level Verbose
        }
        catch {
            $statusCode = Get-ZtHttpStatusCode -ErrorRecord $_
            if ($statusCode -in 401, 403, 404) {
                & $addSkippedResult
                return
            }

            $hasReadError = $true
            Write-PSFMessage "Failed to retrieve Settings Catalog policies: $_" -Tag Test -Level Warning
        }

        foreach ($policy in $asrPolicies) {
            $settingsProperty = $policy.PSObject.Properties['settings']
            $assignmentsProperty = $policy.PSObject.Properties['assignments']
            if ($null -eq $settingsProperty -or $null -eq $settingsProperty.Value -or
                $null -eq $assignmentsProperty -or $null -eq $assignmentsProperty.Value) {
                $hasReadError = $true
                Write-PSFMessage "Expanded settings or assignments were not returned for policy '$($policy.name)'" -Tag Test -Level Warning
                $evaluationResults += [PSCustomObject]@{
                    ProfileName                 = $policy.name
                    Source                      = 'Settings Catalog'
                    ExploitProtectionXmlPresent = 'Unknown'
                    OverrideBlocked             = 'N/A'
                    AssignmentCount             = 'Unknown'
                    Status                      = 'Investigate'
                }
                continue
            }

            $settings = @($policy.settings)
            $settingQueue = [System.Collections.Queue]::new()
            foreach ($setting in @($settings.settingInstance)) {
                if ($null -ne $setting) {
                    $settingQueue.Enqueue($setting)
                }
            }

            $exploitProtectionSettings = @()
            while ($settingQueue.Count -gt 0) {
                $settingInstance = $settingQueue.Dequeue()
                if ([string]$settingInstance.settingDefinitionId -match '(?i)exploitguard_exploitprotectionsettings$') {
                    $exploitProtectionSettings += $settingInstance
                }

                $children = @($settingInstance.choiceSettingValue.children)
                foreach ($collectionValue in @(
                    $settingInstance.choiceSettingCollectionValue
                    $settingInstance.simpleSettingCollectionValue
                    $settingInstance.groupSettingCollectionValue
                    $settingInstance.groupSettingValue
                )) {
                    $children += @($collectionValue.children)
                }
                foreach ($child in @($children | Where-Object { $null -ne $_ })) {
                    $settingQueue.Enqueue($child)
                }
            }

            if ($exploitProtectionSettings.Count -eq 0) {
                continue
            }

            $assignmentCount = @($policy.assignments | Where-Object { $null -ne $_ }).Count
            $status = if ($assignmentCount -gt 0) { 'Pass' } else { 'Fail' }

            $evaluationResults += [PSCustomObject]@{
                ProfileName                 = $policy.name
                Source                      = 'Settings Catalog'
                ExploitProtectionXmlPresent = $true
                OverrideBlocked             = 'N/A'
                AssignmentCount             = $assignmentCount
                Status                      = $status
            }
        }
    }

    #endregion Data Collection

    #region Assessment Logic

    $passed = @($evaluationResults | Where-Object Status -eq 'Pass').Count -gt 0
    $customStatus = $null

    if ($passed) {
        $testResultMarkdown = "✅ Exploit protection is configured and assigned in Microsoft Intune; legacy profile override is blocked where applicable.`n`n%TestResult%"
    }
    elseif ($hasReadError -or @($evaluationResults | Where-Object Status -eq 'Investigate').Count -gt 0) {
        $customStatus = 'Investigate'
        $testResultMarkdown = "⚠️ Intune exploit-protection policy data could not be fully evaluated.`n`n%TestResult%"
    }
    elseif ($evaluationResults.Count -eq 0) {
        $customStatus = 'Investigate'
        $testResultMarkdown = "⚠️ No relevant Intune profiles were located.`n`n%TestResult%"
    }
    else {
        $testResultMarkdown = "❌ Located Intune exploit-protection policies are unassigned, missing exploit-protection XML/settings, or allow legacy user override.`n`n%TestResult%"
    }

    #endregion Assessment Logic

    #region Report Generation

    if ($evaluationResults.Count -gt 0) {
        $portalUrl = 'https://intune.microsoft.com/#view/Microsoft_Intune_Workflows/SecurityManagementMenu/~/asr'
        $tableRows = @($evaluationResults | Select-Object -First 10 | ForEach-Object {
            $displayName = (Get-SafeMarkdown -Text $_.ProfileName) -replace '\|', '\\|'
            "| $displayName | $($_.Source) | $($_.ExploitProtectionXmlPresent) | $($_.OverrideBlocked) | $($_.AssignmentCount) | $($_.Status) |"
        })

        if ($evaluationResults.Count -gt 10) {
            $tableRows += "| ... | | | | | $($evaluationResults.Count) total profiles |"
        }

        $mdInfo = @"

## [Intune attack surface reduction policies]($portalUrl)

| Profile name | Source | Exploit protection XML present | Override blocked | Assignment count | Status |
| :----------- | :----- | :----------------------------- | :--------------- | ---------------: | :----- |
$($tableRows -join "`n")
"@
        $testResultMarkdown = $testResultMarkdown -replace '%TestResult%', $mdInfo
    }
    else {
        $testResultMarkdown = $testResultMarkdown -replace '\s*%TestResult%', ''
    }

    $params = @{
        TestId = '41057'
        Title  = $title
        Status = $passed
        Result = $testResultMarkdown
    }
    if ($null -ne $customStatus) {
        $params.CustomStatus = $customStatus
    }
    Add-ZtTestResultDetail @params

    #endregion Report Generation
}
