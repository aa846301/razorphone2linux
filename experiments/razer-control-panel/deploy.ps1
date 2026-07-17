param(
    [string]$Distro = "Ubuntu-24.04",
    [string]$HostName = "192.168.137.133",
    [string]$UserName = "klipper",
    [string]$IdentityFile = "C:\tmp\razer_usb_ed25519",
    [string]$KnownHostsFile = "C:\tmp\razer_control_panel_known_hosts",
    [string]$SudoPassword = "klipper"
)

$ErrorActionPreference = "Stop"
$experimentDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$kmsSource = Join-Path $experimentDir "razer-kms-present.c"
$kmsBinary = Join-Path $env:TEMP "razer-kms-present-arm64"
$cameraSource = Join-Path $experimentDir "razer-camera-preview.c"
$cameraBinary = Join-Path $env:TEMP "razer-camera-preview-arm64"

function ConvertTo-WslPath([string]$Path) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    $drive = $fullPath.Substring(0, 1).ToLowerInvariant()
    $remainder = $fullPath.Substring(2).Replace("\", "/")
    return "/mnt/$drive$remainder"
}

$kmsSourceWsl = ConvertTo-WslPath $kmsSource
$kmsBinaryWsl = ConvertTo-WslPath $kmsBinary
& wsl.exe -d $Distro --exec aarch64-linux-gnu-gcc -O2 -Wall -Wextra `
    -I /usr/include/drm -o $kmsBinaryWsl $kmsSourceWsl
if ($LASTEXITCODE -ne 0) {
    throw "Failed to cross-compile the DRM/KMS presenter"
}

$cameraSourceWsl = ConvertTo-WslPath $cameraSource
$cameraBinaryWsl = ConvertTo-WslPath $cameraBinary
& wsl.exe -d $Distro --exec aarch64-linux-gnu-gcc -O2 -Wall -Wextra `
    -o $cameraBinaryWsl $cameraSourceWsl
if ($LASTEXITCODE -ne 0) {
    throw "Failed to cross-compile the camera preview helper"
}

if (!(Test-Path -LiteralPath $IdentityFile)) {
    $defaultIdentity = Join-Path $env:USERPROFILE ".ssh\id_ed25519"
    if (Test-Path -LiteralPath $defaultIdentity) {
        Write-Output "Requested identity is missing; using $defaultIdentity"
        $IdentityFile = $defaultIdentity
    }
}

$sshOptions = @(
    "-i", $IdentityFile,
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "UserKnownHostsFile=$KnownHostsFile"
)
$target = "${UserName}@${HostName}"

$savedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& ssh @sshOptions $target "true" 2>$null
$keyLoginExitCode = $LASTEXITCODE
$ErrorActionPreference = $savedErrorActionPreference
if ($keyLoginExitCode -ne 0) {
    $plink = "C:\Program Files\PuTTY\plink.exe"
    $publicKeyFile = "${IdentityFile}.pub"
    if (!(Test-Path -LiteralPath $plink) -or !(Test-Path -LiteralPath $publicKeyFile)) {
        throw "Key login failed and PuTTY/public key is unavailable for password bootstrap"
    }

    $scanFile = [IO.Path]::GetTempFileName()
    try {
        $savedErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            # Windows ssh-keyscan may not support the KEX preferred by a new
            # Ubuntu host. A normal OpenSSH handshake still records the host
            # key before the expected authentication failure.
            & ssh `
                -o BatchMode=yes `
                -o ConnectTimeout=10 `
                -o PreferredAuthentications=none `
                -o StrictHostKeyChecking=accept-new `
                -o UserKnownHostsFile=$scanFile `
                $target "true" 2>$null
        }
        finally {
            $ErrorActionPreference = $savedErrorActionPreference
        }
        if ((Get-Item -LiteralPath $scanFile).Length -eq 0) {
            throw "Unable to record the phone SSH host key"
        }
        $fingerprintLine = & ssh-keygen -lf $scanFile
        if ($LASTEXITCODE -ne 0 -or !$fingerprintLine) {
            throw "Unable to read the phone SSH host key"
        }
        $fingerprint = ($fingerprintLine -split "\s+")[1]
        $publicKey = [IO.File]::ReadAllBytes($publicKeyFile)
        $encodedKey = [Convert]::ToBase64String($publicKey)
        $bootstrap = "umask 077; mkdir -p ~/.ssh; echo '$encodedKey' | base64 -d >> ~/.ssh/authorized_keys; sort -u -o ~/.ssh/authorized_keys ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys"
        & $plink -ssh -batch -pw $SudoPassword -hostkey $fingerprint $target $bootstrap
        if ($LASTEXITCODE -ne 0) {
            throw "Password bootstrap failed"
        }

        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $KnownHostsFile) | Out-Null
        Copy-Item -Force -LiteralPath $scanFile -Destination $KnownHostsFile
    }
    finally {
        Remove-Item -Force -LiteralPath $scanFile -ErrorAction SilentlyContinue
    }
}

& scp @sshOptions `
    (Join-Path $experimentDir "razer-control-panel.py") `
    (Join-Path $experimentDir "razer-control-panel.service") `
    (Join-Path $experimentDir "razer-shutdown-console.sh") `
    (Join-Path $experimentDir "razer-camera-launch.sh") `
    (Join-Path $experimentDir "razer-haptic-test.sh") `
    (Join-Path $experimentDir "razer-audio-test.sh") `
    $kmsBinary `
    $cameraBinary `
    "${target}:/tmp/"
if ($LASTEXITCODE -ne 0) {
    throw "Failed to copy the control panel files"
}

$encodedPassword = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes("$SudoPassword`n"))
$remote = @"
password=`$(printf '%s' '$encodedPassword' | base64 -d)
printf '%s' "`$password" | sudo -S install -m 0755 /tmp/razer-control-panel.py /usr/local/sbin/razer-control-panel
printf '%s' "`$password" | sudo -S install -m 0644 /tmp/razer-control-panel.service /etc/systemd/system/razer-control-panel.service
printf '%s' "`$password" | sudo -S install -m 0755 /tmp/razer-shutdown-console.sh /usr/local/sbin/razer-shutdown-console
printf '%s' "`$password" | sudo -S install -m 0755 /tmp/razer-kms-present-arm64 /usr/local/sbin/razer-kms-present
printf '%s' "`$password" | sudo -S install -m 0755 /tmp/razer-camera-preview-arm64 /usr/local/sbin/razer-camera-preview
printf '%s' "`$password" | sudo -S install -m 0755 /tmp/razer-camera-launch.sh /usr/local/sbin/razer-camera-launch
printf '%s' "`$password" | sudo -S install -m 0755 /tmp/razer-haptic-test.sh /usr/local/sbin/razer-haptic-test
printf '%s' "`$password" | sudo -S install -m 0755 /tmp/razer-audio-test.sh /usr/local/sbin/razer-audio-test
if ! command -v media-ctl >/dev/null || ! command -v v4l2-ctl >/dev/null || ! command -v fftest >/dev/null || ! command -v speaker-test >/dev/null; then
    printf '%s' "`$password" | sudo -S apt-get update
    printf '%s' "`$password" | sudo -S apt-get install -y v4l-utils joystick alsa-utils
fi
printf '%s' "`$password" | sudo -S systemctl disable --now razer-panel-idle-blank.service
printf '%s' "`$password" | sudo -S systemctl disable --now getty@tty1.service
printf '%s' "`$password" | sudo -S systemctl daemon-reload
printf '%s' "`$password" | sudo -S systemctl enable razer-control-panel.service
printf '%s' "`$password" | sudo -S systemctl restart razer-control-panel.service
systemctl --no-pager --full status razer-control-panel.service
"@
$remote = $remote.Replace("`r`n", "`n")

& ssh @sshOptions $target $remote
if ($LASTEXITCODE -ne 0) {
    throw "Failed to install the control panel service"
}

Remove-Item -Force -LiteralPath $kmsBinary -ErrorAction SilentlyContinue
Remove-Item -Force -LiteralPath $cameraBinary -ErrorAction SilentlyContinue
