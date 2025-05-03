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
$MSIFileName        = "" # Name of the MSI file to install (must be in the script's folder)
$RequireReboot      = $false                     # Whether to force a reboot after installation
$ProcessesToKill    = @('')                         # Optional: List of process names to stop before install
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

# --- Logging level-specific wrappers ---
function Log-Info {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message
    )
    Write-Log -Message $Message -Level 'INFO'
}

function Log-Warning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message
    )
    Write-Log -Message $Message -Level 'WARNING'
}

function Log-Error {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message
    )
    Write-Log -Message $Message -Level 'ERROR'
}

# Retrieves a specific property from the MSI file using Windows Installer COM object
function Get-MSIProperty {
    param (
        [Parameter(Mandatory)][string]$PropertyName
    )

    try {
        Log-Info "Retrieving MSI property '$PropertyName'"
        $query = "SELECT Value FROM Property WHERE Property = '$PropertyName'"
        $view  = $msiDatabase.OpenView($query)
        $view.Execute()
        $record = $view.Fetch()

        if ($record) {
            $value = $record.StringData(1)
            Log-Info "Found property '$PropertyName' = '$value'"
            return $value
        }
        else {
            Log-Warning "Property '$PropertyName' not found in MSI database"
            return $null
        }
    }
    catch {
        Log-Error "Error retrieving MSI property '$PropertyName': $_"
        return $null
    }
}

# Retrieves and trims a property value from the MSI
function Get-MSIPropertyAndTrim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PropertyName
    )

    # grab whatever the raw value was (might be $null)
    $raw = Get-MSIProperty -PropertyName $PropertyName

    # force it into a string (so $null → "")
    $text = [string]$raw

    # now trim, unconditionally
    $trimmed = $text.Trim()

    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        Log-Warning "Property '$PropertyName' is empty after trimming; defaulting to 'Unknown'"
        return 'Unknown'
    }

    Log-Info "Property '$PropertyName' trimmed to '$trimmed'"
    return $trimmed
}

# Checks if the application is installed by searching the registry for its product code
function Test-AppInstalled {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$ProductCode,
        [string]$AppName = $ProductCode,
        [int]$TimeoutSeconds = 10
    )

    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode"
    )

    try {
        Log-Info "Checking installation of '$AppName' (ProductCode: $ProductCode) with timeout $TimeoutSeconds sec"
        $startTime = Get-Date

        while ($true) {
            foreach ($path in $registryPaths) {
                Log-Info "Looking for registry key: $path"
                if (Test-Path $path) {
                    Log-Info "Found installation at: $path"
                    return $true
                }
            }

            if ((Get-Date) - $startTime -ge ([TimeSpan]::FromSeconds($TimeoutSeconds))) {
                Log-Info "No installation detected for '$AppName' within $TimeoutSeconds seconds"
                return $false
            }
            Start-Sleep -Seconds 1
        }
    }
    catch {
        Log-Error "Error checking install status for '$AppName' ($ProductCode): $_"
        return $false
    }
}

# Stops one or more processes by name, with logging for each attempt
function Stop-Processes {
    [CmdletBinding()]
    param(
        [string[]]$ProcessNames = @()
    )

    # If no process names were supplied, log and exit
    if ($ProcessNames.Count -eq 0) {
        Log-Warning 'No process names supplied; nothing to stop.'
        return
    }

    Log-Info "Starting process termination for: $($ProcessNames -join ', ')"

    foreach ($Process in $ProcessNames) {
        Log-Info "Searching for process: $Process"
        $running = Get-Process -Name $Process -ErrorAction SilentlyContinue

        if ($running) {
            Log-Info "Found $($running.Count) instance(s) of $Process; terminating..."
            try {
                Stop-Process -Name $Process -Force -ErrorAction Stop
                Log-Info "Successfully terminated all '$Process' processes."
            }
            catch {
                Log-Warning "Failed to terminate process '$Process': $_"
            }
        }
        else {
            Log-Info "No active processes found for '$Process'."
        }
    }
}

# Waits for a specific registry key or value to appear (used to verify installation success)
function Wait-ForRegistryValueOrKey {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Path,
        [string]$Name,
        [int]$Timeout = 30
    )

    # Build a human-readable description of what we're waiting for
    $what = if ($Name) {
        "value '$Name' in '$Path'"
    } else {
        "key '$Path'"
    }

    Log-Info "Waiting up to $Timeout seconds for registry $what."

    $elapsed = 0
    while ($elapsed -lt $Timeout) {
        try {
            if ($Name) {
                $value = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
                if ($null -ne $value) {
                    Log-Info "Registry value '$Name' found in '$Path' after $elapsed seconds."
                    return $true
                }
            }
            else {
                if (Test-Path $Path) {
                    Log-Info "Registry key '$Path' found after $elapsed seconds."
                    return $true
                }
            }
        }
        catch {
            Log-Warning "Error checking registry ${what}: $_"
        }

        Start-Sleep -Seconds 1
        $elapsed++
    }

    if ($Name) {
        Log-Error "Timeout: Registry value '$Name' not found in '$Path' after $Timeout seconds."
    }
    else {
        Log-Error "Timeout: Registry key '$Path' not found after $Timeout seconds."
    }

    return $false
}

# Starts an executable via Task Scheduler under the context of the logged-in user
function Start-ExecutableInUserSession {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ExecutablePath,

        [string]$TaskName = "TempStartTask"
    )

    try {
        Log-Info "Checking for logged-in user to auto-start '$ExecutablePath'..."
        $sessionUser = Get-CimInstance Win32_ComputerSystem |
                       Select-Object -ExpandProperty UserName

        if ($sessionUser) {
            Log-Info "Interactive user detected: $sessionUser"

            if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
                Log-Info "Removed existing task '$TaskName'."
            }

            $action    = New-ScheduledTaskAction   -Execute $ExecutablePath
            $trigger   = New-ScheduledTaskTrigger  -Once -At ((Get-Date).AddMinutes(1))
            $principal = New-ScheduledTaskPrincipal -UserId $sessionUser -LogonType Interactive -RunLevel Highest
            $task      = New-ScheduledTask         -Action $action -Trigger $trigger -Principal $principal

            Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force
            Start-ScheduledTask    -TaskName $TaskName

            Log-Info "Task '$TaskName' created and started for user $sessionUser."
        }
        else {
            Log-Warning "No interactive user found; cannot start '$ExecutablePath'."
        }
    }
    catch {
        Log-Error "Failed to start executable '$ExecutablePath' via Scheduled Task: $_"
    }
}

# Ensures a registry value exists and is set to the expected value; creates or updates as needed
function Ensure-RegistryValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][Alias("Value")][string]$ExpectedValue,
        [ValidateSet("String","ExpandString","Binary","DWord","MultiString","QWord")]
        [string]$PropertyType = "String",
        [int]$Timeout = 30
    )

    if (Wait-ForRegistryValueOrKey -Path $Path -Name $Name -Timeout $Timeout) {
        try {
            $existing = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
            if ($existing -ne $ExpectedValue) {
                Log-Info "Registry entry incorrect: '$Name' = '$existing'. Updating to '$ExpectedValue'..."
                Set-ItemProperty -Path $Path -Name $Name -Value $ExpectedValue -Type $PropertyType -Force
                Log-Info "Updated registry: '$Name' = '$ExpectedValue'."
            }
            else {
                Log-Info "Registry entry is already correct: '$Name' = '$existing'."
            }
        }
        catch {
            Log-Error "Error reading or updating registry value '$Name' at '$Path': $_"
        }
    }
    else {
        Log-Warning "Registry value '$Name' not found at '$Path' within $Timeout seconds. Creating it..."
        try {
            New-ItemProperty -Path $Path -Name $Name -Value $ExpectedValue -PropertyType $PropertyType -Force | Out-Null
            Log-Info "Created registry value: '$Name' = '$ExpectedValue'."
        }
        catch {
            Log-Error "Error creating registry value '$Name' at '$Path': $_"
        }
    }
}

# Self-elevation logic, the script will restart itself in the 64-bit host
function Ensure-64Bit {
    [CmdletBinding()]
    param()

    # If running under the 32-bit host on a 64-bit OS...
    if ($ENV:PROCESSOR_ARCHITEW6432 -eq 'AMD64') {
        # Log & restart in 64-bit
        Log-Info "Detected 32-bit PowerShell; restarting in 64-bit."

        # Rebuild arguments to pass through any bound parameters
        $argList = @('-File', $PSCommandPath)
        foreach ($param in $MyInvocation.BoundParameters.GetEnumerator()) {
            $name  = $param.Key
            $value = $param.Value

            if ($value -is [switch] -and $value.IsPresent) {
                $argList += "-$name"
            }
            elseif ($value -ne $null) {
                $argList += "-$name"
                $argList += $value.ToString()
            }
        }

        try {
            # Launch 64-bit PowerShell and wait
            Start-Process `
                -FilePath "$ENV:WINDIR\SysNative\WindowsPowerShell\v1.0\PowerShell.exe" `
                -ArgumentList $argList `
                -Wait -NoNewWindow

            # Exit the original 32-bit session
            exit
        }
        catch {
            Log-Error "Failed to restart in 64-bit PowerShell: $_"
            throw
        }
    }
}

# -----END FUNCTIONS ----

# --- 64-bit PowerShell Check ---
# If the script is running in 32-bit PowerShell on a 64-bit OS, restart it in 64-bit mode
Ensure-64Bit

# --- Resolve MSI Path ---
# Build the full path to the MSI file and validate it exists
$MSIPath = Join-Path -Path $PSScriptRoot -ChildPath $MSIFileName
Log-Info "Resolving MSI path: $MSIPath"
if (-not (Test-Path $MSIPath)) {
    Log-Error "MSI not found at path: $MSIPath"
    exit 1
}

# --- Read MSI Properties ---
Log-Info "Opening MSI database at path: $MSIPath"
try {
    $windowsInstallerObject = New-Object -ComObject WindowsInstaller.Installer
    $msiDatabase = $windowsInstallerObject.OpenDatabase($MSIPath, 0)
    Log-Info "Successfully opened MSI database"

    $ProductCode    = Get-MSIPropertyAndTrim -PropertyName "ProductCode"
    $ProductVersion = Get-MSIPropertyAndTrim -PropertyName "ProductVersion"
    $AppName        = Get-MSIPropertyAndTrim -PropertyName "ProductName"
    $Publisher      = Get-MSIPropertyAndTrim -PropertyName "Manufacturer"

    Log-Info "Extracted MSI properties: ProductCode=$ProductCode, Version=$ProductVersion, Name=$AppName, Publisher=$Publisher"
}
catch {
    Log-Error "Error reading MSI properties: $_"
    exit 1
}

# --- Check if Already Installed ---
# Exit early if the application is already installed
if (Test-AppInstalled -ProductCode $ProductCode -AppName $AppName -TimeoutSeconds 0) {
    Log-Info "$AppName is already installed. Skipping."
    exit 0
}

# --- Pre-Install ---
# Perform pre-install tasks like stopping background processes
Log-Info "Executing pre-install tasks..."
Stop-Processes -ProcessNames $ProcessesToKill
Log-Info "Pre-install tasks completed."

# --- Install MSI ---
# Run the MSI installation silently (quiet, no restart)
Log-Info "Installing $AppName version $ProductVersion"
$arguments = "/i `"$MSIPath`" /qn /norestart"

try {
    $process = Start-Process `
        -FilePath "msiexec.exe" `
        -ArgumentList $arguments `
        -Wait -PassThru `
        -ErrorAction Stop

    if ($process.ExitCode -eq 0) {
        Log-Info "MSI installation completed successfully."
    }
    else {
        Log-Warning "MSI installation exited with code $($process.ExitCode)."
    }
}
catch {
    Log-Error "Failed to install MSI: $_"
    exit 1
}

# Handle installation result
if ($process.ExitCode -eq 0) {
    Log-Info "Installation successful."
}
elseif ($process.ExitCode -eq 3010) {
    Log-Warning "Installation requires reboot (3010)."
}
else {
    Log-Error "Installation failed with exit code $($process.ExitCode)."
    exit 1
}

# --- Post-Install ---
# Optionally validate registry value and start executable in user session
Log-Info "Post-install tasks..."
if ($ExecutablePath -and (Test-Path $ExecutablePath)) {
    Log-Info "Executable exists: $ExecutablePath"
    if ($RegistryCheckPath -and $RegistryCheckName -and $RegistryCheckValue) {
        Ensure-RegistryValue -Path $RegistryCheckPath `
                             -Name $RegistryCheckName `
                             -ExpectedValue $RegistryCheckValue
    }
    Start-ExecutableInUserSession -ExecutablePath $ExecutablePath
}
else {
    Log-Warning "Executable not found or path empty. Skipping execution and registry tasks."
}

# --- Final Check ---
# Recheck if the application is successfully installed and optionally reboot
if (Test-AppInstalled -ProductCode $ProductCode -AppName $AppName -TimeoutSeconds 60) {
    Log-Info "$AppName installed successfully."
    if ($RequireReboot) {
        Log-Warning "Reboot is enforced. Restarting now..."
        Restart-Computer -Force
    }
    exit 0
}
else {
    Log-Error "Installation not detected after execution."
    exit 1
}
