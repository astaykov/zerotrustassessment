Describe 'Invoke-ZtGraphRequest POST support' {
	BeforeAll {
		$srcRoot = Join-Path $PSScriptRoot '../../src/powershell'

		function global:Write-PSFMessage { param($Message, $Level, $Tag) }
		function global:Get-ObjectProperty {
			param($InputObjects, $Property)
			$InputObjects.PSObject.Properties[$Property].Value
		}
		function global:Invoke-ZtGraphRequestCache {
			param($Method, [uri]$Uri, $Headers, $Body, $OutputType, $DisableCache, $OutputFilePath, $PageIndex)
		}
		function global:ConvertTo-QueryString { param($InputObject) return $null }
		function global:ConvertFrom-QueryString { param($InputStrings, $AsHashtable) return @{} }
		function global:Get-MgContext { throw 'Graph context should not be resolved for validation failures.' }
		function global:Get-MgEnvironment { param($Name) throw 'Graph environment should not be resolved for validation failures.' }

		. (Join-Path $srcRoot 'public/Invoke-ZtGraphRequest.ps1')
	}

	BeforeEach {
		$script:requests = [System.Collections.Generic.List[hashtable]]::new()
		Mock Invoke-ZtGraphRequestCache {
			param($Method, $Uri, $Headers, $Body, $OutputType, $DisableCache, $OutputFilePath, $PageIndex)
			$script:requests.Add(@{
				Method = $Method
				Uri = $Uri
				Headers = $Headers
				Body = $Body
				PageIndex = $PageIndex
			})
			[pscustomobject]@{ result = 'success' }
		}
	}

	It 'forwards a valid POST body and adds the JSON content type' {
		$body = '{"Query":"DeviceProcessEvents | limit 2"}'
		$result = Invoke-ZtGraphRequest -RelativeUri 'security/runHuntingQuery' -Method POST -Body $body -GraphBaseUri 'https://graph.microsoft.com/'

		$result.result | Should -Be 'success'
		$script:requests | Should -HaveCount 1
		$script:requests[0].Method | Should -Be 'POST'
		$script:requests[0].Body | Should -Be $body
		$script:requests[0].Headers['Content-Type'] | Should -Be 'application/json'
	}

	It 'preserves a caller supplied content type for POST' {
		Invoke-ZtGraphRequest -RelativeUri 'security/runHuntingQuery' -Method POST -Body '{}' -Headers @{ 'Content-Type' = 'application/json; charset=utf-8' } -GraphBaseUri 'https://graph.microsoft.com/' | Out-Null

		$script:requests[0].Headers['Content-Type'] | Should -Be 'application/json; charset=utf-8'
	}

	It 'rejects a missing POST body before resolving Graph context' {
		{ Invoke-ZtGraphRequest -RelativeUri 'security/runHuntingQuery' -Method POST } | Should -Throw '*-Body is required*'
	}

	It 'rejects a non-object POST body before resolving Graph context' {
		{ Invoke-ZtGraphRequest -RelativeUri 'security/runHuntingQuery' -Method POST -Body '[]' } | Should -Throw '*JSON object*'
	}

	It 'rejects a body with GET before resolving Graph context' {
		{ Invoke-ZtGraphRequest -RelativeUri 'users' -Body '{}' } | Should -Throw '*only supported when -Method POST*'
	}

	It 'rejects POST-only incompatible parameters' {
		{ Invoke-ZtGraphRequest -RelativeUri 'security/runHuntingQuery' -Method POST -Body '{}' -DisableBatching } | Should -Throw '*DisableBatching*'
		{ Invoke-ZtGraphRequest -RelativeUri 'security/runHuntingQuery' -Method POST -Body '{}' -Select 'id' } | Should -Throw '*Select*'
		{ Invoke-ZtGraphRequest -RelativeUri 'security/runHuntingQuery' -Method POST -Body '{}' -Filter 'id ne null' } | Should -Throw '*Filter*'
		{ Invoke-ZtGraphRequest -RelativeUri 'security/runHuntingQuery' -Method POST -Body '{}' -Top 1 } | Should -Throw '*Top*'
	}

	It 'rejects multiple POST pipeline endpoints without issuing a request' {
		{ @('security/runHuntingQuery', 'directoryObjects/getByIds') | Invoke-ZtGraphRequest -Method POST -Body '{}' -GraphBaseUri 'https://graph.microsoft.com/' } | Should -Throw '*exactly one resolved endpoint*'
		Should -Invoke Invoke-ZtGraphRequestCache -Times 0 -Exactly
	}

	It 'uses GET without a body for a POST continuation link' {
		$script:callNumber = 0
		Mock Invoke-ZtGraphRequestCache {
			param($Method, $Uri, $Headers, $Body, $OutputType, $DisableCache, $OutputFilePath, $PageIndex)
			$script:requests.Add(@{ Method = $Method; Uri = $Uri; Body = $Body; PageIndex = $PageIndex })
			$script:callNumber++
			if ($script:callNumber -eq 1) {
				return [pscustomobject]@{ '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/security/runHuntingQuery?page=2'; result = 'first' }
			}
			return [pscustomobject]@{ result = 'second' }
		}

		$result = Invoke-ZtGraphRequest -RelativeUri 'security/runHuntingQuery' -Method POST -Body '{}' -GraphBaseUri 'https://graph.microsoft.com/'

		$result.result | Should -Be @('first', 'second')
		$script:requests | Should -HaveCount 2
		$script:requests[0].Method | Should -Be 'POST'
		$script:requests[0].Body | Should -Be '{}'
		$script:requests[1].Method | Should -Be 'GET'
		$script:requests[1].Body | Should -BeNullOrEmpty
		$script:requests[1].PageIndex | Should -Be 1
	}

	It 'uses the session-resolved Graph endpoint for GET batch requests' {
		$script:__ZtSession = [pscustomobject]@{ GraphBaseUri = $null }
		Mock Get-MgContext { [pscustomobject]@{ Environment = 'Global' } }
		Mock Get-MgEnvironment { [pscustomobject]@{ GraphEndpoint = 'https://graph.microsoft.com/' } }
		Mock Invoke-ZtGraphRequestCache {
			param($Method, $Uri, $Body)
			$script:requests.Add(@{ Method = $Method; Uri = $Uri; Body = $Body })
			$batch = $Body | ConvertFrom-Json
			[pscustomobject]@{ responses = @($batch.requests | ForEach-Object {
				[pscustomobject]@{ id = $_.id; status = 200; body = [pscustomobject]@{ id = $_.url } }
			}) }
		}

		Invoke-ZtGraphRequest -RelativeUri @('users', 'groups') | Out-Null

		$script:requests | Should -HaveCount 1
		$script:requests[0].Method | Should -Be 'POST'
		$script:requests[0].Uri.AbsoluteUri | Should -Be 'https://graph.microsoft.com/v1.0/$batch'
		Should -Invoke Get-MgContext -Times 1 -Exactly
		Should -Invoke Get-MgEnvironment -Times 1 -Exactly
	}

	It 'retries only a throttled item from an otherwise successful batch' {
		$script:batchCall = 0
		$script:sleepSeconds = $null
		Mock Start-Sleep { param($Seconds) $script:sleepSeconds = $Seconds }
		Mock Invoke-ZtGraphRequestCache {
			param($Method, $Uri, $Body)
			$script:requests.Add(@{ Method = $Method; Uri = $Uri; Body = $Body })
			$script:batchCall++
			if ($script:batchCall -eq 1) {
				return @{ responses = @(
					@{ id = '0'; status = 200; body = @{ id = 'group-1'; displayName = 'Group One' } }
					@{ id = '1'; status = 429; headers = @{ 'Retry-After' = '7' }; body = @{ error = @{ code = 'TooManyRequests' } } }
				) }
			}
			return @{ responses = @(
				@{ id = '1'; status = 200; body = @{ id = 'group-2'; displayName = 'Group Two' } }
			) }
		}

		$result = @(Invoke-ZtGraphRequest -RelativeUri 'groups' -UniqueId @('group-1', 'group-2') -GraphBaseUri 'https://graph.microsoft.com/' -OutputType Hashtable)

		$result.id | Should -Be @('group-1', 'group-2')
		$script:requests | Should -HaveCount 2
		(($script:requests[1].Body | ConvertFrom-Json).requests.id) | Should -Be '1'
		$script:sleepSeconds | Should -Be 7
	}

	It 'retries an item-level server error with exponential backoff' {
		$script:batchCall = 0
		$script:sleepSeconds = $null
		Mock Start-Sleep { param($Seconds) $script:sleepSeconds = $Seconds }
		Mock Invoke-ZtGraphRequestCache {
			$script:batchCall++
			if ($script:batchCall -eq 1) {
				return [pscustomobject]@{ responses = @(
					[pscustomobject]@{ id = '0'; status = 503; body = [pscustomobject]@{ error = [pscustomobject]@{ code = 'ServiceUnavailable' } } }
					[pscustomobject]@{ id = '1'; status = 200; body = [pscustomobject]@{ id = 'group-2' } }
				) }
			}
			return [pscustomobject]@{ responses = @(
				[pscustomobject]@{ id = '0'; status = 200; body = [pscustomobject]@{ id = 'group-1' } }
			) }
		}

		$result = @(Invoke-ZtGraphRequest -RelativeUri 'groups' -UniqueId @('group-1', 'group-2') -GraphBaseUri 'https://graph.microsoft.com/')

		$result.id | Should -Be @('group-1', 'group-2')
		$script:batchCall | Should -Be 2
		$script:sleepSeconds | Should -Be 3
	}

	It 'does not retry a terminal item-level client error' {
		$script:batchCall = 0
		$script:sleepCalled = $false
		Mock Start-Sleep { $script:sleepCalled = $true }
		Mock Invoke-ZtGraphRequestCache {
			$script:batchCall++
			return [pscustomobject]@{ responses = @(
				[pscustomobject]@{ id = '0'; status = 404; body = [pscustomobject]@{ error = [pscustomobject]@{ code = 'Request_ResourceNotFound' } } }
				[pscustomobject]@{ id = '1'; status = 200; body = [pscustomobject]@{ id = 'group-2' } }
			) }
		}

		$result = @(Invoke-ZtGraphRequest -RelativeUri 'groups' -UniqueId @('deleted-group', 'group-2') -GraphBaseUri 'https://graph.microsoft.com/')

		$result[0].error.code | Should -Be 'Request_ResourceNotFound'
		$result[1].id | Should -Be 'group-2'
		$script:batchCall | Should -Be 1
		$script:sleepCalled | Should -BeFalse
	}

	It 'throws after transient item retries are exhausted without emitting partial results' {
		$script:batchCall = 0
		$script:sleepCalls = 0
		Mock Start-Sleep { $script:sleepCalls++ }
		Mock Invoke-ZtGraphRequestCache {
			$script:batchCall++
			return [pscustomobject]@{ responses = @(
				[pscustomobject]@{ id = '0'; status = 200; body = [pscustomobject]@{ id = 'group-1' } }
				[pscustomobject]@{ id = '1'; status = 429; headers = @{ 'Retry-After' = '1' }; body = [pscustomobject]@{ error = [pscustomobject]@{ code = 'TooManyRequests' } } }
			) }
		}

		$output = @()
		$caughtError = $null
		try {
			$output = @(Invoke-ZtGraphRequest -RelativeUri 'groups' -UniqueId @('group-1', 'group-2') -GraphBaseUri 'https://graph.microsoft.com/')
		}
		catch {
			$caughtError = $_
		}

		$output | Should -BeNullOrEmpty
		$caughtError.Exception.Message | Should -BeLike '*item-level transient failures after 6 attempts*'
		$script:batchCall | Should -Be 6
		$script:sleepCalls | Should -Be 5
	}

	It 'retries an item omitted from a batch response' {
		$script:batchCall = 0
		Mock Start-Sleep {}
		Mock Invoke-ZtGraphRequestCache {
			param($Body)
			$script:batchCall++
			if ($script:batchCall -eq 1) {
				return [pscustomobject]@{ responses = @(
					[pscustomobject]@{ id = '0'; status = 200; body = [pscustomobject]@{ id = 'group-1' } }
				) }
			}
			$retriedRequest = ($Body | ConvertFrom-Json).requests[0]
			return [pscustomobject]@{ responses = @(
				[pscustomobject]@{ id = $retriedRequest.id; status = 200; body = [pscustomobject]@{ id = 'group-2' } }
			) }
		}

		$result = @(Invoke-ZtGraphRequest -RelativeUri 'groups' -UniqueId @('group-1', 'group-2') -GraphBaseUri 'https://graph.microsoft.com/')

		$result.id | Should -Be @('group-1', 'group-2')
		$script:batchCall | Should -Be 2
	}

	It 'retries items with missing or nonnumeric batch statuses' {
		$script:batchCall = 0
		Mock Start-Sleep {}
		Mock Invoke-ZtGraphRequestCache {
			$script:batchCall++
			if ($script:batchCall -eq 1) {
				return [pscustomobject]@{ responses = @(
					[pscustomobject]@{ id = '0'; body = [pscustomobject]@{ id = 'invalid-result' } }
					[pscustomobject]@{ id = '1'; status = 'invalid'; body = [pscustomobject]@{ id = 'invalid-result' } }
				) }
			}
			return [pscustomobject]@{ responses = @(
				[pscustomobject]@{ id = '0'; status = 200; body = [pscustomobject]@{ id = 'group-1' } }
				[pscustomobject]@{ id = '1'; status = 200; body = [pscustomobject]@{ id = 'group-2' } }
			) }
		}

		$result = @(Invoke-ZtGraphRequest -RelativeUri 'groups' -UniqueId @('group-1', 'group-2') -GraphBaseUri 'https://graph.microsoft.com/')

		$result.id | Should -Be @('group-1', 'group-2')
		$script:batchCall | Should -Be 2
	}

	It 'rejects batch sizes outside the Microsoft Graph limit' {
		{ Invoke-ZtGraphRequest -RelativeUri @('users', 'groups') -BatchSize 0 } | Should -Throw
		{ Invoke-ZtGraphRequest -RelativeUri @('users', 'groups') -BatchSize 21 } | Should -Throw
	}

	It 'preserves request order and splits workloads at the default batch size' {
		$script:batchBodies = [System.Collections.Generic.List[object]]::new()
		Mock Invoke-ZtGraphRequestCache {
			param($Body)
			$batch = $Body | ConvertFrom-Json
			$script:batchBodies.Add($batch)
			return [pscustomobject]@{ responses = @($batch.requests | Sort-Object id -Descending | ForEach-Object {
				[pscustomobject]@{ id = $_.id; status = 200; body = [pscustomobject]@{ id = $_.url } }
			}) }
		}
		$ids = @(1..21 | ForEach-Object { "group-$_" })

		$result = @(Invoke-ZtGraphRequest -RelativeUri 'groups' -UniqueId $ids -GraphBaseUri 'https://graph.microsoft.com/')

		$script:batchBodies | Should -HaveCount 2
		@($script:batchBodies[0].requests) | Should -HaveCount 20
		@($script:batchBodies[1].requests) | Should -HaveCount 1
		$result.id | Should -Be @($ids | ForEach-Object { "groups/$_" })
	}
}

Describe 'Invoke-ZtGraphRequestCache non-GET output handling' {
	BeforeAll {
		$srcRoot = Join-Path $PSScriptRoot '../../src/powershell'

		function global:Write-PSFMessage { param($Message, $Level, $Tag) }
		function global:Get-PSFConfigValue { param($FullName) return $false }
		function global:Invoke-ZtRetry { param($ScriptBlock) & $ScriptBlock }
		function global:Invoke-MgGraphRequest { param($Method, $Uri, $Headers, $OutputType, $Body) }
		function global:Get-ExportJsonFilePath { param($Path, $PageIndex) return (Join-Path $TestDrive 'post-response.json') }
		function global:Set-PSFFileContent { param($Path, $InputObject) }

		. (Join-Path $srcRoot 'private/core/Invoke-ZtGraphRequestCache.ps1')
	}

	BeforeEach {
		$script:__ZtSession = [pscustomobject]@{ GraphCache = [pscustomobject]@{ Value = @{} } }
		$script:__ZtThrottling = [pscustomobject]@{ Value = @{} }
		Mock Invoke-MgGraphRequest { '{"result":"success"}' }
		Mock Set-PSFFileContent {}
		Mock New-Item { [pscustomobject]@{ FullName = $Path } }
	}

	It 'does not read or write cache entries for POST' {
		$uri = [uri]'https://graph.microsoft.com/v1.0/security/runHuntingQuery'
		$script:__ZtSession.GraphCache.Value[$uri.AbsoluteUri] = [pscustomobject]@{ result = 'cached' }

		$result = Invoke-ZtGraphRequestCache -Uri $uri -Method POST -Body '{}' -OutputType PSObject

		$result | Should -Be '{"result":"success"}'
		Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Body -eq '{}' }
		$script:__ZtSession.GraphCache.Value[$uri.AbsoluteUri].result | Should -Be 'cached'
	}

	It 'writes and returns a parsed POST response when OutputFilePath is specified' {
		$result = Invoke-ZtGraphRequestCache -Uri 'https://graph.microsoft.com/v1.0/security/runHuntingQuery' -Method POST -Body '{}' -OutputFilePath 'response.json'

		$result.result | Should -Be 'success'
		Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $OutputType -eq 'Json' }
		Should -Invoke Set-PSFFileContent -Times 1 -Exactly
	}
}
