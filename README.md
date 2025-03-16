# Automated MDT Windows Image Builder

This solution provides a fully automated, containerized approach to building and maintaining standardized Windows images using Microsoft Deployment Toolkit (MDT) and integrating with Microsoft Endpoint Configuration Manager (MEMCM/SCCM).

## Overview

The solution automates the following workflow:

1. **Image Creation Process**
   - Utilizes a Windows-based container environment as a clean, disposable build workspace
   - Automates the provisioning of Windows images using MDT within the container
   - Applies the most recent Windows updates from Microsoft Update Catalog or WSUS
   - Installs Microsoft 365 Apps for Enterprise using the Office Deployment Tool (ODT)
   - Allows for custom scripts and installers within the MDT task sequence

2. **Image Capture and Storage**
   - Automates sysprep and WIM file capture
   - Validates the WIM file integrity
   - Securely uploads the WIM to a network share

3. **SCCM Integration**
   - Updates the Operating System Image object in SCCM with the new WIM file
   - Distributes the updated image to all relevant Distribution Points (DPs)
   - Provides comprehensive error handling and notifications

## Prerequisites

- Windows Server with the following components:
  - PowerShell 5.1 or higher
  - Docker Desktop with Windows Containers support
  - Hyper-V
  - SCCM console installed with ConfigurationManager PowerShell module
  - Network access to SCCM server and distribution points
  - Access to a network share for storing WIM files

## Directory Structure

```
ImageAutomation/
├── Main-AutomatedImageBuilder.ps1    # Main orchestration script
├── Setup-MDT.ps1                     # MDT installation and configuration
├── MDT-BuildImage.ps1                # Image building process
├── config.json                       # Configuration file
├── Dockerfile                        # Container definition
├── docker-compose.yml                # Container orchestration
├── Resources/                        # Resources directory
│   ├── Office/                       # Office 365 ODT and configuration
│   │   ├── setup.exe                 # Office Deployment Tool
│   │   └── configuration.xml         # Office configuration
│   └── Windows.iso                   # (Optional) Windows installation media
└── Scripts/                          # Custom scripts directory
    └── Custom/                       # Custom scripts for image customization
        ├── Hardening.ps1             # Security hardening script
        ├── InstallApplications.ps1   # Application installation script
        └── ConfigureSettings.ps1     # Windows settings configuration
```

## Configuration

The solution uses a `config.json` file to configure all aspects of the image building process. Edit this file to match your environment before running the automation.

Key configuration sections:

- **Windows**: Specifies the Windows edition and update source
- **Office365**: Configures Microsoft 365 Apps installation
- **Container**: Sets container specifications
- **ImageCapture**: Defines temporary and permanent storage locations
- **SCCM**: Configures SCCM integration
- **Notifications**: Sets up email notifications
- **CustomizationScripts**: Lists custom scripts to be included in the image

## Usage

1. Clone or download this repository
2. Edit the `config.json` file to match your environment
3. Place the Office Deployment Tool and configuration in the Resources/Office directory
4. Add any custom scripts to the Scripts/Custom directory
5. Run the main script:

```powershell
.\Main-AutomatedImageBuilder.ps1 -ConfigPath "C:\ImageAutomation\config.json"
```

### Optional Parameters

- `-LogPath`: Specify a custom log location (default: C:\ImageAutomation\Logs)
- `-NoCleanup`: Prevent cleanup of temporary files and containers

## Advanced Customization

### Custom Scripts

Add custom PowerShell, VBScript, or batch scripts to the Scripts/Custom directory to perform additional customization tasks during the image building process. These scripts will be automatically integrated into the MDT task sequence.

### Office 365 Configuration

Edit the `configuration.xml` file to customize the Microsoft 365 Apps installation. Refer to the [Office Customization Tool](https://config.office.com/) for more options.

### Container Customization

Modify the Dockerfile and docker-compose.yml files to customize the container environment.

## Error Handling and Logging

The solution provides comprehensive error handling and logging:

- Detailed logs are stored in the specified log directory
- Email notifications are sent at key stages of the process
- Each major function includes robust error handling

## Security Considerations

- Credentials for network shares and SMTP are stored in the configuration file and should be secured
- Use secure, encrypted network connections for file transfers
- Consider using environment variables for sensitive information rather than storing in the configuration file

## Troubleshooting

If the automation fails, check the logs in the specified log directory for detailed error information. Common issues include:

- Network connectivity issues to SCCM or file shares
- Insufficient permissions for the account running the automation
- Container resource limitations (memory, CPU)
- Missing prerequisites or resources

## Contributing

Feel free to contribute to this project by submitting issues or pull requests.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
