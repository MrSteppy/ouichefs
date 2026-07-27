#!/bin/bash
# shellcheck disable=SC2317

# mount point of a ouichefs partition
MNT=${MNT:-/mnt/ouichefs}
# block size in bytes
BLOCK_SIZE=4096
NR_BLOCKS=12800
INITIAL_COMMITTED_BLOCKS=255
DEFAULT_RESERVATION_WINDOW=8

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
ignore_test_read_hole() {
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
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include "extent_ioctl.h"

int main(int argc, char **argv)
{
	int ctl, fd;

	if (argc < 3) return 1;

	/* If first arg is a number, treat it as an open FD; otherwise open as filename */
	if (argv[1][0] >= '\''0'\'' && argv[1][0] <= '\''9'\'') {
		fd = atoi(argv[1]);
	} else {
		fd = open(argv[1], O_RDONLY);
		if (fd < 0) {
			perror("open file");
			return 1;
		}
	}

	ctl = open(argv[2], O_RDWR);
	if (ctl < 0) {
		perror("open ctl");
		if (argv[1][0] < '\''0'\'' || argv[1][0] > '\''9'\'') close(fd);
		return 1;
	}

	/* kernel uses copy_from_user → pass &fd */
	if (ioctl(ctl, OUICHEFS_IOC_GET_EXTENTS, &fd) < 0) {
		perror("ioctl");
		close(ctl);
		if (argv[1][0] < '\''0'\'' || argv[1][0] > '\''9'\'') close(fd);
		return 1;
	}

	close(ctl);
	if (argv[1][0] < '\''0'\'' || argv[1][0] > '\''9'\'') close(fd);
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
  counts=$(dmesg | sed -n 's/.*\[[0-9][0-9]*\] start=[0-9][0-9]* count=\([0-9][0-9]*\).*/\1/p')
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

# Validates the reservation window: small sequential writes stay in one extent
# even if another file allocates between them (without reservations that gap
# would force a second extent). One new physical run is taken per exhausted
# window, not per write().
test_reservation() {
  local device ioctl_test_bin
  local file="$MNT/reserved"
  local small_file="$MNT/small"
  cleanup_later "$file" "$small_file"

  if ! setup_ioctl_test device ioctl_test_bin; then
    return 1
  fi

  # Use a single redirection to keep the file handle open across multiple writes
  exec 3>"$file"
  trap 'exec 3>&-' RETURN
  dd if=/dev/zero bs="$((BLOCK_SIZE * 2))" count=1 >&3 2>/dev/null
  # small_file is still separate, it should "break" contiguity if not for reservation
  dd if=/dev/zero of="$small_file" bs="$BLOCK_SIZE" count=1 2>/dev/null
  # append to file again while it is still open (via fd 3)
  dd if=/dev/zero bs="$((BLOCK_SIZE * 2))" count=4 >&3 2>/dev/null
  exec 3>&-
  trap - RETURN

  dmesg -C 2>/dev/null || true

  # Use ioctl to check extents
  if ! "$ioctl_test_bin" "$file" "$device"; then
    pr_err "ioctl on file failed"
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

# Verifies that block reservations are released when the file is closed.
# A short write leaves leftover reserved blocks; while the fd stays open the
# ioctl must report reserved > 0. After close + reopen (no further writes),
# reserved must be 0.
test_reservation_released_on_close() {
  local device ioctl_test_bin
  local file="$MNT/reserv_close"
  cleanup_later "$file"

  if ! setup_ioctl_test device ioctl_test_bin; then
    return 1
  fi

  dmesg -C 2>/dev/null || true

  # Open, write one block, and keep it open via FD 3
  exec 3>"$file"
  trap 'exec 3>&-' RETURN
  dd if=/dev/zero bs="$BLOCK_SIZE" count=1 >&3 2>/dev/null

  # Inspect reservations while still open (passing FD 3 to the ioctl tool)
  if ! "$ioctl_test_bin" 3 "$device"; then
    pr_err "ioctl on open FD failed"
    return 1
  fi

  # Close the FD - this should release leftover reserved blocks
  exec 3>&-
  trap - RETURN

  # Reopen (the ioctl tool will open it normally) and check reservations again
  if ! "$ioctl_test_bin" "$file" "$device"; then
    pr_err "ioctl after close failed"
    return 1
  fi

  local -a reserved_counts
  mapfile -t reserved_counts < <(dmesg | sed -n 's/.* \([0-9][0-9]*\) reserved block(s).*/\1/p')

  if [[ ${#reserved_counts[@]} -ne 2 ]]; then
    pr_err "Expected 2 ioctl reports in dmesg, got ${#reserved_counts[@]}"
    dmesg | grep -E 'extents for inode|reserved block' || true
    return 1
  fi

  local -i reserved_open="${reserved_counts[0]}"
  local -i reserved_after="${reserved_counts[1]}"

  if [[ "$reserved_open" -le 0 ]]; then
    pr_err "Expected reserved blocks > 0 while file open after write, got $reserved_open"
    return 1
  fi

  if [[ "$reserved_after" -ne 0 ]]; then
    pr_err "Expected 0 reserved blocks after close+reopen, got $reserved_after"
    return 1
  fi

  echo "while open after write: $reserved_open reserved block(s)"
  echo "after close+reopen: $reserved_after reserved block(s)"
}

# Verifies GC reclaims reserved-but-unused blocks when the partition is full.
#
# GC only runs when ouichefs_alloc_contiguous finds zero free blocks. Reserved
# windows hold blocks outside the free bitmap, so the recipe is:
#   1. concurrent writers each write 1 block and keep the fd open (hold
#      reservation_size leftover blocks each)
#   2. one filler write consumes every remaining free block
#   3. a write to a pre-created file must then succeed via GC
test_gc_reclamation() {
  local device ioctl_test_bin
  local file_prefix="$MNT/gc_writer_"
  local trigger_file="$MNT/gc_trigger"
  local filler_file="$MNT/gc_filler"
  local sync_dir
  local -i num_writers=4
  local -a writer_files=()
  local -a writer_pids=()
  local stop_file

  if ! setup_ioctl_test device ioctl_test_bin; then
    return 1
  fi

  sync_dir=$(mktemp -d /tmp/ouiche_gc_sync.XXXXXX)
  stop_file="$sync_dir/stop"
  cleanup_later "$sync_dir" "$trigger_file" "$filler_file"

  # Pre-create index blocks while free space still exists. A new inode must
  # start with an empty reservation; otherwise the filler would consume bogus
  # blocks without changing the free-space bitmap.
  if ! : >"$trigger_file" || ! : >"$filler_file"; then
    pr_err "failed to create trigger/filler files"
    return 1
  fi
  dmesg -C 2>/dev/null || true
  if ! "$ioctl_test_bin" "$filler_file" "$device"; then
    pr_err "ioctl on fresh filler file failed"
    return 1
  fi
  local -i fresh_reserved
  fresh_reserved=$(dmesg | sed -n 's/.* \([0-9][0-9]*\) reserved block(s).*/\1/p' | tail -n 1)
  : "${fresh_reserved:=0}"
  if [[ "$fresh_reserved" -ne 0 ]]; then
    pr_err "fresh inode has $fresh_reserved reserved blocks; reservation state was not initialized"
    return 1
  fi

  # Concurrent writers: one data block each, fd held open → leftover reservation.
  echo "Starting $num_writers concurrent reservation holders..."
  local -i i
  for ((i = 0; i < num_writers; i++)); do
    local f="${file_prefix}$i"
    writer_files+=("$f")
    cleanup_later "$f"
    (
      exec 3>"$f"
      if ! dd if=/dev/zero bs="$BLOCK_SIZE" count=1 >&3 2>/dev/null; then
        exit 1
      fi
      while [[ ! -f "$stop_file" ]]; do
        sleep 0.05
      done
      exec 3>&-
    ) &
    writer_pids+=($!)
  done

  # Wait until every writer file exists and has data (reservation established).
  for f in "${writer_files[@]}"; do
    local -i waits=0
    while [[ ! -s "$f" ]]; do
      waits+=1
      if [[ "$waits" -gt 100 ]]; then
        pr_err "writer never created $f"
        touch "$stop_file"
        wait || true
        return 1
      fi
      sleep 0.05
    done
  done

  local -i free_blocks
  free_blocks=$(df -B"$BLOCK_SIZE" --output=avail "$MNT" | tail -n 1 | tr -d ' ')
  if [[ -z "$free_blocks" || "$free_blocks" -le 0 ]]; then
    pr_err "expected free blocks after writers, got '$free_blocks'"
    touch "$stop_file"
    wait || true
    return 1
  fi
  echo "Free blocks after writers: $free_blocks (held open with reservations)"

  dmesg -C 2>/dev/null || true
  if ! "$ioctl_test_bin" "$trigger_file" "$device"; then
    pr_err "ioctl before fill failed"
    touch "$stop_file"
    wait || true
    return 1
  fi
  local -i initial_gc
  initial_gc=$(dmesg | sed -n 's/.*gc_count=\([0-9][0-9]*\).*/\1/p' | tail -n 1)
  : "${initial_gc:=0}"
  echo "gc_count before fill/trigger: $initial_gc"

  # Consume all remaining free blocks. Prefer one large write so the filler
  # finishes with reserved_count == 0 (allocates the free run, uses it all).
  # Keep the filler fd open so close() cannot return space before GC runs.
  exec 8>"$filler_file"
  if ! dd if=/dev/zero bs=$((BLOCK_SIZE * free_blocks)) count=1 >&8 2>/dev/null; then
    # Fall back to per-block writes if a single huge write fails in userspace
    dd if=/dev/zero bs="$BLOCK_SIZE" count="$free_blocks" >&8 2>/dev/null || true
  fi

  # Drain leftovers from short writes / df rounding
  local -i free_after drain_guard=0
  while true; do
    free_after=$(df -B"$BLOCK_SIZE" --output=avail "$MNT" | tail -n 1 | tr -d ' ')
    : "${free_after:=0}"
    [[ "$free_after" -le 0 ]] && break
    drain_guard+=1
    if [[ "$drain_guard" -gt 32 ]]; then
      pr_err "could not drain free space (still $free_after blocks)"
      exec 8>&-
      touch "$stop_file"
      wait || true
      return 1
    fi
    dd if=/dev/zero bs="$BLOCK_SIZE" count="$free_after" >&8 2>/dev/null ||
      dd if=/dev/zero bs="$BLOCK_SIZE" count=1 >&8 2>/dev/null || break
  done
  free_after=$(df -B"$BLOCK_SIZE" --output=avail "$MNT" | tail -n 1 | tr -d ' ')
  : "${free_after:=0}"
  echo "Free blocks after filler: $free_after"
  if [[ "$free_after" -gt 0 ]]; then
    pr_err "disk not full before GC trigger (free=$free_after); cannot force GC"
    exec 8>&-
    touch "$stop_file"
    wait || true
    return 1
  fi

  # With free == 0 and writers still holding reservations, this write must GC.
  if ! dd if=/dev/zero of="$trigger_file" bs="$BLOCK_SIZE" count=1 conv=notrunc 2>/dev/null; then
    pr_err "trigger write failed — GC did not reclaim reserved space"
    exec 8>&-
    touch "$stop_file"
    wait || true
    return 1
  fi

  dmesg -C 2>/dev/null || true
  if ! "$ioctl_test_bin" "$trigger_file" "$device"; then
    pr_err "ioctl after trigger failed"
    exec 8>&-
    touch "$stop_file"
    wait || true
    return 1
  fi
  local -i final_gc
  final_gc=$(dmesg | sed -n 's/.*gc_count=\([0-9][0-9]*\).*/\1/p' | tail -n 1)
  : "${final_gc:=0}"
  echo "gc_count after trigger: $final_gc"

  exec 8>&-
  touch "$stop_file"
  wait || true

  if [[ "$final_gc" -le "$initial_gc" ]]; then
    pr_err "GC was not triggered (initial=$initial_gc final=$final_gc)"
    dmesg | grep -E 'gc_count|Allocated|ENOSPC' | tail -n 30 || true
    return 1
  fi

  # Space should be usable after reclaim (trigger file has one data block).
  local -i trigger_sz
  trigger_sz=$(stat -c '%s' "$trigger_file")
  if [[ "$trigger_sz" -ne "$BLOCK_SIZE" ]]; then
    pr_err "Expected trigger size $BLOCK_SIZE after GC write, got $trigger_sz"
    return 1
  fi

  echo "GC reclaimed reservations (gc_count $initial_gc -> $final_gc)"
}

# Sysfs attrs exist and report the empty-partition baseline.
test_stats_clean_state() {
  local -A s=()
  load_stats s || return 1

  local attr
  for attr in "${OUICHEFS_STAT_NAMES[@]}"; do
    if [[ ! -f "${s[sysfs_path]}/$attr" ]]; then
      pr_err "missing sysfs attribute ${s[sysfs_path]}/$attr"
      return 1
    fi
  done

  local expected_free=$((NR_BLOCKS - INITIAL_COMMITTED_BLOCKS))
  assert_eq "clean free_blocks" "${s[free_blocks]}" "$expected_free" || return 1
  assert_eq "clean commited_blocks" "${s[commited_blocks]}" "$INITIAL_COMMITTED_BLOCKS" || return 1
  assert_eq "clean reserved_blocks" "${s[reserved_blocks]}" 0 || return 1
  assert_eq "clean files" "${s[files]}" 0 || return 1
  assert_eq "clean total_extents" "${s[total_extents]}" 0 || return 1
  assert_eq "clean avg_extent_size" "${s[avg_extent_size]}" 0 || return 1
  assert_eq "clean max_file_size" "${s[max_file_size]}" 0 || return 1
  assert_eq "clean fragmentation" "${s[fragmentation]}" 0 || return 1
  assert_block_accounting s || return 1
}

# reservation_window is read-write.
test_stats_reservation_window() {
  local -A s=()
  load_stats s || return 1

  local initial=${s[reservation_window]}
  local new_window=16
  if [[ "$initial" -eq 16 ]]; then
    new_window=32
  fi

  if ! printf '%s\n' "$new_window" >"${s[sysfs_path]}/reservation_window"; then
    pr_err "failed to write reservation_window"
    return 1
  fi
  load_stats s || return 1
  assert_eq "reservation_window after store" "${s[reservation_window]}" "$new_window" || return 1

  printf '%s\n' "$initial" >"${s[sysfs_path]}/reservation_window"
  load_stats s || return 1
  assert_eq "reservation_window restored" "${s[reservation_window]}" "$initial" || return 1
}

# Small-file block accounting: create (−2 free), in-block append (unchanged), unlink (≥2 freed).
test_stats_file_blocks() {
  local -A s=()
  load_stats s || return 1

  local file="$MNT/stats_small"
  cleanup_later "$file"

  local expected_free=$((NR_BLOCKS - INITIAL_COMMITTED_BLOCKS))
  local content="Hello stats!"
  local content_len=${#content}
  prf "$content" >"$file"

  load_stats s || return 1
  assert_eq "free_blocks after small file" "${s[free_blocks]}" "$((expected_free - 2))" || return 1
  assert_eq "commited_blocks after small file" "${s[commited_blocks]}" "$((INITIAL_COMMITTED_BLOCKS + 2))" || return 1
  assert_eq "reserved_blocks after close" "${s[reserved_blocks]}" 0 || return 1
  assert_eq "files after small file" "${s[files]}" 1 || return 1
  assert_eq "total_extents after small file" "${s[total_extents]}" 1 || return 1
  assert_eq "avg_extent_size after small file" "${s[avg_extent_size]}" 100 || return 1
  assert_eq "max_file_size after small file" "${s[max_file_size]}" "$content_len" || return 1
  assert_eq "fragmentation after small file" "${s[fragmentation]}" 100 || return 1
  assert_block_accounting s || return 1

  local free_before=${s[free_blocks]}
  local committed_before=${s[commited_blocks]}
  prf "!" >>"$file"
  load_stats s || return 1
  assert_eq "free_blocks after in-block append" "${s[free_blocks]}" "$free_before" || return 1
  assert_eq "commited_blocks after in-block append" "${s[commited_blocks]}" "$committed_before" || return 1
  assert_eq "max_file_size after in-block append" "${s[max_file_size]}" "$((content_len + 1))" || return 1

  free_before=${s[free_blocks]}
  rm -f "$file"
  load_stats s || return 1
  local freed=$((${s[free_blocks]} - free_before))
  if [[ "$freed" -lt 2 ]]; then
    pr_err "expected at least 2 blocks freed on unlink, got $freed"
    return 1
  fi
  assert_eq "blocks freed for small file" "$freed" 2 || return 1
  assert_eq "free_blocks after delete" "${s[free_blocks]}" "$expected_free" || return 1
  assert_eq "files after delete" "${s[files]}" 0 || return 1
  assert_eq "max_file_size after delete" "${s[max_file_size]}" 0 || return 1
  assert_block_accounting s || return 1
}

# reserved_blocks tracks the open-fd reservation window leftover; close releases it.
test_stats_reserved_blocks() {
  local -A s=()
  load_stats s || return 1

  local file="$MNT/stats_reserved"
  cleanup_later "$file"
  local expected_free=$((NR_BLOCKS - INITIAL_COMMITTED_BLOCKS))

  printf '%s\n' "$DEFAULT_RESERVATION_WINDOW" >"${s[sysfs_path]}/reservation_window"

  exec 3>"$file"
  trap 'exec 3>&-' RETURN
  dd if=/dev/zero bs="$BLOCK_SIZE" count=1 >&3 2>/dev/null

  load_stats s || return 1
  assert_eq "reserved_blocks while open" "${s[reserved_blocks]}" "$DEFAULT_RESERVATION_WINDOW" || return 1
  assert_eq "commited_blocks while open" "${s[commited_blocks]}" "$((INITIAL_COMMITTED_BLOCKS + 2))" || return 1
  assert_eq "free_blocks while open" "${s[free_blocks]}" "$((expected_free - 2 - DEFAULT_RESERVATION_WINDOW))" || return 1
  assert_block_accounting s || return 1

  exec 3>&-
  trap - RETURN

  load_stats s || return 1
  assert_eq "reserved_blocks after close" "${s[reserved_blocks]}" 0 || return 1
  assert_eq "free_blocks after close" "${s[free_blocks]}" "$((expected_free - 2))" || return 1
  assert_block_accounting s || return 1
}

# total_extents / avg_extent_size / fragmentation for contiguous and fragmented layouts.
test_stats_extents() {
  local -A s=()
  load_stats s || return 1

  local file="$MNT/stats_ext"
  local other="$MNT/stats_ext_other"
  cleanup_later "$file" "$other"

  local -i multi_blocks=3
  local -i multi_bytes=$((multi_blocks * BLOCK_SIZE))
  local expected_free=$((NR_BLOCKS - INITIAL_COMMITTED_BLOCKS))

  dd if=/dev/zero of="$file" bs="$multi_bytes" count=1 2>/dev/null
  load_stats s || return 1
  assert_eq "free_blocks after 3-block file" "${s[free_blocks]}" "$((expected_free - 1 - multi_blocks))" || return 1
  assert_eq "files after 3-block file" "${s[files]}" 1 || return 1
  assert_eq "total_extents after 3-block file" "${s[total_extents]}" 1 || return 1
  assert_eq "avg_extent_size after 3-block file" "${s[avg_extent_size]}" "$((multi_blocks * 100))" || return 1
  assert_eq "fragmentation after 3-block file" "${s[fragmentation]}" 100 || return 1
  assert_eq "max_file_size after 3-block file" "${s[max_file_size]}" "$multi_bytes" || return 1

  # Disable reservations so the spacer file sits on the next physical block and
  # the append cannot coalesce into the first extent.
  printf '%s\n' 0 >"${s[sysfs_path]}/reservation_window"
  rm -f "$file"
  dd if=/dev/zero of="$file" bs="$multi_bytes" count=1 2>/dev/null
  dd if=/dev/zero of="$other" bs="$BLOCK_SIZE" count=1 2>/dev/null
  dd if=/dev/zero of="$file" bs="$BLOCK_SIZE" seek="$multi_blocks" count=1 conv=notrunc 2>/dev/null
  printf '%s\n' "$DEFAULT_RESERVATION_WINDOW" >"${s[sysfs_path]}/reservation_window"

  load_stats s || return 1
  assert_eq "files with two files" "${s[files]}" 2 || return 1
  # file: 2 extents (3+1), other: 1 extent
  assert_eq "total_extents fragmented" "${s[total_extents]}" 3 || return 1
  assert_eq "avg_extent_size fragmented" "${s[avg_extent_size]}" $((5 * 100 / 3)) || return 1
  assert_eq "fragmentation fragmented" "${s[fragmentation]}" 150 || return 1
  assert_eq "max_file_size after append" "${s[max_file_size]}" "$(((multi_blocks + 1) * BLOCK_SIZE))" || return 1
  assert_block_accounting s || return 1
}

# max_file_size tracks the largest file and is recomputed when it is removed.
test_stats_max_file_size() {
  local -A s=()
  load_stats s || return 1

  local small="$MNT/stats_max_small"
  local large="$MNT/stats_max_large"
  cleanup_later "$small" "$large"

  dd if=/dev/zero of="$small" bs=$((BLOCK_SIZE * 2)) count=1 2>/dev/null
  load_stats s || return 1
  assert_eq "max_file_size after small" "${s[max_file_size]}" "$((2 * BLOCK_SIZE))" || return 1

  dd if=/dev/zero of="$large" bs=$((BLOCK_SIZE * 5)) count=1 2>/dev/null
  load_stats s || return 1
  assert_eq "max_file_size after large" "${s[max_file_size]}" "$((5 * BLOCK_SIZE))" || return 1

  rm -f "$large"
  load_stats s || return 1
  assert_eq "max_file_size after removing largest" "${s[max_file_size]}" "$((2 * BLOCK_SIZE))" || return 1

  rm -f "$small"
  load_stats s || return 1
  assert_eq "max_file_size after removing all" "${s[max_file_size]}" 0 || return 1
}

# Force a GC pass and verify gc_count in sysfs increases.
test_stats_gc_count() {
  local -A s=()
  load_stats s || return 1
  local -i initial_gc=${s[gc_count]}

  if ! force_ouichefs_gc; then
    pr_err "failed to force a GC pass"
    return 1
  fi

  load_stats s || return 1
  if [[ "${s[gc_count]}" -le "$initial_gc" ]]; then
    pr_err "gc_count did not increase (initial=$initial_gc final=${s[gc_count]})"
    return 1
  fi
  echo "gc_count $initial_gc -> ${s[gc_count]}"
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

OUICHEFS_STAT_NAMES=(
  free_blocks
  commited_blocks
  reserved_blocks
  files
  total_extents
  avg_extent_size
  max_file_size
  fragmentation
  reservation_window
  gc_count
)

# Resolve /sys/ouichefs/<partition> for the mounted test partition.
ouichefs_sysfs_path() {
  local dev
  dev="$(findmnt -n -o SOURCE "$MNT")"
  if [[ -z "$dev" ]]; then
    pr_err "could not resolve SOURCE for $MNT"
    return 1
  fi
  printf '%s\n' "/sys/ouichefs/$(basename "$dev")"
}

# Load all ouichefs sysfs stats into the nameref'd associative array.
# Also sets stats[sysfs_path].
load_stats() {
  local -n stats_ref=$1
  local sysfs_path name
  sysfs_path="$(ouichefs_sysfs_path)" || return 1
  stats_ref=()
  stats_ref[sysfs_path]=$sysfs_path
  for name in "${OUICHEFS_STAT_NAMES[@]}"; do
    stats_ref[$name]=$(<"$sysfs_path/$name")
  done
}

# Assert numeric equality with a label for the failure message.
assert_eq() {
  local label=$1
  local actual=$2
  local expected=$3
  if [[ "$actual" -ne "$expected" ]]; then
    pr_err "$label: expected $expected but got $actual"
    return 1
  fi
}

# Assert free + committed + reserved == NR_BLOCKS using a loaded stats array.
assert_block_accounting() {
  local -n stats_ref=$1
  local sum=$((stats_ref[free_blocks] + stats_ref[commited_blocks] + stats_ref[reserved_blocks]))
  if [[ "$sum" -ne "$NR_BLOCKS" ]]; then
    pr_err "block accounting: free(${stats_ref[free_blocks]})+committed(${stats_ref[commited_blocks]})+reserved(${stats_ref[reserved_blocks]})=$sum, expected $NR_BLOCKS"
    return 1
  fi
}

# Fill the partition while reservation holders keep leftover windows, then
# force an allocating write that must trigger GC. Used by test_stats_gc_count.
force_ouichefs_gc() {
  local device ioctl_test_bin
  local file_prefix="$MNT/stats_gc_writer_"
  local trigger_file="$MNT/stats_gc_trigger"
  local filler_file="$MNT/stats_gc_filler"
  local sync_dir stop_file
  local -i num_writers=4
  local -a writer_files=()
  local -i i

  if ! setup_ioctl_test device ioctl_test_bin; then
    return 1
  fi

  sync_dir=$(mktemp -d /tmp/ouiche_stats_gc.XXXXXX)
  stop_file="$sync_dir/stop"
  cleanup_later "$sync_dir" "$trigger_file" "$filler_file"

  if ! : >"$trigger_file" || ! : >"$filler_file"; then
    pr_err "failed to create trigger/filler files"
    return 1
  fi

  for ((i = 0; i < num_writers; i++)); do
    local f="${file_prefix}$i"
    writer_files+=("$f")
    cleanup_later "$f"
    (
      exec 3>"$f"
      dd if=/dev/zero bs="$BLOCK_SIZE" count=1 >&3 2>/dev/null || exit 1
      while [[ ! -f "$stop_file" ]]; do
        sleep 0.05
      done
      exec 3>&-
    ) &
  done

  for f in "${writer_files[@]}"; do
    local -i waits=0
    while [[ ! -s "$f" ]]; do
      waits+=1
      if [[ "$waits" -gt 100 ]]; then
        pr_err "writer never created $f"
        touch "$stop_file"
        wait || true
        return 1
      fi
      sleep 0.05
    done
  done

  local -i free_blocks
  free_blocks=$(df -B"$BLOCK_SIZE" --output=avail "$MNT" | tail -n 1 | tr -d ' ')
  if [[ -z "$free_blocks" || "$free_blocks" -le 0 ]]; then
    pr_err "expected free blocks after writers, got '$free_blocks'"
    touch "$stop_file"
    wait || true
    return 1
  fi

  exec 8>"$filler_file"
  if ! dd if=/dev/zero bs=$((BLOCK_SIZE * free_blocks)) count=1 >&8 2>/dev/null; then
    dd if=/dev/zero bs="$BLOCK_SIZE" count="$free_blocks" >&8 2>/dev/null || true
  fi

  local -i free_after drain_guard=0
  while true; do
    free_after=$(df -B"$BLOCK_SIZE" --output=avail "$MNT" | tail -n 1 | tr -d ' ')
    : "${free_after:=0}"
    [[ "$free_after" -le 0 ]] && break
    drain_guard+=1
    if [[ "$drain_guard" -gt 32 ]]; then
      pr_err "could not drain free space (still $free_after blocks)"
      exec 8>&-
      touch "$stop_file"
      wait || true
      return 1
    fi
    dd if=/dev/zero bs="$BLOCK_SIZE" count="$free_after" >&8 2>/dev/null ||
      dd if=/dev/zero bs="$BLOCK_SIZE" count=1 >&8 2>/dev/null || break
  done

  if ! dd if=/dev/zero of="$trigger_file" bs="$BLOCK_SIZE" count=1 conv=notrunc 2>/dev/null; then
    pr_err "trigger write failed — GC did not reclaim reserved space"
    exec 8>&-
    touch "$stop_file"
    wait || true
    return 1
  fi

  exec 8>&-
  touch "$stop_file"
  wait || true
  return 0
}

main "$@"
