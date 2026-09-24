function Resolve-ZtRoleAssignmentPrincipal {
	[CmdletBinding()]
	param (
		[object[]]
		$Assignments,

		[Parameter(Mandatory = $true)]
		[hashtable]
		$Cache
	)

	if (-not $Assignments) {
		return
	}

	$unresolved = @{}
	foreach ($assignment in $Assignments) {
		$principal = $assignment.principal
		$principalId = if ($principal.id) { $principal.id } else { $assignment.principalId }
		if (-not $principalId -or $Cache.ContainsKey($principalId)) {
			continue
		}

		$unresolved[$principalId] = $principal.'@odata.type'
		$Cache[$principalId] = @{
			'@odata.type' = $principal.'@odata.type'
			id = $principalId
			displayName = $null
			userPrincipalName = $null
			uniqueName = $null
		}
	}

	$missingTypeIds = @($unresolved.Keys | Where-Object { -not $unresolved[$_] })
	for ($index = 0; $index -lt $missingTypeIds.Count; $index += 1000) {
		$lastIndex = [Math]::Min($index + 999, $missingTypeIds.Count - 1)
		$ids = @($missingTypeIds[$index..$lastIndex])
		$body = @{
			ids = $ids
			types = @('user', 'group', 'servicePrincipal')
		} | ConvertTo-Json -Depth 3 -Compress

		try {
			$typeResults = @(Invoke-ZtGraphRequest -RelativeUri 'directoryObjects/getByIds' -Method POST -Body $body -ApiVersion beta -OutputType Hashtable -DisableCache)
			foreach ($result in $typeResults) {
				if ($result.id -and $unresolved.ContainsKey($result.id)) {
					$unresolved[$result.id] = $result.'@odata.type'
					$Cache[$result.id]['@odata.type'] = $result.'@odata.type'
				}
			}
		}
		catch {
			Write-PSFMessage -Level Warning -Message 'Failed to resolve role principal types.' -ErrorRecord $_ -Tag Graph, Export
		}
	}

	$typeDefinitions = @(
		@{
			ODataType = '#microsoft.graph.user'
			ODataTypes = @('#microsoft.graph.user', '#microsoft.graph.agentUser')
			RelativeUri = 'users'
			Select = @('id', 'displayName', 'userPrincipalName')
		},
		@{
			ODataType = '#microsoft.graph.group'
			ODataTypes = @('#microsoft.graph.group')
			RelativeUri = 'groups'
			Select = @('id', 'displayName', 'uniqueName')
		},
		@{
			ODataType = '#microsoft.graph.servicePrincipal'
			ODataTypes = @('#microsoft.graph.servicePrincipal')
			RelativeUri = 'servicePrincipals'
			Select = @('id', 'displayName')
		}
	)

	foreach ($typeDefinition in $typeDefinitions) {
		$principalIds = @($unresolved.Keys | Where-Object { $unresolved[$_] -in $typeDefinition.ODataTypes })
		if (-not $principalIds) {
			continue
		}

		try {
			$principals = @(Invoke-ZtGraphRequest -RelativeUri $typeDefinition.RelativeUri -UniqueId $principalIds -Select $typeDefinition.Select -ApiVersion beta -OutputType Hashtable -DisableCache)
			foreach ($principal in $principals) {
				if (-not $principal.id -or -not $Cache.ContainsKey($principal.id)) {
					continue
				}

				$cachedType = $Cache[$principal.id]['@odata.type']
				$resolvedType = $principal.'@odata.type'
				if (-not $resolvedType -or ($resolvedType -eq $typeDefinition.ODataType -and $cachedType -ne $typeDefinition.ODataType)) {
					$resolvedType = $cachedType
				}
				if (-not $resolvedType) {
					$resolvedType = $typeDefinition.ODataType
				}

				$Cache[$principal.id] = @{
					'@odata.type' = $resolvedType
					id = $principal.id
					displayName = $principal.displayName
					userPrincipalName = $principal.userPrincipalName
					uniqueName = $principal.uniqueName
				}
			}
		}
		catch {
			Write-PSFMessage -Level Warning -Message 'Failed to enrich {0} role principals.' -StringValues $typeDefinition.ODataType -ErrorRecord $_ -Tag Graph, Export
		}
	}

	$unenrichedPrincipalIds = @($unresolved.Keys | Where-Object { -not $Cache[$_].displayName } | Sort-Object)
	if ($unenrichedPrincipalIds) {
		$sampleIds = @($unenrichedPrincipalIds | Select-Object -First 10) -join ', '
		Write-PSFMessage -Level Warning -Message '{0} role principals could not be enriched. Their identifiers and known types were preserved. Sample IDs: {1}' -StringValues $unenrichedPrincipalIds.Count, $sampleIds -Tag Graph, Export
	}

	foreach ($assignment in $Assignments) {
		$principalId = if ($assignment.principal.id) { $assignment.principal.id } else { $assignment.principalId }
		if (-not $principalId -or -not $Cache.ContainsKey($principalId)) {
			continue
		}

		if ($assignment -is [System.Collections.IDictionary]) {
			$assignment['principal'] = $Cache[$principalId].Clone()
		}
		else {
			$assignment.principal = [pscustomobject]$Cache[$principalId].Clone()
		}
	}
}
