# Shared helpers for deploy_to_android.ps1 and deploy_to_arduino.ps1.
# Dot-sourced by those scripts; not meant to be run directly.

$ErrorActionPreference = 'Stop'

$ArduinoVid = '2341'
# USB vendor IDs of common Android phone makers (Samsung, Google, Motorola,
# Xiaomi, Huawei, OnePlus, HTC, LG, Sony, vivo, OPPO, ZTE, Amazon).
$PhoneVids = @('04E8', '18D1', '22B8', '2717', '12D1', '2A70', '0BB4', '1004',
               '054C', '0FCE', '2D95', '22D9', '19D2', '1949')

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "    $Message" -ForegroundColor Green
}

function Write-Hint([string]$Message) {
    Write-Host "    $Message" -ForegroundColor Yellow
}

function Stop-Deploy([string]$Message, [string[]]$Hints = @()) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    foreach ($hint in $Hints) { Write-Hint $hint }
    exit 1
}

function Confirm-Action([string]$Question, [switch]$AssumeYes) {
    if ($AssumeYes) { return $true }
    $answer = Read-Host "$Question [y/N]"
    return $answer -match '^(y|yes)$'
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-VidFromInstanceId([string]$InstanceId) {
    if ($InstanceId -match 'VID_([0-9A-F]{4})') { return $Matches[1].ToUpper() }
    return $null
}

# --- usbipd-win: USB devices handed over to WSL are invisible to Windows ---

function Get-UsbipdDevices {
    if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) { return @() }
    try {
        return @((usbipd state | Out-String | ConvertFrom-Json).Devices)
    } catch {
        Write-Hint "Could not read usbipd state ($_); skipping the WSL USB check."
        return @()
    }
}

# Gives USB devices from the given vendors back to Windows: detaches them
# from WSL and removes forced bindings (which need administrator rights).
# Returns $true if anything was changed.
function Release-UsbFromWsl([string[]]$Vids, [string]$What, [switch]$AssumeYes) {
    $changed = $false
    foreach ($dev in Get-UsbipdDevices) {
        $vid = Get-VidFromInstanceId $dev.InstanceId
        if (-not $vid -or $Vids -notcontains $vid -or -not $dev.BusId) { continue }

        if ($dev.ClientIPAddress) {
            Write-Hint "$What ($($dev.Description)) is attached to WSL; detaching it."
            usbipd detach --busid $dev.BusId | Out-Null
            $changed = $true
        }
        if ($dev.IsForced) {
            Write-Hint "$What ($($dev.Description)) is force-bound by usbipd, which hides it from Windows."
            if (-not (Confirm-Action "Unbind it so Windows can use it? (needs administrator rights)" -AssumeYes:$AssumeYes)) {
                Stop-Deploy "$What is owned by usbipd/WSL." @("Run as administrator: usbipd unbind --busid $($dev.BusId)")
            }
            if (Test-IsAdmin) {
                usbipd unbind --busid $dev.BusId | Out-Null
            } else {
                $proc = Start-Process usbipd -ArgumentList 'unbind', '--busid', $dev.BusId `
                    -Verb RunAs -Wait -PassThru -WindowStyle Hidden
                if ($proc.ExitCode -ne 0) {
                    Stop-Deploy "usbipd unbind failed (exit $($proc.ExitCode))." @("Run as administrator: usbipd unbind --busid $($dev.BusId)")
                }
            }
            $changed = $true
        }
    }
    if ($changed) {
        Write-Ok "Waiting for Windows to pick the device up again..."
        Start-Sleep -Seconds 5
    }
    return $changed
}

# --- adb ---

function Find-Adb {
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
        "${env:ProgramFiles(x86)}\Android\android-sdk\platform-tools\adb.exe",
        "$env:ProgramFiles\Android\android-sdk\platform-tools\adb.exe"
    )
    foreach ($path in $candidates) {
        if ($path -and (Test-Path $path)) { return $path }
    }
    return $null
}

# Returns objects with Serial, State and Model ('' for non-Android devices
# such as the UNO Q, whose adbd does not report a model).
function Get-AdbDevices([string]$Adb) {
    $lines = & $Adb devices -l 2>$null
    $devices = @()
    foreach ($line in $lines) {
        if ($line -match '^(\S+)\s+(device|unauthorized|offline|no permissions|recovery|sideload|bootloader)\b(.*)$') {
            $device = [pscustomobject]@{ Serial = $Matches[1]; State = $Matches[2]; Model = '' }
            if ($Matches[3] -match 'model:(\S+)') { $device.Model = $Matches[1] }
            $devices += $device
        }
    }
    return $devices
}

function Restart-AdbServer([string]$Adb) {
    & $Adb kill-server 2>$null | Out-Null
    & $Adb start-server 2>$null | Out-Null
    # Devices take a few seconds to reappear after a restart.
    for ($i = 0; $i -lt 8; $i++) {
        Start-Sleep -Seconds 1
        if (@(Get-AdbDevices $Adb | Where-Object State -ne 'offline').Count) { break }
    }
}

# --- misc ---

# Encodes a bash script so it survives any shell quoting (ssh, adb, wsl).
function ConvertTo-BashCommand([string]$Script) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Script.Replace("`r", ''))
    return "echo $([Convert]::ToBase64String($bytes)) | base64 -d | bash"
}
