// SPDX-License-Identifier: CDDL-1.0
/*
 * CDDL HEADER START
 *
 * The contents of this file are subject to the terms of the
 * Common Development and Distribution License (the "License").
 * You may not use this file except in compliance with the License.
 *
 * You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
 * or https://opensource.org/licenses/CDDL-1.0.
 * See the License for the specific language governing permissions
 * and limitations under the License.
 *
 * When distributing Covered Code, include this CDDL HEADER in each
 * file and include the License file at usr/src/OPENSOLARIS.LICENSE.
 * If applicable, add the following below this CDDL HEADER, with the
 * fields enclosed by brackets "[]" replaced with your own identifying
 * information: Portions Copyright [yyyy] [name of copyright owner]
 *
 * CDDL HEADER END
 */

/*
 * Copyright (c) 2026 Bartosz Stebel
 */

/*
 * Verify that open_by_handle_at() succeeds on a file that has been unlinked
 * while a file descriptor on it is still open. The Linux VFS contract is
 * that such an inode remains valid and openable by handle until the last
 * reference is dropped. ext4/xfs/btrfs honor this; ZFS historically
 * returned ESTALE through zfs_vget() because z_unlinked was checked
 * independently of whether the in-memory inode was still live.
 *
 * Usage: fh_unlinked_open <path>
 * Creates <path>, writes a marker, gets its handle, unlinks <path>
 * while holding the fd open, then opens by handle and reads the marker
 * back. Exits 0 on success, non-0 with diagnostic on failure.
 */

#ifndef _GNU_SOURCE
#define	_GNU_SOURCE
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/types.h>

static const char marker[] = "fh_unlinked_open marker";

int
main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s <path>\n", argv[0]);
		return (2);
	}
	const char *path = argv[1];

	/* Create the file and write a marker we can verify after re-open. */
	int fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0644);
	if (fd < 0) {
		fprintf(stderr, "open(%s): %s\n", path, strerror(errno));
		return (1);
	}
	if (write(fd, marker, sizeof (marker)) != sizeof (marker)) {
		fprintf(stderr, "write(%s): %s\n", path, strerror(errno));
		return (1);
	}

	/* Encode a file handle for the path while the fd is open. */
	struct {
		struct file_handle fh;
		unsigned char buf[128];
	} h = { .fh.handle_bytes = sizeof (h.buf) };
	int mnt_id;
	if (name_to_handle_at(AT_FDCWD, path, &h.fh, &mnt_id, 0) < 0) {
		fprintf(stderr, "name_to_handle_at(%s): %s\n",
		    path, strerror(errno));
		return (1);
	}

	/* Unlink while the fd is still open: the inode must stay valid. */
	if (unlink(path) < 0) {
		fprintf(stderr, "unlink(%s): %s\n", path, strerror(errno));
		return (1);
	}

	/*
	 * The pinned fd keeps the inode alive, so drop_caches can't evict it;
	 * call it anyway so this test exercises the same flow as nfsd, which
	 * may drop dentry caches between encode and decode.
	 */
	int dc = open("/proc/sys/vm/drop_caches", O_WRONLY);
	if (dc >= 0) {
		(void) write(dc, "2\n", 2);
		close(dc);
	}

	/* The actual assertion: open by handle must succeed. */
	int fd2 = open_by_handle_at(AT_FDCWD, &h.fh, O_RDONLY);
	if (fd2 < 0) {
		fprintf(stderr,
		    "open_by_handle_at on unlinked-but-open file: %s "
		    "(expected success)\n", strerror(errno));
		return (1);
	}

	/* Verify it really is the same file by reading the marker back. */
	char buf[sizeof (marker)] = { 0 };
	ssize_t n = pread(fd2, buf, sizeof (buf), 0);
	if (n != sizeof (marker) || memcmp(buf, marker, sizeof (marker)) != 0) {
		fprintf(stderr, "marker mismatch after open_by_handle_at: "
		    "read %zd bytes\n", n);
		return (1);
	}

	close(fd2);
	close(fd);
	return (0);
}
