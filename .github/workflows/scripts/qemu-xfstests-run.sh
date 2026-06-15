#!/usr/bin/env bash

######################################################################
# Run xfstests against the freshly-built ZFS on the test VM.
#
# Self-dispatching, like qemu-6-tests.sh:
#   - called with no args  -> runner side: ssh into vm1 and stream output
#   - called with 'guest'  -> runs inside the test VM (vm1)
#
# The ZFS/xfstests configuration here mirrors the proven local nix runner:
#   FSTYP=zfs, TEST_DEV=testpool/testfs (persistent), scratch pool built by
#   xfstests from SCRATCH_DEV_POOL.
######################################################################

set -eu

############################
# Runner side (no args)
############################
if [ -z "${1:-}" ]; then
  source /var/tmp/env.txt
  SCRIPT='$HOME/zfs/.github/workflows/scripts/qemu-xfstests-run.sh'
  # Pass the user-chosen ./check arguments through to the guest.
  ssh zfs@vm1 "OS='$OS' XFSTESTS_OPTIONS='${XFSTESTS_OPTIONS:-}' $SCRIPT guest" \
    2>&1 | stdbuf -oL tee /var/tmp/xfstests-run.log
  exit 0
fi

############################
# Guest side (arg 'guest')
############################
OS="${OS:?}"
OPTS="${XFSTESTS_OPTIONS:--g quick}"
export PATH="$PATH:/sbin:/usr/sbin:/usr/local/sbin:/usr/local/bin"

# Load the ZFS module we built + installed on the (now-cloned) image.
sudo modprobe zfs

# The CI environment is heavily virtualized and oversubscribed; relax the
# RCU stall timeout so we don't get spurious soft-lockup splats (mirrors ZTS).
rcu="/sys/module/rcupdate/parameters/rcu_cpu_stall_timeout"
test -f "$rcu" && echo 120 | sudo tee "$rcu" >/dev/null || true

# Carve the 64 GiB tests disk (attached by qemu-5-setup.sh as the 2nd virtio
# disk) into a TEST_DEV partition + three SCRATCH pool members. The local nix
# runner used separate disks; one partitioned disk is the least-invasive way
# to get the same layout without touching qemu-5-setup.sh.
DEV=/dev/vdb
sudo wipefs -a "$DEV" || true
sudo sgdisk -Z "$DEV"
sudo sgdisk -n1:0:+20G -n2:0:+14G -n3:0:+14G -n4:0:0 "$DEV"
sudo partprobe "$DEV"
sleep 2

# Persistent test pool/dataset. Properties match the nix runner's local.config
# build (acltype=posix + xattr=sa are required for several generic/ tests).
sudo zpool create -f \
  -O mountpoint=legacy -O acltype=posix -O xattr=sa \
  -O compression=off -O relatime=off \
  testpool "${DEV}1"
sudo zfs create -o mountpoint=legacy -o recordsize=64K testpool/testfs

sudo mkdir -p /mnt/test /mnt/scratch
sudo mount -t zfs testpool/testfs /mnt/test

cd "$HOME/xfstests"
cat > local.config <<EOF
export FSTYP=zfs
export TEST_DEV=testpool/testfs
export TEST_DIR=/mnt/test
export SCRATCH_MNT=/mnt/scratch
export SCRATCH_ZPOOL_NAME=scratchpool
export SCRATCH_DEV_POOL="${DEV}2 ${DEV}3 ${DEV}4"
EOF

# Apply the ZFS exclude list only for group runs; when a caller names tests
# explicitly they want exactly those (e.g. debugging an excluded failure).
EXCLUDE=""
case "$OPTS" in
  *-g*) EXCLUDE="-E exclude.zfs.txt" ;;
esac

sudo dmesg -c > /var/tmp/dmesg-prerun.txt || true

RV=0
# shellcheck disable=SC2086 # word-splitting of OPTS/EXCLUDE is intentional
sudo HOST_OPTIONS="$PWD/local.config" ./check $EXCLUDE $OPTS || RV=$?
echo "$RV" | sudo tee /var/tmp/tests-exitcode.txt >/dev/null

sudo dmesg > /var/tmp/dmesg-postrun.txt || true
sync
exit 0
