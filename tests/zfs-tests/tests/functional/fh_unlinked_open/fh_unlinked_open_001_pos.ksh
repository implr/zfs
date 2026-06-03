#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or https://opensource.org/licenses/CDDL-1.0.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#

#
# Copyright (c) 2026 Bartosz Stebel
#

. $STF_SUITE/include/libtest.shlib

#
# DESCRIPTION:
# open_by_handle_at() must succeed on a file that has been unlinked while
# a file descriptor on it is still open. The Linux VFS contract is that
# such an inode remains valid as long as a reference is held; ext4/xfs/btrfs
# honor this. ZFS previously returned ESTALE here because zfs_vget()
# rejected any znode with z_unlinked set, even when the in-memory inode was
# still live and igrab-able. Regression test for that fix.
#
# STRATEGY:
# 1. Create a file under $TESTDIR and write a marker into it.
# 2. Encode a file handle for the path while the fd is open.
# 3. Unlink the file while keeping the fd open.
# 4. Call open_by_handle_at(): expect success.
# 5. Read the marker back and verify it matches.
#

verify_runnable "both"

log_assert "open_by_handle_at succeeds on an unlinked-but-open file"

log_must fh_unlinked_open $TESTDIR/fh_unlinked_open.tmp

log_pass "open_by_handle_at on unlinked-but-open file works"
