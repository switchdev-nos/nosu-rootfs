#!/bin/bash

ROOTCONF_DIR="./rootconf"
ROOTDIR="/tmp/rootfs"
FWDIR="$ROOTDIR/lib/firmware/mellanox"

fail() {
    [ "$1" != "" ] && echo $1
    exit 1
}

# check root privileges
[ $(id -g) = 0 ] || fail "Need root privilegies. Run 'sudo $0'"

if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
  echo "Usage: $0 [ENV_FILE]"
  exit 0
fi

if [ -n "$1" ]; then
  if [ -r "$1" ]; then
    set -a
    . "$1"
    set +a
  else
    fail "ENV_FILE not readable or missing"
  fi
fi

if [ -d "$ROOTDIR" ]; then
echo "== Cleaning up $ROOTDIR"
rm -fr $ROOTDIR
fi

echo "== Loading Ubuntu base image into $ROOTDIR"
mkdir -p $ROOTDIR
curl $NOSU_UBUNTU_BASE_URL | tar -xz -C $ROOTDIR

echo "== Copying custom packages"
# copy custom kernel
rsync -a ./kernel "$ROOTDIR/tmp/"

# copy custom packages
rsync -a ./packages "$ROOTDIR/tmp/"

# mount fs
echo "== Preparing rootfs"
mount -t proc /proc "$ROOTDIR"/proc/
mount --rbind /sys "$ROOTDIR"/sys/
mount --rbind /dev "$ROOTDIR"/dev/

## configure dns
chroot "$ROOTDIR" sh -c "rm -f /etc/resolv.conf"
chroot "$ROOTDIR" sh -c "echo 'nameserver 8.8.8.8' > /etc/resolv.conf"

## instal packages
echo "== Installing packages"
chroot "$ROOTDIR" sh -c "apt -yqq update --no-install-recommends"
chroot "$ROOTDIR" sh -c "DEBIAN_FRONTEND=noninteractive apt -yqq upgrade --no-install-recommends"

#### systemd
chroot "$ROOTDIR" sh -c "DEBIAN_FRONTEND=noninteractive apt -yq --no-install-recommends install systemd systemd-sysv udev dbus ifupdown2"

#### grub
chroot "$ROOTDIR" sh -c "DEBIAN_FRONTEND=noninteractive apt -yq --no-install-recommends install grub-pc initramfs-tools"

#### custom kernel
chroot "$ROOTDIR" sh -c "DEBIAN_FRONTEND=noninteractive apt -yq --no-install-recommends install /tmp/kernel/*.deb"

#### network services
chroot "$ROOTDIR" sh -c "DEBIAN_FRONTEND=noninteractive apt -yq --no-install-recommends install openssh-server update-inetd telnetd lldpd snmpd snmptrapd ntp isc-dhcp-relay isc-dhcp-client vsftpd"

#### network tools
chroot "$ROOTDIR" sh -c "DEBIAN_FRONTEND=noninteractive apt -yq --no-install-recommends install iproute2 libnl-route-3-200 ethtool bridge-utils net-tools iputils-ping traceroute tcpdump tshark bwm-ng bc"

#### tools
chroot "$ROOTDIR" sh -c "DEBIAN_FRONTEND=noninteractive apt -yq --no-install-recommends install sudo rsyslog lm-sensors smartmontools curl wget lsb-release gnupg2 ca-certificates vim nano less dnsutils pciutils usbutils lshw dmidecode lsof parted sosreport python locales"

RELEASE=$(chroot "$ROOTDIR" sh -c "lsb_release -s -c")
#### FRR protocol stack
chroot "$ROOTDIR" sh -c "curl -s https://deb.frrouting.org/frr/keys.asc | apt-key add -"
chroot "$ROOTDIR" sh -c "echo 'deb https://deb.frrouting.org/frr $RELEASE $NOSU_FRRVER' | tee /etc/apt/sources.list.d/frr.list"
chroot "$ROOTDIR" sh -c "apt update"
chroot "$ROOTDIR" sh -c "DEBIAN_FRONTEND=noninteractive apt -yq --no-install-recommends install frr frr-pythontools"
chroot "$ROOTDIR" sh -c "echo '#deb https://deb.frrouting.org/frr $RELEASE $NOSU_FRRVER' | tee /etc/apt/sources.list.d/frr.list"

#### Keepalived
chroot "$ROOTDIR" sh -c "echo 'deb http://ppa.launchpad.net/hnakamur/keepalived/ubuntu $RELEASE main' | tee /etc/apt/sources.list.d/keepalived.list"
chroot "$ROOTDIR" sh -c "apt update"
chroot "$ROOTDIR" sh -c "DEBIAN_FRONTEND=noninteractive apt -yq --no-install-recommends install keepalived"
chroot "$ROOTDIR" sh -c "echo '#deb http://ppa.launchpad.net/hnakamur/keepalived/ubuntu $RELEASE main' | tee /etc/apt/sources.list.d/keepalived.list"

#### custom packages
chroot "$ROOTDIR" sh -c "DEBIAN_FRONTEND=noninteractive apt -yq --no-install-recommends install /tmp/packages/*.deb"

# CONFIGURE ADDITIONAL SERVICES
echo "== Configuring system"

# version information
if [ -n "$NOSU_VERSION" ]; then
echo "VARIANT=nosu" >> "$ROOTDIR/etc/os-release"
echo "VARIANT_ID=$NOSU_VERSION" >> "$ROOTDIR/etc/os-release"
fi

# hostname config
chroot "$ROOTDIR" sh -c "echo $NOSU_HOSTNAME > /etc/hostname"
cat << EOF > "$ROOTDIR/etc/hosts"
127.0.0.1       $NOSU_HOSTNAME localhost
::1             $NOSU_HOSTNAME localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
ff02::3         ip6-allhosts
EOF


# users config
USERPASSC=$(perl -e "print crypt("$NOSU_USERPASS","Q4")")
ROOTPASSC=$(perl -e "print crypt("$NOSU_ROOTPASS","Q4")")
chroot "$ROOTDIR" sh -c "useradd -m -s /bin/bash -G sudo -p $USERPASSC $NOSU_USERNAME"
chroot "$ROOTDIR" sh -c "usermod -p $USERPASSC root"

# copy the contents of the rootconf folder to the rootfs
rsync -avz --chown root:root "$ROOTCONF_DIR"/* "$ROOTDIR"

# post config
echo "== Finalizing system config"
chroot "$ROOTDIR" sh -c "chmod +x /etc/rc.local"
chroot "$ROOTDIR" sh -c "chown -R frr:frr /etc/frr"
chroot "$ROOTDIR" sh -c "ssh-keygen -A"
chroot "$ROOTDIR" sh -c "echo | ssh-keygen -q -t rsa -P ''"
chroot "$ROOTDIR" sh -c "su - $NOSU_USERNAME -c 'echo | ssh-keygen -q -t rsa'"
chroot "$ROOTDIR" sh -c "systemctl disable motd-news.timer"
chroot "$ROOTDIR" sh -c "systemctl disable keepalived.service"
chroot "$ROOTDIR" sh -c "systemctl disable isc-dhcp-relay.service"
chroot "$ROOTDIR" sh -c "systemctl disable isc-dhcp-relay6.service"
chroot "$ROOTDIR" sh -c "systemctl disable smartd.service"
chroot "$ROOTDIR" sh -c "systemctl disable smartmontools.service"
chroot "$ROOTDIR" sh -c "systemctl disable postfix.service"
chroot "$ROOTDIR" sh -c "systemctl disable bird.service"
chroot "$ROOTDIR" sh -c "systemctl disable inetd.service"
chroot "$ROOTDIR" sh -c "systemctl disable snmpd.service"
chroot "$ROOTDIR" sh -c "systemctl disable ntp.service"
chroot "$ROOTDIR" sh -c "systemctl disable vsftpd.service"
chroot "$ROOTDIR" sh -c "systemctl disable ptmd.service"
chroot "$ROOTDIR" sh -c "systemctl disable mlnx-eswitch.service"
chroot "$ROOTDIR" sh -c "systemctl enable systemd-resolved"
chroot "$ROOTDIR" sh -c "systemctl enable sshd.service"
chroot "$ROOTDIR" sh -c "systemctl enable hw-management.service"
chroot "$ROOTDIR" sh -c "systemctl enable lldpd.service"
chroot "$ROOTDIR" sh -c "systemctl enable rsyslog.service"
chroot "$ROOTDIR" sh -c "systemctl enable frr.service"

chroot "$ROOTDIR" sh -c "locale-gen en_US.UTF-8"
chroot "$ROOTDIR" sh -c "update-locale LANG=en_US.UTF-8"
chroot "$ROOTDIR" sh -c "locale-gen --purge en_US.UTF-8"

chroot "$ROOTDIR" sh -c "rm -f /etc/localtime && ln -s /usr/share/zoneinfo/$NOSU_TIMEZONE /etc/localtime"

# cleanup
echo "== Cleaning up"
chroot "$ROOTDIR" sh -c "rm -f /etc/resolv.conf && ln -sf /var/run/systemd/resolve/resolv.conf /etc/resolv.conf"
chroot "$ROOTDIR" sh -c "apt autoremove -y && apt clean all"
rm -rf "$ROOTDIR/tmp"/*
rm -rf "$ROOTDIR/var/lib/apt/lists"/*
umount -R "$ROOTDIR"/proc/
umount -R "$ROOTDIR"/sys/
umount -R "$ROOTDIR"/dev/

# pack image
if [ "$NOSU_COMPRESS" = "xz" ]; then
    ARGS="-cpJf"
else
    NOSU_COMPRESS="gz"
    ARGS="-cpzf"
fi
ROOTFS_FILE="nosu-rootfs-$NOSU_VERSION.tar.$NOSU_COMPRESS"

echo "== Packing rootfs into ./image/$ROOTFS_FILE"
tar -C "$ROOTDIR" "$ARGS" "./image/$ROOTFS_FILE" .
