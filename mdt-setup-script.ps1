#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Installs and configures Microsoft Deployment Toolkit (MDT) in the container environment.
.DESCRIPTION
    This script automates the installation and configuration of MDT, including:
    - Downloading and installing MDT
    - Creating deployment shares
    - Configuring MDT settings
    - Setting up task sequences
    - Importing Windows source files
.PARAMETER MDTPath
    Path where MDT will be installed
.PARAMETER DeploymentSharePath
    Path where the MDT deployment share will be created
.EXAMPLE
    .\Setup-MDT.ps1 -MDTPath "C:\Program Files\Microsoft Deployment Toolkit" -DeploymentSharePath "C:\DeploymentShare"
.NOTES
    Author: System Administrator
    Last Edit: 2025-03-16
    Version 1.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$MDTPath = "C:\Program Files\Microsoft Deployment Toolkit",
    
    [Parameter(Mandatory = $false)]
    [string]$DeploymentSharePath = "C:\DeploymentShare"
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
    $logFile = Join-Path -Path $logPath -ChildPath "MDT_Setup_$(Get-Date -Format 'yyyyMMdd').log"
    
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

function Install-MDT {
    [CmdletBinding()]
    param()
    
    process {
        try {
            Write-Log -Message "Starting MDT installation..." -Level INFO
            
            # Download MDT
            $mdtDownloadUrl = "https://download.microsoft.com/download/3/3/9/339BE62D-B4B8-4956-B58D-73C4685FC492/MicrosoftDeploymentToolkit_x64.msi"
            $mdtInstallerPath = "C:\Temp\MicrosoftDeploymentToolkit_x64.msi"
            
            # Create temp directory
            if (-not (Test-Path -Path "C:\Temp")) {
                New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null
            }
            
            # Download MDT installer
            Write-Log -Message "Downloading MDT installer..." -Level INFO
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $mdtDownloadUrl -OutFile $mdtInstallerPath
            
            # Install MDT
            Write-Log -Message "Installing MDT..." -Level INFO
            $mdtInstallArgs = "/i `"$mdtInstallerPath`" /qn INSTALLDIR=`"$MDTPath`""
            $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $mdtInstallArgs -Wait -PassThru
            
            if ($process.ExitCode -ne 0) {
                throw "MDT installation failed with exit code $($process.ExitCode)."
            }
            
            # Install ADK components if not already installed
            # Check if Windows ADK is installed
            $adkInstalled = Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -like "*Windows Assessment and Deployment Kit*" }
            
            if (-not $adkInstalled) {
                Write-Log -Message "Installing Windows ADK..." -Level INFO
                
                # Download ADK installer
                $adkDownloadUrl = "https://go.microsoft.com/fwlink/?linkid=2226703"
                $adkInstallerPath = "C:\Temp\adksetup.exe"
                
                Invoke-WebRequest -Uri $adkDownloadUrl -OutFile $adkInstallerPath
                
                # Install ADK with required features
                $adkInstallArgs = "/quiet /installpath=`"C:\Program Files (x86)\Windows Kits\10`" /features OptionId.DeploymentTools OptionId.UserStateMigrationTool OptionId.ImagingAndConfigurationDesigner"
                $process = Start-Process -FilePath $adkInstallerPath -ArgumentList $adkInstallArgs -Wait -PassThru
                
                if ($process.ExitCode -ne 0) {
                    throw "Windows ADK installation failed with exit code $($process.ExitCode)."
                }
                
                # Download and install ADK WinPE
                $adkWinPEDownloadUrl = "https://go.microsoft.com/fwlink/?linkid=2226592"
                $adkWinPEInstallerPath = "C:\Temp\adkwinpesetup.exe"
                
                Invoke-WebRequest -Uri $adkWinPEDownloadUrl -OutFile $adkWinPEInstallerPath
                
                $adkWinPEInstallArgs = "/quiet /installpath=`"C:\Program Files (x86)\Windows Kits\10`""
                $process = Start-Process -FilePath $adkWinPEInstallerPath -ArgumentList $adkWinPEInstallArgs -Wait -PassThru
                
                if ($process.ExitCode -ne 0) {
                    throw "Windows ADK WinPE installation failed with exit code $($process.ExitCode)."
                }
            }
            
            # Import MDT PowerShell module
            Import-Module "$MDTPath\bin\MicrosoftDeploymentToolkit.psd1"
            
            Write-Log -Message "MDT installation completed successfully." -Level SUCCESS
            return $true
        }
        catch {
            Write-Log -Message "MDT installation failed: $_" -Level ERROR
            return $false
        }
    }
}

function New-MDTDeploymentShare {
    [CmdletBinding()]
    param()
    
    process {
        try {
            Write-Log -Message "Creating MDT deployment share at '$DeploymentSharePath'..." -Level INFO
            
            # Create deployment share directory if it doesn't exist
            if (-not (Test-Path -Path $DeploymentSharePath)) {
                New-Item -Path $DeploymentSharePath -ItemType Directory -Force | Out-Null
            }
            
            # Create deployment share
            New-PSDrive -Name "DS001" -PSProvider MDTProvider -Root $DeploymentSharePath -Description "MDT Deployment Share" -NetworkPath "\\localhost\DeploymentShare$" -Verbose | Add-MDTPersistentDrive
            
            # Update deployment share to create folder structure
            $null = New-Item -Path "DS001:\Boot" -ItemType Directory -Force
            $null = New-Item -Path "DS001:\Operating Systems" -ItemType Directory -Force
            $null = New-Item -Path "DS001:\Applications" -ItemType Directory -Force
            $null = New-Item -Path "DS001:\Packages" -ItemType Directory -Force
            $null = New-Item -Path "DS001:\Task Sequences" -ItemType Directory -Force
            $null = New-Item -Path "DS001:\Out-of-Box Drivers" -ItemType Directory -Force
            $null = New-Item -Path "DS001:\Advanced Configuration" -ItemType Directory -Force
            
            # Configure MDT deployment share settings
            $iniFile = "$DeploymentSharePath\Control\Settings.xml"
            [xml]$settingsXml = Get-Content -Path $iniFile
            
            # Update settings
            $settingsXml.Settings.SupportX86 = "False"
            $settingsXml.Settings.DoNotCreateExtraPartition = "True"
            $settingsXml.Settings.SkipWizard = "SkipSummary,SkipApplications,SkipComputerBackup,SkipBitLocker,SkipBDDWelcome,SkipTaskSequence,SkipComputerName,SkipTimeZone,SkipLocaleSelection,SkipDomainMembership,SkipUserData,SkipCapture"
            $settingsXml.Settings.WSUSServer = ""
            $settingsXml.Settings.FinishAction = "SHUTDOWN"
            
            # Save settings
            $settingsXml.Save($iniFile)
            
            # Create file share
            $shareName = "DeploymentShare$"
            $null = Remove-SmbShare -Name $shareName -Force -ErrorAction SilentlyContinue
            $null = New-SmbShare -Name $shareName -Path $DeploymentSharePath -FullAccess "Administrators" -ChangeAccess "Users"
            
            Write-Log -Message "MDT deployment share created successfully." -Level SUCCESS
            return $true
        }
        catch {
            Write-Log -Message "Failed to create MDT deployment share: $_" -Level ERROR
            return $false
        }
    }
}

function Import-WindowsImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ISOPath,
        
        [Parameter(Mandatory = $true)]
        [string]$WindowsEdition
    )
    
    process {
        try {
            Write-Log -Message "Importing Windows image from ISO '$ISOPath'..." -Level INFO
            
            # Mount ISO
            $mountResult = Mount-DiskImage -ImagePath $ISOPath -PassThru
            $driveLetter = ($mountResult | Get-Volume).DriveLetter
            
            if (-not $driveLetter) {
                throw "Failed to mount ISO."
            }
            
            $drivePath = "$($driveLetter):"
            Write-Log -Message "ISO mounted at drive $drivePath" -Level INFO
            
            # Find install.wim
            $wimPath = "$drivePath\sources\install.wim"
            
            if (-not (Test-Path -Path $wimPath)) {
                # Try install.esd if install.wim doesn't exist
                $wimPath = "$drivePath\sources\install.esd"
                
                if (-not (Test-Path -Path $wimPath)) {
                    throw "Could not find install.wim or install.esd in the ISO."
                }
            }
            
            # Get index of specified Windows edition
            $imageIndexes = Get-WindowsImage -ImagePath $wimPath | Where-Object { $_.ImageName -like "*$WindowsEdition*" }
            
            if (-not $imageIndexes) {
                throw "Could not find Windows edition '$WindowsEdition' in the ISO."
            }
            
            $imageIndex = $imageIndexes[0].ImageIndex
            
            # Import operating system
            $osName = "Windows 10 $WindowsEdition $(Get-Date -Format 'yyyy-MM-dd')"
            $destinationFolder = "DS001:\Operating Systems\$osName"
            
            Import-MDTOperatingSystem -Path "DS001:\Operating Systems" -SourceFile $wimPath -DestinationFolder $osName -SetupPath "$drivePath\" -Index $imageIndex
            
            # Clean up
            Dismount-DiskImage -ImagePath $ISOPath
            
            Write-Log -Message "Windows image imported successfully." -Level SUCCESS
            return $osName
        }
        catch {
            Write-Log -Message "Failed to import Windows image: $_" -Level ERROR
            
            # Clean up
            try {
                if ($ISOPath) {
                    Dismount-DiskImage -ImagePath $ISOPath -ErrorAction SilentlyContinue
                }
            }
            catch {
                # Ignore cleanup errors
            }
            
            return $null
        }
    }
}

function Update-DeploymentShareContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WindowsEdition
    )
    
    process {
        try {
            Write-Log -Message "Updating task sequences, applications and packages..." -Level INFO
            
            # Get imported OS
            $importedOS = Get-ChildItem -Path "DS001:\Operating Systems" | Where-Object { $_.Name -like "*$WindowsEdition*" } | Select-Object -First 1
            
            if (-not $importedOS) {
                throw "Could not find imported Windows OS."
            }
            
            # Create task sequence
            $tsName = "Build Windows $WindowsEdition Image"
            $tsID = "BUILD-$WindowsEdition-$(Get-Date -Format 'yyyyMMdd')"
            
            New-MDTTaskSequence -Path "DS001:\Task Sequences" -ID $tsID -Name $tsName -Template "Client.xml" -OperatingSystemPath "DS001:\Operating Systems\$($importedOS.Name)" -FullName "Windows User" -OrgName "Contoso" -HomePage "about:blank"
            
            # Create selection profile for updates
            New-Item -Path "DS001:\Selection Profiles\Updates" -Enable "True" -Comments "Windows Updates" -Definition "<SelectionProfile><Include path=`"Packages\Windows Updates`" /></SelectionProfile>"
            
            # Configure task sequence to apply updates
            $tsXmlPath = "$DeploymentSharePath\Control\$tsID\ts.xml"
            [xml]$tsXml = Get-Content -Path $tsXmlPath
            
            # Add update steps
            $updateStepXml = @"
<step type="BDD_InstallUpdatesOffline" name="Install Updates Offline" description="" disable="false" continueOnError="false" successCodeList="0 3010" retryCount="2" retryDelay="30">
    <defaultVarList>
        <variable name="SelectionProfile" property="SelectionProfile">Updates</variable>
    </defaultVarList>
    <action>cscript.exe "%SCRIPTROOT%\ZTIPatches.wsf"</action>
</step>
"@
            
            # Find the "Tattoo" step to insert after
            $tattooStep = $tsXml.SelectSingleNode("//step[@name='Tattoo']")
            
            if ($tattooStep) {
                $updateStepNode = $tsXml.CreateElement("sequence")
                $updateStepNode.InnerXml = $updateStepXml
                $tattooStep.ParentNode.InsertAfter($updateStepNode.FirstChild, $tattooStep)
            }
            
            # Add sysprep capture steps
            $sysprepXml = @"
<group expand="true" name="Capture Image" description="Prepares and captures the reference image">
    <step type="BDD_PrepareOS" name="Prepare OS for Capture" description="" disable="false" continueOnError="false" successCodeList="0 3010" retryCount="2" retryDelay="30">
        <defaultVarList>
            <variable name="DoCapture" property="DoCapture">YES</variable>
        </defaultVarList>
        <action>cscript.exe "%SCRIPTROOT%\ZTIPrepareOS.wsf"</action>
    </step>
    <step type="BDD_Capture" name="Capture Image" description="" disable="false" continueOnError="false" successCodeList="0 3010" retryCount="2" retryDelay="30">
        <defaultVarList>
            <variable name="CaptureDestination" property="CaptureDestination">\\localhost\DeploymentShare$\Captures</variable>
            <variable name="CompressionType" property="CompressionType">Maximum</variable>
            <variable name="CaptureFolderPath" property="CaptureFolderPath">\Captures</variable>
        </defaultVarList>
        <action>cscript.exe "%SCRIPTROOT%\ZTIBackup.wsf"</action>
    </step>
</group>
"@
            
            # Add capture group at the end
            $stateRestoreGroup = $tsXml.SelectSingleNode("//group[@name='State Restore']")
            
            if ($stateRestoreGroup) {
                $captureGroupNode = $tsXml.CreateElement("sequence")
                $captureGroupNode.InnerXml = $sysprepXml
                $stateRestoreGroup.ParentNode.InsertAfter($captureGroupNode.FirstChild, $stateRestoreGroup)
            }
            
            # Save task sequence XML
            $tsXml.Save($tsXmlPath)
            
            # Create Captures folder if it doesn't exist
            $capturesFolder = "$DeploymentSharePath\Captures"
            if (-not (Test-Path -Path $capturesFolder)) {
                New-Item -Path $capturesFolder -ItemType Directory -Force | Out-Null
            }
            
            # Update deployment share (generate boot images)
            Write-Log -Message "Updating deployment share (generating boot images)..." -Level INFO
            Update-MDTDeploymentShare -Path "DS001:" -Force
            
            Write-Log -Message "Deployment share content updated successfully." -Level SUCCESS
            return $true
        }
        catch {
            Write-Log -Message "Failed to update deployment share content: $_" -Level ERROR
            return $false
        }
    }
}

#endregion

#region Main Execution

$ErrorActionPreference = 'Stop'

try {
    # Start timing
    $startTime = Get-Date
    
    # Log script start
    Write-Log -Message "========== Starting MDT Setup Process ==========" -Level INFO
    
    # Install MDT
    $mdtInstalled = Install-MDT
    if (-not $mdtInstalled) {
        throw "MDT installation failed."
    }
    
    # Create deployment share
    $dsCreated = New-MDTDeploymentShare
    if (-not $dsCreated) {
        throw "Failed to create MDT deployment share."
    }
    
    # Log setup completion
    $endTime = Get-Date
    $elapsedTime = New-TimeSpan -Start $startTime -End $endTime
    
    Write-Log -Message "========== MDT Setup Process Completed Successfully ==========" -Level SUCCESS
    Write-Log -Message "Total elapsed time: $($elapsedTime.Hours)h $($elapsedTime.Minutes)m $($elapsedTime.Seconds)s" -Level INFO
    
    return $true
}
catch {
    # Log error
    Write-Log -Message "MDT setup process failed: $_" -Level ERROR
    return $false
}

#endregion
