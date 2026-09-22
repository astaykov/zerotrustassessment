Describe "Export-ZtGraphEntity" {
    # Regression tests for the Add-GraphProperty guard:
    #
    #   Fix: Guard in Add-GraphProperty skips the batch call when Graph returns an empty page.
    #     if (-not $Results) { return }
    #
    #   Without this guard, passing @() to Invoke-ZtGraphBatchRequest -ArgumentList caused:
    #     "Cannot bind argument to parameter 'ArgumentList' because it is an empty array."

    BeforeAll {
        $srcRoot = Join-Path $PSScriptRoot "../../src/powershell"
        if (-not (Get-Module ZeroTrustAssessment -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $srcRoot "ZeroTrustAssessment.psd1") -Global 3>$null
            Import-Module (Join-Path $srcRoot "ZeroTrustAssessment.psm1") -Global -Force 3>$null
        }
        if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) {
            function global:Get-MgContext {}
        }
    }

    Context "Add-GraphProperty — guard skips batch when page is empty" {
        BeforeAll {
            $script:exportPath = Join-Path $env:TEMP "zt-test-graphentity-$(Get-Random)"
            New-Item -ItemType Directory -Path $script:exportPath -Force | Out-Null
        }

        AfterAll {
            Remove-Item $script:exportPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        BeforeEach {
            Mock -ModuleName ZeroTrustAssessment Get-ZtConfig            { return $false }
            Mock -ModuleName ZeroTrustAssessment Set-ZtConfig            {}
            Mock -ModuleName ZeroTrustAssessment Update-ZtProgressState  {}
            Mock -ModuleName ZeroTrustAssessment Get-PSFConfigValue      { return 1073741824 }
        }

        It "Does not throw when Graph API returns an empty page" {
            # Invoke-ZtRetry returns { "value": [] } — same as the customer tenant.
            # The guard must return early without calling Invoke-ZtGraphBatchRequest.
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtRetry { return @{ value = @() } }
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtGraphBatchRequest {
                throw "Guard missing — called with empty ArgumentList"
            }

            {
                Export-ZtGraphEntity -Name 'ServicePrincipal' -Uri 'beta/servicePrincipals' `
                    -QueryString '$top=999' -RelatedPropertyNames @('oauth2PermissionGrants') `
                    -ExportPath $script:exportPath
            } | Should -Not -Throw
        }

        It "Invoke-ZtGraphBatchRequest is not called when the page is empty" {
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtRetry { return @{ value = @() } }
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtGraphBatchRequest {}

            Export-ZtGraphEntity -Name 'ServicePrincipal' -Uri 'beta/servicePrincipals' `
                -QueryString '$top=999' -RelatedPropertyNames @('oauth2PermissionGrants') `
                -ExportPath $script:exportPath

            Should -Invoke -ModuleName ZeroTrustAssessment -CommandName Invoke-ZtGraphBatchRequest -Times 0 -Exactly
        }

        It "Does not throw when Invoke-ZtRetry returns null" {
            # $null is distinct from @() — guard must handle both without calling Invoke-ZtGraphBatchRequest.
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtRetry { return $null }
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtGraphBatchRequest {
                throw "Guard missing — called with null Results"
            }

            {
                Export-ZtGraphEntity -Name 'ServicePrincipal' -Uri 'beta/servicePrincipals' `
                    -QueryString '$top=999' -RelatedPropertyNames @('oauth2PermissionGrants') `
                    -ExportPath $script:exportPath
            } | Should -Not -Throw
        }

        It "Invoke-ZtGraphBatchRequest is not called when Invoke-ZtRetry returns null" {
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtRetry { return $null }
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtGraphBatchRequest {}

            Export-ZtGraphEntity -Name 'ServicePrincipal' -Uri 'beta/servicePrincipals' `
                -QueryString '$top=999' -RelatedPropertyNames @('oauth2PermissionGrants') `
                -ExportPath $script:exportPath

            Should -Invoke -ModuleName ZeroTrustAssessment -CommandName Invoke-ZtGraphBatchRequest -Times 0 -Exactly
        }

        It "Invoke-ZtGraphBatchRequest is called once when the page has items" {
            # Verifies the guard does not suppress normal (non-empty) pages and correctly
            # skips the batch call on an empty second page.
            # The first page must include '@odata.nextLink' so the do-while loop makes a
            # second call; without it the loop breaks immediately and the second branch
            # of the mock is never reached.
            $script:call = 0
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtRetry {
                $script:call++
                if ($script:call -eq 1) {
                    return @{
                        value             = @(@{ id = 'sp-1'; displayName = 'TestSP' })
                        '@odata.nextLink' = 'https://graph.microsoft.com/beta/servicePrincipals?$skiptoken=abc'
                    }
                }
                return @{ value = @() }
            }
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtGraphBatchRequest { return @() }

            Export-ZtGraphEntity -Name 'ServicePrincipal' -Uri 'beta/servicePrincipals' `
                -QueryString '$top=999' -RelatedPropertyNames @('oauth2PermissionGrants') `
                -ExportPath $script:exportPath

            Should -Invoke -ModuleName ZeroTrustAssessment -CommandName Invoke-ZtGraphBatchRequest -Times 1 -Exactly
        }

        It "Uses related-property query options while preserving the result property name" {
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtRetry {
                return @{ value = @(@{ id = 'app-1'; displayName = 'Test application' }) }
            }
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtGraphBatchRequest {
                param($Path, $ArgumentList)

                $script:relatedPropertyPath = $Path
                return @([pscustomobject]@{
                    Success = $true
                    Argument = $ArgumentList[0]
                    Result = @(@{ id = 'owner-1'; displayName = 'Test owner' })
                })
            }

            Export-ZtGraphEntity -Name 'Application' -Uri 'beta/applications' `
                -QueryString '$top=999' -RelatedPropertyNames @('owners?$select=id,displayName') `
                -ExportPath $script:exportPath

            $script:relatedPropertyPath | Should -Be 'beta/applications/{0}/owners?$select=id,displayName'
            $exportedApplication = Get-Content (Join-Path $script:exportPath 'Application/Application-0.json') -Raw | ConvertFrom-Json
            $exportedApplication.value[0].owners[0].id | Should -Be 'owner-1'
        }
    }

    Context "Role principal enrichment" {
        BeforeAll {
            $script:roleExportPath = Join-Path $env:TEMP "zt-test-role-principal-$(Get-Random)"
            New-Item -ItemType Directory -Path $script:roleExportPath -Force | Out-Null
        }

        AfterAll {
            Remove-Item $script:roleExportPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        BeforeEach {
            Mock -ModuleName ZeroTrustAssessment Get-ZtConfig            { return $false }
            Mock -ModuleName ZeroTrustAssessment Set-ZtConfig            {}
            Mock -ModuleName ZeroTrustAssessment Update-ZtProgressState  {}
            Mock -ModuleName ZeroTrustAssessment Get-PSFConfigValue      { return 1073741824 }
        }

        It "Enriches each supported principal type and persists a scalar minimal object" {
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtRetry {
                return @{ value = @(
                    @{ id = 'assignment-user'; principalId = 'user-1'; principal = @{ id = 'user-1'; '@odata.type' = '#microsoft.graph.user' } }
                    @{ id = 'assignment-group'; principalId = 'group-1'; principal = @{ id = 'group-1'; '@odata.type' = '#microsoft.graph.group' } }
                    @{ id = 'assignment-sp'; principalId = 'sp-1'; principal = @{ id = 'sp-1'; '@odata.type' = '#microsoft.graph.servicePrincipal' } }
                ) }
            }
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtGraphRequest {
                param($RelativeUri)
                switch ($RelativeUri) {
                    'users' { return @{ id = 'user-1'; displayName = 'Test User'; userPrincipalName = 'user@contoso.com' } }
                    'groups' { return @{ id = 'group-1'; displayName = 'Test Group'; uniqueName = 'group@contoso.com' } }
                    'servicePrincipals' { return @{ id = 'sp-1'; displayName = 'Test App' } }
                }
            }

            Export-ZtGraphEntity -Name 'RoleAssignmentScheduleInstance' `
                -Uri 'beta/roleManagement/directory/roleAssignmentScheduleInstances' `
                -QueryString '$expand=principal($select=id)' -ResolveRolePrincipals `
                -ExportPath $script:roleExportPath

            $export = Get-Content (Join-Path $script:roleExportPath 'RoleAssignmentScheduleInstance/RoleAssignmentScheduleInstance-0.json') -Raw | ConvertFrom-Json
            $export.value[0].principal | Should -BeOfType PSCustomObject
            @($export.value[0].principal.PSObject.Properties.Name) | Should -HaveCount 5
            $export.value[0].principal.userPrincipalName | Should -Be 'user@contoso.com'
            $export.value[1].principal.uniqueName | Should -Be 'group@contoso.com'
            $export.value[2].principal.displayName | Should -Be 'Test App'
            $export.value[2].principal.'@odata.type' | Should -Be '#microsoft.graph.servicePrincipal'
        }

        It "Fetches a repeated principal only once across pages" {
            $script:rolePage = 0
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtRetry {
                $script:rolePage++
                if ($script:rolePage -eq 1) {
                    return @{
                        value = @(@{ id = 'assignment-1'; principalId = 'user-1'; principal = @{ id = 'user-1'; '@odata.type' = '#microsoft.graph.user' } })
                        '@odata.nextLink' = 'https://graph.microsoft.com/beta/roleManagement/directory/roleAssignmentScheduleInstances?$skiptoken=next'
                    }
                }
                return @{ value = @(@{ id = 'assignment-2'; principalId = 'user-1'; principal = @{ id = 'user-1'; '@odata.type' = '#microsoft.graph.user' } }) }
            }
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtGraphRequest {
                return @{ id = 'user-1'; displayName = 'Test User'; userPrincipalName = 'user@contoso.com' }
            }

            Export-ZtGraphEntity -Name 'RoleAssignmentScheduleInstance' `
                -Uri 'beta/roleManagement/directory/roleAssignmentScheduleInstances' `
                -QueryString '$expand=principal($select=id)' -ResolveRolePrincipals `
                -ExportPath $script:roleExportPath

            Should -Invoke -ModuleName ZeroTrustAssessment -CommandName Invoke-ZtGraphRequest -Times 1 -Exactly -ParameterFilter { $RelativeUri -eq 'users' }
            $secondPage = Get-Content (Join-Path $script:roleExportPath 'RoleAssignmentScheduleInstance/RoleAssignmentScheduleInstance-1.json') -Raw | ConvertFrom-Json
            $secondPage.value[0].principal.displayName | Should -Be 'Test User'
        }

        It "Resolves a missing principal type before querying the typed endpoint" {
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtRetry {
                return @{ value = @(@{ id = 'assignment-1'; principalId = 'user-1'; principal = @{ id = 'user-1' } }) }
            }
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtGraphRequest {
                param($RelativeUri, $Method)
                if ($Method -eq 'POST') {
                    return @{ id = 'user-1'; '@odata.type' = '#microsoft.graph.user' }
                }
                return @{ id = 'user-1'; displayName = 'Test User'; userPrincipalName = 'user@contoso.com' }
            }

            Export-ZtGraphEntity -Name 'RoleEligibilityScheduleInstance' `
                -Uri 'beta/roleManagement/directory/roleEligibilityScheduleInstances' `
                -QueryString '$expand=principal($select=id)' -ResolveRolePrincipals `
                -ExportPath $script:roleExportPath

            Should -Invoke -ModuleName ZeroTrustAssessment -CommandName Invoke-ZtGraphRequest -Times 1 -Exactly -ParameterFilter { $RelativeUri -eq 'directoryObjects/getByIds' -and $Method -eq 'POST' }
            Should -Invoke -ModuleName ZeroTrustAssessment -CommandName Invoke-ZtGraphRequest -Times 1 -Exactly -ParameterFilter { $RelativeUri -eq 'users' }
            $export = Get-Content (Join-Path $script:roleExportPath 'RoleEligibilityScheduleInstance/RoleEligibilityScheduleInstance-0.json') -Raw | ConvertFrom-Json
            $export.value[0].principal.'@odata.type' | Should -Be '#microsoft.graph.user'
        }

        It "Preserves the identifier and type when a principal cannot be enriched" {
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtRetry {
                return @{ value = @(@{ id = 'assignment-1'; principalId = 'deleted-user'; principal = @{ id = 'deleted-user'; '@odata.type' = '#microsoft.graph.user' } }) }
            }
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtGraphRequest { return @() }

            Export-ZtGraphEntity -Name 'RoleEligibilityScheduleInstance' `
                -Uri 'beta/roleManagement/directory/roleEligibilityScheduleInstances' `
                -QueryString '$expand=principal($select=id)' -ResolveRolePrincipals `
                -ExportPath $script:roleExportPath

            $export = Get-Content (Join-Path $script:roleExportPath 'RoleEligibilityScheduleInstance/RoleEligibilityScheduleInstance-0.json') -Raw | ConvertFrom-Json
            $export.value[0].principal.id | Should -Be 'deleted-user'
            $export.value[0].principal.'@odata.type' | Should -Be '#microsoft.graph.user'
            $export.value[0].principal.displayName | Should -BeNullOrEmpty
        }

        It "Preserves principalId when the expanded principal is null" {
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtRetry {
                return @{ value = @(@{ id = 'assignment-1'; principalId = 'deleted-user'; principal = $null }) }
            }
            Mock -ModuleName ZeroTrustAssessment Invoke-ZtGraphRequest { return @() }

            Export-ZtGraphEntity -Name 'RoleEligibilityScheduleInstance' `
                -Uri 'beta/roleManagement/directory/roleEligibilityScheduleInstances' `
                -QueryString '$expand=principal($select=id)' -ResolveRolePrincipals `
                -ExportPath $script:roleExportPath

            $export = Get-Content (Join-Path $script:roleExportPath 'RoleEligibilityScheduleInstance/RoleEligibilityScheduleInstance-0.json') -Raw | ConvertFrom-Json
            $export.value[0].principal.id | Should -Be 'deleted-user'
            $export.value[0].principal.'@odata.type' | Should -BeNullOrEmpty
        }
    }
}
