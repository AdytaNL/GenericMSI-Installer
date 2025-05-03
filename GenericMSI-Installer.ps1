<#
    This PowerShell script installs a specified MSI package with optional pre- and post-install logic.
    It includes features such as:
    - Logging to file and console
    - Killing specific processes before install
    - Reading MSI properties (ProductCode, Version, etc.)
    - Checking or setting registry values
    - Starting an executable in the user session
    - Verifying install success and optionally rebooting the machine
#>

# --- LOGGING INITIALIZATION ---
# Set up the path where log files are written
$logPath = "C:\Install\Scripts\Logs"
$logFile = Join-Path -Path $logPath -ChildPath ((Get-Item -Path $PSCommandPath).Name.Replace(".ps1", ".log"))

# ----- Script Variables ----
# Customize these variables for the specific MSI you're installing
$MSIFileName        = "<MSI-Filename-HERE>.msi" # Name of the MSI file to install (must be in the script's folder)
$RequireReboot      = $false                      # Whether to force a reboot after installation
$ProcessesToKill    = @()                         # Optional: List of process names (without .exe extension!) to stop before install
$ExecutablePath     = ""                          # Optional: Path to an executable to validate or start after install
$RegistryCheckPath  = ""                          # Optional: Registry path to validate or create
$RegistryCheckName  = ""                          # Optional: Registry value name to validate or create
$RegistryCheckValue = ""                          # Optional: Expected data for the registry value
# ----- END Script Variables ----

# ----- FUNCTIONS ----

# Logs messages to both console and file with a timestamp and log level
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $username = $env:USERNAME
    if (-not (Test-Path $logPath)) {
        New-Item -ItemType Directory -Path $logPath -Force | Out-Null
    }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "$timestamp [$Level] [$username] $Message"
    if ($Host.UI.RawUI -ne $null) {
        Write-Host $logLine
    }
    Add-Content -Path $logFile -Value $logLine
}

# Retrieves a specific property from the MSI file using Windows Installer COM object
function Get-MSIProperty {
    param ([string]$propertyName)
    $query = "SELECT Value FROM Property WHERE Property = '$propertyName'"
    $view = $msiDatabase.OpenView($query)
    $view.Execute()
    $record = $view.Fetch()
    if ($record) { return $record.StringData(1) }
    else { return $null }
}

# Retrieves and trims a property value from the MSI
function Get-MSIPropertyAndTrim {
    param ([string]$propertyName)
    $propertyValue = Get-MSIProperty $propertyName
    if ($propertyValue) {
        $propertyValue = [string]$propertyValue
        $propertyValue = $propertyValue.Trim()
    } else {
        Write-Log "$propertyName is empty or null. Cannot trim." "WARNING"
        $propertyValue = "Unknown"
    }
    return $propertyValue
}

# Checks if the application is installed by searching the registry for its product code
function Test-AppInstalled {
    param (
        [string]$ProductCode,
        [string]$AppName,
        [int]$TimeoutSeconds = 10
    )
    $RegistryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode"
    )
    $StartTime = Get-Date
    while ($true) {
        foreach ($RegistryPath in $RegistryPaths) {
            Write-Log "Checking path: $RegistryPath"
            if (Test-Path $RegistryPath) {
                Write-Log "Found: $RegistryPath"
                return $true
            }
        }
        $Elapsed = (Get-Date) - $StartTime
        if ($Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Write-Log "No existing installation found for $AppName ($ProductCode) within $TimeoutSeconds seconds." "INFO"
            return $false
        }
        Start-Sleep -Seconds 1
    }
}

# Stops one or more processes by name, with logging for each attempt
function Stop-Processes {
    param ([string[]]$ProcessNames)
    Write-Log "Starting process kill for: $($ProcessNames -join ', ')"
    foreach ($Process in $ProcessNames) {
        Write-Log "Searching for process: $Process"
        $RunningProcesses = Get-Process -Name $Process -ErrorAction SilentlyContinue
        if ($RunningProcesses) {
            Write-Log "Found processes for $Process, terminating..."
            try {
                Stop-Process -Name $Process -Force -ErrorAction Stop
                Write-Log "Successfully terminated all $Process processes."
            } catch {
                Write-Log "Failed to terminate process $Process. $_" "WARNING"
            }
        } else {
            Write-Log "No active processes found for $Process."
        }
    }
}

# Waits for a specific registry key or value to appear (used to verify installation success)
function Wait-ForRegistryValueOrKey {
    param (
        [Parameter(Mandatory)][string]$Path,
        [string]$Name,
        [int]$Timeout = 30
    )
    $elapsed = 0
    while ($elapsed -lt $Timeout) {
        try {
            if ($Name) {
                $value = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
                if ($null -ne $value) {
                    Write-Log "Registry value '$Name' found in '$Path' after $elapsed seconds."
                    return $true
                }
            } else {
                if (Test-Path $Path) {
                    Write-Log "Registry key found: '$Path' after $elapsed seconds."
                    return $true
                }
            }
        } catch {}
        Start-Sleep -Seconds 1
        $elapsed++
    }
    if ($Name) {
        Write-Log "Timeout: Registry value '$Name' not found in '$Path' after $Timeout seconds." "ERROR"
    } else {
        Write-Log "Timeout: Registry key '$Path' not found after $Timeout seconds." "ERROR"
    }
    return $false
}

# Starts an executable via Task Scheduler under the context of the logged-in user
function Start-ExecutableInUserSession {
    param (
        [Parameter(Mandatory)][string]$ExecutablePath,
        [string]$TaskName = "TempStartTask"
    )
    Write-Log "Checking for logged-in user to auto-start $ExecutablePath..."
    $sessionUser = (Get-CimInstance Win32_ComputerSystem | Select-Object -ExpandProperty UserName)
    if ($sessionUser) {
        Write-Log "Interactive user detected: $sessionUser"
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Log "Removed existing task '$TaskName'."
        }
        $action    = New-ScheduledTaskAction -Execute $ExecutablePath
        $trigger   = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1))
        $principal = New-ScheduledTaskPrincipal -UserId $sessionUser -LogonType Interactive -RunLevel Highest
        $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal
        Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force
        Start-ScheduledTask -TaskName $TaskName
        Write-Log "Task '$TaskName' created and started for user $sessionUser."
    } else {
        Write-Log "No interactive user found to start $ExecutablePath." "WARNING"
    }
}

# Ensures a registry value exists and is set to the expected value; creates or updates as needed
function Ensure-RegistryValue {
    param (
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][Alias("Value")][string]$ExpectedValue,
        [ValidateSet("String", "ExpandString", "Binary", "DWord", "MultiString", "QWord")]
        [string]$PropertyType = "String",
        [int]$Timeout = 30
    )
    if (Wait-ForRegistryValueOrKey -Path $Path -Name $Name -Timeout $Timeout) {
        try {
            $ExistingValue = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
            if ($ExistingValue -ne $ExpectedValue) {
                Write-Log "Registry entry incorrect. Updating..."
                Set-ItemProperty -Path $Path -Name $Name -Value $ExpectedValue -Type $PropertyType -Force
                Write-Log "Registry entry updated: $Name = $ExpectedValue"
            } else {
                Write-Log "Registry entry is correct: $Name = $ExistingValue"
            }
        } catch {
            Write-Log "Error reading registry value $Name $_" "ERROR"
        }
    } else {
        Write-Log "Registry value '$Name' not found in time. Creating manually." "WARNING"
        try {
            New-ItemProperty -Path $Path -Name $Name -Value $ExpectedValue -PropertyType $PropertyType -Force | Out-Null
            Write-Log "Registry value created: $Name = $ExpectedValue"
        } catch {
            Write-Log "Error creating registry value $Name $_" "ERROR"
        }
    }
}

# Self-elevation logic, the script will restart itself in the 64-bit host
function Ensure-64Bit {
    # If running under the 32-bit host on a 64-bit OS...
    if ($ENV:PROCESSOR_ARCHITEW6432 -eq "AMD64") {
        # Log & restart in 64-bit
        Write-Log -Message "Detected 32-bit PowerShell; restarting in 64-bit." -Level "INFO"

        # Rebuild arguments to pass through any bound parameters
        $argList = @("-File", $PSCommandPath)
        foreach ($param in $MyInvocation.BoundParameters.GetEnumerator()) {
            $name  = $param.Key
            $value = $param.Value
            if ($value -is [switch] -and $value.IsPresent) {
                $argList += "-$name"
            }
            elseif ($value -ne $null) {
                $argList += "-$name"; $argList += $value.ToString()
            }
        }

        # Launch 64-bit PowerShell and wait
        Start-Process -FilePath "$ENV:WINDIR\SysNative\WindowsPowerShell\v1.0\PowerShell.exe" `
                      -ArgumentList $argList `
                      -Wait -NoNewWindow

        # Exit the 32-bit instance
        exit
    }
}
# -----END FUNCTIONS ----

# --- 64-bit PowerShell Check ---
# If the script is running in 32-bit PowerShell on a 64-bit OS, restart it in 64-bit mode
Ensure-64Bit

# --- Resolve MSI Path ---
# Build the full path to the MSI file and validate it exists
$MSIPath = Join-Path -Path $PSScriptRoot -ChildPath $MSIFileName
if (-not (Test-Path $MSIPath)) {
    Write-Log "Error: MSI not found at $MSIPath" "ERROR"
    exit 1
}

# --- Read MSI Properties ---
# Extract metadata from the MSI file: ProductCode, Version, Name, Publisher
try {
    $windowsInstallerObject = New-Object -ComObject WindowsInstaller.Installer
    $msiDatabase = $windowsInstallerObject.OpenDatabase($MSIPath, 0)
    $ProductCode    = Get-MSIPropertyAndTrim "ProductCode"
    $ProductVersion = Get-MSIPropertyAndTrim "ProductVersion"
    $AppName        = Get-MSIPropertyAndTrim "ProductName"
    $Publisher      = Get-MSIPropertyAndTrim "Manufacturer"
} catch {
    Write-Log "Error reading MSI properties: $_" "ERROR"
    exit 1
}

# Log what we found
Write-Log "MSI Path: $MSIPath"
Write-Log "ProductCode: $ProductCode"
Write-Log "Version: $ProductVersion"
Write-Log "AppName: $AppName"
Write-Log "Publisher: $Publisher"

# --- Check if Already Installed ---
# Exit early if the application is already installed
if (Test-AppInstalled -ProductCode $ProductCode -AppName $AppName -TimeoutSeconds 0) {
    Write-Log "$AppName is already installed. Skipping."
    exit 0
}

# --- Pre-Install ---
# Perform pre-install tasks like stopping background processes
Write-Log "Executing pre-install tasks..."
Stop-Processes -ProcessNames $ProcessesToKill
Write-Log "Pre-install tasks completed."

# --- Install MSI ---
# Run the MSI installation silently (quiet, no restart)
Write-Log "Installing $AppName version $ProductVersion"
$Arguments = "/i `"$MSIPath`" /qn /norestart"
$process = Start-Process -FilePath "msiexec.exe" -ArgumentList $Arguments -Wait -PassThru

# Handle installation result
if ($process.ExitCode -eq 0) {
    Write-Log "Installation successful."
} elseif ($process.ExitCode -eq 3010) {
    Write-Log "Installation requires reboot (3010)." "WARNING"
} else {
    Write-Log "Installation failed with exit code $($process.ExitCode)" "ERROR"
    exit 1
}

# --- Post-Install ---
# Optionally validate registry value and start executable in user session
Write-Log "Post-install tasks..."
if ($ExecutablePath -and (Test-Path $ExecutablePath)) {
    Write-Log "Executable exists: $ExecutablePath"
    if ($RegistryCheckPath -and $RegistryCheckName -and $RegistryCheckValue) {
        Ensure-RegistryValue -Path $RegistryCheckPath -Name $RegistryCheckName -ExpectedValue $RegistryCheckValue
    }
    Start-ExecutableInUserSession -ExecutablePath $ExecutablePath
} else {
    Write-Log "Executable not found or path empty. Skipping execution/registry." "WARNING"
}

# --- Final Check ---
# Recheck if the application is successfully installed and optionally reboot
if (Test-AppInstalled -ProductCode $ProductCode -AppName $AppName -TimeoutSeconds 60) {
    Write-Log "$AppName installed successfully."
    if ($RequireReboot -eq $true) {
        Write-Log "Reboot is enforced. Restarting now..." "WARNING"
        Restart-Computer -Force
    }
    exit 0
} else {
    Write-Log "Installation not detected after execution." "ERROR"
    exit 1
}

