<#
 .SYNOPSIS
   Helper module to run graph request that supports paging, batching and caching.

 .Description
    The version of Invoke-Graph request supports
    * Filter, Select and Unique IDs as parameters
    * Automatic paging if Graph returns a nextLink
    * Batching of requests to Graph if multiple requests are piped through
	* Item-level retries for throttled or transiently failed batch requests
    * Caching of results for the duration of the session
    * Ability to skip cache and go directly to Graph
    * Specify consistency level as a parameter
    * Additional custom headers via the Headers parameter

	POST is intended for read/query Graph endpoints. POST requests require a JSON object body,
	are not cached or batched, and can target only one endpoint per invocation.

    :::info
    Note: Batch requests don't support caching.
    :::

 .Example

    Invoke-ZtGraphRequest -RelativeUri "users" -Filter "displayName eq 'John Doe'" -Select "displayName" -Top 10

    Get all users with a display name of "John Doe" and return the first 10 results.

 .Example

	 $body = @{ Query = 'DeviceProcessEvents | limit 2' } | ConvertTo-Json -Compress
	 Invoke-ZtGraphRequest -RelativeUri 'security/runHuntingQuery' -Method POST -Body $body

	 Run a Microsoft Defender advanced hunting query. POST is intended only for Graph query endpoints.

#>
function Invoke-ZtGraphRequest {
	[CmdletBinding()]
	param(
		# Graph endpoint such as "users".
		[Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
		[string[]] $RelativeUri,
		# Specifies unique Id(s) for the URI endpoint. For example, users endpoint accepts Id or UPN.
		[Parameter(Mandatory = $false)]
		[string[]] $UniqueId = '',
		# Filters properties (columns).
		[Parameter(Mandatory = $false)]
		[string[]] $Select,
		# Filters results (rows). https://docs.microsoft.com/en-us/graph/query-parameters#filter-parameter
		[Parameter(Mandatory = $false)]
		[string] $Filter,
		# The number of items to be included in the result.
		[Parameter(Mandatory = $false)]
		[string] $Top,
		# Parameters
		[Parameter(Mandatory = $false)]
		[hashtable] $QueryParameters,
		# API Version.
		[Parameter(Mandatory = $false)]
		[ValidateSet('v1.0', 'beta')]
		[string] $ApiVersion = 'v1.0',
		# HTTP method. POST is intended for read/query endpoints.
		[Parameter(Mandatory = $false)]
		[ValidateSet('GET', 'POST')]
		[string] $Method = 'GET',
		# JSON object request body for POST requests.
		[Parameter(Mandatory = $false)]
		[string] $Body,
		# Specifies consistency level.
		[Parameter(Mandatory = $false)]
		[string] $ConsistencyLevel = 'eventual',
		# Only return first page of results.
		[Parameter(Mandatory = $false)]
		[switch] $DisablePaging,
		# Force individual requests to MS Graph.
		[Parameter(Mandatory = $false)]
		[switch] $DisableBatching,
		# Specify batch size, from 1 to the Microsoft Graph maximum of 20.
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 20)]
		[int] $BatchSize = 20,
		# Base URL for Microsoft Graph API.
		[Parameter(Mandatory = $false)]
		[uri] $GraphBaseUri,
		# Specify if this request should skip cache and go directly to Graph.
		[Parameter(Mandatory = $false)]
		[switch] $DisableCache,
		# Specify the output type
		[Parameter(Mandatory = $false)]
		[ValidateSet('PSObject', 'PSCustomObject', 'Hashtable')]
		[string] $OutputType = 'PSObject',
		# If specified, writes the raw results to disk
		[Parameter(Mandatory = $false)]
		[string] $OutputFilePath,
		# Additional headers to include in the request
		[Parameter(Mandatory = $false)]
		[hashtable] $Headers
	)

	begin {
		$batchRequests = New-Object 'System.Collections.Generic.List[psobject]'
		$postRelativeUris = New-Object 'System.Collections.Generic.List[string]'

		if ($Method -eq 'GET') {
			if ($PSBoundParameters.ContainsKey('Body')) {
				throw [System.ArgumentException]::new('-Body is only supported when -Method POST is specified.', 'Body')
			}
		}
		else {
			if ([string]::IsNullOrWhiteSpace($Body)) {
				throw [System.ArgumentException]::new('-Body is required when -Method POST is specified and must be a JSON object.', 'Body')
			}
			if (-not (Test-Json -Json $Body -ErrorAction SilentlyContinue)) {
				throw [System.ArgumentException]::new('-Body must be valid JSON.', 'Body')
			}
			try {
				$bodyObject = $Body | ConvertFrom-Json -AsHashtable -ErrorAction Stop
			}
			catch {
				throw [System.ArgumentException]::new('-Body must be a JSON object.', 'Body', $_.Exception)
			}
			if ($bodyObject -isnot [System.Collections.IDictionary]) {
				throw [System.ArgumentException]::new('-Body must be a JSON object.', 'Body')
			}
			if ($DisableBatching) {
				throw [System.ArgumentException]::new('-DisableBatching cannot be used with -Method POST because POST requests are never batched.', 'DisableBatching')
			}
			foreach ($parameterName in 'Select', 'Filter', 'Top') {
				if ($PSBoundParameters.ContainsKey($parameterName)) {
					throw [System.ArgumentException]::new("-$parameterName cannot be used with -Method POST.", $parameterName)
				}
			}
			if ($UniqueId.Count -ne 1) {
				throw [System.ArgumentException]::new('-Method POST supports exactly one resolved endpoint.', 'UniqueId')
			}
		}

		$requestHeaders = if ($Headers) { $Headers.Clone() } else { @{} }
		$requestHeaders['ConsistencyLevel'] = $ConsistencyLevel
		if ($Method -eq 'POST' -and -not $requestHeaders.ContainsKey('Content-Type')) {
			$requestHeaders['Content-Type'] = 'application/json'
		}

		$requestParam = @{
			Headers = $requestHeaders
			OutputType = $OutputType
			DisableCache = $DisableCache
			OutputFilePath = $OutputFilePath
			Method = $Method
		}
		if ($Method -eq 'POST') {
			$requestParam['Body'] = $Body
		}

		#region Utility Functions
		function Format-Result {
			[CmdletBinding()]
			param (
				$Results,

				$RawOutput
			)
			# Do nothing on null
			if (-not $Results) {
				return
			}
			if ($RawOutput) {
				return $Results
			}

			$hasValueProperty = $Results.PSObject.Properties.Name -contains "value" -or $Results.Keys -contains 'value'
			if (-not $hasValueProperty) {
				return $Results
			}

			$dataContextName = '@odata.context'
			foreach ($result in $Results.value) {
				if ($result.$dataContextName) {
					$result
					continue
				}

				if ($result -is [hashtable]) {
					$result[$dataContextName] = '{0}/$entity' -f $Results.'@odata.context'
				}
				else {
					[PSFramework.Object.ObjectHost]::AddNoteProperty($result, $dataContextName, ('{0}/$entity' -f $Results.'@odata.context'), $true)
				}
				$result
			}
		}

		function Complete-Result {
			[CmdletBinding()]
			param (
				$Results,

				$DisablePaging,

				$RequestParam
			)
			if ($DisablePaging -or -not $Results) {
				return
			}
			$pagingRequestParam = $RequestParam.Clone()
			$pagingRequestParam.Remove('Method')
			$pagingRequestParam.Remove('Body')
			$pageIndex = 1
			while ($Results.'@odata.nextLink') {
				$Results = Invoke-ZtGraphRequestCache -Method GET -Uri $results.'@odata.nextLink' @pagingRequestParam -PageIndex $pageIndex
				$pageIndex++
				Format-Result -Results $Results -RawOutput $DisablePaging
			}
		}

		function Resolve-GraphBaseUri {
			if ($GraphBaseUri) {
				return $GraphBaseUri
			}
			if (-not $script:__ZtSession.GraphBaseUri) {
				Write-PSFMessage -Message 'Setting GraphBaseUri to default value from MgContext.'
				$mgContext = Get-MgContext
				if (-not $mgContext) {
					throw 'No Microsoft Graph context found. Please connect to Microsoft Graph using Connect-ZtAssessment.'
				}

				$script:__ZtSession.GraphBaseUri = (Get-MgEnvironment -Name $mgContext.Environment).GraphEndpoint
			}

			return [uri] $script:__ZtSession.GraphBaseUri
		}

		function Invoke-GraphBatchChunk {
			[CmdletBinding()]
			param (
				[object[]]
				$Requests,

				[uri]
				$BatchUri
			)

			$pendingRequests = @($Requests)
			$responsesById = @{}
			$retryCount = 0
			$retryDelay = 3
			$maximumRetryCount = 5

			while ($pendingRequests.Count -gt 0) {
				$jsonRequests = New-Object psobject -Property @{ requests = $pendingRequests } | ConvertTo-Json -Depth 5

				$batchResult = Invoke-ZtGraphRequestCache -Method POST -Uri $BatchUri.AbsoluteUri -Body $jsonRequests -OutputType $OutputType -DisableCache:$DisableCache
				$responseLookup = @{}
				foreach ($response in @($batchResult.responses)) {
					if ($null -ne $response.id) {
						$responseLookup[[string]$response.id] = $response
					}
				}

				$retryRequests = [System.Collections.Generic.List[object]]::new()
				$retryAfterSeconds = 0
				foreach ($request in $pendingRequests) {
					$requestId = [string]$request.id
					$response = $responseLookup[$requestId]
					$status = 0
					if ($response) {
						[void][int]::TryParse([string]$response.status, [ref]$status)
					}
					$isTransientFailure = -not $response -or $status -lt 100 -or $status -eq 429 -or ($status -ge 500 -and $status -le 599)

					if ($isTransientFailure) {
						$retryRequests.Add($request)
						$currentRetryAfter = 0
						if ($status -eq 429 -and [int]::TryParse([string]$response.headers.'Retry-After', [ref]$currentRetryAfter)) {
							$retryAfterSeconds = [Math]::Max($retryAfterSeconds, $currentRetryAfter)
						}
						continue
					}

					$responsesById[$requestId] = $response
				}

				if ($retryRequests.Count -eq 0) {
					break
				}
				if ($retryCount -ge $maximumRetryCount) {
					throw "Graph batch contained $($retryRequests.Count) item-level transient failures after $($maximumRetryCount + 1) attempts."
				}

				$waitSeconds = [Math]::Max($retryDelay, $retryAfterSeconds)
				Write-PSFMessage -Level Warning -Message 'Graph batch contained {0} transient item failures. Retrying those items in {1} seconds.' -StringValues $retryRequests.Count, $waitSeconds -Tag Graph, Retry
				Start-Sleep -Seconds $waitSeconds
				$pendingRequests = @($retryRequests)
				$retryCount++
				$retryDelay *= 2
			}

			foreach ($request in $Requests) {
				$response = $responsesById[[string]$request.id]
				Format-Result -Results $response.body -RawOutput $DisablePaging
				Complete-Result -Results $response.body -DisablePaging $DisablePaging -RequestParam $requestParam
			}
		}

		function Invoke-ResolvedGraphRequest {
			param(
				[string[]] $Uris
			)

			$resolvedGraphBaseUri = Resolve-GraphBaseUri
			if ($DisableBatching -and ($Uris.Count -gt 1 -or $UniqueId.Count -gt 1)) {
				Write-Warning ('This command is invoking {0} individual Graph requests. For better performance, remove the -DisableBatching parameter.' -f ($Uris.Count * $UniqueId.Count))
			}
			$doBatch = ($Method -eq 'GET') -and -not $DisableBatching -and ($Uris.Count -gt 1 -or $UniqueId.Count -gt 1)

			foreach ($uri in $Uris) {
				$uriQueryEndpoint = [System.UriBuilder]::new([IO.Path]::Combine($resolvedGraphBaseUri.AbsoluteUri, $ApiVersion, $uri))

				#region Process Uri & Query
				if ($uriQueryEndpoint.Query) {
					$finalQueryParameters = ConvertFrom-QueryString -InputStrings $uriQueryEndpoint.Query -AsHashtable
					if ($QueryParameters) {
						foreach ($ParameterName in $QueryParameters.Keys) {
							$finalQueryParameters[$ParameterName] = $QueryParameters[$ParameterName]
						}
					}
				}
				elseif ($QueryParameters) {
					$finalQueryParameters = $QueryParameters
				}
				else {
					$finalQueryParameters = @{ }
				}
				if ($Select) {
					$finalQueryParameters['$select'] = $Select -join ','
				}
				if ($Filter) {
					$finalQueryParameters['$filter'] = $Filter
				}
				if ($Top) {
					$finalQueryParameters['$top'] = $Top
				}
				$uriQueryEndpoint.Query = ConvertTo-QueryString $finalQueryParameters
				#endregion Process Uri & Query

				foreach ($id in $UniqueId) {
					$uriQueryEndpointFinal = New-Object System.UriBuilder -ArgumentList $uriQueryEndpoint.Uri
					$uriQueryEndpointFinal.Path = ([IO.Path]::Combine($uriQueryEndpointFinal.Path, $id))

					if ($doBatch) {
						$batchHeaders = if ($Headers) { $Headers.Clone() } else { @{} }
						$batchHeaders['ConsistencyLevel'] = $ConsistencyLevel

						$request = [PSCustomObject]@{
							id      = $batchRequests.Count
							method  = 'GET'
							url     = $uriQueryEndpointFinal.Uri.AbsoluteUri -replace ('{0}{1}/' -f $resolvedGraphBaseUri.AbsoluteUri, $ApiVersion)
							headers = $batchHeaders
						}
						$batchRequests.Add($request)
					}
					else {
						$results = Invoke-ZtGraphRequestCache -Uri $uriQueryEndpointFinal.Uri.AbsoluteUri @requestParam

						Format-Result -Results $results -RawOutput $DisablePaging
						Complete-Result -Results $results -DisablePaging $DisablePaging -RequestParam $requestParam
					}
				}
			}
		}
		#endregion Utility Functions
	}

	process {
		if ($Method -eq 'POST') {
			foreach ($uri in $RelativeUri) {
				$postRelativeUris.Add($uri)
			}
			return
		}

		Invoke-ResolvedGraphRequest -Uris $RelativeUri
	}

	end {
		if ($Method -eq 'POST') {
			if ($postRelativeUris.Count -ne 1) {
				throw [System.ArgumentException]::new('-Method POST supports exactly one resolved endpoint.', 'RelativeUri')
			}
			Invoke-ResolvedGraphRequest -Uris $postRelativeUris.ToArray()
		}

		if ($batchRequests.Count -lt 1) {
			return
		}

		$resolvedGraphBaseUri = Resolve-GraphBaseUri
		$uriQueryEndpoint = [System.UriBuilder]::new([IO.Path]::Combine($resolvedGraphBaseUri.AbsoluteUri, $ApiVersion, '$batch'))
		for ($iRequest = 0; $iRequest -lt $batchRequests.Count; $iRequest += $BatchSize) {
			$indexEnd = [System.Math]::Min($iRequest + $BatchSize - 1, $batchRequests.Count - 1)
			Invoke-GraphBatchChunk -Requests @($batchRequests[$iRequest..$indexEnd]) -BatchUri $uriQueryEndpoint.Uri
		}
	}
}
