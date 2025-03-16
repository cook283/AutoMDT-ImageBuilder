#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -Modules ConfigurationManager, Hyper-V, ThreadJob

<#
.SYNOPSIS
    Fully automated containerized Windows image creation with MDT and SCCM integration.
.DESCRIPTION
    This script orchestrates the entire process of creating a Windows image within a container,
    capturing it, validating it, and integrating it with SCCM for deployment.
    
    The workflow includes:
    1. Setting up a containerized environment
    2. Installing and configuring MDT within the container
    3. Building a Windows image with updates and Microsoft 365 Apps
    4. Capturing the image to a WIM file
    5. Validating the WIM file
    6. Uploading to a network location
    7. Integrating with SCCM
    8. Distributing to deployment points
    
.PARAMETER ConfigPath
    Path to the JSON configuration file
.PARAMETER LogPath
    Path where logs will be stored
.PARAMETER NoCleanup
    Switch to prevent cleanup of temporary files and containers
.EXAMPLE
    .\Main-AutomatedImageBuilder.ps1 -ConfigPath "C:\ImageAutomation\config.json"
.NOTES
    Author: System Administrator
    Last Edit: 2025-03-16
    Version 1.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,
    
    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\ImageAutomation\Logs",
    
    [Parameter(Mandatory = $false)]
    [switch]$NoCleanup
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
    if (-not (Test-Path -Path $LogPath)) {
        New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
    }
    
    # Define log file with date stamp
    $logFile = Join-Path -Path $LogPath -ChildPath "ImageBuilder_$(Get-Date -Format 'yyyyMMdd').log"
    
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

function Send-Notification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Subject,
        
        [Parameter(Mandatory = $true)]
        [string]$Body,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )
    
    try {
        $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
        
        $emailParams = @{
            SmtpServer  = $config.Notifications.SmtpServer
            Port        = $config.Notifications.Port
            UseSsl      = $config.Notifications.UseSsl
            From        = $config.Notifications.From
            To          = $config.Notifications.Recipients
            Subject     = "[$Level] Windows Image Builder: $Subject"
            Body        = $Body
            BodyAsHtml  = $true
        }
        
        # Add credentials if specified in config
        if ($config.Notifications.UseCredentials) {
            $securePassword = ConvertTo-SecureString $config.Notifications.Password -AsPlainText -Force
            $credentials = New-Object System.Management.Automation.PSCredential($config.Notifications.Username, $securePassword)
            $emailParams.Credential = $credentials
        }
        
        Send-MailMessage @emailParams
        Write-Log -Message "Notification sent: $Subject" -Level INFO
    }
    catch {
        Write-Log -Message "Failed to send notification: $_" -Level ERROR
    }
}

function Test-Prerequisites {
    [CmdletBinding()]
    param()
    
    process {
        try {
            Write-Log -Message "Checking prerequisites..." -Level INFO
            
            # Verify PowerShell version
            if ($PSVersionTable.PSVersion.Major -lt 5) {
                throw "PowerShell 5.1 or higher is required."
            }
            
            # Verify running as Administrator
            $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
            if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
                throw "This script must be run as Administrator."
            }
            
            # Verify required modules
            $requiredModules = @('ConfigurationManager', 'Hyper-V', 'ThreadJob')
            foreach ($module in $requiredModules) {
                if (-not (Get-Module -Name $module -ListAvailable)) {
                    throw "Required module '$module' is not installed."
                }
            }
            
            # Check if Docker is installed and running
            try {
                $dockerStatus = docker info
                if (-not $?) {
                    throw "Docker is not running or accessible."
                }
            }
            catch {
                throw "Docker is not installed or not running. Please install Docker Desktop with Windows container support."
            }
            
            # Check if Windows containers are enabled
            try {
                $windowsContainerCheck = docker info | Select-String "OSType: windows"
                if (-not $windowsContainerCheck) {
                    throw "Windows containers are not enabled in Docker."
                }
            }
            catch {
                throw "Failed to check Windows container status: $_"
            }
            
            # Verify configuration file
            if (-not (Test-Path -Path $ConfigPath)) {
                throw "Configuration file not found at '$ConfigPath'."
            }
            
            try {
                $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
            }
            catch {
                throw "Invalid JSON in configuration file: $_"
            }
            
            # Verify network share access
            $networkShare = $config.ImageCapture.DestinationShare
            if (-not (Test-Path -Path $networkShare)) {
                throw "Cannot access network share at '$networkShare'."
            }
            
            # Verify SCCM connection
            try {
                Import-Module ConfigurationManager
                $sccmSitePath = $config.SCCM.SitePath
                if (-not (Test-Path -Path $sccmSitePath)) {
                    throw "Cannot access SCCM site at '$sccmSitePath'."
                }
                Push-Location $sccmSitePath
                # Test basic SCCM command
                $null = Get-CMSite
                Pop-Location
            }
            catch {
                throw "Failed to connect to SCCM: $_"
            }
            
            Write-Log -Message "All prerequisites verified successfully." -Level SUCCESS
            return $true
        }
        catch {
            Write-Log -Message "Prerequisite check failed: $_" -Level ERROR
            Send-Notification -Subject "Prerequisite Check Failed" -Body "The image building process could not start due to failed prerequisites: $_" -Level ERROR
            return $false
        }
    }
}

function New-ImageBuildContainer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config
    )
    
    process {
        try {
            Write-Log -Message "Creating Windows container for image building..." -Level INFO
            
            # Prepare Docker files directory
            $dockerFilesPath = Join-Path -Path $env:TEMP -ChildPath "ImageBuilder_Docker_$(Get-Date -Format 'yyyyMMddHHmmss')"
            New-Item -Path $dockerFilesPath -ItemType Directory -Force | Out-Null
            
            # Create Dockerfile
            $dockerfilePath = Join-Path -Path $dockerFilesPath -ChildPath "Dockerfile"
            @"
# Use the specified Windows container image
FROM $($Config.Container.BaseImage)

# Set working directory
WORKDIR C:\\ImageBuilder

# Install Windows features needed for MDT
RUN dism /online /enable-feature /featurename:NetFX3 /all
RUN dism /online /enable-feature /featurename:NetFX4 /all
RUN Install-WindowsFeature -Name Web-WebServer,Web-Asp-Net,Web-Net-Ext,Web-ISAPI-Ext,Web-ISAPI-Filter,Web-Mgmt-Console,Web-Scripting-Tools

# Copy scripts and resources
COPY Scripts\\ C:\\ImageBuilder\\Scripts\\
COPY Resources\\ C:\\ImageBuilder\\Resources\\

# Set PowerShell as the entrypoint
ENTRYPOINT ["powershell.exe", "-ExecutionPolicy", "Bypass"]
"@ | Out-File -FilePath $dockerfilePath -Encoding utf8
            
            # Create scripts directory and copy scripts
            $scriptsDir = Join-Path -Path $dockerFilesPath -ChildPath "Scripts"
            New-Item -Path $scriptsDir -ItemType Directory -Force | Out-Null
            
            # Create MDT setup script
            $mdtSetupScript = Join-Path -Path $scriptsDir -ChildPath "Setup-MDT.ps1"
            $mdtSetupScriptContent = Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath "Setup-MDT.ps1") -Raw
            $mdtSetupScriptContent | Out-File -FilePath $mdtSetupScript -Encoding utf8
            
            # Create resources directory
            $resourcesDir = Join-Path -Path $dockerFilesPath -ChildPath "Resources"
            New-Item -Path $resourcesDir -ItemType Directory -Force | Out-Null
            
            # Copy ODT and configuration
            Copy-Item -Path $Config.Office365.ODTPath -Destination $resourcesDir -Recurse
            Copy-Item -Path $Config.Office365.ConfigXMLPath -Destination $resourcesDir
            
            # Copy Windows ISO if specified
            if ($Config.Windows.ISOPath) {
                Copy-Item -Path $Config.Windows.ISOPath -Destination $resourcesDir
            }
            
            # Build the Docker image
            $containerImageName = "mdt-image-builder:$(Get-Date -Format 'yyyyMMdd')"
            Write-Log -Message "Building Docker image '$containerImageName'..." -Level INFO
            $buildResult = docker build -t $containerImageName $dockerFilesPath
            
            if (-not $?) {
                throw "Failed to build Docker image: $buildResult"
            }
            
            # Create and run the container
            $containerName = "mdt-image-builder-$(Get-Date -Format 'yyyyMMddHHmmss')"
            $runResult = docker run --name $containerName -d -v $Config.ImageCapture.TempLocation:C:\Capture $containerImageName -Command "Start-Sleep -Seconds 86400"
            
            if (-not $?) {
                throw "Failed to create and run container: $runResult"
            }
            
            Write-Log -Message "Container '$containerName' created and running." -Level SUCCESS
            return $containerName
        }
        catch {
            Write-Log -Message "Failed to create image build container: $_" -Level ERROR
            Send-Notification -Subject "Container Creation Failed" -Body "Failed to create the image building container: $_" -Level ERROR
            return $null
        }
    }
}

function Invoke-MDTImageBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ContainerName,
        
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config
    )
    
    process {
        try {
            Write-Log -Message "Starting MDT image build process in container '$ContainerName'..." -Level INFO
            
            # Copy MDT build script to container
            $localMDTBuildScript = Join-Path -Path $PSScriptRoot -ChildPath "MDT-BuildImage.ps1"
            docker cp $localMDTBuildScript ${ContainerName}:C:\ImageBuilder\MDT-BuildImage.ps1
            
            # Execute MDT build script in container
            $buildParams = @{
                WindowsEdition = $Config.Windows.Edition
                UpdateSource = $Config.Windows.UpdateSource
                Office365Channel = $Config.Office365.Channel
                CustomScriptsPath = "C:\ImageBuilder\Scripts\Custom"
                OutputPath = "C:\Capture"
            } | ConvertTo-Json -Compress
            
            $encodedParams = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($buildParams))
            
            $buildCommand = "powershell.exe -ExecutionPolicy Bypass -File C:\ImageBuilder\MDT-BuildImage.ps1 -EncodedParams $encodedParams"
            $buildResult = docker exec $ContainerName cmd /c $buildCommand
            
            if (-not $?) {
                throw "MDT image build failed in container: $buildResult"
            }
            
            # Check for the expected WIM file
            $wimCheckCommand = "if (Test-Path -Path 'C:\Capture\Windows.wim') { Write-Host 'WIM_FILE_EXISTS' }"
            $wimCheckResult = docker exec $ContainerName powershell.exe -Command $wimCheckCommand
            
            if ($wimCheckResult -ne "WIM_FILE_EXISTS") {
                throw "WIM file was not created successfully."
            }
            
            Write-Log -Message "MDT image build completed successfully." -Level SUCCESS
            return $true
        }
        catch {
            Write-Log -Message "MDT image build failed: $_" -Level ERROR
            Send-Notification -Subject "MDT Image Build Failed" -Body "The MDT image build process failed in the container: $_" -Level ERROR
            return $false
        }
    }
}

function Test-WIMFileIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WIMPath
    )
    
    process {
        try {
            Write-Log -Message "Validating WIM file integrity for '$WIMPath'..." -Level INFO
            
            # Check if file exists
            if (-not (Test-Path -Path $WIMPath)) {
                throw "WIM file not found at '$WIMPath'."
            }
            
            # Check file size (should be at least 2GB for a Windows image)
            $fileSize = (Get-Item -Path $WIMPath).Length
            if ($fileSize -lt 2GB) {
                throw "WIM file is too small ($($fileSize / 1GB) GB). Expected at least 2GB."
            }
            
            # Use DISM to check WIM integrity
            $dismResult = dism /Check-ImageHealth /ImageFile:$WIMPath
            
            if ($dismResult -notcontains "The image is in good health.") {
                throw "DISM integrity check failed: $dismResult"
            }
            
            # Get image info
            $imageInfo = dism /Get-ImageInfo /ImageFile:$WIMPath
            
            if ($imageInfo -notcontains "Index") {
                throw "Failed to get image information from WIM file."
            }
            
            Write-Log -Message "WIM file validation passed successfully." -Level SUCCESS
            return $true
        }
        catch {
            Write-Log -Message "WIM file validation failed: $_" -Level ERROR
            Send-Notification -Subject "WIM Validation Failed" -Body "The WIM file integrity check failed: $_" -Level ERROR
            return $false
        }
    }
}

function Copy-WIMToNetworkShare {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceWIMPath,
        
        [Parameter(Mandatory = $true)]
        [string]$DestinationShare,
        
        [Parameter(Mandatory = $false)]
        [PSCredential]$Credential
    )
    
    process {
        try {
            Write-Log -Message "Copying WIM file to network share '$DestinationShare'..." -Level INFO
            
            # Ensure destination directory exists
            if (-not (Test-Path -Path $DestinationShare)) {
                if ($Credential) {
                    New-Item -Path $DestinationShare -ItemType Directory -Credential $Credential -Force | Out-Null
                }
                else {
                    New-Item -Path $DestinationShare -ItemType Directory -Force | Out-Null
                }
            }
            
            # Generate destination filename with timestamp
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $destinationFileName = "Windows_Image_$timestamp.wim"
            $destinationPath = Join-Path -Path $DestinationShare -ChildPath $destinationFileName
            
            # Copy file with progress
            $copyParams = @{
                Path = $SourceWIMPath
                Destination = $destinationPath
                Force = $true
            }
            
            if ($Credential) {
                $copyParams.Credential = $Credential
            }
            
            Copy-Item @copyParams
            
            # Verify copy
            if (-not (Test-Path -Path $destinationPath)) {
                throw "Failed to copy WIM file to '$destinationPath'."
            }
            
            $sourceHash = Get-FileHash -Path $SourceWIMPath -Algorithm SHA256
            $destHash = Get-FileHash -Path $destinationPath -Algorithm SHA256
            
            if ($sourceHash.Hash -ne $destHash.Hash) {
                throw "File hash mismatch between source and destination."
            }
            
            Write-Log -Message "WIM file copied successfully to '$destinationPath'." -Level SUCCESS
            return $destinationPath
        }
        catch {
            Write-Log -Message "Failed to copy WIM file to network share: $_" -Level ERROR
            Send-Notification -Subject "WIM File Copy Failed" -Body "Failed to copy the WIM file to the network share: $_" -Level ERROR
            return $null
        }
    }
}

function Update-SCCMOSImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WIMPath,
        
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config
    )
    
    process {
        try {
            Write-Log -Message "Updating SCCM OS Image with new WIM file..." -Level INFO
            
            # Import ConfigurationManager module
            Import-Module ConfigurationManager
            
            # Connect to SCCM site
            Push-Location $Config.SCCM.SitePath
            
            # Get existing OS Image or create new one
            $osImageName = $Config.SCCM.OSImageName
            $osImage = Get-CMOperatingSystemImage -Name $osImageName
            
            if ($osImage) {
                # Update existing OS Image
                Write-Log -Message "Updating existing OS Image '$osImageName'..." -Level INFO
                
                Set-CMOperatingSystemImage -Name $osImageName -Path $WIMPath -Description "Updated on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                
                # Trigger content update
                Update-CMDistributionPoint -OperatingSystemImageName $osImageName
            }
            else {
                # Create new OS Image
                Write-Log -Message "Creating new OS Image '$osImageName'..." -Level INFO
                
                New-CMOperatingSystemImage -Name $osImageName -Path $WIMPath -Description "Created on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                
                # Distribute content to distribution points
                $dpGroups = $Config.SCCM.DistributionPointGroups
                
                foreach ($dpGroup in $dpGroups) {
                    Start-CMContentDistribution -OperatingSystemImageName $osImageName -DistributionPointGroupName $dpGroup
                }
            }
            
            # Verify OS Image exists and has content
            $updatedOSImage = Get-CMOperatingSystemSystemImage -Name $osImageName
            
            if (-not $updatedOSImage) {
                throw "Failed to find OS Image '$osImageName' after update."
            }
            
            Pop-Location
            
            Write-Log -Message "SCCM OS Image updated successfully." -Level SUCCESS
            return $true
        }
        catch {
            Write-Log -Message "Failed to update SCCM OS Image: $_" -Level ERROR
            Send-Notification -Subject "SCCM Integration Failed" -Body "Failed to update the SCCM OS Image: $_" -Level ERROR
            
            # Return to original location
            if ((Get-Location).Path -eq $Config.SCCM.SitePath) {
                Pop-Location
            }
            
            return $false
        }
    }
}

function Remove-ImageBuildContainer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ContainerName
    )
    
    process {
        try {
            Write-Log -Message "Cleaning up container '$ContainerName'..." -Level INFO
            
            # Stop container
            docker stop $ContainerName
            
            # Remove container
            docker rm $ContainerName
            
            Write-Log -Message "Container cleanup completed successfully." -Level INFO
            return $true
        }
        catch {
            Write-Log -Message "Failed to clean up container: $_" -Level WARNING
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
    
    # Load configuration
    $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    
    # Log script start
    Write-Log -Message "========== Starting Automated Image Building Process ==========" -Level INFO
    
    # Send notification of process start
    Send-Notification -Subject "Image Building Process Started" -Body "The automated Windows image building process has started." -Level INFO
    
    # Check prerequisites
    $prerequisitesOk = Test-Prerequisites
    if (-not $prerequisitesOk) {
        throw "Prerequisites check failed. Aborting process."
    }
    
    # Create temporary location for image capture
    $tempLocation = $config.ImageCapture.TempLocation
    if (-not (Test-Path -Path $tempLocation)) {
        New-Item -Path $tempLocation -ItemType Directory -Force | Out-Null
    }
    
    # Create container for image building
    $containerName = New-ImageBuildContainer -Config $config
    if (-not $containerName) {
        throw "Failed to create image building container."
    }
    
    # Build image using MDT in container
    $buildSuccess = Invoke-MDTImageBuild -ContainerName $containerName -Config $config
    if (-not $buildSuccess) {
        throw "Image building process failed."
    }
    
    # Locate WIM file
    $wimPath = Join-Path -Path $tempLocation -ChildPath "Windows.wim"
    
    # Validate WIM file
    $wimValid = Test-WIMFileIntegrity -WIMPath $wimPath
    if (-not $wimValid) {
        throw "WIM file validation failed."
    }
    
    # Copy WIM to network share
    $networkSharePath = Copy-WIMToNetworkShare -SourceWIMPath $wimPath -DestinationShare $config.ImageCapture.DestinationShare
    if (-not $networkSharePath) {
        throw "Failed to copy WIM file to network share."
    }
    
    # Update SCCM OS Image
    $sccmUpdateSuccess = Update-SCCMOSImage -WIMPath $networkSharePath -Config $config
    if (-not $sccmUpdateSuccess) {
        throw "Failed to update SCCM OS Image."
    }
    
    # Clean up unless NoCleanup switch is specified
    if (-not $NoCleanup) {
        Remove-ImageBuildContainer -ContainerName $containerName
        Remove-Item -Path $wimPath -Force
    }
    
    # Calculate elapsed time
    $endTime = Get-Date
    $elapsedTime = New-TimeSpan -Start $startTime -End $endTime
    
    # Log successful completion
    Write-Log -Message "========== Image Building Process Completed Successfully ==========" -Level SUCCESS
    Write-Log -Message "Total elapsed time: $($elapsedTime.Hours)h $($elapsedTime.Minutes)m $($elapsedTime.Seconds)s" -Level INFO
    
    # Send completion notification
    $notificationBody = @"
<h2>Windows Image Building Process Completed Successfully</h2>
<p><strong>Image:</strong> $networkSharePath</p>
<p><strong>SCCM OS Image:</strong> $($config.SCCM.OSImageName)</p>
<p><strong>Total Time:</strong> $($elapsedTime.Hours)h $($elapsedTime.Minutes)m $($elapsedTime.Seconds)s</p>
"@
    
    Send-Notification -Subject "Image Building Process Completed" -Body $notificationBody -Level SUCCESS
    
    return $true
}
catch {
    # Log error
    Write-Log -Message "Image building process failed: $_" -Level ERROR
    
    # Send failure notification
    $notificationBody = @"
<h2>Windows Image Building Process Failed</h2>
<p><strong>Error:</strong> $_</p>
<p><strong>Please check logs at:</strong> $LogPath</p>
"@
    
    Send-Notification -Subject "Image Building Process Failed" -Body $notificationBody -Level ERROR
    
    return $false
}

#endregion
