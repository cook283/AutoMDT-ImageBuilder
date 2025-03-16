#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Builds a Windows image using MDT within a container environment.
.DESCRIPTION
    This script automates the Windows image building process using MDT, including:
    - Installing Windows updates
    - Installing Microsoft 365 Apps
    - Running custom scripts
    - Capturing the image to a WIM file
.PARAMETER EncodedParams
    Base64 encoded JSON string containing all parameters
.EXAMPLE
    .\MDT-BuildImage.ps1 -EncodedParams "eyJXaW5kb3dzRWRpdGlvbiI6..."
.NOTES
    Author: System Administrator
    Last Edit: 2025-03-16
    Version 1.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$EncodedParams
)

#region Functions

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Create log directory if it doesn't exist
    $logPath = "C:\Logs\MDT"
    if (-not (Test-Path -Path $logPath)) {
        New-Item -Path $logPath -ItemType Directory -Force | Out-Null
    }
    
    # Define log file with date stamp
    $logFile = Join-Path -Path $logPath -ChildPath "MDT_Build_$(Get-Date -Format 'yyyyMMdd').log"
    
    # Write to log file
    Add-Content -Path $logFile -Value $logMessage
    
    # Output to console with color
    switch ($Level) {
        'INFO'    { Write-Host $logMessage -ForegroundColor Cyan }
        'WARNING' { Write-Host $logMessage -ForegroundColor Yellow }
        'ERROR'   { Write-Host $logMessage -ForegroundColor Red }
        'SUCCESS' { Write-Host $logMessage -ForegroundColor Green }
    }
}

function Import-WindowsUpdates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$UpdateSource,
        
        [Parameter(Mandatory = $true)]
        [string]$MDTPath
    )
    
    process {
        try {
            Write-Log -Message "Importing Windows updates from '$UpdateSource'..." -Level INFO
            
            # Create updates directory in MDT
            $updatesPath = "$MDTPath\Packages\Windows Updates"
            if (-not (Test-Path -Path $updatesPath)) {
                New-Item -Path $updatesPath -ItemType Directory -Force | Out-Null
            }
            
            # Check if the update source is a directory or URL
            if (Test-Path -Path $UpdateSource -PathType Container) {
                # Local directory - copy updates
                Copy-Item -Path "$UpdateSource\*.msu" -Destination $updatesPath -Force
                Copy-Item -Path "$UpdateSource\*.cab" -Destination $updatesPath -Force
            }
            else {
                # URL - assume it's WSUS or Microsoft Update Catalog
                # Create temp directory for downloads
                $tempDir = "C:\Temp\Updates"
                if (-not (Test-Path -Path $tempDir)) {
                    New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
                }
                
                # Use WSUS Offline Update tool or similar to download updates
                Write-Log -Message "Downloading updates using WSUS Offline Update..." -Level INFO
                
                # Download WSUS Offline Update
                $wsusDownloadUrl = "https://download.wsusoffline.net/wsusoffline114.zip"
                $wsusZipPath = "C:\Temp\wsusoffline.zip"
                $wsusExtractPath = "C:\Temp\WSUSOffline"
                
                Invoke-WebRequest -Uri $wsusDownloadUrl -OutFile $wsusZipPath
                Expand-Archive -Path $wsusZipPath -DestinationPath $wsusExtractPath -Force
                
                # Run WSUS Offline Update to download latest Windows updates
                $wsusCmd = "cmd.exe /c $wsusExtractPath\UpdateGenerator.exe /seconly /includedotnet /verify"
                Invoke-Expression -Command $wsusCmd
                
                # Copy downloaded updates to MDT
                if (Test-Path -Path "$wsusExtractPath\client\w10-x64\glb") {
                    Copy-Item -Path "$wsusExtractPath\client\w10-x64\glb\*.cab" -Destination $updatesPath -Force
                    Copy-Item -Path "$wsusExtractPath\client\w10-x64\glb\*.msu" -Destination $updatesPath -Force
                }
            }
            
            # Check if updates were imported
            $updateCount = (Get-ChildItem -Path $updatesPath -Filter *.cab).Count + (Get-ChildItem -Path $updatesPath -Filter *.msu).Count
            
            Write-Log -Message "Imported $updateCount Windows updates." -Level SUCCESS
            return $updateCount -gt 0
        }
        catch {
            Write-Log -Message "Failed to import Windows updates: $_" -Level ERROR
            return $false
        }
    }
}

function Install-Office365Apps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ODTPath,
        
        [Parameter(Mandatory = $true)]
        [string]$ConfigXMLPath,
        
        [Parameter(Mandatory = $true)]
        [string]$MDTPath,
        
        [Parameter(Mandatory = $true)]
        [string]$Channel
    )
    
    process {
        try {
            Write-Log -Message "Setting up Microsoft 365 Apps installation in MDT..." -Level INFO
            
            # Create Office 365 application in MDT
            $office365Path = "$MDTPath\Applications\Microsoft 365 Apps"
            if (-not (Test-Path -Path $office365Path)) {
                New-Item -Path $office365Path -ItemType Directory -Force | Out-Null
            }
            
            # Copy ODT files
            Copy-Item -Path "$ODTPath\setup.exe" -Destination $office365Path -Force
            
            # Customize configuration XML with specified channel
            [xml]$configXml = Get-Content -Path $ConfigXMLPath
            $configNode = $configXml.SelectSingleNode("//Add")
            $configNode.Channel = $Channel
            
            # Save modified configuration XML
            $customConfigPath = "$office365Path\configuration.xml"
            $configXml.Save($customConfigPath)
            
            # Create application in MDT
            Import-Module "$MDTPath\bin\MicrosoftDeploymentToolkit.psd1"
            
            # Create PSDrive for MDT
            if (-not (Get-PSDrive -Name "DS001" -ErrorAction SilentlyContinue)) {
                New-PSDrive -Name "DS001" -PSProvider MDTProvider -Root $MDTPath -Description "MDT Deployment Share" -NetworkPath "\\localhost\DeploymentShare$" | Add-MDTPersistentDrive
            }
            
            # Add Office 365 as an application in MDT
            Import-MDTApplication -Path "DS001:\Applications" -Name "Microsoft 365 Apps" -ShortName "M365Apps" -CommandLine "setup.exe /configure configuration.xml" -WorkingDirectory ".\Applications\Microsoft 365 Apps" -ApplicationSourcePath $office365Path -DestinationFolder "Microsoft 365 Apps"
            
            # Modify task sequence to include Office 365 installation
            $tsXmlPath = "$MDTPath\Control\BUILD-$WindowsEdition-*\ts.xml"
            $tsXmlFiles = Get-Item -Path $tsXmlPath
            
            if ($tsXmlFiles) {
                foreach ($tsXmlFile in $tsXmlFiles) {
                    [xml]$tsXml = Get-Content -Path $tsXmlFile.FullName
                    
                    # Find the "Install Applications" step
                    $installAppsStep = $tsXml.SelectSingleNode("//step[@type='BDD_InstallApplication']")
                    
                    if ($installAppsStep) {
                        # Add Office 365 to applications list
                        $office365StepXml = @"
<step type="BDD_InstallApplication" name="Install Microsoft 365 Apps" description="" disable="false" continueOnError="false" successCodeList="0 3010" retryCount="2" retryDelay="30">
    <defaultVarList>
        <variable name="ApplicationGUID" property="ApplicationGUID">M365Apps</variable>
    </defaultVarList>
    <action>cscript.exe "%SCRIPTROOT%\ZTIApplications.wsf"</action>
</step>
"@
                        
                        # Insert Office 365 step after Install Applications
                        $office365StepNode = $tsXml.CreateElement("sequence")
                        $office365StepNode.InnerXml = $office365StepXml
                        $installAppsStep.ParentNode.InsertAfter($office365StepNode.FirstChild, $installAppsStep)
                        
                        # Save task sequence XML
                        $tsXml.Save($tsXmlFile.FullName)
                    }
                }
            }
            
            Write-Log -Message "Microsoft 365 Apps setup completed successfully." -Level SUCCESS
            return $true
        }
        catch {
            Write-Log -Message "Failed to set up Microsoft 365 Apps: $_" -Level ERROR
            return $false
        }
    }
}

function Add-CustomScripts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CustomScriptsPath,
        
        [Parameter(Mandatory = $true)]
        [string]$MDTPath
    )
    
    process {
        try {
            Write-Log -Message "Adding custom scripts to MDT..." -Level INFO
            
            # Check if custom scripts path exists
            if (-not (Test-Path -Path $CustomScriptsPath)) {
                Write-Log -Message "Custom scripts path does not exist. Skipping." -Level WARNING
                return $true
            }
            
            # Create custom scripts directory in MDT
            $mdtScriptsPath = "$MDTPath\Scripts\Custom"
            if (-not (Test-Path -Path $mdtScriptsPath)) {
                New-Item -Path $mdtScriptsPath -ItemType Directory -Force | Out-Null
            }
            
            # Copy custom scripts
            Copy-Item -Path "$CustomScriptsPath\*" -Destination $mdtScriptsPath -Recurse -Force
            
            # Count scripts
            $scriptCount = (Get-ChildItem -Path $mdtScriptsPath -Filter *.ps1).Count + (Get-ChildItem -Path $mdtScriptsPath -Filter *.vbs).Count + (Get-ChildItem -Path $mdtScriptsPath -Filter *.wsf).Count
            
            # Modify task sequence to include custom scripts
            $tsXmlPath = "$MDTPath\Control\BUILD-$WindowsEdition-*\ts.xml"
            $tsXmlFiles = Get-Item -Path $tsXmlPath
            
            if ($tsXmlFiles -and $scriptCount -gt 0) {
                foreach ($tsXmlFile in $tsXmlFiles) {
                    [xml]$tsXml = Get-Content -Path $tsXmlFile.FullName
                    
                    # Find the last step before capture
                    $stateRestoreGroup = $tsXml.SelectSingleNode("//group[@name='State Restore']")
                    
                    if ($stateRestoreGroup) {
                        # Add custom scripts group
                        $customScriptsGroupXml = @"
<group expand="true" name="Custom Scripts" description="Runs custom scripts and configurations">
</group>
"@
                        
                        # Create custom scripts group
                        $customScriptsGroupNode = $tsXml.CreateElement("sequence")
                        $customScriptsGroupNode.InnerXml = $customScriptsGroupXml
                        $stateRestoreGroup.ParentNode.InsertAfter($customScriptsGroupNode.FirstChild, $stateRestoreGroup)
                        
                        # Get the custom scripts group node
                        $customScriptsGroup = $tsXml.SelectSingleNode("//group[@name='Custom Scripts']")
                        
                        # Add each script as a step
                        $scripts = Get-ChildItem -Path $mdtScriptsPath -Include *.ps1, *.vbs, *.wsf -Recurse
                        
                        foreach ($script in $scripts) {
                            $scriptName = $script.Name
                            $scriptExt = $script.Extension
                            $scriptRelativePath = "Scripts\Custom\$scriptName"
                            
                            $scriptCommand = switch ($scriptExt) {
                                ".ps1" { "powershell.exe -ExecutionPolicy Bypass -File %SCRIPTROOT%\Custom\$scriptName" }
                                ".vbs" { "cscript.exe //nologo %SCRIPTROOT%\Custom\$scriptName" }
                                ".wsf" { "cscript.exe //nologo %SCRIPTROOT%\Custom\$scriptName" }
                                default { "cmd.exe /c %SCRIPTROOT%\Custom\$scriptName" }
                            }
                            
                            $scriptStepXml = @"
<step type="BDD_RunCommand" name="Run Custom Script - $scriptName" description="" disable="false" continueOnError="false" successCodeList="0 3010" retryCount="2" retryDelay="30">
    <defaultVarList>
        <variable name="CommandLine" property="CommandLine">$scriptCommand</variable>
    </defaultVarList>
    <action>$scriptCommand</action>
</step>
"@
                            
                            # Add script step to custom scripts group
                            $scriptStepNode = $tsXml.CreateElement("sequence")
                            $scriptStepNode.InnerXml = $scriptStepXml
                            $customScriptsGroup.AppendChild($scriptStepNode.FirstChild)
                        }
                        
                        # Save task sequence XML
                        $tsXml.Save($tsXmlFile.FullName)
                    }
                }
            }
            
            Write-Log -Message "Added $scriptCount custom scripts to MDT." -Level SUCCESS
            return $true
        }
        catch {
            Write-Log -Message "Failed to add custom scripts: $_" -Level ERROR
            return $false
        }
    }
}

function Start-ImageBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MDTPath,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )
    
    process {
        try {
            Write-Log -Message "Starting Windows image build process..." -Level INFO
            
            # Import MDT module
            Import-Module "$MDTPath\bin\MicrosoftDeploymentToolkit.psd1"
            
            # Create PSDrive for MDT
            if (-not (Get-PSDrive -Name "DS001" -ErrorAction SilentlyContinue)) {
                New-PSDrive -Name "DS001" -PSProvider MDTProvider -Root $MDTPath -Description "MDT Deployment Share" -NetworkPath "\\localhost\DeploymentShare$" | Add-MDTPersistentDrive
            }
            
            # Get task sequence ID
            $tsID = Get-ChildItem -Path "DS001:\Task Sequences" | Where-Object { $_.Name -like "*$WindowsEdition*" } | Select-Object -ExpandProperty ID -First 1
            
            if (-not $tsID) {
                throw "Could not find task sequence for Windows edition '$WindowsEdition'."
            }
            
            # Create rules to automate deployment
            $customSettingsPath = "$MDTPath\Control\CustomSettings.ini"
            @"
[Settings]
Priority=Default
Properties=MyCustomProperty

[Default]
DeployRoot=\\localhost\DeploymentShare$
SkipBDDWelcome=YES
SkipCapture=NO
SkipApplications=YES
SkipTaskSequence=YES
TaskSequenceID=$tsID
SkipComputerBackup=YES
SkipBitLocker=YES
SkipComputerName=YES
SkipDomainMembership=YES
SkipUserData=YES
SkipLocaleSelection=YES
KeyboardLocale=en-US
UserLocale=en-US
UILanguage=en-US
TimeZoneName=Pacific Standard Time
SkipTimeZone=YES
SkipSummary=YES
SkipFinalSummary=YES
FinishAction=SHUTDOWN
"@ | Out-File -FilePath $customSettingsPath -Encoding ASCII -Force
            
            # Create bootstrap.ini
            $bootstrapPath = "$MDTPath\Control\Bootstrap.ini"
            @"
[Settings]
Priority=Default

[Default]
DeployRoot=\\localhost\DeploymentShare$
UserID=MDTUser
UserPassword=MDTPassword
SkipBDDWelcome=YES
"@ | Out-File -FilePath $bootstrapPath -Encoding ASCII -Force
            
            # Update deployment share
            Write-Log -Message "Updating deployment share..." -Level INFO
            Update-MDTDeploymentShare -Path "DS001:" -Force
            
            # Prepare Hyper-V virtual machine for building
            Write-Log -Message "Creating Hyper-V virtual machine for building..." -Level INFO
            
            # Check if Hyper-V is enabled
            if (-not (Get-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V -Online).State -eq "Enabled") {
                throw "Hyper-V is not enabled on this system."
            }
            
            # Create virtual switch if it doesn't exist
            $switchName = "MDTSwitch"
            if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
                New-VMSwitch -Name $switchName -SwitchType Internal
                
                # Configure IP address for the internal switch
                $interfaceIndex = (Get-NetAdapter | Where-Object { $_.Name -like "*$switchName*" }).ifIndex
                New-NetIPAddress -InterfaceIndex $interfaceIndex -IPAddress 192.168.0.1 -PrefixLength 24
                
                # Configure NAT for internet access
                New-NetNat -Name "MDTNat" -InternalIPInterfaceAddressPrefix 192.168.0.0/24
            }
            
            # Create VM
            $vmName = "MDT-BuildVM-$(Get-Date -Format 'yyyyMMddHHmmss')"
            $vmPath = "C:\Hyper-V\VMs"
            
            if (-not (Test-Path -Path $vmPath)) {
                New-Item -Path $vmPath -ItemType Directory -Force | Out-Null
            }
            
            # Create VM
            New-VM -Name $vmName -Path $vmPath -MemoryStartupBytes 4GB -SwitchName $switchName -Generation 2 -NewVHDPath "$vmPath\$vmName.vhdx" -NewVHDSizeBytes 80GB
            
            # Configure VM
            Set-VM -Name $vmName -ProcessorCount 4 -DynamicMemory -MemoryMinimumBytes 2GB -MemoryMaximumBytes 8GB
            Set-VMFirmware -VMName $vmName -EnableSecureBoot Off
            
            # Mount boot ISO
            $bootIsoPath = "$MDTPath\Boot\LiteTouchPE_x64.iso"
            Add-VMDvdDrive -VMName $vmName -Path $bootIsoPath
            
            # Set boot order to DVD first
            $vmDvdDrive = Get-VMDvdDrive -VMName $vmName
            Set-VMFirmware -VMName $vmName -FirstBootDevice $vmDvdDrive
            
            # Start VM
            Start-VM -Name $vmName
            
            # Wait for build to complete (VM will shut down)
            Write-Log -Message "Waiting for image build to complete (this may take several hours)..." -Level INFO
            
            $timeout = New-TimeSpan -Hours 8
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            
            while ($stopwatch.Elapsed -lt $timeout) {
                $vmState = (Get-VM -Name $vmName).State
                
                if ($vmState -eq "Off") {
                    Write-Log -Message "VM has shut down, build process completed." -Level SUCCESS
                    break
                }
                
                Start-Sleep -Seconds 60
            }
            
            if ((Get-VM -Name $vmName).State -ne "Off") {
                Write-Log -Message "Build process timeout reached. Stopping VM." -Level WARNING
                Stop-VM -Name $vmName -Force
            }
            
            # Check for captured WIM file
            $capturedWimPath = "$MDTPath\Captures\*.wim"
            $wimFiles = Get-Item -Path $capturedWimPath
            
            if (-not $wimFiles) {
                throw "No WIM files found in the captures folder. Build may have failed."
            }
            
            # Copy WIM file to output location
            if (-not (Test-Path -Path $OutputPath)) {
                New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
            }
            
            $destinationWimPath = "$OutputPath\Windows.wim"
            Copy-Item -Path $wimFiles[0].FullName -Destination $destinationWimPath -Force
            
            # Clean up
            Write-Log -Message "Cleaning up VM and temporary files..." -Level INFO
            Remove-VM -Name $vmName -Force
            Remove-Item -Path "$vmPath\$vmName.vhdx" -Force
            
            Write-Log -Message "Image build completed successfully. WIM file saved to '$destinationWimPath'." -Level SUCCESS
            return $destinationWimPath
        }
        catch {
            Write-Log -Message "Image build process failed: $_" -Level ERROR
            
            # Clean up VM if it exists
            if (Get-VM -Name "MDT-BuildVM-*" -ErrorAction SilentlyContinue) {
                Remove-VM -Name "MDT-BuildVM-*" -Force
            }
            
            return $null
        }
    }
}

#endregion

#region Main Execution

$ErrorActionPreference = 'Stop'

try {
    # Start timing
    $startTime = Get-Date
    
    # Decode parameters
    $paramsJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EncodedParams))
    $params = ConvertFrom-Json -InputObject $paramsJson
    
    # Extract parameters
    $WindowsEdition = $params.WindowsEdition
    $UpdateSource = $params.UpdateSource
    $Office365Channel = $params.Office365Channel
    $CustomScriptsPath = $params.CustomScriptsPath
    $OutputPath = $params.OutputPath
    
    # Set default paths
    $MDTPath = "C:\DeploymentShare"
    $ODTPath = "C:\ImageBuilder\Resources\Office"
    $ConfigXMLPath = "C:\ImageBuilder\Resources\Office\configuration.xml"
    
    # Log script start
    Write-Log -Message "========== Starting Windows Image Build Process ==========" -Level INFO
    Write-Log -Message "Windows Edition: $WindowsEdition" -Level INFO
    Write-Log -Message "Update Source: $UpdateSource" -Level INFO
    Write-Log -Message "Office 365 Channel: $Office365Channel" -Level INFO
    
    # Import Windows updates
    $updatesImported = Import-WindowsUpdates -UpdateSource $UpdateSource -MDTPath $MDTPath
    if (-not $updatesImported) {
        Write-Log -Message "Warning: Failed to import Windows updates. Continuing without updates." -Level WARNING
    }
    
    # Set up Office 365 Apps
    $office365Setup = Install-Office365Apps -ODTPath $ODTPath -ConfigXMLPath $ConfigXMLPath -MDTPath $MDTPath -Channel $Office365Channel
    if (-not $office365Setup) {
        Write-Log -Message "Warning: Failed to set up Microsoft 365 Apps. Continuing without Office." -Level WARNING
    }
    
    # Add custom scripts
    $scriptsAdded = Add-CustomScripts -CustomScriptsPath $CustomScriptsPath -MDTPath $MDTPath
    if (-not $scriptsAdded) {
        Write-Log -Message "Warning: Failed to add custom scripts. Continuing without custom scripts." -Level WARNING
    }
    
    # Start image build process
    $wimPath = Start-ImageBuild -MDTPath $MDTPath -OutputPath $OutputPath
    if (-not $wimPath) {
        throw "Image build process failed."
    }
    
    # Calculate elapsed time
    $endTime = Get-Date
    $elapsedTime = New-TimeSpan -Start $startTime -End $endTime
    
    # Log successful completion
    Write-Log -Message "========== Windows Image Build Process Completed Successfully ==========" -Level SUCCESS
    Write-Log -Message "WIM file: $wimPath" -Level INFO
    Write-Log -Message "Total elapsed time: $($elapsedTime.Hours)h $($elapsedTime.Minutes)m $($elapsedTime.Seconds)s" -Level INFO
    
    return $true
}
catch {
    # Log error
    Write-Log -Message "Windows image build process failed: $_" -Level ERROR
    return $false
}

#endregion
