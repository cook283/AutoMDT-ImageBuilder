# Use Windows Server Core as the base image
FROM mcr.microsoft.com/windows/servercore:ltsc2022

# Set working directory
WORKDIR C:\\ImageBuilder

# Install Windows features needed for MDT
RUN powershell -Command \
    $ErrorActionPreference = 'Stop'; \
    Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart; \
    Enable-WindowsOptionalFeature -Online -FeatureName NetFx4-AdvSvcsPack -All -NoRestart; \
    Install-WindowsFeature -Name Web-WebServer,Web-Asp-Net,Web-Net-Ext,Web-ISAPI-Ext,Web-ISAPI-Filter,Web-Mgmt-Console,Web-Scripting-Tools

# Install Windows ADK for Windows 10
RUN powershell -Command \
    $ErrorActionPreference = 'Stop'; \
    New-Item -Path C:\\Temp -ItemType Directory -Force; \
    Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2226703' -OutFile C:\\Temp\\adksetup.exe; \
    Start-Process -FilePath C:\\Temp\\adksetup.exe -ArgumentList '/quiet /installpath="C:\Program Files (x86)\Windows Kits\10" /features OptionId.DeploymentTools OptionId.UserStateMigrationTool OptionId.ImagingAndConfigurationDesigner' -Wait; \
    Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2226592' -OutFile C:\\Temp\\adkwinpesetup.exe; \
    Start-Process -FilePath C:\\Temp\\adkwinpesetup.exe -ArgumentList '/quiet /installpath="C:\Program Files (x86)\Windows Kits\10"' -Wait

# Install Microsoft Deployment Toolkit
RUN powershell -Command \
    $ErrorActionPreference = 'Stop'; \
    Invoke-WebRequest -Uri 'https://download.microsoft.com/download/3/3/9/339BE62D-B4B8-4956-B58D-73C4685FC492/MicrosoftDeploymentToolkit_x64.msi' -OutFile C:\\Temp\\MDT.msi; \
    Start-Process -FilePath msiexec.exe -ArgumentList '/i C:\\Temp\\MDT.msi /qn INSTALLDIR="C:\DeploymentShare"' -Wait

# Install Hyper-V PowerShell modules
RUN powershell -Command \
    $ErrorActionPreference = 'Stop'; \
    Install-WindowsFeature -Name Hyper-V-PowerShell

# Set up directory structure
RUN powershell -Command \
    $ErrorActionPreference = 'Stop'; \
    New-Item -Path C:\\ImageBuilder\\Scripts -ItemType Directory -Force; \
    New-Item -Path C:\\ImageBuilder\\Scripts\\Custom -ItemType Directory -Force; \
    New-Item -Path C:\\ImageBuilder\\Resources -ItemType Directory -Force; \
    New-Item -Path C:\\Logs\\MDT -ItemType Directory -Force; \
    New-Item -Path C:\\Capture -ItemType Directory -Force

# Copy scripts
COPY Setup-MDT.ps1 C:\\ImageBuilder\\
COPY MDT-BuildImage.ps1 C:\\ImageBuilder\\

# Copy resources
COPY Resources\\ C:\\ImageBuilder\\Resources\\

# Set PowerShell as the entrypoint
ENTRYPOINT ["powershell.exe", "-ExecutionPolicy", "Bypass"]
