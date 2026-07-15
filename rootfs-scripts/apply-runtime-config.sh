#!/bin/bash
# Idempotent runtime configuration overlay for the Razer Phone 2 rootfs.
#
# This script runs inside the target rootfs. Keep package installation out of
# this file so validation refreshes can update an existing image without
# replaying apt/dpkg in a QEMU chroot.

set -euo pipefail

if [ ! -x /usr/local/bin/usb-gadget-setup.sh ]; then
    echo "ERROR: /usr/local/bin/usb-gadget-setup.sh is missing or not executable"
    exit 1
fi

# NetworkManager owns WiFi. The USB gadget has a static address and must not be
# reconfigured by NetworkManager during boot.
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/10-unmanaged-usb-gadget.conf << 'NM_USB_EOF'
[keyfile]
unmanaged-devices=interface-name:usb0
NM_USB_EOF

# ath10k_snoc may receive an invalid MAC from WLAN firmware and otherwise picks
# a new random address each boot. A device-specific factory MAC can be supplied
# through /etc/razerphone2linux/device.env; never bake one phone's MAC into a
# public image.
if [ -f /etc/razerphone2linux/device.env ]; then
    # shellcheck disable=SC1091
    source /etc/razerphone2linux/device.env
fi

if [[ "${RAZER_WLAN_MAC:-}" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] &&
   [ "$RAZER_WLAN_MAC" != "00:00:00:00:00:00" ]; then
    mkdir -p /etc/systemd/network
    cat > /etc/systemd/network/10-wlan0-mac.link << WLAN_LINK_EOF
[Match]
OriginalName=wlan0

[Link]
MACAddress=${RAZER_WLAN_MAC}
WLAN_LINK_EOF

    # NetworkManager must not randomise the MAC for scans or connections.
    cat > /etc/NetworkManager/conf.d/20-wlan-mac.conf << NM_WLAN_EOF
[device-wlan-rand]
match-device=interface-name:wlan0
wifi.scan-rand-mac-address=no

[connection-wlan-mac]
match-device=interface-name:wlan0
wifi.cloned-mac-address=${RAZER_WLAN_MAC}
NM_WLAN_EOF
else
    rm -f /etc/systemd/network/10-wlan0-mac.link
    rm -f /etc/NetworkManager/conf.d/20-wlan-mac.conf
fi

systemctl enable NetworkManager 2>/dev/null || true
systemctl enable bluetooth.service 2>/dev/null || true

cat > /etc/systemd/system/razer-wifi-ready.service <<'WIFI_READY_EOF'
[Unit]
Description=Wait for Razer Phone 2 WiFi before network-dependent services
Wants=NetworkManager.service tqftpserv.service rmtfs.service
After=systemd-modules-load.service NetworkManager.service tqftpserv.service rmtfs.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/razer-wifi-ready
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
WIFI_READY_EOF
systemctl enable razer-wifi-ready.service 2>/dev/null || true

cat > /etc/systemd/system/resizefs.service << 'RESIZE_EOF'
[Unit]
Description=Expand root filesystem to fill partition
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c 'exec /usr/sbin/resize2fs $(findmnt -nvo SOURCE /)'
ExecStartPost=/usr/bin/systemctl disable resizefs.service
RemainAfterExit=true

[Install]
WantedBy=default.target
RESIZE_EOF
systemctl enable resizefs.service 2>/dev/null || true

cat > /etc/systemd/system/serial-getty@ttyMSM0.service << 'UART_EOF'
[Unit]
Description=Serial Console on ttyMSM0 (UART Debug)

[Service]
ExecStart=-/usr/sbin/agetty -L 115200 ttyMSM0 xterm-256color
Type=idle
Restart=always
RestartSec=0

[Install]
WantedBy=multi-user.target
UART_EOF
systemctl enable serial-getty@ttyMSM0.service 2>/dev/null || true

cat > /etc/systemd/system/serial-getty@ttyGS0.service << 'USB_EOF'
[Unit]
Description=Serial Console on ttyGS0 (USB Gadget)

[Service]
ExecStart=-/usr/sbin/agetty -L 115200 ttyGS0 xterm-256color
Type=idle
Restart=always
RestartSec=0

[Install]
WantedBy=multi-user.target
USB_EOF
systemctl enable serial-getty@ttyGS0.service 2>/dev/null || true

cat > /etc/systemd/system/usb-gadget.service << 'GADGET_SERVICE_EOF'
[Unit]
Description=USB ACM serial + NCM ethernet gadget
DefaultDependencies=no
After=systemd-modules-load.service local-fs.target
Before=sysinit.target
Before=serial-getty@ttyGS0.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/usb-gadget-setup.sh

[Install]
WantedBy=sysinit.target
GADGET_SERVICE_EOF
systemctl enable usb-gadget.service 2>/dev/null || true

mkdir -p /etc/systemd/system/serial-getty@ttyGS0.service.d
cat > /etc/systemd/system/serial-getty@ttyGS0.service.d/after-usb-gadget.conf << 'GADGET_DROPIN_EOF'
[Unit]
After=usb-gadget.service
Wants=usb-gadget.service
GADGET_DROPIN_EOF

cat > /etc/modules-load.d/razer-aura.conf << 'MODULES_EOF'
# Razer Phone 2 kernel modules (June-proven set).
# Keep MDSS/DSI/MSM DRM out of the default path. The practical display path is
# bootloader framebuffer -> simpledrm/fbdev (native NT36830 panel comes later).
# qcom_q6v5_mss must load early: rmtfs -P needs the mss remoteproc device to
# exist before it starts, and the modem itself waits for the RFS QMI service.
qcom_sysmon
qcom_q6v5_mss
ath10k_core
ath10k_snoc
# Touchscreen
rmi_i2c
MODULES_EOF

# Only IPA is kept away from autoload: bringing it up while the modem stack
# is broken or the modem is down hard-resets the SoC ~30s later (TZ/XPU
# class, silent). razer-wifi-ready loads it after verifying the pmOS-
# documented userspace set (rmtfs/pd-mapper/tqftpserv/qrtr-ns) and a running
# modem. Note: blacklist only blocks udev alias autoload; the guarded
# explicit modprobe in razer-wifi-ready still works.
cat > /etc/modprobe.d/razer-staged-bringup.conf << 'STAGED_EOF'
blacklist ipa
STAGED_EOF

# The modem userspace stack must survive early races (pd-mapper needs qrtr,
# rmtfs -P needs the mss rproc device): retry forever instead of dying to
# the default start-limit after 5 attempts.
mkdir -p /etc/systemd/system/pd-mapper.service.d
cat > /etc/systemd/system/pd-mapper.service.d/razer-resilience.conf << 'PDM_RES_EOF'
[Unit]
After=qrtr-ns.service systemd-modules-load.service
StartLimitIntervalSec=0

[Service]
Restart=on-failure
RestartSec=2
PDM_RES_EOF

mkdir -p /etc/systemd/system/rmtfs.service.d
cat > /etc/systemd/system/rmtfs.service.d/razer-resilience.conf << 'RMTFS_RES_EOF'
[Unit]
After=systemd-modules-load.service
StartLimitIntervalSec=0

[Service]
RestartSec=2
RMTFS_RES_EOF

# Warm reboot used to hang in an RCU-stall storm: systemd stops the QMI
# userspace (tqftpserv/rmtfs/...) while the remoteprocs are still running,
# and the modem teardown then stalls cpu1's timer softirq forever. Stop the
# remoteprocs FIRST on shutdown: this unit starts after the modem stack, so
# its ExecStop runs before those services stop (reverse order).
cat > /etc/systemd/system/razer-modem-stop.service << 'MODEM_STOP_EOF'
[Unit]
Description=Stop Qualcomm remoteprocs before the QMI userspace goes away
After=rmtfs.service pd-mapper.service tqftpserv.service qrtr-ns.service razer-wifi-ready.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=/bin/sh -c 'for r in /sys/class/remoteproc/remoteproc*; do [ "$(cat $r/state 2>/dev/null)" = "running" ] && echo stop > $r/state 2>/dev/null; done; true'
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
MODEM_STOP_EOF
systemctl enable razer-modem-stop.service 2>/dev/null || true

rm -f /etc/modprobe.d/razer-late-modem-test.conf

cat > /etc/modprobe.d/razer-no-kernel-pdmapper.conf << 'PDM_BLACKLIST_EOF'
# Follow the SDM845 userspace pd-mapper path. Keep the in-kernel mapper out if
# a future config accidentally builds it again.
blacklist qcom_pd_mapper
install qcom_pd_mapper /bin/false
PDM_BLACKLIST_EOF

cat > /usr/local/sbin/razer-wifi-late-start << 'LATE_WIFI_EOF'
#!/bin/sh
set -eu

MSS=""

if ! lsmod | grep -q '^qcom_q6v5_mss '; then
    modprobe qcom_q6v5_mss
fi
sleep 1

for r in /sys/class/remoteproc/remoteproc*; do
    [ -e "$r/name" ] || continue
    if [ "$(cat "$r/name" 2>/dev/null || true)" = "4080000.remoteproc" ]; then
        MSS="$r"
        break
    fi
done

if [ -z "$MSS" ]; then
    echo "MSS_NOT_FOUND"
    exit 3
fi

echo disabled > "$MSS/recovery" 2>/dev/null || true
systemctl reset-failed rmtfs.service 2>/dev/null || true
systemctl restart rmtfs.service 2>/dev/null || true
sleep 2

state="$(cat "$MSS/state" 2>/dev/null || true)"
echo "MSS state before=$state"

if [ "$state" != "running" ]; then
    echo start > "$MSS/state" || true
fi

sleep 2
echo "MSS state after start=$(cat "$MSS/state" 2>/dev/null || true)"

echo "=== load ath10k ==="
modprobe ath10k_core || true
modprobe ath10k_snoc || true

for i in 1 2 3 4 5 6 7 8; do
    echo "=== poll $i ==="
    cat "$MSS/name" "$MSS/state" "$MSS/recovery" 2>/dev/null || true
    ip -br link
    ls -la /sys/class/ieee80211 2>/dev/null || true
    qrtr-lookup 2>/dev/null | grep -E '(^ *69|WLFW|wlan|Service|  *66|  *43|  *14|  *64|4096)' || true
    sleep 5
done

echo "=== rmtfs ==="
journalctl -u rmtfs -b --no-pager | tail -120 || true

echo "=== tqftpserv ==="
journalctl -u tqftpserv -b --no-pager | tail -120 || true

echo "=== dmesg tail ==="
dmesg --time-format=iso |
    egrep -i 'remoteproc|q6v5|mpss|mba|modem|fatal|crash|ipa|ath10k|wlan|wifi|wlfw|qrtr|tftp|servreg|pd_mapper|rmtfs|glink|firmware' |
    tail -220
LATE_WIFI_EOF
chmod 0755 /usr/local/sbin/razer-wifi-late-start

if [ -f /usr/lib/firmware/qcom/sdm845/Razer/aura/wlanmdsp.mbn ]; then
    mkdir -p /usr/lib/firmware/qcom/sdm845 /lib/firmware/qcom/sdm845
    ln -sfn Razer/aura/wlanmdsp.mbn /usr/lib/firmware/qcom/sdm845/wlanmdsp.mbn
    ln -sfn Razer/aura/wlanmdsp.mbn /lib/firmware/qcom/sdm845/wlanmdsp.mbn

    mkdir -p /lib/firmware/image /readonly/firmware /readonly/vendor/firmware /readonly/vendor/firmware_mnt/image
    ln -sfn ../qcom/sdm845/Razer/aura/wlanmdsp.mbn /lib/firmware/image/wlanmdsp.mbn
    for jsn in modemr.jsn modemuw.jsn; do
        if [ -f "/usr/lib/firmware/qcom/sdm845/Razer/aura/$jsn" ]; then
            cp -f "/usr/lib/firmware/qcom/sdm845/Razer/aura/$jsn" "/lib/firmware/image/$jsn"
        fi
    done
    ln -sfn /lib/firmware/image /readonly/firmware/image
    ln -sfn /lib/firmware/qcom/sdm845/Razer/aura/wlanmdsp.mbn /readonly/vendor/firmware/wlanmdsp.mbn
    ln -sfn /lib/firmware/qcom/sdm845/Razer/aura/wlanmdsp.mbn /readonly/vendor/firmware_mnt/image/wlanmdsp.mbn
fi

if [ -x /usr/bin/tqftpserv ] || [ -x /usr/local/bin/tqftpserv ]; then
    if [ ! -f /etc/systemd/system/tqftpserv.service ] &&
       [ ! -f /usr/lib/systemd/system/tqftpserv.service ] &&
       [ ! -f /lib/systemd/system/tqftpserv.service ]; then
        cat > /etc/systemd/system/tqftpserv.service <<'TQFTP_SERVICE_EOF'
[Unit]
Description=QRTR TFTP service
After=qrtr-ns.service
Wants=qrtr-ns.service

[Service]
ExecStart=/usr/bin/tqftpserv
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
TQFTP_SERVICE_EOF
    fi
    systemctl enable tqftpserv.service 2>/dev/null || true
fi

if [ -x /usr/local/bin/pd-mapper ]; then
    cat > /etc/systemd/system/pd-mapper.service <<'PDM_SERVICE_EOF'
[Unit]
Description=Qualcomm Protection Domain Mapper
After=systemd-modules-load.service
Before=rmtfs.service tqftpserv.service

[Service]
ExecStart=/usr/local/bin/pd-mapper
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
PDM_SERVICE_EOF
    systemctl enable pd-mapper.service 2>/dev/null || true
else
    echo "WARNING: /usr/local/bin/pd-mapper missing; userspace pd-mapper service not installed"
fi

if [ -x /usr/local/bin/rmtfs-razer-test ]; then
    mkdir -p /etc/systemd/system/rmtfs.service.d
    cat > /etc/systemd/system/rmtfs.service.d/razer-nvdef.conf <<'RMTFS_RAZER_EOF'
[Service]
ExecStart=
ExecStart=/usr/local/bin/rmtfs-razer-test -r -P -s -v
RMTFS_RAZER_EOF
    if [ "${RAZER_MSS_DIAG_MANUAL:-0}" = "1" ]; then
        mkdir -p /etc/razerphone2linux
        cat > /etc/razerphone2linux/mss-diagnostic-mode <<'MSS_DIAG_EOF'
RAZER_MSS_DIAG_MANUAL=1
rmtfs.service is intentionally disabled.
Use /usr/local/sbin/razer-wifi-late-start or a controlled evidence script over SSH.
MSS_DIAG_EOF
        systemctl disable rmtfs.service 2>/dev/null || true
        systemctl reset-failed rmtfs.service 2>/dev/null || true
    else
        rm -f /etc/razerphone2linux/mss-diagnostic-mode 2>/dev/null || true
        systemctl enable rmtfs.service 2>/dev/null || true
    fi
fi


cat > /usr/local/bin/razer-display-keepalive.sh <<'DISPLAY_KEEPALIVE_EOF'
#!/bin/bash
set -euo pipefail

# Keep the bootloader scanout path visible while MDSS/DSI remains disabled.
# Safety rule: do not raise panel backlight or WLED brightness automatically.
# The live device has shown unsafe full-brightness behavior when PMI8998 WLED is
# exposed without Razer-specific limits. Backlight tests must be explicit,
# manual, low brightness, and short lived.
if [ -w /sys/class/graphics/fb0/blank ]; then
    echo 0 > /sys/class/graphics/fb0/blank || true
fi
DISPLAY_KEEPALIVE_EOF
chmod 0755 /usr/local/bin/razer-display-keepalive.sh

cat > /etc/systemd/system/razer-display-keepalive.service <<'DISPLAY_SERVICE_EOF'
[Unit]
Description=Keep Razer bootloader framebuffer visible
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/razer-display-keepalive.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
DISPLAY_SERVICE_EOF
systemctl enable razer-display-keepalive.service 2>/dev/null || true

systemctl disable apt-daily.timer 2>/dev/null || true
systemctl disable apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable fstrim.timer 2>/dev/null || true

systemctl daemon-reload 2>/dev/null || true
