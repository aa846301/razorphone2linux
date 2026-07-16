param(
    [string]$HostName = "192.168.137.133",
    [string]$UserName = "klipper",
    [string]$IdentityFile = "C:\tmp\razer_usb_ed25519",
    [string]$KnownHostsFile = "C:\tmp\razer_control_panel_known_hosts",
    [string]$SudoPassword = "klipper"
)

$ErrorActionPreference = "Stop"
$sshOptions = @(
    "-i", $IdentityFile,
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "UserKnownHostsFile=$KnownHostsFile"
)
$target = "${UserName}@${HostName}"
$encodedPassword = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes("$SudoPassword`n"))
$remote = @"
password=`$(printf '%s' '$encodedPassword' | base64 -d)
printf '%s' "`$password" | sudo -S systemctl disable --now razer-control-panel.service
printf '%s' "`$password" | sudo -S rm -f /usr/local/sbin/razer-control-panel /usr/local/sbin/razer-kms-present /etc/systemd/system/razer-control-panel.service /run/razer-control-panel.frame
printf '%s' "`$password" | sudo -S rm -rf /var/lib/razer-control-panel
printf '%s' "`$password" | sudo -S systemctl daemon-reload
printf '%s' "`$password" | sudo -S systemctl enable --now razer-charge-limits.service
printf '%s' "`$password" | sudo -S systemctl enable --now getty@tty1.service
printf '%s' "`$password" | sudo -S systemctl enable --now razer-panel-idle-blank.service
"@

& ssh @sshOptions $target $remote
if ($LASTEXITCODE -ne 0) {
    throw "Failed to remove the experimental control panel"
}
