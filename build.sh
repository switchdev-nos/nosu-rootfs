#!/bin/bash

ROOTCONF_DIR="./rootconf"
ROOTFS_FILE="ubuntu1804_mlnx.tar.xz"
ROOTDIR="/tmp/rootfs"
UBUNTU_BASE_URL="http://cdimage.ubuntu.com/ubuntu-base/releases/18.04.2/release/ubuntu-base-18.04-base-amd64.tar.gz"
FWURL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mellanox"
FWDIR="$ROOTDIR/lib/firmware/mellanox"
FRRVER="frr-stable"
TLABEL=NOS
TIMEZONE="Europe/Moscow"

HOSTNAME=mellanox
USERNAME=admin
USERPASS=admin
ROOTPASS=root

fail() {
    [ "$1" != "" ] && echo $1
    exit 1
}

# check root privileges
[ $(id -g) = 0 ] || fail "Need root privilegies. Run 'sudo $0'"

if [ -d "$ROOTDIR" ]; then
echo "== Cleaning up $ROOTDIR"
rm -fr $ROOTDIR
fi

echo "== Loading Ubuntu base image into $ROOTDIR"
mkdir -p $ROOTDIR
curl $UBUNTU_BASE_URL | tar -xz -C /tmp/rootfs

echo "== Copying custom packages"
# copy custom kernel
cp -Rf ./kernel "$ROOTDIR/tmp"

# copy custom packages
cp -Rf ./packages "$ROOTDIR/tmp"

# download mellanox firmware
echo "== Loading Ubuntu base image into $ROOTDIR"
mkdir -p $FWDIR
for file in $(curl -s $FWURL |
                   sed -e 's/\(<[^<][^<]*>\)//g' |
                   grep mlxsw); do
    curl -s -o "$FWDIR/$file" "$FWURL/$file"
done

# mount fs
echo "== Preparing rootfs"
chroot "$ROOTDIR" sh -c "mount -t proc /proc /proc; mount -t sysfs /sys /sys; mount -t devpts devpts /dev/pts"

## configure dns
chroot "$ROOTDIR" sh -c "rm -f /etc/resolv.conf"
chroot "$ROOTDIR" sh -c "echo 'nameserver 8.8.8.8' > /etc/resolv.conf"

## instal packages
echo "== Installing packages"
chroot "$ROOTDIR" sh -c "apt -yqq update --no-install-recommends && apt -yqq upgrade --no-install-recommends"
chroot "$ROOTDIR" sh -c "DEBIAN_FRONTEND=noninteractive apt -yqq upgrade --no-install-recommends"

#### systemd
chroot "$ROOTDIR" sh -c "DEBIAN_FRONTEND=noninteractive apt -yq --no-install-recommends install systemd systemd-sysv udev dbus"

#### grub
chroot "$ROOTDIR" sh -c "DEBIAN_FRONTEND=noninteractive apt -yq --no-install-recommends install grub-pc initramfs-tools"

#### custom kernel
chroot "$ROOTDIR" sh -c "DEBIAN_FRONTEND=noninteractive apt -yq --no-install-recommends install /tmp/kernel/*.deb"

#### network services
chroot "$ROOTDIR" sh -c "DEBIAN_FRONTEND=noninteractive apt -yq --no-install-recommends install openssh-server xinetd telnetd snmpd ntp isc-dhcp-relay isc-dhcp-client"

#### network tools
chroot "$ROOTDIR" sh -c "DEBIAN_FRONTEND=noninteractive apt -yq --no-install-recommends install iproute2 libnl-route-3-200 ethtool bridge-utils net-tools iputils-ping traceroute tcpdump tshark bwm-ng"

#### tools
chroot "$ROOTDIR" sh -c "DEBIAN_FRONTEND=noninteractive apt -yq --no-install-recommends install sudo rsyslog lm-sensors smartmontools curl wget lsb-release gnupg2 ca-certificates vim nano less dnsutils pciutils usbutils lshw dmidecode lsof parted sosreport python locales"

#### FRR protocol stack
chroot "$ROOTDIR" sh -c "curl -s https://deb.frrouting.org/frr/keys.asc | apt-key add -"
RELEASE=$(chroot "$ROOTDIR" sh -c "lsb_release -s -c")
chroot "$ROOTDIR" sh -c "echo 'deb https://deb.frrouting.org/frr $RELEASE $FRRVER' | tee /etc/apt/sources.list.d/frr.list"
chroot "$ROOTDIR" sh -c "apt update"
chroot "$ROOTDIR" sh -c "DEBIAN_FRONTEND=noninteractive apt -yq --no-install-recommends install frr frr-pythontools"
chroot "$ROOTDIR" sh -c "echo '#deb https://deb.frrouting.org/frr $RELEASE $FRRVER' | tee /etc/apt/sources.list.d/frr.list"

#### custom packages
chroot "$ROOTDIR" sh -c "DEBIAN_FRONTEND=noninteractive apt -yq --no-install-recommends install /tmp/packages/*.deb"

# CONFIGURE ADDITIONAL SERVICES
echo "== Configuring system"

# hostname config
chroot "$ROOTDIR" sh -c "echo $HOSTNAME > /etc/hostname"
cat << EOF > "$ROOTDIR/etc/hosts"
127.0.0.1       $HOSTNAME localhost
::1             $HOSTNAME localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
ff02::3         ip6-allhosts
EOF


# users config
USERPASSC=$(perl -e "print crypt("$USERPASS","Q4")")
ROOTPASSC=$(perl -e "print crypt("$ROOTPASS","Q4")")
chroot "$ROOTDIR" sh -c "useradd -m -s /bin/bash -G sudo -p $USERPASSC $USERNAME"
chroot "$ROOTDIR" sh -c "usermod -p $USERPASSC root"

# copy the contents of the rootconf folder to the rootfs
rsync -avz --chown root:root "$ROOTCONF_DIR/*" "$ROOTDIR"

# post config
echo "== Finalizing system config"
chroot "$ROOTDIR" sh -c "chmod +x /etc/rc.local"
chroot "$ROOTDIR" sh -c "ssh-keygen -A"
chroot "$ROOTDIR" sh -c "echo | ssh-keygen -q -t rsa -P ''"
chroot "$ROOTDIR" sh -c "su - $USERNAME -c 'echo | ssh-keygen -q -t rsa'"
chroot "$ROOTDIR" sh -c "systemctl disable motd-news.timer"
chroot "$ROOTDIR" sh -c "systemctl disable keepalived.service"
chroot "$ROOTDIR" sh -c "systemctl disable lldpad.service"
chroot "$ROOTDIR" sh -c "systemctl disable isc-dhcp-relay.service"
chroot "$ROOTDIR" sh -c "systemctl disable isc-dhcp-relay6.service"
chroot "$ROOTDIR" sh -c "systemctl disable smartd.service"
chroot "$ROOTDIR" sh -c "systemctl disable smartmontools.service"
chroot "$ROOTDIR" sh -c "systemctl disable postfix.service"
chroot "$ROOTDIR" sh -c "systemctl disable bird.service"
chroot "$ROOTDIR" sh -c "systemctl disable vsftpd.service"
chroot "$ROOTDIR" sh -c "systemctl disable xinetd.service"
chroot "$ROOTDIR" sh -c "systemctl enable systemd-resolved"
chroot "$ROOTDIR" sh -c "systemctl enable sshd.service"
chroot "$ROOTDIR" sh -c "systemctl enable hw-management.service"
chroot "$ROOTDIR" sh -c "systemctl enable lldpd.service"
chroot "$ROOTDIR" sh -c "systemctl enable ntp.service"
chroot "$ROOTDIR" sh -c "systemctl enable rsyslog.service"

chroot "$ROOTDIR" sh -c "locale-gen en_US.UTF-8"
chroot "$ROOTDIR" sh -c "update-locale LANG=en_US.UTF-8"
chroot "$ROOTDIR" sh -c "locale-gen --purge en_US.UTF-8"

chroot "$ROOTDIR" sh -c "rm -f /etc/localtime && ln -s /usr/share/zoneinfo/$TIMEZONE /etc/localtime"

# cleanup
echo "== Cleaning up"
chroot "$ROOTDIR" sh -c "rm -f /etc/resolv.conf && ln -sf /var/run/systemd/resolve/resolv.conf /etc/resolv.conf"
chroot "$ROOTDIR" sh -c "apt autoremove -y && apt clean all"
rm -rf "$ROOTDIR/tmp"/*
rm -rf "$ROOTDIR/var/lib/apt/lists"/*
chroot "$ROOTDIR" sh -c "umount /proc; umount /sys; umount /dev/pts"

# pack image
echo "== Packing rootfs into $ROOTFS_FILE"
tar -C "$ROOTDIR" -cpJf "./$ROOTFS_FILE" .