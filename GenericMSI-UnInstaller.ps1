<#
    Generic MSI Uninstaller
    Mirrors the structure of the GenericMSI-Installer.ps1
    Only $ProductCode (and optionally $RequireReboot) needs to be defined.

    To interactively discover installed MSI product codes,
    download GetMSI-Info.ps1 from:
    https://github.com/AdytaNL/GetMSI-Info
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

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    if (-not (Test-Path $logPath)) {
        New-Item -ItemType Directory -Path $logPath -Force | Out-Null
    }
    $ts    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "$ts [$Level] $Message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry
}

function Test-AppInstalled {
    param (
        [string]$ProductCode,
        [int]   $TimeoutSeconds = 10
    )
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode"
    )
    $start = Get-Date
    while ((Get-Date) - $start -lt [TimeSpan]::FromSeconds($TimeoutSeconds)) {
        foreach ($p in $paths) {
            if (Test-Path $p) { return $true }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Stop-Processes {
    param ([string[]]$ProcessNames)
    if ($ProcessNames.Count -gt 0) {
        Write-Log "Pre-uninstall: stopping processes: $($ProcessNames -join ', ')"
        foreach ($name in $ProcessNames) {
            $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
            if ($procs) {
                Write-Log " → Found $($procs.Count) ‘$name’ process(es); terminating..."
                try {
                    Stop-Process -Name $name -Force -ErrorAction Stop
                    Write-Log "   Terminated all ‘$name’ processes."
                } catch {
                    Write-Log "   Warning: failed to terminate ‘$name’: $_" "WARNING"
                }
            } else {
                Write-Log " → No running processes named ‘$name’."
            }
        }
    }
}

# ----- END FUNCTIONS ----

# --- PRE-UNINSTALL ---
Write-Log "Executing pre-uninstall tasks for ProductCode $ProductCode"
Stop-Processes -ProcessNames $ProcessesToKill
Write-Log "Pre-uninstall tasks completed."

# --- BEGIN UNINSTALL PROCESS ---
Write-Log "Starting uninstall of ProductCode $ProductCode"
$arguments = "/x `"$ProductCode`" /qn /norestart"
Write-Log "Running: msiexec.exe $arguments"

$proc = Start-Process -FilePath "msiexec.exe" `
                      -ArgumentList $arguments `
                      -Wait -PassThru

# Handle msiexec exit codes
switch ($proc.ExitCode) {
    0 {
        Write-Log "msiexec reported success (0)."
    }
    3010 {
        Write-Log "Installation requires reboot (3010)." "WARNING"
    }
    default {
        Write-Log "msiexec failed with exit code $($proc.ExitCode)." "ERROR"
        exit 1
    }
}

# --- FINAL CHECK ---
if (-not (Test-AppInstalled -ProductCode $ProductCode -TimeoutSeconds 60)) {
    Write-Log "ProductCode $ProductCode uninstalled successfully."
    if ($RequireReboot) {
        Write-Log "Reboot is enforced. Restarting now..." "WARNING"
        Restart-Computer -Force
    }
    exit 0
} else {
    Write-Log "ProductCode $ProductCode still detected after uninstall." "ERROR"
    exit 1
}
