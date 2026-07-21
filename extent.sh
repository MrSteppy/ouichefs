#!/bin/sh
#
# Simple read/write tests for ouichefs.
# Expects ouichefs already mounted at $MNT (default: /mnt/ouichefs).
#
#   mkdir -p /mnt/ouichefs
#   dd if=/dev/zero of=test.img bs=1M count=50
#   ./mkfs/mkfs.ouichefs test.img
#   mount -t ouichefs -o loop test.img /mnt/ouichefs
#   ./extent.sh
#

MNT=${MNT:-/mnt/ouichefs}
valid=1

if [ ! -d "$MNT" ]; then
	echo "mount point $MNT does not exist!"
	exit 1
fi

############################################
# READ
############################################

echo "=== READ: within one block ==="
printf 'hello' > "$MNT/r1"
got=$(cat "$MNT/r1")
if [ "$got" != "hello" ]; then
	echo "expected hello, got $got"
	valid=0
fi
rm -f "$MNT/r1"


echo "=== READ: across two blocks ==="
# block size is 4096; write past that so data lives in 2 blocks
dd if=/dev/zero of="$MNT/r2" bs=4100 count=1 2>/dev/null
# marker right on the block boundary (2 bytes in block0, 2 in block1)
printf 'AABB' | dd of="$MNT/r2" bs=1 seek=4094 conv=notrunc 2>/dev/null
got=$(dd if="$MNT/r2" bs=1 skip=4094 count=4 2>/dev/null)
if [ "$got" != "AABB" ]; then
	echo "cross-block read failed, got '$got'"
	valid=0
fi
rm -f "$MNT/r2"


echo "=== READ: hole must not return the superblock ==="
# only write in the 2nd block → 1st block stays unallocated.
# a buggy read of that hole would return the superblock ("WICH").
dd if=/dev/zero of="$MNT/r3" bs=1 seek=4096 count=10 2>/dev/null
if dd if="$MNT/r3" of=/tmp/ouiche_hole bs=1 count=4 2>/dev/null; then
	if grep -q WICH /tmp/ouiche_hole; then
		echo "read returned superblock magic!"
		valid=0
	else
		echo "reading a hole should fail"
		valid=0
	fi
fi
rm -f "$MNT/r3" /tmp/ouiche_hole


echo "=== READ: beyond end of file ==="
printf 'abcdef' > "$MNT/r4"
# ask for way more than the file has; should only get 6 bytes
got=$(dd if="$MNT/r4" bs=1 count=100 2>/dev/null)
if [ "$got" != "abcdef" ]; then
	echo "read past EOF failed, got '$got'"
	valid=0
fi
rm -f "$MNT/r4"


############################################
# WRITE
############################################

echo "=== WRITE: regular ==="
printf 'regular' > "$MNT/w1"
got=$(cat "$MNT/w1")
if [ "$got" != "regular" ]; then
	echo "regular write failed, got $got"
	valid=0
fi
rm -f "$MNT/w1"


echo "=== WRITE: truncate then rewrite longer ==="
printf 'AAAAAAAAAA' > "$MNT/w2"
printf 'BB' > "$MNT/w2"
got=$(cat "$MNT/w2")
sz=$(stat -c '%s' "$MNT/w2")
if [ "$got" != "BB" ] || [ "$sz" -ne 2 ]; then
	echo "truncate rewrite failed (got='$got' size=$sz)"
	valid=0
fi
printf 'CCCCCCCCCCCC' > "$MNT/w2"
got=$(cat "$MNT/w2")
if [ "$got" != "CCCCCCCCCCCC" ]; then
	echo "longer rewrite failed, got $got"
	valid=0
fi
rm -f "$MNT/w2"


echo "=== WRITE: append ==="
printf 'first' > "$MNT/w3"
printf 'SECOND' >> "$MNT/w3"
got=$(cat "$MNT/w3")
if [ "$got" != "firstSECOND" ]; then
	echo "append failed, got $got"
	valid=0
fi
rm -f "$MNT/w3"


echo "=== WRITE: across two blocks ==="
dd if=/dev/zero of="$MNT/w4" bs=5000 count=1 2>/dev/null
sz=$(stat -c '%s' "$MNT/w4")
if [ "$sz" -ne 5000 ]; then
	echo "expected size 5000, got $sz"
	valid=0
fi
rm -f "$MNT/w4"


echo "=== WRITE: past EOF updates size ==="
printf 'xxxx' > "$MNT/w5"
dd if=/dev/zero of="$MNT/w5" bs=1 seek=100 count=10 conv=notrunc 2>/dev/null
sz=$(stat -c '%s' "$MNT/w5")
if [ "$sz" -ne 110 ]; then
	echo "expected size 110 after write past EOF, got $sz"
	valid=0
fi
rm -f "$MNT/w5"


echo "=== WRITE: over OUICHEFS_MAX_FILESIZE (2 MiB) ==="
dd if=/dev/zero of="$MNT/w6" bs=4096 count=1024 2>/dev/null
sz=$(stat -c '%s' "$MNT/w6")
if [ "$sz" -ne 2097152 ]; then
	echo "could not create 2MiB file, size=$sz"
	valid=0
else
	if dd if=/dev/zero of="$MNT/w6" bs=1 seek=4194304 count=1 conv=notrunc 2>/dev/null; then
		echo "write past max filesize should have failed"
		valid=0
	fi
fi
rm -f "$MNT/w6"

echo "=== WRITE: exactly OUICHEFS_MAX_FILESIZE (2 MiB) ==="
dd if=/dev/zero of="$MNT/w7" bs=4096 count=512 2>/dev/null
sz=$(stat -c '%s' "$MNT/w7")
if [ "$sz" -ne 2097152 ]; then
	echo "could not create 2MiB file, size=$sz"
	valid=0
fi
rm -f "$MNT/w7"



############################################
# MIXED
############################################

echo "=== MIXED: write, read, rewrite, read ==="
printf 'version-one' > "$MNT/m1"
got=$(cat "$MNT/m1")
if [ "$got" != "version-one" ]; then
	echo "first write/read failed, got $got"
	valid=0
fi

printf 'version-two' > "$MNT/m1"
got=$(cat "$MNT/m1")
if [ "$got" != "version-two" ]; then
	echo "rewrite/read failed, got $got"
	valid=0
fi
rm -f "$MNT/m1"


############################################
# IOCTL
############################################

echo "=== IOCTL: GET_EXTENTS ==="

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
major=$(grep ouichefs /proc/devices | awk '{print $1}')
if [ -z "$major" ]; then
	echo "no major number for ouichefs in /proc/devices!"
	valid=0
else
	device=/dev/ouichefs_ioctl
	rm -f "$device"
	if ! mknod "$device" c "$major" 0; then
		echo "could not create $device"
		valid=0
	else
		# file spanning a few blocks → at least one extent
		dd if=/dev/zero of="$MNT/ioctl_file" bs=4096 count=4 2>/dev/null

		printf '%s\n' '
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include "extent_ioctl.h"

int main(int argc, char **argv)
{
	int ctl, fd;

	fd = open(argv[1], O_RDONLY);
	if (fd < 0) {
		perror("open file");
		return 1;
	}

	ctl = open(argv[2], O_RDWR);
	if (ctl < 0) {
		perror("open ctl");
		return 1;
	}

	/* kernel uses copy_from_user → pass &fd */
	if (ioctl(ctl, OUICHEFS_IOC_GET_EXTENTS, &fd) < 0) {
		perror("ioctl");
		return 1;
	}

	close(ctl);
	close(fd);
	return 0;
}
' > /tmp/ouiche_ioctl_test.c

		# userspace needs the ioctl macros; pull header from this dir
		cp "$SCRIPT_DIR/extent_ioctl.h" /tmp/extent_ioctl.h
		# ensure _IOW is available if the header does not include it
		if ! grep -q 'linux/ioctl.h\|sys/ioctl.h' /tmp/extent_ioctl.h; then
			printf '%s\n' '#include <sys/ioctl.h>' | cat - /tmp/extent_ioctl.h > /tmp/extent_ioctl.h.new
			mv /tmp/extent_ioctl.h.new /tmp/extent_ioctl.h
		fi

		dmesg -C 2>/dev/null || true

		if ! gcc -I/tmp -o /tmp/ouiche_ioctl_test /tmp/ouiche_ioctl_test.c; then
			echo "can't compile ioctl test"
			valid=0
		elif ! /tmp/ouiche_ioctl_test "$MNT/ioctl_file" "$device"; then
			echo "ioctl test program failed"
			valid=0
		elif ! dmesg | grep -q 'extents for inode'; then
			echo "missing 'extents for inode' line in dmesg"
			valid=0
		elif ! dmesg | grep -qE '\[0\] start=[0-9]+ count=[0-9]+'; then
			echo "missing extent detail line in dmesg"
			valid=0
		else
			# show the pseudo-output style lines
			dmesg | grep -E 'extents for inode|start='
		fi

		rm -f "$MNT/ioctl_file" "$device" \
			/tmp/ouiche_ioctl_test /tmp/ouiche_ioctl_test.c \
			/tmp/extent_ioctl.h /tmp/extent_ioctl.h.new
	fi
fi


############################################

if [ "$valid" -eq 0 ]; then
	echo "SOME TESTS FAILED"
	exit 1
fi

echo "ALL TESTS PASSED"
