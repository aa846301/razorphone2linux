#!/bin/sh
# Minimal non-rootfs diagnostic init for separating kernel/DT/USB failures
# from UFS, rootfs, and systemd failures.

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
mkdir -p /dev/pts /run /sys/kernel/config
mount -t devpts devpts /dev/pts
mount -t tmpfs none /run
mount -t configfs none /sys/kernel/config
mdev -s

echo "razer-7.1-minimal-init reached" > /dev/kmsg

g=/sys/kernel/config/usb_gadget/diag
mkdir -p "$g/configs/c.1" "$g/strings/0x409" \
	 "$g/configs/c.1/strings/0x409"
echo 0x0525 > "$g/idVendor"
echo 0xa4a7 > "$g/idProduct"
echo 0x0200 > "$g/bcdUSB"
echo 0x0100 > "$g/bcdDevice"
echo 0x02 > "$g/bDeviceClass"
echo 0x02 > "$g/bDeviceSubClass"
echo 0x01 > "$g/bDeviceProtocol"
echo "aura-7.1-diag" > "$g/strings/0x409/serialnumber"
echo "Razer" > "$g/strings/0x409/manufacturer"
echo "Razer Phone 2 Linux 7.1 diagnostic" > "$g/strings/0x409/product"
echo "ACM diagnostic" > "$g/configs/c.1/strings/0x409/configuration"
echo 120 > "$g/configs/c.1/MaxPower"
mkdir -p "$g/functions/acm.usb0"
ln -s "$g/functions/acm.usb0" "$g/configs/c.1/acm.usb0"

udc=$(ls /sys/class/udc | head -n 1)
if [ -n "$udc" ]; then
	echo "$udc" > "$g/UDC"
	echo "razer-7.1-usb-acm-ready" > /dev/kmsg
fi

# Do not touch UFS or the real rootfs. This diagnostic intentionally waits for
# a host only after proving that the kernel reached /init and created USB ACM.
# Once the COM port is opened, provide a recovery shell.
sleep 1
mdev -s
if [ -c /dev/ttyGS0 ]; then
	exec /bin/sh </dev/ttyGS0 >/dev/ttyGS0 2>&1
fi

while :; do
	sleep 10
done
