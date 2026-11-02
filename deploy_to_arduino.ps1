#Requires -Version 7.3
<#
.SYNOPSIS
    Deploys the robot app (app.yaml, python/, sketch/) to the Arduino UNO Q.

.DESCRIPTION
    Uses USB (adb) when the board is plugged in, otherwise SSH over the
    network. The board is found automatically with arduino-cli; the USB port
    is taken back from usbipd/WSL when needed, and SSH key access can be set
    up on the first run.

    On the board it backs up the current app, copies the new files (with LF
    line endings), restarts the App Lab app (which recompiles and flashes the
    sketch), (re)installs the Bluetooth relay service and checks the logs.

.PARAMETER BoardHost
    IP address or hostname of the board (skips auto-discovery).

.PARAMETER Transport
    auto (default: USB if available, else network), usb or ssh.

.PARAMETER User
    Linux user on the board.

.PARAMETER AppName
    Folder name of the app under ~/ArduinoApps on the board.

.PARAMETER SkipRelay
    Do not reinstall/restart the Bluetooth relay service.

.PARAMETER Pair
    After deploying, make the board discoverable and auto-accept Bluetooth
    pairing for this many seconds (pair the phone from its Bluetooth settings).

.PARAMETER Yes
    Answer yes to all questions.

.EXAMPLE
    .\deploy_to_arduino.ps1
.EXAMPLE
    .\deploy_to_arduino.ps1 -BoardHost 10.0.0.10 -Pair 120
#>
[CmdletBinding()]
param(
    [string]$BoardHost,
    [ValidateSet('auto', 'usb', 'ssh')]
    [string]$Transport = 'auto',
    [string]$User = 'arduino',
    [string]$AppName = 'robot-control',
    [switch]$SkipRelay,
    [int]$Pair = 0,
    [switch]$Yes
)

. "$PSScriptRoot\deploy_common.ps1"

$AppFiles = @('app.yaml', 'python\main.py', 'python\host\bt_relay.py',
              'python\host\install.sh', 'sketch\sketch.ino', 'sketch\sketch.yaml')
$RemoteTar = "/tmp/$AppName-deploy.tar"
$SshOptions = @('-o', 'ConnectTimeout=8', '-o', 'StrictHostKeyChecking=accept-new')

# --- 0. Local checks ------------------------------------------------------------

Write-Step 'Checking local files'
foreach ($file in $AppFiles) {
    if (-not (Test-Path (Join-Path $PSScriptRoot $file))) { Stop-Deploy "Missing $file" }
}
$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
    & $python.Source -m py_compile (Join-Path $PSScriptRoot 'python\main.py') (Join-Path $PSScriptRoot 'python\host\bt_relay.py')
    if ($LASTEXITCODE -ne 0) { Stop-Deploy 'Python syntax error (see above).' }
    Write-Ok 'Python files compile.'
}

# --- 1. Find the board ------------------------------------------------------------

Write-Step 'Looking for the UNO Q'
$Board = $null   # @{ Kind = 'usb'|'ssh'; Target = adb serial or user@host; Adb = path }

function Find-UsbBoard {
    $adb = Find-Adb
    if (-not $adb) { return $null }
    if (Release-UsbFromWsl -Vids @($ArduinoVid) -What 'The UNO Q' -AssumeYes:$Yes) {
        Restart-AdbServer $adb
        Start-Sleep -Seconds 2
    }
    # Android phones report a model; the UNO Q's adbd does not.
    foreach ($dev in Get-AdbDevices $adb | Where-Object { $_.State -eq 'device' -and -not $_.Model }) {
        $check = (& $adb -s $dev.Serial shell 'command -v arduino-app-cli' 2>$null | Out-String).Trim()
        if ($check) { return @{ Kind = 'usb'; Target = $dev.Serial; Adb = $adb } }
    }
    return $null
}

function Find-NetworkBoardHost {
    if ($BoardHost) { return $BoardHost }
    if (-not (Get-Command arduino-cli -ErrorAction SilentlyContinue)) { return $null }
    try {
        $ports = (arduino-cli board list --format json | Out-String | ConvertFrom-Json).detected_ports
    } catch { return $null }
    $found = @($ports | Where-Object {
        $_.port.protocol -eq 'network' -and ($_.matching_boards | Where-Object fqbn -eq 'arduino:zephyr:unoq')
    })
    if ($found.Count -gt 1) {
        Stop-Deploy 'Several UNO Q boards are on the network.' @(
            "Pick one with -BoardHost: $(($found | ForEach-Object { $_.port.label }) -join ', ')")
    }
    if ($found) { return $found[0].port.address }
    return $null
}

function Test-Ssh([string]$Target) {
    $out = & ssh @SshOptions -o BatchMode=yes $Target 'command -v arduino-app-cli' 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $out.Trim()) { return 'ok' }
    if ($out -match 'Permission denied') { return 'auth' }
    if ($LASTEXITCODE -eq 0) { return 'not-unoq' }
    return "unreachable: $($out.Trim())"
}

# Copies this PC's public key to the board (asks for the board password once).
function Install-SshKey([string]$Target) {
    $keyFile = Join-Path $env:USERPROFILE '.ssh\id_ed25519'
    if (-not (Test-Path "$keyFile.pub")) {
        $rsa = Join-Path $env:USERPROFILE '.ssh\id_rsa'
        if (Test-Path "$rsa.pub") {
            $keyFile = $rsa
        } else {
            Write-Hint 'Creating an SSH key for this PC...'
            New-Item -ItemType Directory -Force (Split-Path $keyFile) | Out-Null
            ssh-keygen -q -t ed25519 -N '' -f $keyFile
        }
    }
    Write-Hint "Enter the board password for $Target (the one set up in App Lab):"
    Get-Content "$keyFile.pub" | & ssh @SshOptions $Target 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
    if ($LASTEXITCODE -ne 0) { Stop-Deploy 'Could not install the SSH key on the board.' }
}

if ($Transport -ne 'ssh') {
    $Board = Find-UsbBoard
    if (-not $Board -and $Transport -eq 'usb') {
        Stop-Deploy 'The UNO Q was not found over USB.' @(
            'Check the USB-C cable (it must carry data), or use -Transport ssh.')
    }
}

if (-not $Board) {
    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        Stop-Deploy 'ssh is not available.' @('Install the Windows OpenSSH client (Settings > Optional features).')
    }
    $boardHostName = Find-NetworkBoardHost
    if (-not $boardHostName) {
        Stop-Deploy 'The UNO Q was not found over USB or on the network.' @(
            'Plug it in over USB, or make sure it is on the same Wi-Fi network as this PC.',
            'Or pass its address: -BoardHost <ip>')
    }
    $target = "$User@$boardHostName"
    $status = Test-Ssh $target
    if ($status -eq 'auth') {
        Write-Hint "This PC has no SSH key access to $target."
        if (-not (Confirm-Action 'Set up SSH key access now?' -AssumeYes:$Yes)) {
            Stop-Deploy 'Cannot log in to the board.'
        }
        Install-SshKey $target
        $status = Test-Ssh $target
    }
    switch -Wildcard ($status) {
        'ok' { }
        'auth' { Stop-Deploy "SSH key login to $target still fails." }
        'not-unoq' { Stop-Deploy "$boardHostName is reachable but has no arduino-app-cli; is it a UNO Q?" }
        default { Stop-Deploy "Cannot reach $target ($status)." @('Check that the board is powered and on the network.') }
    }
    # scp needs IPv6 addresses in brackets (user@[addr]:path); ssh does not.
    $scpHost = if ($boardHostName -match ':') { "[$boardHostName]" } else { $boardHostName }
    $Board = @{ Kind = 'ssh'; Target = $target; ScpTarget = "$User@$scpHost" }
}

if ($Board.Kind -eq 'usb') { Write-Ok "Using USB (adb serial $($Board.Target))." }
else { Write-Ok "Using the network ($($Board.Target))." }

function Invoke-Board([string]$Script) {
    $command = ConvertTo-BashCommand $Script
    if ($Board.Kind -eq 'usb') {
        & $Board.Adb -s $Board.Target shell $command | Out-Host
    } else {
        & ssh @SshOptions -o BatchMode=yes $Board.Target $command | Out-Host
    }
    return $LASTEXITCODE
}

function Copy-ToBoard([string]$LocalPath, [string]$RemotePath) {
    if ($Board.Kind -eq 'usb') {
        $out = & $Board.Adb -s $Board.Target push $LocalPath $RemotePath 2>&1 | Out-String
    } else {
        $out = & scp -q @SshOptions -o BatchMode=yes $LocalPath "$($Board.ScpTarget):$RemotePath" 2>&1 | Out-String
    }
    if ($LASTEXITCODE -ne 0) { Stop-Deploy "Copying files to the board failed: $($out.Trim())" }
}

# --- 2. Package and copy -----------------------------------------------------

Write-Step 'Packaging the app'
$staging = Join-Path ([IO.Path]::GetTempPath()) "$AppName-deploy-$PID"
$tarFile = "$staging.tar"
Remove-Item $staging, $tarFile -Recurse -Force -ErrorAction SilentlyContinue
try {
    foreach ($file in $AppFiles) {
        $dest = Join-Path $staging $file
        New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
        # The board runs Linux: CRLF line endings break shell scripts.
        $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $file)).Replace("`r`n", "`n")
        [IO.File]::WriteAllText($dest, $text, (New-Object Text.UTF8Encoding $false))
    }
    tar -C $staging -cf $tarFile @($AppFiles | ForEach-Object { $_ -replace '\\', '/' })
    if ($LASTEXITCODE -ne 0) { Stop-Deploy 'Could not create the archive.' }

    Write-Step 'Copying to the board'
    Copy-ToBoard $tarFile $RemoteTar
} finally {
    Remove-Item $staging, $tarFile -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 3. Install, restart and verify on the board -------------------------------

$remote = @'
APP='__APP__'
ID="user:$APP"
APPDIR="$HOME/ArduinoApps/$APP"
BACKUPS="$HOME/.robot-control-backups"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

step() { echo "==> $*"; }
ok() { echo "    $*"; }

command -v arduino-app-cli >/dev/null || { echo "ERROR: arduino-app-cli not found"; exit 2; }

step "Installing files in $APPDIR"
mkdir -p "$APPDIR" "$BACKUPS"
if [ -f "$APPDIR/app.yaml" ]; then
  backup="$BACKUPS/$APP-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -C "$APPDIR" --exclude=./.cache -czf "$backup" . && ok "Previous version backed up to $backup"
  ls -1t "$BACKUPS/$APP-"*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f
fi
tar -C "$APPDIR" -xf '__TAR__' || { echo "ERROR: could not unpack the files"; exit 3; }
rm -f '__TAR__'
find "$APPDIR/python" -name __pycache__ -prune -exec rm -rf {} +

step "Restarting the app (compiles and flashes the sketch; can take a few minutes)"
arduino-app-cli app stop "$ID" >/dev/null 2>&1
STATUS="$APPDIR/.cache/status.txt"
MARKER=$(mktemp)   # only accept a status file written after this point
out=$(timeout 900 arduino-app-cli app start "$ID" 2>&1)
if ! printf '%s' "$out" | grep -q "started successfully"; then
  rm -f "$MARKER"
  echo "ERROR: the app did not start. Last output:"
  printf '%s\n' "$out" | grep -vE '^\[INFO\] (Info|Warn) :|Progress\[' | tail -n 40
  exit 4
fi
ok "App started."

if [ '__RELAY__' = 1 ]; then
  step "Installing the Bluetooth relay service"
  sh "$APPDIR/python/host/install.sh" >/dev/null 2>&1
  if systemctl --user is-active --quiet robot-bt-relay; then
    ok "Relay service running."
  else
    echo "ERROR: the relay service is not running:"
    journalctl --user -u robot-bt-relay -n 15 --no-pager
    exit 5
  fi
fi

step "Checking the app status"
# python/main.py records its startup status here (the Docker log of the app
# can be unreadable after an unclean shutdown).
status=""
for i in $(seq 60); do
  if [ "$STATUS" -nt "$MARKER" ] && grep -q "Waiting for phone" "$STATUS"; then
    status=$(cat "$STATUS")
    break
  fi
  sleep 1
done
rm -f "$MARKER"
if [ -z "$status" ]; then
  echo "WARNING: the app has not reported 'Waiting for phone' within 60 s - check: arduino-app-cli app logs $ID"
else
  printf '%s\n' "$status" | sed 's/^/    /'
  printf '%s' "$status" | grep -q "Modulino Motors detected: True" || \
    echo "WARNING: the Modulino Motors was not found - check the Qwiic cables, then redeploy."
  printf '%s' "$status" | grep -q "Modulino Distance detected: True" || \
    echo "WARNING: the Modulino Distance was not found - the obstacle stop is OFF. Check the Qwiic cables."
fi

step "Checking Bluetooth"
if ! bluetoothctl show 2>/dev/null | grep -q "Powered: yes"; then
  bluetoothctl power on >/dev/null 2>&1
  sleep 1
fi
if bluetoothctl show 2>/dev/null | grep -q "Powered: yes"; then
  ok "Bluetooth is on."
else
  echo "WARNING: Bluetooth is off and could not be turned on (try: rfkill unblock bluetooth)."
fi
paired=$(bluetoothctl devices Paired 2>/dev/null | cut -d' ' -f3-)
if [ -n "$paired" ]; then
  ok "Paired devices: $(printf '%s' "$paired" | paste -sd ',' - | sed 's/,/, /g')"
else
  echo "WARNING: no phone is paired yet - run this script with -Pair 120."
fi

if [ '__PAIR__' -gt 0 ]; then
  step "Pairing window open for __PAIR__ s: pair the phone with $(hostname) now"
  ( echo "agent NoInputNoOutput"; echo "default-agent"; echo "discoverable-timeout __PAIR__"
    echo "discoverable on"; echo "pairable on"
    for i in $(seq $(( __PAIR__ / 2 ))); do sleep 2; echo yes; done
    echo "discoverable off"; echo "pairable off" ) | bluetoothctl 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g' | grep -E "Paired: yes|Device .* Connected: yes" | sed 's/^/    /'
  ok "Pairing window closed."
fi
'@
$remote = $remote.Replace('__APP__', $AppName).Replace('__TAR__', $RemoteTar).
    Replace('__RELAY__', $(if ($SkipRelay) { '0' } else { '1' })).Replace('__PAIR__', [string]$Pair)

$exit = Invoke-Board $remote
switch ($exit) {
    0 { }
    2 { Stop-Deploy 'The board has no arduino-app-cli; is it a UNO Q?' }
    3 { Stop-Deploy 'Unpacking the files on the board failed.' }
    4 { Stop-Deploy 'The app failed to start (sketch compile/flash error?). See the output above.' }
    5 { Stop-Deploy 'The Bluetooth relay service failed. See the output above.' }
    default { Stop-Deploy "Deployment failed on the board (exit $exit)." }
}

Write-Host ''
Write-Host 'Done. Connect from the phone app to drive.' -ForegroundColor Green
