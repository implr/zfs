#!/usr/bin/env bash

######################################################################
# Bake xfstests into the build VM image.
#
# Runs on the build machine (vm0) AFTER ZFS has been built and installed
# (qemu-4-build.sh, invoked WITHOUT --poweroff) and BEFORE qemu-5-setup.sh
# snapshots + clones the image. Everything installed here lands in the
# zpool/openzfs@now snapshot, so the cloned test VM(s) come up with
# xfstests, its deps, and the fsgqa service accounts already present.
#
# Called on the runner as:
#   ssh zfs@vm0 '$HOME/zfs/.github/workflows/scripts/qemu-xfstests-bake-vm.sh' $OS
#
# The script powers the VM off at the end (like qemu-4-build-vm.sh does)
# so the subsequent qemu-5-setup.sh can snapshot a clean, powered-off disk.
######################################################################

set -eu

OS="$1"

# xfstests source. Kept in the user's fork for now; the kernel.org tree is
# unlikely to take the ZFS port, and a home in the OpenZFS org is a "later"
# problem. Pin to the 'zfs' branch which carries the FSTYP=zfs support and
# the exclude.zfs.txt list.
XFSTESTS_REPO="${XFSTESTS_REPO:-https://github.com/implr/xfstests}"
XFSTESTS_BRANCH="${XFSTESTS_BRANCH:-zfs}"

echo "##[group]Install xfstests dependencies"
case "$OS" in
  debian*|ubuntu*)
    sudo apt-get update
    # Build toolchain + xfstests build/runtime deps. gdisk/parted are for
    # carving the test disk in qemu-xfstests-run.sh.
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      git build-essential autoconf automake libtool pkg-config gettext \
      uuid-dev libattr1-dev libacl1-dev libaio-dev libgdbm-dev libssl-dev \
      xfsprogs e2fsprogs attr acl quota gdisk parted
    # Best-effort extras some tests want; don't fail the bake if missing.
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y fio dbench || true
    ;;
  *)
    echo "xfstests bake is only implemented for debian/ubuntu so far" >&2
    exit 1
    ;;
esac
echo "##[endgroup]"

echo "##[group]Create xfstests service users"
# xfstests' common/config insists on these accounts. Idempotent; the odd
# digit-leading name needs --badnames on modern shadow-utils.
sudo groupadd -f fsgqa
for u in fsgqa fsgqa2 123456-fsgqa; do
  if ! id "$u" &>/dev/null; then
    sudo useradd --badnames -g fsgqa -m "$u" 2>/dev/null \
      || sudo useradd -g fsgqa -m "$u" 2>/dev/null || true
  fi
done
echo "##[endgroup]"

echo "##[group]Clone + build xfstests ($XFSTESTS_BRANCH)"
rm -rf "$HOME/xfstests"
git clone --depth 1 -b "$XFSTESTS_BRANCH" "$XFSTESTS_REPO" "$HOME/xfstests"
cd "$HOME/xfstests"
make -j"$(nproc)"
echo "xfstests baked at $HOME/xfstests ($(git rev-parse --short HEAD))"
echo "##[endgroup]"

# Reset cloud-init and power off so the disk can be snapshotted cleanly.
# Mirrors the tail of qemu-4-build-vm.sh.
sudo cloud-init clean --logs
sync && sleep 2 && sudo poweroff &
exit 0
