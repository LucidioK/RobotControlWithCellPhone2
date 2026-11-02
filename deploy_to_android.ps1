#Requires -Version 7.3
<#
.SYNOPSIS
    Builds the Android app in WSL and installs it on a USB-connected phone.

.DESCRIPTION
    1. Builds Android/ with Buildozer inside WSL (creates the Buildozer venv if
       needed and repairs a Gradle cache corrupted by an unclean WSL shutdown).
    2. Makes sure Windows can see the phone: gives it back from usbipd/WSL,
       and explains what to do when USB debugging is off, the computer is not
       authorized yet, or a USB driver is missing.
    3. Installs the APK and starts the app.

.PARAMETER SkipBuild
    Install the newest APK in Android\bin without rebuilding.

.PARAMETER Serial
    adb serial of the phone, when several phones are connected.

.PARAMETER Distro
    WSL distribution used for building.

.PARAMETER Reinstall
    Uninstall the app first if the installed copy was signed with another key.
    This deletes the app's data on the phone.

.PARAMETER NoLaunch
    Do not start the app after installing.

.PARAMETER Yes
    Answer yes to all questions (e.g. unbinding the phone from usbipd).

.EXAMPLE
    .\deploy_to_android.ps1
.EXAMPLE
    .\deploy_to_android.ps1 -SkipBuild -Serial R38M608J8MK
#>
[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [string]$Serial,
    [string]$Distro = 'Ubuntu-26.04',
    [switch]$Reinstall,
    [switch]$NoLaunch,
    [switch]$Yes
)

. "$PSScriptRoot\deploy_common.ps1"

$AndroidDir = Join-Path $PSScriptRoot 'Android'
$SpecFile = Join-Path $AndroidDir 'buildozer.spec'
$ApkDir = Join-Path $AndroidDir 'bin'

function Get-SpecValue([string]$Key) {
    $line = Select-String -Path $SpecFile -Pattern "^\s*$([regex]::Escape($Key))\s*=\s*(.+?)\s*$" |
        Select-Object -First 1
    if ($line) { return $line.Matches[0].Groups[1].Value }
    return $null
}

$PackageId = "$(Get-SpecValue 'package.domain').$(Get-SpecValue 'package.name')"
$MinApi = [int](Get-SpecValue 'android.minapi')
$Archs = @((Get-SpecValue 'android.archs') -split '\s*,\s*')

# --- 1. Build ---------------------------------------------------------------

function Invoke-WslBuild {
    Write-Step "Building the APK in WSL ($Distro)"
    if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
        Stop-Deploy 'WSL is not installed.' @('Install it with: wsl --install', 'Or use -SkipBuild to install an existing APK.')
    }
    $distros = (wsl -l -q | Out-String).Replace("`0", '') -split "`r?`n" | Where-Object { $_.Trim() }
    if ($distros -notcontains $Distro) {
        Stop-Deploy "WSL distribution '$Distro' not found." @("Installed: $($distros -join ', ')", 'Pass one with -Distro <name>.')
    }

    $srcWsl = (wsl -d $Distro -- wslpath -a ($AndroidDir -replace '\\', '/')).Trim()
    $script = @'
set -uo pipefail
SRC='__SRC__'
PROJ="$HOME/robotremote"
VENV="$HOME/venvs/buildozer"

missing=""
for c in python3 java git zip unzip autoconf libtoolize pkg-config cmake; do
  command -v "$c" >/dev/null || missing="$missing $c"
done
if [ -n "$missing" ]; then
  echo "MISSING_TOOLS:$missing"
  echo "Install them in WSL, e.g.: sudo apt install python3-venv openjdk-17-jdk git zip unzip autoconf libtool pkg-config cmake zlib1g-dev libncurses-dev libffi-dev libssl-dev"
  exit 2
fi

if [ ! -x "$VENV/bin/buildozer" ]; then
  echo "Creating the Buildozer environment in $VENV (first run only)..."
  python3 -m venv "$VENV" && "$VENV/bin/pip" install -q --upgrade pip setuptools \
    && "$VENV/bin/pip" install -q buildozer cython || { echo "Could not install Buildozer"; exit 2; }
fi
. "$VENV/bin/activate"

mkdir -p "$PROJ"
cp "$SRC"/*.py "$SRC/buildozer.spec" "$PROJ/"
cd "$PROJ"

# An unclean WSL shutdown can leave zero-filled Gradle lock files, which make
# every later build fail with "Unexpected lock protocol found in lock file".
bad=""
if [ -d "$HOME/.gradle/caches" ]; then
  bad=$(find "$HOME/.gradle/caches" -name '*.lock' -type f -size +0 2>/dev/null | while read -r f; do
          tr -d '\000' < "$f" | head -c1 | grep -q . || echo "$f"
        done | head -n 1)
fi
if [ -n "$bad" ]; then
  stamp=$(date +%Y%m%d%H%M%S)
  echo "Gradle cache is corrupted ($bad); moving it to ~/.gradle/caches.corrupt-$stamp"
  pkill -f org.gradle 2>/dev/null
  mv "$HOME/.gradle/caches" "$HOME/.gradle/caches.corrupt-$stamp"
  rm -rf "$HOME/.gradle/daemon"
fi

echo "Running buildozer (log: $PROJ/build.log)..."
# "yes" answers license prompts; it dies of SIGPIPE when buildozer exits, so
# judge the build by buildozer's own exit status.
yes | buildozer android debug > "$PROJ/build.log" 2>&1
if [ "${PIPESTATUS[1]}" -ne 0 ]; then
  echo "BUILD FAILED. Last errors from $PROJ/build.log:"
  sed 's/\x1b\[[0-9;]*m//g' "$PROJ/build.log" | grep -E 'What went wrong|Error|Traceback' -A4 \
    | grep -v SyntaxError | tail -n 30
  exit 1
fi
apk=$(ls -t bin/*.apk | head -n 1)
mkdir -p "$SRC/bin"
cp "$apk" "$SRC/bin/"
echo "Built $(basename "$apk")"
'@
    $script = $script.Replace('__SRC__', $srcWsl)
    wsl -d $Distro -- bash -c (ConvertTo-BashCommand $script)
    switch ($LASTEXITCODE) {
        0 { }
        2 { Stop-Deploy 'The WSL build environment is incomplete (see above).' }
        default { Stop-Deploy 'The APK build failed (see above).' @('Use -SkipBuild to install the last APK that built.') }
    }
}

if (-not $SkipBuild) { Invoke-WslBuild }

$Apk = Get-ChildItem -Path $ApkDir -Filter '*.apk' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $Apk) {
    Stop-Deploy "No APK found in $ApkDir." @('Run without -SkipBuild to build one.')
}
Write-Ok "APK: $($Apk.Name) ($([math]::Round($Apk.Length / 1MB, 1)) MB, built $($Apk.LastWriteTime))"

# --- 2. Find the phone --------------------------------------------------------

Write-Step 'Looking for the phone'
$Adb = Find-Adb
if (-not $Adb) {
    Stop-Deploy 'adb was not found.' @('Install Android platform-tools (winget install Google.PlatformTools) or add adb to PATH.')
}

if (Release-UsbFromWsl -Vids $PhoneVids -What 'The phone' -AssumeYes:$Yes) {
    Restart-AdbServer $Adb
}

function Get-PhoneCandidates {
    $devices = Get-AdbDevices $Adb
    if ($Serial) { return @($devices | Where-Object Serial -eq $Serial) }
    # The UNO Q also speaks adb; Android phones are the ones reporting a model.
    # Unauthorized phones report no model yet, so keep those too.
    return @($devices | Where-Object { $_.Model -or $_.State -eq 'unauthorized' })
}

# Explains why Windows sees no adb phone, based on the USB devices present.
function Show-NoPhoneDiagnosis {
    $present = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $PhoneVids -contains (Get-VidFromInstanceId $_.InstanceId) })
    if (-not $present) {
        Stop-Deploy 'No phone is connected over USB.' @(
            'Plug the phone in with a cable that carries data (many cables only charge).',
            'On the phone, pull down the notifications, tap the USB notification and choose "File transfer".',
            'Try a USB port directly on the PC instead of a hub.')
    }
    $adbInterface = $present | Where-Object { $_.FriendlyName -match 'ADB' -or $_.Class -eq 'AndroidUsbDeviceClass' }
    $broken = $present | Where-Object { $_.Status -eq 'Error' }
    if ($broken) {
        Stop-Deploy "Windows has no working driver for part of the phone ($($broken[0].FriendlyName))." @(
            'Install the phone maker''s USB driver (Samsung: "Samsung Android USB Driver"; others: Google USB Driver).',
            'Then unplug and replug the phone.')
    }
    if (-not $adbInterface) {
        Stop-Deploy 'The phone is connected, but USB debugging is off.' @(
            'Enable Developer options: Settings > About phone > Software information > tap "Build number" 7 times.',
            'Then Settings > Developer options > turn on "USB debugging".',
            'Unplug and replug the phone, and accept the "Allow USB debugging?" prompt.')
    }
    Stop-Deploy 'The phone exposes an ADB interface, but adb does not list it.' @(
        'Unplug and replug the phone, then run this script again.',
        'If it persists: adb kill-server; adb start-server')
}

$phones = Get-PhoneCandidates
if (-not $phones) {
    Restart-AdbServer $Adb
    Start-Sleep -Seconds 2
    $phones = Get-PhoneCandidates
}
if (-not $phones -and $Serial) {
    $others = @(Get-AdbDevices $Adb | Where-Object { $_.Model -or $_.State -eq 'unauthorized' } |
        ForEach-Object { "$($_.Serial) ($(if ($_.Model) { $_.Model } else { $_.State }))" })
    Stop-Deploy "No device with serial '$Serial' is connected." @(
        $(if ($others) { "Connected phones: $($others -join ', ')" } else { 'No phones are connected.' }))
}
if (-not $phones) { Show-NoPhoneDiagnosis }

$phones = @($phones | Sort-Object Serial -Unique)
if ($phones.Count -gt 1) {
    Stop-Deploy 'More than one phone is connected.' @(
        "Pick one with -Serial: $(($phones | ForEach-Object { "$($_.Serial) ($($_.Model))" }) -join ', ')")
}
$Phone = $phones[0]

# Wait for the user to authorize this computer on the phone.
$deadline = (Get-Date).AddSeconds(60)
$hinted = $false
while ($Phone.State -ne 'device') {
    if ($Phone.State -eq 'unauthorized') {
        if (-not $hinted) {
            Write-Hint 'Unlock the phone and accept "Allow USB debugging?" (tick "Always allow from this computer"). Waiting up to 60 s...'
            $hinted = $true
        }
    } elseif ($Phone.State -eq 'offline') {
        & $Adb -s $Phone.Serial reconnect 2>$null | Out-Null
    } else {
        Stop-Deploy "The phone is in '$($Phone.State)' mode." @('Reboot it normally, then run this script again.')
    }
    if ((Get-Date) -gt $deadline) {
        Stop-Deploy "The phone is still '$($Phone.State)'." @(
            'If no prompt appears: Developer options > "Revoke USB debugging authorizations", then replug.')
    }
    Start-Sleep -Seconds 3
    $Phone = @(Get-AdbDevices $Adb | Where-Object Serial -eq $Phone.Serial)[0]
    if (-not $Phone) { Stop-Deploy 'The phone disconnected.' }
}

function Invoke-PhoneShell([string]$Command) {
    return (& $Adb -s $Phone.Serial shell $Command 2>$null | Out-String).Trim()
}

$model = Invoke-PhoneShell 'getprop ro.product.model'
$sdk = [int](Invoke-PhoneShell 'getprop ro.build.version.sdk')
$abis = (Invoke-PhoneShell 'getprop ro.product.cpu.abilist') -split ','
Write-Ok "Phone: $model ($($Phone.Serial)), Android API $sdk"

if ($MinApi -and $sdk -lt $MinApi) {
    Stop-Deploy "The phone runs Android API $sdk; the app needs API $MinApi or newer."
}
if (-not ($Archs | Where-Object { $abis -contains $_ })) {
    Stop-Deploy "The APK is built for $($Archs -join ', ') but the phone supports $($abis -join ', ')." @(
        'Add the phone''s architecture to android.archs in Android\buildozer.spec (build one at a time).')
}

# --- 3. Install and launch --------------------------------------------------

Write-Step "Installing $PackageId"
Write-Hint 'If the phone shows a Play Protect or "Install via USB" prompt, allow it.'

function Install-Apk {
    return (& $Adb -s $Phone.Serial install -r $Apk.FullName 2>&1 | Out-String)
}

$result = Install-Apk
if ($result -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE|INSTALL_FAILED_VERSION_DOWNGRADE') {
    if ($Reinstall -or (Confirm-Action 'The installed app was signed with a different key (or is newer). Uninstall it first? Its data on the phone will be lost.' -AssumeYes:$Yes)) {
        & $Adb -s $Phone.Serial uninstall $PackageId | Out-Null
        $result = Install-Apk
    }
}

if ($result -notmatch 'Success') {
    $hints = @()
    switch -Regex ($result) {
        'INSTALL_FAILED_USER_RESTRICTED' { $hints += 'Installing over USB is blocked on the phone. Allow it (Xiaomi: Developer options > "Install via USB"), or accept the prompt.' }
        'INSTALL_FAILED_INSUFFICIENT_STORAGE' { $hints += 'The phone is out of storage. Free some space and retry.' }
        'INSTALL_FAILED_VERIFICATION_FAILURE|INSTALL_FAILED_ABORTED' { $hints += 'The install was rejected on the phone (Play Protect / Auto Blocker). Allow it on the phone and retry.' }
        'INSTALL_FAILED_NO_MATCHING_ABIS' { $hints += 'The APK does not match the phone''s CPU; check android.archs in buildozer.spec.' }
        'device offline|no devices|closed' { $hints += 'The USB connection dropped. Replug the phone (try another cable/port) and retry.' }
    }
    Stop-Deploy "Install failed: $($result.Trim())" $hints
}
Write-Ok 'Installed.'

if (-not $NoLaunch) {
    Write-Step 'Starting the app'
    if ((Invoke-PhoneShell 'dumpsys window') -match 'mDreamingLockscreen=true|isStatusBarKeyguard=true|mShowingLockscreen=true') {
        Write-Hint 'The phone is locked; unlock it to see the app.'
    }
    & $Adb -s $Phone.Serial shell monkey -p $PackageId -c android.intent.category.LAUNCHER 1 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Hint 'Could not start the app automatically; open "Robot Remote" on the phone.'
    } else {
        Write-Ok 'App started.'
    }
}

Write-Host ''
Write-Host 'Done. On the phone: pick the robot, tap Connect, hold HOLD TO DRIVE and tilt.' -ForegroundColor Green
