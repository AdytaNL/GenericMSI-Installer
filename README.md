# Generic MSI Installer

⚠️ **Disclaimer**
This script was developed for internal use. You are free to use or adapt it under the license below, but:

- It is not actively maintained
- No support is provided
- Use at your own risk

Feel free to submit pull requests if you find ways to improve it — but please understand there is no guarantee of response.


A reusable PowerShell framework for installing and uninstalling MSIs, designed for seamless integration with Microsoft Intune Win32 app deployments.

## Contents

- **GenericMSI-Installer.ps1**: Wrapper to install any MSI with logging, hooks, and verification.
- **GenericMSI-UnInstaller.ps1**: Companion script to uninstall by ProductCode with the same logging and cleanup.

## Prerequisites

- Windows PowerShell (tested on 5.1+).
- Administrator privileges to install/uninstall applications.

## Optional - script can be used with/without Intune
- Microsoft Intune Win32 Content Prep Tool for packaging into `.intunewin`. 

## Packaging for Intune

> **Note**: For `GenericMSI-UnInstaller.ps1`, you must set the `$ProductCode` variable to your MSI’s GUID (including braces) inside the script. If you don’t know the code, you can extract MSI properties using the [`GetMSI-Info.ps1`](https://github.com/AdytaNL/GetMSI-Info/blob/main/GetMSI-Info.ps1) helper script.
>
> **Note**: For `GenericMSI-Installer.ps1`, place your MSI file in the same directory as the scripts and set the `$MSIFileName` variable at the top of the script to match the MSI filename.

1. Place your MSI, `GenericMSI-Installer.ps1`, and `GenericMSI-UnInstaller.ps1` in the same folder.
2. Run the Intune Win32 Content Prep Tool to generate a `.intunewin` package.
3. In Intune:
   - **Install command**:
     ```powershell
     powershell.exe -ExecutionPolicy Bypass -File GenericMSI-Installer.ps1
     ```
   - **Uninstall command**:
     ```powershell
     powershell.exe -ExecutionPolicy Bypass -File GenericMSI-UnInstaller.ps1
     ```
   - **Detection rule**: Use the MSI’s ProductCode in the registry or a custom registry/file check matching your script’s verification logic.

## 64-bit PowerShell Check

Intune launches PowerShell in 32-bit mode by default on 64-bit systems unless you explicitly reference the 64-bit executable path in the Intune GUI. This script uses self-elevation logic to ensure that even when using a generic `powershell.exe ...` install command, the script will restart itself in the 64-bit host, preserving correct behavior for MSI installs and registry access.

This function ensures your scripts always execute in the correct PowerShell host, avoiding issues with registry redirection or process architecture.

## Functions Reference

### Write-Log

**Description**: Logs timestamped messages to both console and a file.

**Usage**:
```powershell
Write-Log -Message <string> [-Level <string>]
```
- `-Message` (string, required): Text to log.
- `-Level` (string, default "INFO"): One of `INFO`, `WARNING`, `ERROR`, etc.

**Example**:
```powershell
Write-Log -Message "Starting MSI installation" -Level "INFO"
```

---

### Log-Info

**Description**: Wrapper around `Write-Log` that logs a message at the **INFO** level.

**Usage**:
```powershell
Log-Info -Message <string>
```
- `-Message` (string, required): The text to log.

**Example**:
```powershell
Log-Info -Message "Starting MSI installation"
```

---

### Log-Warning

**Description**: Wrapper around `Write-Log` that logs a message at the **WARNING** level.

**Usage**:
```powershell
Log-Warning -Message <string>
```
- `-Message` (string, required): The text to log.

**Example**:
```powershell
Log-Warning -Message "Installation completed with non-fatal issues"
```

---

### Log-Error

**Description**: Wrapper around `Write-Log` that logs a message at the **ERROR** level.

**Usage**:
```powershell
Log-Error -Message <string>
```
- `-Message` (string, required): The text to log.

**Example**:
```powershell
Log-Error -Message "Failed to install MSI package"
```

---

### Get-MSIProperty

**Description**: Retrieves a raw property from an MSI via COM.

**Usage**:
```powershell
Get-MSIProperty -PropertyName <string>
```
- `-PropertyName` (string, required): e.g. "ProductCode", "ProductVersion".

**Example**:
```powershell
$code = Get-MSIProperty -PropertyName "ProductCode"
Write-Log -Message "Raw ProductCode: $code"
```

---

### Get-MSIPropertyAndTrim

**Description**: Wraps `Get-MSIProperty`, trims whitespace, and defaults to "Unknown" if empty.

**Usage**:
```powershell
Get-MSIPropertyAndTrim -PropertyName <string>
```

**Example**:
```powershell
$version = Get-MSIPropertyAndTrim -PropertyName "ProductVersion"
Write-Log -Message "Version: $version"
```

---

### Test-AppInstalled

**Description**: Verifies if an MSI’s ProductCode is present in the registry, polling up to a timeout.

**Usage**:
```powershell
Test-AppInstalled -ProductCode <string> -AppName <string> [-TimeoutSeconds <int>]
```
- `-ProductCode` (string, required): The MSI’s GUID (including braces).
- `-AppName` (string, required): Friendly name for logs.
- `-TimeoutSeconds` (int, default 10): Seconds to wait.

**Example**:
```powershell
if (Test-AppInstalled -ProductCode $productCode -AppName "MyApp" -TimeoutSeconds 15) {
    Write-Log -Message "MyApp installed"
} else {
    Write-Log -Message "Install failed" -Level "ERROR"
    exit 1
}
```

---

### Stop-Processes

**Description**: Kills specified processes if running.

**Usage**:
```powershell
Stop-Processes -ProcessNames <string[]>
```
- `-ProcessNames` (string[], required): Process names without `.exe`.

**Example**:
```powershell
Stop-Processes -ProcessNames @("notepad", "calc")
```

---

### Wait-ForRegistryValueOrKey

**Description**: Waits for a registry key or specific value to appear, up to a timeout.

**Usage**:
```powershell
Wait-ForRegistryValueOrKey -Path <string> [-Name <string>] [-Timeout <int>]
```
- `-Path` (string, required): e.g. "HKLM:\SOFTWARE\MyCo\MyApp".
- `-Name` (string, optional): Value name.
- `-Timeout` (int, default 30): Seconds to wait.

**Example**:
```powershell
if (-not (Wait-ForRegistryValueOrKey -Path "HKLM:\SOFTWARE\MyCo\MyApp" -Name "InstallDir" -Timeout 60)) {
    Write-Log -Message "Timeout waiting for InstallDir" -Level "ERROR"
    exit 1
}
```

---

### Ensure-RegistryValue

**Description**: Ensures a registry value matches an expected value, updating or creating it as needed.

**Usage**:
```powershell
Ensure-RegistryValue -Path <string> -Name <string> -ExpectedValue <string> [-PropertyType <string>] [-Timeout <int>]
```

**Example**:
```powershell
Ensure-RegistryValue -Path "HKLM:\SOFTWARE\MyCo\MyApp" -Name "InstallDir" -ExpectedValue "C:\Program Files\MyApp" -PropertyType "String" -Timeout 30
```

---

### Start-ExecutableInUserSession

**Description**: Launches an executable in the currently logged-on user’s session via a temporary scheduled task.

**Usage**:
```powershell
Start-ExecutableInUserSession -ExecutablePath <string> [-TaskName <string>]
```
- `-ExecutablePath` (string, required): Full path to `.exe`.
- `-TaskName` (string, default "TempStartTask"): Name for the task.

**Example**:
```powershell
Start-ExecutableInUserSession -ExecutablePath "C:\Program Files\MyApp\MyApp.exe" -TaskName "LaunchMyAppGUI"
```

---

### Ensure-64Bit

**Description**:  
Detects if the script is running under 32-bit PowerShell on a 64-bit OS. If so, it logs an informational message via `Write-Log`, rebuilds and forwards all bound switches and parameters, restarts the script under the 64-bit PowerShell host (`SysNative\WindowsPowerShell\v1.0\PowerShell.exe`), waits for that process to finish, and then exits the original 32-bit session.

**Usage**:
```powershell
Ensure-64Bit
```

---

## 👤 Author

Lambert

---

## License

MIT License. Feel free to adapt and extend for your organization.
