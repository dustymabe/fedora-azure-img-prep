#!/bin/bash
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free  Software Foundation; either version 2 of the License, or
# (at your option)  any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA 02110-1301 USA.
#
#
# purpose: This script will download a fedora 26 cloud image and then modify
#          it to prepare it for the Microsoft Azure infrastructure. It uses
#          Docker to hopefully guarantee the behavior is consistent across
#          different machines.

set -eux

AZUREIMGLOCATION="/tmp/azureimg"

docker run --runtime=runc -i --rm --privileged -e AZUREIMGLOCATION=${AZUREIMGLOCATION} -v ${AZUREIMGLOCATION}:${AZUREIMGLOCATION} fedora:26 bash << 'EOF'
set -eux

IMGMNT="/mnt/fedora"
IMGNAME="Fedora-Cloud-Base-26-1.5.x86_64"
VHDIMG="${IMGNAME}.vhd"
IMG="${IMGNAME}.raw"
XZIMG="${IMG}.xz"
XZIMGURL="https://download.fedoraproject.org/pub/fedora/linux/releases/26/CloudImages/x86_64/images/${XZIMG}"
CLOUDINITURL="https://kojipkgs.fedoraproject.org//packages/cloud-init/0.7.9/9.fc26/noarch/cloud-init-0.7.9-9.fc26.noarch.rpm"
KERNELMODULESURL="https://dl.fedoraproject.org/pub/fedora/linux/releases/26/Everything/x86_64/os/Packages/k/kernel-modules-4.11.8-300.fc26.x86_64.rpm"
KERNELFIRMWAREURL="https://dl.fedoraproject.org/pub/fedora/linux/releases/26/Everything/x86_64/os/Packages/l/linux-firmware-20170622-75.gita3a26af2.fc26.noarch.rpm"

mkdir -p ${IMGMNT}

# Get the tools we need
dnf install -y wget qemu-img xz kpartx

# Get the xz image and decompress it
wget $XZIMGURL && unxz $XZIMG

# Download the specific cloud-init version
wget ${CLOUDINITURL}

# Create a loop device from the image
LOOPDEV=$(kpartx -a -v ${IMG} | tr -s ' ' | cut -d ' ' -f 3)

# Mount the loop device
mount /dev/mapper/${LOOPDEV} ${IMGMNT}

# Install specific cloud-init version, and update kernel and firmware to
# support UDF CD-ROM for cloud-init
dnf install -y --installroot /mnt/fedora/ ${CLOUDINITURL} ${KERNELMODULESURL} ${KERNELFIRMWAREURL}

# Set SELINUX to permissive
# This is needed since this bug https://bugzilla.redhat.com/show_bug.cgi?id=1489166
# is still not solved.
sed -i s/SELINUX=enforcing/SELINUX=permissive/ "${IMGMNT}/etc/selinux/config"

# Clean up everything
dnf clean all --installroot ${IMGMNT}

# Unmount the loop device
umount ${IMGMNT}

# Destroy the loop device
kpartx -d -v ${IMG}

# Convert the raw image to vhd format
qemu-img convert -f raw -o subformat=fixed,force_size -O vpc $IMG $VHDIMG

# Copy VHD file created to the host
echo "AZUREIMGLOCATION=${AZUREIMGLOCATION}"
cp -a ${VHDIMG} ${AZUREIMGLOCATION}

EOF
