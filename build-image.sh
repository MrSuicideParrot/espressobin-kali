#!/bin/bash
set -e

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

if [[ $# -eq 0 ]] ; then
    echo "Please pass version number, e.g. $0 2.0"
    exit 0
fi

basedir=`pwd`/espressobin-$1

# Custom hostname variable
hostname=${2:-kali}
# Custom image file name variable - MUST NOT include .img at the end.
imagename=${3:-kali-linux-$1-espressobin}
# Size of image in megabytes (Default is 7000=7GB)
size=3000
# Suite to use.
# Valid options are:
# kali-rolling, kali-dev, kali-bleeding-edge, kali-dev-only, kali-experimental, kali-last-snapshot
# A release is done against kali-last-snapshot, but if you're building your own, you'll probably want to build
# kali-rolling.
suite=kali-rolling

# Generate a random machine name to be used.
machine=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)

# Package installations for various sections.
# This is the section to edit if you would like to add more packages.
# See http://www.kali.org/news/kali-linux-metapackages/ for meta packages you
# can use. You can also install packages, using just the package name, but keep
# in mind that not all packages work on ARM! If you specify one of those, the
# script will throw an error, but will still continue on, and create an unusable
# image, keep that in mind.

arm="abootimg cgpt fake-hwclock ntpdate u-boot-tools vboot-utils vboot-kernel-utils"
base="apt-transport-https apt-utils console-setup e2fsprogs ifupdown initramfs-tools iw kali-defaults man-db mlocate netcat-traditional net-tools parted psmisc rfkill screen snmpd snmp sudo tftp tmux unrar usbutils vim wget zerofree gnupg2 software-properties-common"
tools="tshark bridge-utils"
services="openssh-server"
extras="wpasupplicant"

packages="${arm} ${base} ${services} ${extras}"

architecture="arm64"
# If you have your own preferred mirrors, set them here.
# You may want to leave security.kali.org alone, but if you trust your local
# mirror, feel free to change this as well.
# After generating the rootfs, we set the sources.list to the default settings.
mirror=http.kali.org

# Set this to use an http proxy, like apt-cacher-ng, and uncomment further down
# to unset it.
#export http_proxy="http://localhost:3142/"

mkdir -p "${basedir}"
cd "${basedir}"

# create the rootfs - not much to modify here, except maybe throw in some more packages if you want.
debootstrap --foreign --keyring=/usr/share/keyrings/kali-archive-keyring.gpg --include=kali-archive-keyring --arch ${architecture} ${suite} kali-${architecture} http://${mirror}/kali

cp /usr/bin/qemu-arm-static kali-${architecture}/usr/bin/

LANG=C systemd-nspawn -M ${machine} -D kali-${architecture} /debootstrap/debootstrap --second-stage

mkdir -p kali-${architecture}/etc/apt/
cat << EOF > kali-${architecture}/etc/apt/sources.list
deb http://${mirror}/kali ${suite} main contrib non-free
EOF

echo "${hostname}" > kali-${architecture}/etc/hostname

cat << EOF > kali-${architecture}/etc/hosts
127.0.0.1       ${hostname}   localhost
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

mkdir -p kali-${architecture}/etc/modprobe.d/
cat << EOF > kali-${architecture}/etc/modprobe.d/ipv6.conf
# Don't load ipv6 by default
alias net-pf-10 off
#alias ipv6 off
EOF

mkdir -p kali-${architecture}/etc/network/
cat << EOF > kali-${architecture}/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet manual

allow-hotplug lan0
iface lan0 inet manual

allow-hotplug lan1
iface lan1 inet manual

allow-hotplug wan
iface wan inet dhcp

EOF

cat << EOF > kali-${architecture}/etc/resolv.conf
nameserver 8.8.8.8
EOF

export MALLOC_CHECK_=0 # workaround for LP: #520465
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

#mount -t proc proc kali-${architecture}/proc
#mount -o bind /dev/ kali-${architecture}/dev/
#mount -o bind /dev/pts kali-${architecture}/dev/pts

cat << EOF > kali-${architecture}/debconf.set
console-common console-data/keymap/policy select Select keymap from full list
console-common console-data/keymap/full select en-latin1-nodeadkeys
EOF

mkdir -p kali-${architecture}/usr/lib/systemd/system/
cat << 'EOF' > kali-${architecture}/usr/lib/systemd/system/regenerate_ssh_host_keys.service
[Unit]
Description=Regenerate SSH host keys
Before=ssh.service
[Service]
Type=oneshot
ExecStartPre=-/bin/dd if=/dev/hwrng of=/dev/urandom count=1 bs=4096
ExecStartPre=-/bin/sh -c "/bin/rm -f -v /etc/ssh/ssh_host_*_key*"
ExecStart=/usr/bin/ssh-keygen -A -v
ExecStartPost=/bin/sh -c "for i in /etc/ssh/ssh_host_*_key*; do actualsize=$(wc -c <\"$i\") ;if [ $actualsize -eq 0 ]; then echo size is 0 bytes ; exit 1 ; fi ; done ; /bin/systemctl disable regenerate_ssh_host_keys"
[Install]
WantedBy=multi-user.target
EOF
chmod 644 kali-${architecture}/usr/lib/systemd/system/regenerate_ssh_host_keys.service

cat << EOF > kali-${architecture}/usr/lib/systemd/system/smi-hack.service
[Unit]
Description=shared-mime-info update hack
Before=regenerate_ssh_host_keys.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c "dpkg-reconfigure shared-mime-info"
ExecStartPost=/bin/systemctl disable smi-hack
[Install]
WantedBy=multi-user.target
EOF
chmod 644 kali-${architecture}/usr/lib/systemd/system/smi-hack.service

mkdir -p kali-${architecture}/etc/initramfs/post-update.d
cat << EOF > kali-${architecture}/etc/initramfs/post-update.d/99-uInitrd
#!/bin/sh
set -e

echo "update-initramfs: Converting to /boot/uInitrd" >&2
temp="/boot/uInitrd-\$1"
mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd -d \$2 \$temp 1> /dev/null
ln -sf  uInitrd-\$1 /boot/uInitrd > /dev/null 2>&1
EOF
chmod 755 kali-${architecture}/etc/initramfs/post-update.d/99-uInitrd


cat << EOF > kali-${architecture}/third-stage
#!/bin/bash
set -e
dpkg-divert --add --local --divert /usr/sbin/invoke-rc.d.chroot --rename /usr/sbin/invoke-rc.d
cp /bin/true /usr/sbin/invoke-rc.d
echo -e "#!/bin/sh\nexit 101" > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d
apt-get update
apt-get --yes --allow-change-held-packages install locales-all
debconf-set-selections /debconf.set
rm -f /debconf.set
apt-get update
apt-get -y install git-core binutils ca-certificates initramfs-tools u-boot-tools
apt-get -y install locales console-common less nano git
echo "root:toor" | chpasswd
rm -f /etc/udev/rules.d/70-persistent-net.rules
export DEBIAN_FRONTEND=noninteractive
# This looks weird, but we do it twice because every so often, there's a failure to download from the mirror
# So to workaround it, we attempt to install them twice.
apt-get --yes --allow-change-held-packages install ${packages} || apt-get --yes --fix-broken install
apt-get --yes --allow-change-held-packages install ${packages} || apt-get --yes --fix-broken install
apt-get --yes --allow-change-held-packages install ${desktop} ${tools} || apt-get --yes --fix-broken install
apt-get --yes --allow-change-held-packages install ${desktop} ${tools} || apt-get --yes --fix-broken install
apt-get --yes --allow-change-held-packages dist-upgrade
apt-get --yes --allow-change-held-packages autoremove

# Install the kernel image
echo "deb http://apt.armbian.com buster main buster-utils" > /etc/apt/sources.list.d/armbian.list
wget -O - https://apt.armbian.com/armbian.key | apt-key add -
apt-get update
apt-get install --yes --allow-change-held-packages linux-base linux-dtb-next-mvebu64 linux-image-next-mvebu64 linux-headers-next-mvebu64  linux-u-boot-espressobin-next armbian-firmware

# Because copying in authorized_keys is hard for people to do, let's make the
# image insecure and enable root login with a password.
echo "Making the image insecure"
sed -i -e 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
# Regenerated the shared-mime-info database on the first boot
# since it fails to do so properly in a chroot.
systemctl enable smi-hack
# Generate SSH host keys on first run
systemctl enable regenerate_ssh_host_keys
systemctl enable ssh
# Copy bashrc
cp  /etc/skel/.bashrc /root/.bashrc
rm -f /usr/sbin/policy-rc.d
rm -f /usr/sbin/invoke-rc.d
dpkg-divert --remove --rename /usr/sbin/invoke-rc.d
rm -f /third-stage
EOF

chmod 755 kali-${architecture}/third-stage
LANG=C systemd-nspawn -M ${machine} -D kali-${architecture} /third-stage

cat << EOF > kali-${architecture}/cleanup
#!/bin/bash
rm -rf /root/.bash_history
apt-get update
apt-get clean
rm -f /0
rm -f /hs_err*
rm -f cleanup
rm -f /usr/bin/qemu*
EOF

chmod 755 kali-${architecture}/cleanup
LANG=C systemd-nspawn -M ${machine} -D kali-${architecture} /cleanup

# Enable serial console on ttyMV0
echo 'T1:12345:respawn:/sbin/agetty 115200 ttyMV0 vt100' >> "${basedir}"/kali-${architecture}/etc/inittab

cat << EOF >> "${basedir}"/kali-${architecture}/etc/udev/links.conf
M   ttyMV0 c 5 1
EOF

cat << EOF >> "${basedir}"/kali-${architecture}/etc/securetty
ttyMV0
EOF

cat << EOF > "${basedir}"/kali-${architecture}/etc/apt/sources.list
deb http://http.kali.org/kali kali-rolling main non-free contrib
deb-src http://http.kali.org/kali kali-rolling main non-free contrib
EOF

# Uncomment this if you use apt-cacher-ng or else git clones will fail.
#unset http_proxy


cd "${basedir}"

# Create boot.txt file
cat << EOF > "${basedir}"/kali-${architecture}/boot/boot.txt
# DO NOT EDIT THIS FILE
#
# Please edit /boot/armbianEnv.txt to set supported parameters
#

# default values
setenv rootdev "/dev/mmcblk0p1"
setenv verbosity "1"
setenv rootfstype "ext4"

# additional values
setenv ethaddr "F0:AD:4E:03:64:7F"

load \${boot_interface} \${devnum}:1 \${scriptaddr} \${prefix}armbianEnv.txt
env import -t \${scriptaddr} \${filesize}

setenv bootargs "\$console root=\${rootdev} rootfstype=\${rootfstype} rootwait loglevel=\${verbosity} usb-storage.quirks=\${usbstoragequirks} mtdparts=spi0.0:1536k(uboot),64k(uboot-environment),-(reserved) \${extraargs}"

setenv fdt_name_a dtb/marvell/armada-3720-community.dtb
setenv fdt_name_b dtb/marvell/armada-3720-espressobin.dtb

ext4load \$boot_interface 0:1 \$kernel_addr \${prefix}\$image_name
ext4load \$boot_interface 0:1 \$initrd_addr \${prefix}\$initrd_image
ext4load \$boot_interface 0:1 \$fdt_addr \${prefix}\$fdt_name_a
ext4load \$boot_interface 0:1 \$fdt_addr \${prefix}\$fdt_name_b

booti \$kernel_addr \$initrd_addr \$fdt_addr
EOF

# Create u-boot boot script image
mkimage -A arm -T script -C none -d "${basedir}"/kali-${architecture}/boot/boot.txt "${basedir}"/kali-${architecture}/boot/boot.scr


sed -i -e 's/^#PermitRootLogin.*/PermitRootLogin yes/' "${basedir}"/kali-${architecture}/etc/ssh/sshd_config

# Create the disk and partition it
echo "Creating image file ${imagename}.img"
dd if=/dev/zero of="${basedir}"/${imagename}.img bs=1M count=${size}
parted ${imagename}.img --script -- mklabel msdos
parted ${imagename}.img --script -- mkpart primary ext4 2048s 100%
parted ${imagename}.img --script -- set 1 boot on

# Set the partition variables
loopdevice=`losetup -f --show "${basedir}"/${imagename}.img`
device=`kpartx -va ${loopdevice} | sed 's/.*\(loop[0-9]\+\)p.*/\1/g' | head -1`
sleep 5
device="/dev/mapper/${device}"
rootp=${device}p1

# Create file systems
mkfs.ext4 -O ^64bit -O ^flex_bg -O ^metadata_csum ${rootp}

UUID="UUID=`blkid -o value ${rootp}| head -n 1`"

#Root partition definition
cat << EOF > "${basedir}"/kali-${architecture}/boot/armbianEnv.txt
verbosity=1
emmc_fix=off
eth1addr=02:31:5D:99:70:15
eth2addr=00:50:43:84:25:2f
eth3addr=00:50:43:0d:19:18
rootdev=${UUID}
rootfstype=ext4
usbstoragequirks=0x2537:0x1066:u,0x2537:0x1068:u
EOF

cat << EOF > "${basedir}"/kali-${architecture}/etc/fstab
/dev/${UUID} / auto errors=remount-ro 0 1
EOF

# Create the dirs for the partitions and mount them
mkdir -p "${basedir}"/root
mount ${rootp} "${basedir}"/root

# We do this down here to get rid of the build system's resolv.conf after running through the build.
cat << EOF > kali-${architecture}/etc/resolv.conf
nameserver 8.8.8.8
EOF

echo "Rsyncing rootfs into image file"
rsync -HPavz -q "${basedir}"/kali-${architecture}/ "${basedir}"/root/

# Unmount partitions
sync
umount ${rootp}
kpartx -dv ${loopdevice}
losetup -d ${loopdevice}

# Don't pixz on 32bit, there isn't enough memory to compress the images.
MACHINE_TYPE=`uname -m`
if [ ${MACHINE_TYPE} == 'x86_64' ]; then
echo "Compressing ${imagename}.img"
pixz "${basedir}"/${imagename}.img "${basedir}"/../${imagename}.img.xz
rm "${basedir}"/${imagename}.img
fi

# Clean up all the temporary build stuff and remove the directories.
# Comment this out to keep things around if you want to see what may have gone
# wrong.
echo "Removing temporary build files"
rm -rf "${basedir}"
