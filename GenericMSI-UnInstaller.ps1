<#
.SYNOPSIS
    Automates the silent uninstallation of a specified MSI package 
    with robust pre and post-uninstall logic.

.DESCRIPTION
    Mirrors the structure of the GenericMSI-Installer.ps1
    Only $ProductCode (and optionally $RequireReboot) needs to be defined.

    To interactively discover installed MSI product codes,
    download GetMSI-Info.ps1 from:
    https://github.com/AdytaNL/GetMSI-Info

    GenericMSI-UnInstaller.ps1 removes an MSI application identified by its ProductCode,
    optionally terminating specified processes beforehand,
    ensures the script runs in a 64-bit PowerShell host on 64-bit OS,
    logs detailed events to both console and a log file,
    executes msiexec.exe with `/x <ProductCode> /qn /norestart`,
    handles and records msiexec exit codes (including reboot-required 3010),
    verifies removal by checking registry uninstall keys,
    and enforces an optional system reboot upon successful uninstallation.

.AUTHOR
    Lambert
    Adyta.nl

.LICENSE
    MIT
#>

# --- LOGGING INITIALIZATION ---
$logPath = "C:\Install\Scripts\Logs"
$logFile = Join-Path -Path $logPath `
                     -ChildPath ((Get-Item -Path $PSCommandPath).Name.Replace(".ps1", ".log"))

# ----- Script Variables ----
$ProductCode     = "{YOUR-PRODUCTCODE-HERE}"  # MSI GUID in braces
$RequireReboot   = $false                     # Force reboot after uninstall?
$ProcessesToKill = @()                        # e.g. "MyApp","MyApp.Service"
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
# ----- END FUNCTIONS ----

# --- 64-bit PowerShell Check ---
# If the script is running in 32-bit PowerShell on a 64-bit OS, restart it in 64-bit mode
Ensure-64Bit

# --- PRE-UNINSTALL ---
Log-Info "Executing pre-uninstall tasks for ProductCode $ProductCode"
Stop-Processes -ProcessNames $ProcessesToKill
Log-Info "Pre-uninstall tasks completed."

# --- BEGIN UNINSTALL PROCESS ---
Log-Info "Starting uninstall of ProductCode $ProductCode"
$arguments = "/x `"$ProductCode`" /qn /norestart"
Log-Info "Running: msiexec.exe $arguments"

try {
    $process = Start-Process `
        -FilePath "msiexec.exe" `
        -ArgumentList $arguments `
        -Wait -PassThru `
        -ErrorAction Stop

    if ($process.ExitCode -eq 0) {
        Log-Info "MSI uninstallation completed successfully."
    }
    else {
        Log-Warning "MSI uninstallation exited with code $($process.ExitCode)."
    }
}
catch {
    Log-Error "Failed to uninstall MSI: $_"
    exit 1
}
# Handle msiexec exit codes
if ($process.ExitCode -eq 0) {
    Log-Info "Uninstallation successful."
}
elseif ($process.ExitCode -eq 3010) {
    Log-Warning "Uninstallation requires reboot (3010)."
}
else {
    Log-Error "Uninstallation failed with exit code $($process.ExitCode)."
    exit 1
}

# --- FINAL CHECK ---
if (-not (Test-AppInstalled -ProductCode $ProductCode -TimeoutSeconds 60)) {
    Log-Info "ProductCode $ProductCode uninstalled successfully."
    if ($RequireReboot) {
        Log-Warning "Reboot is enforced. Restarting now..."
        Restart-Computer -Force
    }
    exit 0
} else {
    Log-Error "ProductCode $ProductCode still detected after uninstall."
    exit 1
}
