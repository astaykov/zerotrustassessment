Describe "Assessment telemetry removal" {
	BeforeAll {
		$srcRoot = Join-Path $PSScriptRoot '..\..\src\powershell'
		$assessmentPath = Join-Path $srcRoot 'public\Invoke-ZtAssessment.ps1'
		$script:AssessmentSource = Get-Content -Path $assessmentPath -Raw
		$script:ConfigSource = Get-Content -Path (Join-Path $srcRoot 'private\core\New-ZtInteractiveConfig.ps1') -Raw
		$script:CmdletSource = Get-Content -Path (Join-Path $srcRoot 'ZeroTrustAssessment\InvokeAssessment.cs') -Raw
		$script:TelemetryPath = Join-Path $srcRoot 'private\Send-ZtAppInsightsTelemetry.ps1'

		$tokens = $null
		$script:ParseErrors = $null
		$script:AssessmentAst = [System.Management.Automation.Language.Parser]::ParseFile(
			$assessmentPath, [ref]$tokens, [ref]$script:ParseErrors
		)
		$script:AssessmentFunction = $script:AssessmentAst.Find({
			param($node)
			$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
				$node.Name -eq 'Invoke-ZtAssessment'
		}, $true)
	}

	It "preserves valid PowerShell syntax" {
		$script:ParseErrors | Should -BeNullOrEmpty
		$tokens = $null
		$errors = $null
		$null = [System.Management.Automation.Language.Parser]::ParseInput(
			$script:ConfigSource, [ref]$tokens, [ref]$errors
		)
		$errors | Should -BeNullOrEmpty
	}

	It "removes the telemetry parameter while retaining assessment controls" {
		$parameterNames = $script:AssessmentFunction.Body.ParamBlock.Parameters.Name.VariablePath.UserPath
		$parameterNames | Should -Not -Contain 'DisableTelemetry'
		foreach ($name in @('Path', 'Days', 'ShowLog', 'ExportLog', 'Resume', 'Tests', 'ConfigurationFile', 'TestTimeout', 'NoBrowser')) {
			$parameterNames | Should -Contain $name
		}
	}

	It "removes telemetry calls, configuration mapping, and help" {
		$script:AssessmentSource | Should -Not -Match '(?i)telemetry|ZTv2TenantId'
	}

	It "does not display a telemetry notice in the startup banner" {
		$banner = $script:AssessmentFunction.Body.Find({
			param($node)
			$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
				$node.Name -eq 'Show-ZtiBanner'
		}, $true)
		$banner | Should -Not -BeNullOrEmpty
		. ([scriptblock]::Create($banner.Extent.Text))
		$output = (Show-ZtiBanner 6>&1 | Out-String)
		$output | Should -Match 'Starting Zero Trust Assessment'
		$output | Should -Not -Match '(?i)telemetry|tenant ID'
	}

	It "removes the telemetry sender file" {
		$script:TelemetryPath | Should -Not -Exist
	}

	It "does not offer or save telemetry settings in the configuration wizard" {
		$script:ConfigSource | Should -Not -Match '(?i)telemetry'
	}

	It "does not create or pass an Application Insights client in the C# cmdlet" {
		$script:CmdletSource | Should -Not -Match '(?i)telemetry|ApplicationInsights|InstrumentationKey'
		$script:CmdletSource | Should -Match 'new GraphData\(configOptions, AccessToken, null\)'
	}
}
