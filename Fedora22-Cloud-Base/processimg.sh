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
# purpose: This script will download a fedora image and then modify it 
#          to prepare it for the Microsoft Azure infrastructure. It uses 
#          Docker to hopefully guarantee the behavior is consistent across 
#          different machines.
#  author: Dusty Mabe (dusty@dustymabe.com)

set -eux 
mkdir -p /tmp/azureimg/

docker run -i --rm --privileged -v /tmp/azureimg:/tmp/azuremg fedora:22 bash << 'EOF'
set -eux
WORKDIR=/workdir
TMPMNT=/workdir/tmp/mnt

# Vars for the image
XZIMGURL='http://download.fedoraproject.org/pub/fedora/linux/releases/22/Cloud/x86_64/Images/Fedora-Cloud-Base-22-20150521.x86_64.raw.xz'
XZIMG=$(basename $XZIMGURL) # Just the file name
IMG=${XZIMG:0:-3}           # Pull .xz off of the end
VHDIMG=${IMG:0:-4}.vhd

# File location for DO cloud config
export AZURECLOUDCFGFILE='/etc/cloud/cloud.cfg.d/01_azure.cfg'

# File to use as reference for selinux 
export CLOUDINITLOGCFGFILE='/etc/cloud/cloud.cfg.d/05_logging.cfg'

# Create workdir and cd to it
mkdir -p $TMPMNT && cd $WORKDIR

# Get any additional rpms that we need
dnf install -y wget qemu-img

# Get the xz image and decompress it
wget $XZIMGURL && unxz $XZIMG

# Find the starting byte and the total bytes in the 1st partition
# NOTE: normally would be able to use partx/kpartx directly to loopmount
#       the disk image and add the partitions, but inside of docker I found
#       that wasn't working quite right so I resorted to this manual approach.
PAIRS=$(partx --pairs $IMG)
eval `echo "$PAIRS" | head -n 1 | sed 's/ /\n/g'`
STARTBYTES=$((512*START))   # 512 bytes * the number of the start sector
TOTALBYTES=$((512*SECTORS)) # 512 bytes * the number of sectors in the partition

# Discover the next available loopback device
LOOPDEV=$(losetup -f)
LOMAJOR=''

# Make the loopback device if it doesn't exist already
if [ ! -e $LOOPDEV ]; then
    LOMAJOR=${LOOPDEV#/dev/loop} # Get just the number
    mknod -m660 $LOOPDEV b 7 $LOMAJOR
fi

# Loopmount the first partition of the device
losetup -v --offset $STARTBYTES --sizelimit $TOTALBYTES $LOOPDEV $IMG

# Mount it on $TMPMNT
mount $LOOPDEV $TMPMNT

# Get the DO datasource and store in the right place

# Put in place the config 
cat << END > ${TMPMNT}/${AZURECLOUDCFGFILE}
datasource_list: [ Azure ]
END
chcon --reference ${TMPMNT}/${CLOUDINITLOGCFGFILE} ${TMPMNT}/${AZURECLOUDCFGFILE}

# Install the Azure specific agent
dnf install -y --installroot ${TMPMNT} WALinuxAgent

# Install kernel-modules (needed for udf.ko.xz so we can mount the "cdrom"
# azure attaches to the instance).
VR=$(rpm -q kernel-core --qf "%{VERSION}-%{RELEASE}" --root ${TMPMNT})
dnf install -y --installroot ${TMPMNT} kernel-modules-$VR

# Clean up everything
dnf clean all --installroot ${TMPMNT}

# Fstrim to recover space
fstrim -v ${TMPMNT}

# umount and tear down loop device
umount $TMPMNT
losetup -d $LOOPDEV
[ ! -z $LOMAJOR ] && rm -f $LOOPDEV #Only remove if we created it

# convert the raw image to vhd format
qemu-img convert -f raw -O vpc $IMG $VHDIMG

# finally, cp $IMG into /tmp/azureimg/ on the host
cp -a $VHDIMG /tmp/azureimg/ 

EOF
