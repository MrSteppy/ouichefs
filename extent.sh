#!/bin/bash
# shellcheck disable=SC2317

# mount point of a ouichefs partition
MNT=${MNT:-/mnt/ouichefs}
# block size in bytes
BLOCK_SIZE=4096

# How to setup this test:
#
# * Create ouichefs partition:
#   - dd if=/dev/zero of=ouichefs.img bs=1M count=50
#   - ./mkfs/mkfs.ouichefs ouichefs.img
# * Mount partition at /mnt/ouichefs
#   - mkdir /mnt/ouichefs
#   - mount ouichefs.img /mnt/ouichefs
# * Run this test script
#   - ./extent.sh

# ensure that mount point has expected file system
if ! findmnt -t ouichefs "$MNT" >/dev/null; then
  echo "Partition mounted at $MNT is not of type ouichefs"
  exit 1
fi

# list of files to be cleaned up after each test
declare -a _cleanup_files

main() {
  local test_functions
  mapfile -t test_functions < <(declare -F | awk '{print $3}' | grep '^test_')

  local -i passed=0
  local -i failed=0

  for func in "${test_functions[@]}"; do
    # Reset the global cleanup array for each test case
    _cleanup_files=()
    echo "=== Running $func ==="
    if $func; then
      echo "=== OK ==="
      passed+=1
    else
      echo "=== $func FAILED ==="
      failed+=1
    fi
    _do_cleanup
  done

  echo "-------------------------------"
  if [[ failed -gt 0 ]]; then
    echo "THERE ARE TEST FAILURES!" >&2
  else
    echo "All test-cases passed :)"
  fi

  echo "Ran $((passed + failed)) test-cases ($passed passed, $failed failed)."
}

# registers a file for deletion on function return
cleanup_later() {
  _cleanup_files+=("$@")
}

_do_cleanup() {
  [[ ${#_cleanup_files[@]} -gt 0 ]] && rm -rf "${_cleanup_files[@]}"
}

###################
# BEGIN TESTCASES #
###################

# Verifies that reading data within a single filesystem block returns the correct content.
test_read_within_one_block() {
  local file="$MNT/hello"
  cleanup_later "$file"
  local expected="Hello world!"
  prf "$expected" >"$file"
  local actual
  actual="$(cat "$file")"
  if [[ "$actual" != "$expected" ]]; then
    pr_err "Expected '$expected' but got '$actual'"
    return 1
  fi
}

# Verifies that reading data that spans across two filesystem blocks returns the correct content.
test_read_across_two_blocks() {
  local file="$MNT/file"
  cleanup_later "$file"
  local expected="AABB"
  local -i size=${#expected}
  dd if=/dev/zero of="$file" bs=$((BLOCK_SIZE + size)) count=1 2>/dev/null
  # write data exactly on the edge between the two blocks
  local -i offset=$((BLOCK_SIZE - 2))
  prf "$expected" | dd of="$file" bs=1 seek="$offset" conv=notrunc 2>/dev/null
  local actual
  actual=$(dd if="$file" bs=1 skip="$offset" count="$size" 2>/dev/null)
  if [[ "$actual" != "$expected" ]]; then
    pr_err "Expected '$expected' but got '$actual'"
    return 1
  fi
}

# Verifies that reading from an unallocated file hole returns an error and doesn't leak superblock data.
test_read_hole() {
  local file="$MNT/empty"
  local hole_output="/tmp/ouiche_hole"
  cleanup_later "$file" "$hole_output"

  # only write in the 2nd block → 1st block stays unallocated.
  # a buggy read of that hole would return the superblock ("WICH").
  dd if=/dev/zero of="$file" bs=10 seek="$BLOCK_SIZE" count=1 conv=notrunc 2>/dev/null
  if dd if="$file" of="$hole_output" bs=4 count=1 2>/dev/null; then
    if grep -q WICH "$hole_output"; then
      pr_err "read returned superblock magic!"
      return 1
    else
      pr_err "reading a hole should fail"
      return 1
    fi
  fi
}

# Verifies that reading beyond the current end-of-file (EOF) only returns the available data.
test_read_beyond_eof() {
  local file="$MNT/short"
  cleanup_later "$file"
  local expected="abcdef"
  prf "$expected" >"$file"
  # ask for way more than the file has; should only get 6 bytes
  local actual
  actual=$(dd if="$file" bs=1 count=100 2>/dev/null)
  if [[ "$actual" != "$expected" ]]; then
    pr_err "Expected '$expected' but got '$actual'"
    return 1
  fi
}

# Verifies a basic write operation to a file and ensures the data can be read back correctly.
test_write_regular() {
  local file="$MNT/w1"
  cleanup_later "$file"
  local expected="regular"
  prf "$expected" >"$file"
  local actual
  actual=$(cat "$file")
  if [[ "$actual" != "$expected" ]]; then
    pr_err "Expected '$expected' but got '$actual'"
    return 1
  fi
}

# Verifies that truncating a file and then rewriting it with more data correctly updates content and size.
test_write_truncate_longer() {
  local file="$MNT/file"
  cleanup_later "$file"
  prf "AAAAAAAAAA" >"$file"
  local expected="BB"
  prf "$expected" >"$file"
  local actual
  actual=$(cat "$file")
  local actual_size
  actual_size=$(stat -c '%s' "$file")
  local expected_sz=${#expected}
  if [[ "$actual" != "$expected" ]] || [[ "$actual_size" -ne "$expected_sz" ]]; then
    pr_err "Expected '$expected' (size $expected_sz) but got '$actual' (size $actual_size)"
    return 1
  fi
  expected="CCCCCCCCCCCC"
  prf "$expected" >"$file"
  actual=$(cat "$file")
  actual_size=$(stat -c '%s' "$file")
  expected_sz=${#expected}
  if [[ "$actual" != "$expected" ]] || [[ "$actual_size" -ne "$expected_sz" ]]; then
    pr_err "Expected '$expected' (size $expected_sz) but got '$actual' (size $actual_size)"
    return 1
  fi
}

# Verifies that appending data to an existing file correctly updates the content and preserves previous data.
test_write_append() {
  local file="$MNT/file"
  cleanup_later "$file"
  local content1="first"
  local content2="SECOND"
  prf "$content1" >"$file"
  prf "$content2" >>"$file"
  local expected="${content1}${content2}"
  local actual
  actual=$(cat "$file")
  if [[ "$actual" != "$expected" ]]; then
    pr_err "Expected '$expected' but got '$actual'"
    return 1
  fi
}

# Verifies that writing data across a block boundary correctly updates the file size.
test_write_across_two_blocks() {
  local file="$MNT/file"
  cleanup_later "$file"
  local expected_sz=5000
  dd if=/dev/zero of="$file" bs="$expected_sz" count=1 2>/dev/null
  local actual_size
  actual_size=$(stat -c '%s' "$file")
  if [[ "$actual_size" -ne "$expected_sz" ]]; then
    pr_err "Expected size $expected_sz but got $actual_size"
    return 1
  fi
}

# Verifies that writing data at an offset beyond the current EOF correctly extends the file size.
test_write_past_eof_updates_size() {
  local file="$MNT/file"
  cleanup_later "$file"
  local initial_content="xxxx"
  local -i seek_offset=100
  local -i write_count=10
  prf "$initial_content" >"$file"
  dd if=/dev/zero of="$file" bs=1 seek="$seek_offset" count="$write_count" conv=notrunc 2>/dev/null
  local -i expected_sz=$((seek_offset + write_count))
  local actual_size
  actual_size=$(stat -c '%s' "$file")
  if [[ "$actual_size" -ne "$expected_sz" ]]; then
    pr_err "Expected size $expected_sz after write past EOF, but got $actual_size"
    return 1
  fi
}

# Verifies that a series of writes and reads to the same file correctly update and retrieve data.
test_mixed_write_read() {
  local file="$MNT/file"
  cleanup_later "$file"
  local expected="version-one"
  prf "$expected" >"$file"
  local actual
  actual=$(cat "$file")
  if [[ "$actual" != "$expected" ]]; then
    pr_err "Expected '$expected' but got '$actual'"
    return 1
  fi

  expected="version-two"
  prf "$expected" >"$file"
  actual=$(cat "$file")
  if [[ "$actual" != "$expected" ]]; then
    pr_err "Expected '$expected' but got '$actual'"
    return 1
  fi
}

# Verifies the ability to handle files larger than 4 MiB, testing the filesystem's extent mapping beyond basic limits.
test_large_sequential_file() {
  # Sequential append-only write from offset 0 (no backward seeks, no sparse
  # holes). Slightly larger than the old 4 MiB block-pointer limit.
  local expected_sz=$((4 * 1024 * 1024 + BLOCK_SIZE)) # 4 MiB + 1 block
  local ref_file="/tmp/ouiche_large_ref"
  local got_file="/tmp/ouiche_large_got"
  local file="$MNT/large"
  cleanup_later "$ref_file" "$got_file" "$file"

  # patterned reference so we catch short/corrupt reads, not just size
  dd if=/dev/urandom of="$ref_file" bs="$expected_sz" count=1 2>/dev/null
  if ! dd if="$ref_file" of="$file" bs="$expected_sz" count=1 2>/dev/null; then
    pr_err "failed to write >4MiB sequential file"
    return 1
  fi

  local actual_size
  actual_size=$(stat -c '%s' "$file")
  if [[ "$actual_size" -ne "$expected_sz" ]]; then
    pr_err "Expected size $expected_sz after >4MiB write, but got $actual_size"
    return 1
  fi

  if ! dd if="$file" of="$got_file" bs="$BLOCK_SIZE" 2>/dev/null; then
    pr_err "failed to read >4MiB file back"
    return 1
  fi

  if ! cmp -s "$ref_file" "$got_file"; then
    pr_err ">4MiB readback mismatch"
    return 1
  fi
}

# Helper to setup ioctl test environment (mknod, compile C tool).
# Sets up the device node and compiles the helper binary.
setup_ioctl_test() {
  local -n device_ref=$1
  local -n bin_ref=$2

  local major
  major=$(grep ouichefs /proc/devices | awk '{print $1}')
  if [[ -z "$major" ]]; then
    pr_err "no major number for ouichefs in /proc/devices!"
    return 1
  fi

  device_ref="/dev/ouichefs"
  cleanup_later "$device_ref"

  local ioctl_test_c="/tmp/ouichefs_ioctl_test.c"
  bin_ref="/tmp/ouichefs_ioctl_test"
  local ioctl_header="/tmp/extent_ioctl.h"
  local ioctl_header_new="/tmp/extent_ioctl.h.new"
  local script_dir
  script_dir=$(cd -- "$(dirname "$0")" && pwd)

  if ! mknod "$device_ref" c "$major" 0; then
    pr_err "could not create $device_ref"
    return 1
  fi

  printf '%s\n' '
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include "extent_ioctl.h"

int main(int argc, char **argv)
{
	int ctl, fd;

	if (argc < 3) return 1;

	fd = open(argv[1], O_RDONLY);
	if (fd < 0) {
		perror("open file");
		return 1;
	}

	ctl = open(argv[2], O_RDWR);
	if (ctl < 0) {
		perror("open ctl");
		close(fd);
		return 1;
	}

	/* kernel uses copy_from_user → pass &fd */
	if (ioctl(ctl, OUICHEFS_IOC_GET_EXTENTS, &fd) < 0) {
		perror("ioctl");
		close(ctl);
		close(fd);
		return 1;
	}

	close(ctl);
	close(fd);
	return 0;
}
' >"$ioctl_test_c"

  cp "$script_dir/extent_ioctl.h" "$ioctl_header"
  if ! grep -q 'linux/ioctl.h\|sys/ioctl.h' "$ioctl_header"; then
    printf '%s\n' '#include <sys/ioctl.h>' | cat - "$ioctl_header" >"$ioctl_header_new"
    mv "$ioctl_header_new" "$ioctl_header"
  fi

  if ! gcc -I/tmp -o "$bin_ref" "$ioctl_test_c"; then
    pr_err "can't compile ioctl test"
    rm -f "$ioctl_test_c" "$ioctl_header"
    return 1
  fi
  cleanup_later "$ioctl_test_c" "$ioctl_header" "$bin_ref"
}

# Verifies the OUICHEFS_IOC_GET_EXTENTS ioctl on a small multi-block file.
test_ioctl_small_file() {
  local device ioctl_test_bin
  local file="$MNT/ioctl_small"
  cleanup_later "$file"

  if ! setup_ioctl_test device ioctl_test_bin; then
    return 1
  fi
  local -i small_sz=$((BLOCK_SIZE * 4))
  dd if=/dev/zero of="$file" bs="$small_sz" count=1 2>/dev/null
  dmesg -C 2>/dev/null || true

  if ! "$ioctl_test_bin" "$file" "$device"; then
    pr_err "ioctl on small file failed"
    return 1
  fi

  if ! dmesg | grep -q 'extents for inode'; then
    pr_err "missing 'extents for inode' line in dmesg"
    return 1
  fi

  if ! dmesg | grep -qE '\[0\] start=[0-9]+ count=[0-9]+'; then
    pr_err "missing extent detail line in dmesg"
    return 1
  fi

  dmesg | grep -E 'extents for inode|start='
}

# Verifies the OUICHEFS_IOC_GET_EXTENTS ioctl on a large file (> 4 MiB).
test_ioctl_file() {
  local device ioctl_test_bin
  local file="$MNT/large_ioctl"
  cleanup_later "$file"

  if ! setup_ioctl_test device ioctl_test_bin; then
    return 1
  fi
  local -i expected_blocks=$(((4 * 1024 * 1024 / BLOCK_SIZE) + 1))
  local -i large_bytes=$((expected_blocks * BLOCK_SIZE))
  dd if=/dev/zero of="$file" bs="$large_bytes" count=1 2>/dev/null
  dmesg -C 2>/dev/null || true

  if ! "$ioctl_test_bin" "$file" "$device"; then
    pr_err "ioctl on >4MiB file failed"
    return 1
  fi

  if ! dmesg | grep -q 'extents for inode'; then
    pr_err "missing extents summary for large file"
    return 1
  fi

  dmesg | grep -E 'extents for inode|start='

  local counts
  counts=$(dmesg | sed -n 's/.*count=\([0-9][0-9]*\).*/\1/p')
  local -i actual_sum=0
  local -i n_ext=0
  for c in $counts; do
    actual_sum=$((actual_sum + c))
    n_ext=$((n_ext + 1))
  done

  if [[ "$actual_sum" -ne "$expected_blocks" ]]; then
    pr_err "Expected $expected_blocks data blocks, but extent list covers $actual_sum blocks"
    return 1
  fi

  echo "extent list covers $actual_sum blocks in $n_ext extent(s)"
}

# Verifies that the filesystem allocates contiguous blocks when possible.
# Creates two small files, deletes the first, then creates a larger file and verifies it occupies a single extent.
test_contiguous_allocation() {
  local device ioctl_test_bin
  local small_file_1="$MNT/contig_1"
  local small_file_2="$MNT/contig_2"
  local file="$MNT/contig_large"
  cleanup_later "$small_file_1" "$small_file_2" "$file"

  if ! setup_ioctl_test device ioctl_test_bin; then
    return 1
  fi

  # Create two small files
  dd if=/dev/zero of="$small_file_1" bs="$BLOCK_SIZE" count=1 2>/dev/null
  dd if=/dev/zero of="$small_file_2" bs="$BLOCK_SIZE" count=1 2>/dev/null

  # Delete the first one to free up space (potentially creating a hole or just testing allocation)
  rm -f "$small_file_1"

  # Create a larger file
  # Use bs=... count=1 to ensure a single write() call, which is optimal for contiguous allocation.
  local -i expected_blocks=4
  local -i large_sz=$((expected_blocks * BLOCK_SIZE))
  dd if=/dev/zero of="$file" bs="$large_sz" count=1 2>/dev/null
  dmesg -C 2>/dev/null || true

  # Use ioctl to check extents
  if ! "$ioctl_test_bin" "$file" "$device"; then
    pr_err "ioctl on large file failed"
    return 1
  fi

  # Verify it is a single extent
  if ! dmesg | grep -q 'extents for inode'; then
    pr_err "missing extents summary in dmesg"
    return 1
  fi

  local n_ext
  n_ext=$(dmesg | grep -c 'start=')
  local -i expected_extents=1

  if [[ "$n_ext" -ne "$expected_extents" ]]; then
    pr_err "Expected $expected_extents extent, but found $n_ext extents"
    dmesg | grep 'start='
    return 1
  fi

  echo "Confirmed: large file is allocated in $n_ext contiguous extent(s)"
}

#################
# END TESTCASES #
#################

# alias for printf
prf() {
  printf '%s' "$1"
}

# prints an error
pr_err() {
  echo "[ERROR] $1" >&2
}

main "$@"
