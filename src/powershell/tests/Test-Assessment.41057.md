Exploit protection applies mitigation techniques to operating system processes and individual apps to make exploit-based malware less reliable. Microsoft Learn documents support beginning with Windows 10 version 1709, Windows 11, and Windows Server version 1803; it also documents that configurations can be exported as XML and distributed to multiple devices. This matters because threat actors can use a weaponized document, browser exploit, vulnerable service, or memory-corruption bug to move from initial access to execution and privilege escalation. If exploit protection is not deployed through Intune, or if users can override the deployed policy, mitigations might be absent where vulnerable applications run. The control is not a patching substitute, and Microsoft warns that some mitigations can have application compatibility issues, so teams still need vulnerability management, audit-mode testing, and change control. It can reduce exploit reliability and produce Defender for Endpoint events for auditing or blocking. This check covers both original Intune implementation paths: legacy **windows10EndpointProtectionConfiguration** device configuration profiles and Settings Catalog / Endpoint Security Attack Surface Reduction policies.

## Remediation action

- [Exploit protection](https://learn.microsoft.com/en-us/defender-endpoint/exploit-protection)
- [Customize exploit protection](https://learn.microsoft.com/en-us/defender-endpoint/customize-exploit-protection)
- [Import, export, and deploy exploit protection configurations](https://learn.microsoft.com/en-us/defender-endpoint/import-export-exploit-protection-emet-xml)
- [Evaluate exploit protection](https://learn.microsoft.com/en-us/defender-endpoint/evaluate-exploit-protection)

<!--- Results --->
%TestResult%
