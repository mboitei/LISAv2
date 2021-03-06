##############################################################################################
# Run-LisaV2.ps1
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
#
<#
.SYNOPSIS
	This is the entrance script for LISAv2.
	LISAv2 is the test framework running Linux test automation on Azure and HyperV platforms,
	including remote test launching in dev system.

.PARAMETER
	See source code for the detailed parameters

.NOTES
	PREREQUISITES:
	1) Prepare necessary 3rd party tools and put them into the Tools folder;
	2) Review the XML configuration files under XML folder and make necessary change for your environment.
	See more from https://github.com/LIS/LISAv2 for helps including README and How-to-use document.

.EXAMPLE
	.\Run-LisaV2.ps1	-TestPlatform "Azure" -TestLocation "westus2" -RGIdentifier "mylisatest"
					-ARMImageName "Canonical UbuntuServer 16.04-LTS latest"
					-XMLSecretFile "C:\MySecrets.xml"
					-TestNames "BVT-VERIFY-DEPLOYMENT-PROVISION"

	.\Run-LisaV2.ps1 -TestParameters .\XML\TestParameters.xml
	Note: Please refer .\XML\TestParameters.xml file for more details.

#>
###############################################################################################

[CmdletBinding()]
Param(
	#Do not use. Reserved for Jenkins use.
	$BuildNumber=$env:BUILD_NUMBER,

	#[Optional]
	[string] $ParametersFile = "",

	#[Required]
	[ValidateSet('Azure','HyperV', IgnoreCase = $false)]
	[string] $TestPlatform = "",

	#[Required] for Azure.
	[string] $TestLocation="",
	[string] $ARMImageName = "",
	[string] $StorageAccount="",

	#[Required] for HyperV
	[string] $SourceOsVHDPath="",

	#[Required] for Two Hosts HyperV
	[string] $DestinationOsVHDPath="",

	#[Required] Common for HyperV and Azure.
	[string] $RGIdentifier = "",
	[string] $OsVHD = "",   #... [Azure: Required only if -ARMImageName is not provided.]
							#... [HyperV: Mandatory]
	[string] $TestCategory = "",
	[string] $TestArea = "",
	[string] $TestTag = "",
	[string] $TestNames="",

	#[Optional] Parameters for Image preparation before running tests.
	[string] $CustomKernel = "",
	[string] $CustomLIS,

	#[Optional] Parameters for changing framework behavior.
	[string] $CoreCountExceededTimeout,
	[int]    $TestIterations,
	[string] $TiPSessionId,
	[string] $TiPCluster,
	[string] $XMLSecretFile = "",
	[switch] $EnableTelemetry,

	#[Optional] Parameters for Overriding VM Configuration.
	[string] $CustomParameters = "",
	[string] $OverrideVMSize = "",
	[switch] $EnableAcceleratedNetworking,
	[string] $OverrideHyperVDiskMode = "",
	[switch] $ForceDeleteResources,
	[switch] $UseManagedDisks,
	[switch] $DoNotDeleteVMs,
	[string] $VMGeneration = "",

	[string] $ResultDBTable = "",
	[string] $ResultDBTestTag = "",

	[switch] $ExitWithZero
)

# Import the Functions from Library Files.
Get-ChildItem .\Libraries -Recurse | Where-Object { $_.FullName.EndsWith(".psm1") } | `
	ForEach-Object { Import-Module $_.FullName -Force -Global -DisableNameChecking }

try {
	$TestID = "{0}{1}" -f $(-join ((65..90) | Get-Random -Count 4 | ForEach-Object {[char]$_})), $(Get-Random -Maximum 99999 -Minimum 11111)
	Write-Output "Test ID generated for this test run: $TestID"
	Set-Variable -Name "TestID" -Value $TestID -Scope Global -Force

	# Prepare the workspace
	$MaxDirLength = 32
	$WorkingDirectory = Split-Path -parent $MyInvocation.MyCommand.Definition
	if ( $WorkingDirectory.Length -gt $MaxDirLength) {
		$OriginalWorkingDirectory = $WorkingDirectory
		Write-Output "Current working directory '$WorkingDirectory' length is greater than $MaxDirLength."
		$tempWorkspace    = "$(Split-Path $OriginalWorkingDirectory -Qualifier)"
		$tempParentFolder = "$tempWorkspace\LISAv2"
		$tempWorkingDir   = "$tempWorkspace\LISAv2\$TestID"

		New-Item -ItemType Directory -Path $tempParentFolder -Force -ErrorAction SilentlyContinue | Out-Null
		New-Item -ItemType Directory -Path $tempWorkingDir    -Force -ErrorAction SilentlyContinue | Out-Null
		$tmpSource = '\\?\' + "$OriginalWorkingDirectory\*"
		Write-Output "Copying current workspace to $tempWorkingDir"
		$excludedDirectories = @(".git", ".github", "TestResults", "VHDs_Destination_Path", "*.zip", "report")
		Copy-Item -Path $tmpSource -Destination $tempWorkingDir -Recurse -Force -Exclude $excludedDirectories | Out-Null
		Set-Location -Path $tempWorkingDir | Out-Null
		Write-Output "Working directory has been changed to $tempWorkingDir"
		$WorkingDirectory = $tempWorkingDir
	}
	Set-Variable -Name WorkingDirectory -Value $WorkingDirectory  -Scope Global

	# Load test parameters as PS objects
	$ParameterList = (Get-Command -Name $PSCmdlet.MyInvocation.InvocationName).Parameters;
	$ScriptVariables = New-Object PSObject
	foreach ($key in $ParameterList.keys) {
		$var = Get-Variable -Name $key -Scope Script -ErrorAction SilentlyContinue
		if($var) {
			$ScriptVariables | add-member -MemberType Noteproperty -Name $($var.name) -Value $($var.value)
		}
	}
	# Import parameters from file if -ParametersFile is given
	if ($ParametersFile) {
		Import-LISAv2ParametersFromXMLFile -ParametersFile $ParametersFile
	}
	# Set all parameters as Global Variables
	foreach ($key in $ParameterList.keys) {
		if($ScriptVariables.$Key) {
			if ($ParametersFile) {
				$IgnoredParameterNames = ("ParametersFile")
				if ($ScriptVariables.$Key) {
					if (-not $IgnoredParameterNames.Contains($Key)) {
						LogMsg "Overriding specified parameter $Key = $($ScriptVariables.$Key)"
					}
					Set-Variable -Name $Key -Value $ScriptVariables.$Key -Scope Global -Force
				}
			}
			else {
				Set-Variable -Name $Key -Value $ScriptVariables.$Key -Scope Global -Force
			}
		}
	}
	$GlobalVariables = Get-Variable -Scope Global
	foreach ($var in $GlobalVariables) {
		[void](Set-Variable -Name $var.Name -Value $var.Value -Scope Local -ErrorAction SilentlyContinue)
	}

	# Prepare log folder
	$LogDir = ".\TestResults\$(Get-Date -Format 'yyyy-dd-MM-HH-mm-ss-ffff')"
	Set-Variable -Name LogDir -Value $LogDir -Scope Global -Force
	New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
	New-Item -ItemType Directory -Path Temp -Force -ErrorAction SilentlyContinue | Out-Null
	LogMsg "Created LogDir: $LogDir"

	# Validate the test parameters.
	Validate-Parameters

	# Handle the Secrets file
	if ($env:Azure_Secrets_File) {
		$XMLSecretFile = $env:Azure_Secrets_File
		LogMsg "Found Secrets file from environment."
	}
	if ($XMLSecretFile -ne [string]::Empty) {
		if ((Test-Path -Path $XMLSecretFile) -eq $true) {
			$xmlSecrets = ([xml](Get-Content $XMLSecretFile))
			Set-Variable -Value $xmlSecrets -Name XmlSecrets -Scope Global -Force

			# Download the tools required for LISAv2 execution.
			Get-LISAv2Tools -XMLSecretFile $XMLSecretFile

			# Update the configuration files based on the settings in the XMLSecretFile
			UpdateGlobalConfigurationXML $XMLSecretFile
			UpdateXMLStringsFromSecretsFile $XMLSecretFile

			if ($TestPlatform -eq "Azure") {
				.\Utilities\AddAzureRmAccountFromSecretsFile.ps1 -customSecretsFilePath $XMLSecretFile
			}
		} else {
			LogErr "The Secret file provided: $XMLSecretFile does not exist"
		}
	} else {
		LogErr "Failed to update configuration files. '-XMLSecretFile [FilePath]' is not provided."
	}

	ValidateXmlFiles -ParentFolder $WorkingDirectory

	# Consolidate all test cases into a unified test xml file
	$TestXMLs = Get-ChildItem -Path "$WorkingDirectory\XML\TestCases\*.xml"
	$SetupTypeXMLs = Get-ChildItem -Path "$WorkingDirectory\XML\VMConfigurations\*.xml"
	$AllLisaTests = @()
	$ARMImage = $ARMImageName.Trim().Split(" ")
	$TestConfigurationXmlFile = "$WorkingDirectory\TestConfiguration.xml"
	if ( $TestCategory -eq "All") { $TestCategory = "" }
	if ( $TestArea -eq "All") {	$TestArea = "" }
	if ( $TestNames -eq "All") { $TestNames = "" }
	if ( $TestTag -eq "All") { $TestTag = "" }

	$AllLisaTests = CollectTestCases -TestXMLs $TestXMLs
	if( !$AllLisaTests.innerXML ) {
		Throw "Specified -TestNames or -TestCategory not found"
	}

	$SetupTypes = $AllLisaTests.SetupType | Sort-Object | Get-Unique

	#region Create the Test XML file
	$tab = CreateArrayOfTabs
	$TestCycle = "TC-$TestID"
	$GlobalConfiguration = [xml](Get-content .\XML\GlobalConfigurations.xml)
	<##########################################################################
	We're following the Indentation of the XML file to make XML creation easier.
	##########################################################################>
	$xmlContent =  ("$($tab[0])" + '<?xml version="1.0" encoding="utf-8"?>')
	$xmlContent += ("$($tab[0])" + "<config>`n")
	$xmlContent += ("$($tab[0])" + "<CurrentTestPlatform>$TestPlatform</CurrentTestPlatform>`n")
	if ($TestPlatform -eq "Azure") {
		$xmlContent += ("$($tab[1])" + "<Azure>`n")
			# Add Subscription Details
			$xmlContent += ("$($tab[2])" + "<General>`n")

			foreach ( $line in $GlobalConfiguration.Global.$TestPlatform.Subscription.InnerXml.Replace("><",">`n<").Split("`n")) {
				$xmlContent += ("$($tab[3])" + "$line`n")
			}
			$xmlContent += ("$($tab[2])" + "<Location>$TestLocation</Location>`n")
			$xmlContent += ("$($tab[2])" + "</General>`n")

			# Database details
			$xmlContent += ("$($tab[2])" + "<database>`n")
			foreach ( $line in $GlobalConfiguration.Global.$TestPlatform.ResultsDatabase.InnerXml.Replace("><",">`n<").Split("`n")) {
				$xmlContent += ("$($tab[3])" + "$line`n")
			}
			$xmlContent += ("$($tab[2])" + "</database>`n")

			# Deployment details
			$xmlContent += ("$($tab[2])" + "<Deployment>`n")
				$xmlContent += ("$($tab[3])" + "<Data>`n")
					$xmlContent += ("$($tab[4])" + "<Distro>`n")
						$xmlContent += ("$($tab[5])" + "<Name>$RGIdentifier</Name>`n")
						$xmlContent += ("$($tab[5])" + "<ARMImage>`n")
							$xmlContent += ("$($tab[6])" + "<Publisher>" + "$($ARMImage[0])" + "</Publisher>`n")
							$xmlContent += ("$($tab[6])" + "<Offer>" + "$($ARMImage[1])" + "</Offer>`n")
							$xmlContent += ("$($tab[6])" + "<Sku>" + "$($ARMImage[2])" + "</Sku>`n")
							$xmlContent += ("$($tab[6])" + "<Version>" + "$($ARMImage[3])" + "</Version>`n")
						$xmlContent += ("$($tab[5])" + "</ARMImage>`n")
						$xmlContent += ("$($tab[5])" + "<OsVHD>" + "$OsVHD" + "</OsVHD>`n")
						$xmlContent += ("$($tab[5])" + "<VMGeneration>" + "$VMGeneration" + "</VMGeneration>`n")
					$xmlContent += ("$($tab[4])" + "</Distro>`n")
					$xmlContent += ("$($tab[4])" + "<UserName>" + "$($GlobalConfiguration.Global.$TestPlatform.TestCredentials.LinuxUsername)" + "</UserName>`n")
					$xmlContent += ("$($tab[4])" + "<Password>" + "$($GlobalConfiguration.Global.$TestPlatform.TestCredentials.LinuxPassword)" + "</Password>`n")
				$xmlContent += ("$($tab[3])" + "</Data>`n")

				foreach ( $file in $SetupTypeXMLs.FullName)	{
					foreach ( $SetupType in $SetupTypes ) {
						$CurrentSetupType = ([xml]( Get-Content -Path $file)).TestSetup
						if ($null -ne $CurrentSetupType.$SetupType) {
							$SetupTypeElement = $CurrentSetupType.$SetupType
							$xmlContent += ("$($tab[3])" + "<$SetupType>`n")
								#$xmlContent += ("$($tab[4])" + "$($SetupTypeElement.InnerXml)`n")
								foreach ( $line in $SetupTypeElement.InnerXml.Replace("><",">`n<").Split("`n")) {
									$xmlContent += ("$($tab[4])" + "$line`n")
								}
							$xmlContent += ("$($tab[3])" + "</$SetupType>`n")
						}
					}
				}
			$xmlContent += ("$($tab[2])" + "</Deployment>`n")
		$xmlContent += ("$($tab[1])" + "</Azure>`n")
	} elseif ($TestPlatform -eq "Hyperv") {
		$xmlContent += ("$($tab[1])" + "<Hyperv>`n")
			# Add Hosts Details
			$xmlContent += ("$($tab[2])" + "<Hosts>`n")
				$xmlContent += ("$($tab[3])" + "<Host>`n")
				foreach ( $line in $GlobalConfiguration.Global.HyperV.Hosts.FirstChild.InnerXml.Replace("><",">`n<").Split("`n")) {
					$xmlContent += ("$($tab[4])" + "$line`n")
				}
				$xmlContent += ("$($tab[3])" + "</Host>`n")

				if($TestLocation -and $TestLocation.split(',').Length -eq 2){
					$xmlContent += ("$($tab[3])" + "<Host>`n")
					foreach ( $line in $GlobalConfiguration.Global.HyperV.Hosts.LastChild.InnerXml.Replace("><",">`n<").Split("`n")) {
						$xmlContent += ("$($tab[4])" + "$line`n")
					}
					$xmlContent += ("$($tab[3])" + "</Host>`n")
				}
			$xmlContent += ("$($tab[2])" + "</Hosts>`n")

			# Database details
			$xmlContent += ("$($tab[2])" + "<database>`n")
				foreach ( $line in $GlobalConfiguration.Global.HyperV.ResultsDatabase.InnerXml.Replace("><",">`n<").Split("`n")) {
					$xmlContent += ("$($tab[3])" + "$line`n")
				}
			$xmlContent += ("$($tab[2])" + "</database>`n")

			# Deployment details
			$xmlContent += ("$($tab[2])" + "<Deployment>`n")
				$xmlContent += ("$($tab[3])" + "<Data>`n")
					$xmlContent += ("$($tab[4])" + "<Distro>`n")
						$xmlContent += ("$($tab[5])" + "<Name>$RGIdentifier</Name>`n")
						$xmlContent += ("$($tab[5])" + "<ARMImage>`n")
							$xmlContent += ("$($tab[6])" + "<Publisher>" + "$($ARMImage[0])" + "</Publisher>`n")
							$xmlContent += ("$($tab[6])" + "<Offer>" + "$($ARMImage[1])" + "</Offer>`n")
							$xmlContent += ("$($tab[6])" + "<Sku>" + "$($ARMImage[2])" + "</Sku>`n")
							$xmlContent += ("$($tab[6])" + "<Version>" + "$($ARMImage[3])" + "</Version>`n")
						$xmlContent += ("$($tab[5])" + "</ARMImage>`n")
						$xmlContent += ("$($tab[5])" + "<OsVHD>" + "$OsVHD" + "</OsVHD>`n")
					$xmlContent += ("$($tab[4])" + "</Distro>`n")
					$xmlContent += ("$($tab[4])" + "<UserName>" + "$($GlobalConfiguration.Global.$TestPlatform.TestCredentials.LinuxUsername)" + "</UserName>`n")
					$xmlContent += ("$($tab[4])" + "<Password>" + "$($GlobalConfiguration.Global.$TestPlatform.TestCredentials.LinuxPassword)" + "</Password>`n")
				$xmlContent += ("$($tab[3])" + "</Data>`n")

				foreach ( $file in $SetupTypeXMLs.FullName)	{
					foreach ( $SetupType in $SetupTypes ) {
						$CurrentSetupType = ([xml]( Get-Content -Path $file)).TestSetup
						if ($null -ne $CurrentSetupType.$SetupType) {
							$SetupTypeElement = $CurrentSetupType.$SetupType
							$xmlContent += ("$($tab[3])" + "<$SetupType>`n")
								#$xmlContent += ("$($tab[4])" + "$($SetupTypeElement.InnerXml)`n")
								foreach ( $line in $SetupTypeElement.InnerXml.Replace("><",">`n<").Split("`n")) {
									$xmlContent += ("$($tab[4])" + "$line`n")
								}

							$xmlContent += ("$($tab[3])" + "</$SetupType>`n")
						}
					}
				}
			$xmlContent += ("$($tab[2])" + "</Deployment>`n")
		$xmlContent += ("$($tab[1])" + "</Hyperv>`n")
	}
		# TestDefinition
		$xmlContent += ("$($tab[1])" + "<testsDefinition>`n")
		foreach ( $currentTest in $AllLisaTests) {
			if ($currentTest.Platform.Contains($TestPlatform)) {
				$xmlContent += ("$($tab[2])" + "<test>`n")
				foreach ( $line in $currentTest.InnerXml.Replace("><",">`n<").Split("`n")) {
					$xmlContent += ("$($tab[3])" + "$line`n")
				}
				$xmlContent += ("$($tab[2])" + "</test>`n")
			} else {
				LogErr "*** UNSUPPORTED TEST *** : $currentTest. Skipped."
			}
		}
		$xmlContent += ("$($tab[1])" + "</testsDefinition>`n")

		# TestCycle
		$xmlContent += ("$($tab[1])" + "<testCycles>`n")
			$xmlContent += ("$($tab[2])" + "<Cycle>`n")
				$xmlContent += ("$($tab[3])" + "<cycleName>$TestCycle</cycleName>`n")
				foreach ( $currentTest in $AllLisaTests) {
					$line = $currentTest.TestName
					$xmlContent += ("$($tab[3])" + "<test>`n")
						$xmlContent += ("$($tab[4])" + "<Name>$line</Name>`n")
					$xmlContent += ("$($tab[3])" + "</test>`n")
				}
			$xmlContent += ("$($tab[2])" + "</Cycle>`n")
		$xmlContent += ("$($tab[1])" + "</testCycles>`n")
	$xmlContent += ("$($tab[0])" + "</config>`n")
	Set-Content -Value $xmlContent -Path $TestConfigurationXmlFile -Force

	#This function will inject default / custom replaceable test parameters to TestConfiguration.xml
	Add-ReplaceableTestParameters -XmlConfigFilePath $TestConfigurationXmlFile

	try {
		$xmlConfig = [xml](Get-Content $TestConfigurationXmlFile)
		$xmlConfig.Save("$TestConfigurationXmlFile")
		LogMsg "Auto created $TestConfigurationXmlFile validated successfully."
	} catch {
		Throw "Framework error: $TestConfigurationXmlFile is not valid. Please report to lisasupport@microsoft.com"
	}
	#endregion

	#region Prepare execution command
	$command = ".\AutomationManager.ps1 -xmlConfigFile '$TestConfigurationXmlFile' -cycleName 'TC-$TestID' -RGIdentifier '$RGIdentifier' -runtests -UseAzureResourceManager"

	if ( $CustomKernel) { $command += " -CustomKernel '$CustomKernel'" }
	if ( $OverrideVMSize ) { $command += " -OverrideVMSize $OverrideVMSize" }
	if ( $EnableAcceleratedNetworking ) { $command += " -EnableAcceleratedNetworking" }
	if ( $ForceDeleteResources ) { $command += " -ForceDeleteResources" }
	if ( $DoNotDeleteVMs ) { $command += " -DoNotDeleteVMs" }
	if ( $CustomLIS) { $command += " -CustomLIS $CustomLIS" }
	if ( $CoreCountExceededTimeout ) { $command += " -CoreCountExceededTimeout $CoreCountExceededTimeout" }
	if ( $TestIterations -gt 1 ) { $command += " -TestIterations $TestIterations" }
	if ( $TiPSessionId) { $command += " -TiPSessionId $TiPSessionId" }
	if ( $TiPCluster) { $command += " -TiPCluster $TiPCluster" }
	if ($UseManagedDisks) {	$command += " -UseManagedDisks" }
	if ($XMLSecretFile) { $command += " -XMLSecretFile '$XMLSecretFile'" }

	LogMsg $command
	#endregion

	Invoke-Expression -Command $command

	$zipFile = "$TestPlatform"
	if ( $TestCategory ) { $zipFile += "-$TestCategory"	}
	if ( $TestArea ) { $zipFile += "-$TestArea" }
	if ( $TestTag ) { $zipFile += "-$($TestTag)" }

	$zipFile += "-$TestID-buildlogs.zip"
	$out = ZipFiles -zipfilename $zipFile -sourcedir $LogDir

	if ($out -match "Everything is Ok") {
		LogMsg "$WorkingDirectory\$zipfilename created successfully."
	}

	try {
		if (Test-Path -Path ".\report\report_$(($TestCycle).Trim()).xml" ) {
			$resultXML = [xml](Get-Content ".\report\report_$(($TestCycle).Trim()).xml" -ErrorAction SilentlyContinue)
			Copy-Item -Path ".\report\report_$(($TestCycle).Trim()).xml" -Destination ".\report\report_$(($TestCycle).Trim())-junit.xml" -Force -ErrorAction SilentlyContinue
			LogMsg "Copied : .\report\report_$(($TestCycle).Trim()).xml --> .\report\report_$(($TestCycle).Trim())-junit.xml"
			LogMsg "Analyzing results.."
			LogMsg "PASS  : $($resultXML.testsuites.testsuite.tests - $resultXML.testsuites.testsuite.errors - $resultXML.testsuites.testsuite.failures)"
			LogMsg "FAIL  : $($resultXML.testsuites.testsuite.failures)"
			LogMsg "ABORT : $($resultXML.testsuites.testsuite.errors)"
			if ( ( $resultXML.testsuites.testsuite.failures -eq 0 ) -and ( $resultXML.testsuites.testsuite.errors -eq 0 ) -and ( $resultXML.testsuites.testsuite.tests -gt 0 )) {
				$ExitCode = 0
			} else {
				$ExitCode = 1
			}
		} else {
			LogErr "Summary file: .\report\report_$(($TestCycle).Trim()).xml does not exist. Exiting with 1."
			$ExitCode = 1
		}
	}
	catch {
		LogErr "$($_.Exception.GetType().FullName, " : ",$_.Exception.Message)"
		$ExitCode = 1
	}
	finally {
		if ( $ExitWithZero -and ($ExitCode -ne 0) ) {
			LogMsg "Changed exit code from 1 to 0. (-ExitWithZero specified in command line)"
			$ExitCode = 0
		}
	}
} catch {
	$line = $_.InvocationInfo.ScriptLineNumber
	$script_name = ($_.InvocationInfo.ScriptName).Replace($PWD,".")
	$ErrorMessage =  $_.Exception.Message

	if ( $_.FullyQualifiedErrorId -eq "InvokeMethodOnNull") {
		Write-Error "WebClient failed to download required tools from blob Storage Location. Those files should be placed in Tools folder before next execution."
	}
	LogErr "EXCEPTION : $ErrorMessage"
	LogErr "Source : Line $line in script $script_name."
	$ExitCode = 1
} finally {
	if ( $tempWorkingDir ) {
		Write-Host "Copying all files back to original working directory: $originalWorkingDirectory."
		$tmpDest = '\\?\' + $originalWorkingDirectory
		Copy-Item -Path "$tempWorkingDir\*" -Destination $tmpDest -Force -Recurse | Out-Null
		Set-Location ..
		Write-Host "Cleaning up $tempWorkingDir"
		Remove-Item -Path $tempWorkingDir -Force -Recurse -ErrorAction SilentlyContinue
		Write-Host "Setting workspace back to original location: $originalWorkingDirectory"
		Set-Location $originalWorkingDirectory
	}
	Get-Variable -Exclude PWD,*Preference,ExitCode | Remove-Variable -Force -ErrorAction SilentlyContinue
	LogMsg "LISAv2 exits with code: $ExitCode"

	exit $ExitCode
}
