#!/bin/bash
# shellcheck disable=SC2317

# mount point of a ouichefs partition
MNT=${MNT:-/mnt/ouichefs}
# block size in bytes
BLOCK_SIZE=4096
NR_BLOCKS=12800
INITIAL_COMMITTED_BLOCKS=255
DEFAULT_RESERVATION_WINDOW=8
# OUICHEFS_BLOCK_SIZE / sizeof(struct ouichefs_extent) == 4096 / 8
OUICHEFS_MAX_EXTENTS=512

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

# Verifies that reading from an unallocated file hole returns zeros (not
# superblock data) and that hole extents are reflected in sysfs stats.
test_read_hole() {
  local file="$MNT/empty"
  local hole_output="/tmp/ouiche_hole"
  cleanup_later "$file" "$hole_output"

  local -A base=() s=()
  load_stats base || return 1

  # Write only in the 3rd block → block 0 is zero-filled at EOF, block 1 is a
  # hole. A buggy read of that hole would return the superblock ("WICH").
  dd if=/dev/zero of="$file" bs="$BLOCK_SIZE" seek=2 count=1 conv=notrunc 2>/dev/null

  local -i expected_sz=$((3 * BLOCK_SIZE))
  local actual_size
  actual_size=$(stat -c '%s' "$file")
  if [[ "$actual_size" -ne "$expected_sz" ]]; then
    pr_err "Expected size $expected_sz but got $actual_size"
    return 1
  fi

  # Read 4 bytes from the hole (start of block 1)
  if ! dd if="$file" of="$hole_output" bs=1 skip="$BLOCK_SIZE" count=4 2>/dev/null; then
    pr_err "Reading a sparse file failed"
    return 1
  fi

  # check that we only read zeros
  if ! cmp -s /dev/zero "$hole_output" --bytes=4; then
    pr_err "read returned non-zero data from hole!"
    return 1
  fi

  # index + 2 data blocks; hole is not physical. Extents: data, hole, data.
  load_stats s || return 1
  assert_eq "free_blocks after hole file" "${s[free_blocks]}" "$((base[free_blocks] - 3))" || return 1
  assert_eq "committed_blocks after hole file" "${s[committed_blocks]}" "$((base[committed_blocks] + 3))" || return 1
  assert_eq "files after hole file" "${s[files]}" "$((base[files] + 1))" || return 1
  assert_eq "total_extents after hole file" "${s[total_extents]}" "$((base[total_extents] + 3))" || return 1
  assert_eq "max_file_size after hole file" "${s[max_file_size]}" "$(max_of "$expected_sz" "${base[max_file_size]}")" || return 1
  assert_eq "fragmentation after hole file" "${s[fragmentation]}" "$((${s[total_extents]} * 100 / ${s[files]}))" || return 1
  if [[ "${base[total_extents]}" -eq 0 ]]; then
    assert_eq "avg_extent_size after hole file" "${s[avg_extent_size]}" 100 || return 1
  fi
  assert_block_accounting s || return 1
}

# Verifies a sparse file with data on both sides of a hole reads correctly and
# keeps extent stats consistent with the hole.
test_read_with_hole() {
  local file="$MNT/sparse"
  cleanup_later "$file"

  local -A base=() s=()
  load_stats base || return 1

  local expected1="Hello hole!"
  local expected2="Bye hole :("
  local -i offset=4
  local -i hole_start=${#expected1}
  local -i hole_end=$((BLOCK_SIZE * 2 + offset))
  local -i hole_len=$((hole_end - hole_start))
  local -i expected_sz=$((hole_end + ${#expected2}))

  # dd seek/skip are in units of bs — use bs=1 for byte offsets
  prf "$expected1" | dd of="$file" bs=1 count=${#expected1} 2>/dev/null
  prf "$expected2" | dd of="$file" bs=1 count=${#expected2} seek="$hole_end" conv=notrunc 2>/dev/null

  local actual_size
  actual_size=$(stat -c '%s' "$file")
  if [[ "$actual_size" -ne "$expected_sz" ]]; then
    pr_err "Expected size $expected_sz but got $actual_size"
    return 1
  fi

  local actual
  actual=$(dd if="$file" bs=1 count=${#expected1} 2>/dev/null)
  if [[ "$actual" != "$expected1" ]]; then
    pr_err "Expected '$expected1' but got '$actual'"
    return 1
  fi

  # Hole between expected1 and expected2 must read as zeros
  if ! dd if="$file" bs=1 skip="$hole_start" count="$hole_len" 2>/dev/null |
    cmp -s /dev/zero - --bytes="$hole_len"; then
    pr_err "Hole contains non-zero data"
    return 1
  fi

  actual=$(dd if="$file" bs=1 skip="$hole_end" count=${#expected2} 2>/dev/null)
  if [[ "$actual" != "$expected2" ]]; then
    pr_err "Expected '$expected2' but got '$actual'"
    return 1
  fi

  # Extents: data (blk0), hole (blk1), data (blk2). Hole blocks still count
  # toward avg_extent_size via accumulated_extents_count.
  load_stats s || return 1
  assert_eq "free_blocks after sparse file" "${s[free_blocks]}" "$((base[free_blocks] - 3))" || return 1
  assert_eq "committed_blocks after sparse file" "${s[committed_blocks]}" "$((base[committed_blocks] + 3))" || return 1
  assert_eq "files after sparse file" "${s[files]}" "$((base[files] + 1))" || return 1
  assert_eq "total_extents after sparse file" "${s[total_extents]}" "$((base[total_extents] + 3))" || return 1
  assert_eq "max_file_size after sparse file" "${s[max_file_size]}" "$(max_of "$expected_sz" "${base[max_file_size]}")" || return 1
  assert_eq "fragmentation after sparse file" "${s[fragmentation]}" "$((${s[total_extents]} * 100 / ${s[files]}))" || return 1
  if [[ "${base[total_extents]}" -eq 0 ]]; then
    assert_eq "avg_extent_size after sparse file" "${s[avg_extent_size]}" 100 || return 1
  fi
  assert_block_accounting s || return 1
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

# Verifies that shrinking a file with truncate(2) actually deallocates blocks.
# A file written sequentially lives in a single extent, so the new end of file
# falls inside that extent and only its tail may be freed.
test_truncate_smaller_frees_blocks() {
  local file="$MNT/trunc_small"
  cleanup_later "$file"

  local -i initial_blocks=20
  local -i new_size=8097
  # ceil(8097 / BLOCK_SIZE) data blocks + the index block
  local -i expected_blocks=$((((new_size + BLOCK_SIZE - 1) / BLOCK_SIZE) + 1))

  dd if=/dev/urandom of="$file" bs="$BLOCK_SIZE" count="$initial_blocks" 2>/dev/null

  local -i blocks_before
  blocks_before=$(stat -c '%b' "$file")
  if [[ "$blocks_before" -ne $((initial_blocks + 1)) ]]; then
    pr_err "Expected $((initial_blocks + 1)) blocks before truncate, got $blocks_before"
    return 1
  fi

  truncate -s "$new_size" "$file"

  local -i actual_size blocks_after
  actual_size=$(stat -c '%s' "$file")
  blocks_after=$(stat -c '%b' "$file")

  if [[ "$actual_size" -ne "$new_size" ]]; then
    pr_err "Expected size $new_size after truncate, got $actual_size"
    return 1
  fi

  if [[ "$blocks_after" -ne "$expected_blocks" ]]; then
    pr_err "Truncation smaller mismatch. Size: $actual_size, Blocks: $blocks_before -> $blocks_after (expected $expected_blocks)"
    return 1
  fi

  # The surviving data must be untouched
  local -i tail_len=$((new_size - BLOCK_SIZE))
  if ! dd if="$file" bs=1 skip="$BLOCK_SIZE" count="$tail_len" 2>/dev/null |
    wc -c | grep -qx "$tail_len"; then
    pr_err "Could not read back $tail_len bytes after truncate"
    return 1
  fi
}

# Verifies that truncating to a size inside a hole releases the trailing extents
# without touching the surviving hole blocks.
test_truncate_smaller_multi_extent() {
  local file="$MNT/trunc_multi"
  cleanup_later "$file"

  # data block 0, hole blocks 1-2, data block 3 -> three extents
  prf "head" >"$file"
  prf "tail" | dd of="$file" bs=1 seek=$((BLOCK_SIZE * 3)) conv=notrunc 2>/dev/null

  local -i blocks_before
  blocks_before=$(stat -c '%b' "$file")

  # keep block 0 and the first hole block only
  local -i new_size=$((BLOCK_SIZE * 2))
  truncate -s "$new_size" "$file"

  local -i actual_size blocks_after
  actual_size=$(stat -c '%s' "$file")
  blocks_after=$(stat -c '%b' "$file")

  if [[ "$actual_size" -ne "$new_size" ]]; then
    pr_err "Expected size $new_size after truncate, got $actual_size"
    return 1
  fi

  # only block 0 is a real data block, plus the index block
  if [[ "$blocks_after" -ne 2 ]]; then
    pr_err "Expected 2 blocks after truncate, got $blocks_after (was $blocks_before)"
    return 1
  fi

  local actual
  actual=$(dd if="$file" bs=1 count=4 2>/dev/null)
  if [[ "$actual" != "head" ]]; then
    pr_err "Expected 'head' after truncate, got '$actual'"
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

# Verifies writing at the beginning of a hole for amounts smaller, equal and
# larger than the hole. File size must stay unchanged (writes are within EOF).
test_write_hole_beginning() {
  local -i hole_blocks=4
  _test_write_into_hole "begin" "$hole_blocks" 0 || return 1
}

# Verifies writing in the middle of a hole for amounts smaller, equal and
# larger than the hole. File size must stay unchanged.
test_write_hole_middle() {
  local -i hole_blocks=4
  # start at block 1 of a 4-block hole → leaves a hole on both sides for small writes
  _test_write_into_hole "middle" "$hole_blocks" 1 || return 1
}

# Verifies writing at the end of a hole for amounts smaller, equal and larger
# than the hole. File size must stay unchanged.
test_write_hole_end() {
  local -i hole_blocks=4
  _test_write_into_hole "end" "$hole_blocks" -1 || return 1
}

# Verifies that filling a hole cannot create more extents than OUICHEFS_MAX_EXTENTS.
# A middle-of-hole write that would need two new slots must fail once the index
# is full, and the file size must remain unchanged.
test_write_hole_max_extents() {
  local file="$MNT/max_ext"
  cleanup_later "$file"

  local -A s=() base=()
  load_stats base || return 1
  printf '%s\n' 0 >"${base[sysfs_path]}/reservation_size"

  # Layout: [D][H3][D] then (H1,D)*254 → 511 extents, one free slot.
  # Middle write into H3 needs shift_by=2 → ENOSPC.
  dd if=/dev/zero of="$file" bs="$BLOCK_SIZE" count=1 2>/dev/null || {
    printf '%s\n' "$DEFAULT_RESERVATION_WINDOW" >"${base[sysfs_path]}/reservation_size"
    pr_err "failed to write leading data block"
    return 1
  }
  dd if=/dev/zero of="$file" bs="$BLOCK_SIZE" seek=4 count=1 conv=notrunc 2>/dev/null || {
    printf '%s\n' "$DEFAULT_RESERVATION_WINDOW" >"${base[sysfs_path]}/reservation_size"
    pr_err "failed to create initial hole+trailing data"
    return 1
  }

  local -i next_block=6
  local -i target_extents=$((OUICHEFS_MAX_EXTENTS - 1))
  local -i cur_extents=3
  while [[ "$cur_extents" -lt "$target_extents" ]]; do
    dd if=/dev/zero of="$file" bs="$BLOCK_SIZE" seek="$next_block" count=1 conv=notrunc 2>/dev/null || {
      printf '%s\n' "$DEFAULT_RESERVATION_WINDOW" >"${base[sysfs_path]}/reservation_size"
      pr_err "failed to grow extent list at block $next_block"
      return 1
    }
    next_block=$((next_block + 2))
    cur_extents=$((cur_extents + 2))
  done

  load_stats s || {
    printf '%s\n' "$DEFAULT_RESERVATION_WINDOW" >"${base[sysfs_path]}/reservation_size"
    return 1
  }
  assert_eq "extents before overflow write" "${s[total_extents]}" "$((base[total_extents] + target_extents))" || {
    printf '%s\n' "$DEFAULT_RESERVATION_WINDOW" >"${base[sysfs_path]}/reservation_size"
    return 1
  }

  local -i expected_sz
  expected_sz=$(stat -c '%s' "$file")
  local -i extents_before=${s[total_extents]}
  local -i committed_before=${s[committed_blocks]}
  local -i free_before=${s[free_blocks]}

  # Write one block into the middle of the leading 3-block hole (logical blk 2)
  if dd if=/dev/urandom of="$file" bs="$BLOCK_SIZE" seek=2 count=1 conv=notrunc 2>/dev/null; then
    printf '%s\n' "$DEFAULT_RESERVATION_WINDOW" >"${s[sysfs_path]}/reservation_size"
    pr_err "write into hole should fail when max extents would be exceeded"
    return 1
  fi

  local actual_size
  actual_size=$(stat -c '%s' "$file")
  if [[ "$actual_size" -ne "$expected_sz" ]]; then
    printf '%s\n' "$DEFAULT_RESERVATION_WINDOW" >"${s[sysfs_path]}/reservation_size"
    pr_err "Expected size $expected_sz after failed hole write, got $actual_size"
    return 1
  fi

  # Hole must still read as zeros
  if ! dd if="$file" bs="$BLOCK_SIZE" skip=2 count=1 2>/dev/null |
    cmp -s /dev/zero - --bytes="$BLOCK_SIZE"; then
    printf '%s\n' "$DEFAULT_RESERVATION_WINDOW" >"${s[sysfs_path]}/reservation_size"
    pr_err "hole was modified despite failed write"
    return 1
  fi

  load_stats s || {
    printf '%s\n' "$DEFAULT_RESERVATION_WINDOW" >"${s[sysfs_path]}/reservation_size"
    return 1
  }
  assert_eq "total_extents after failed overflow" "${s[total_extents]}" "$extents_before" || {
    printf '%s\n' "$DEFAULT_RESERVATION_WINDOW" >"${s[sysfs_path]}/reservation_size"
    return 1
  }
  assert_eq "committed_blocks after failed overflow" "${s[committed_blocks]}" "$committed_before" || {
    printf '%s\n' "$DEFAULT_RESERVATION_WINDOW" >"${s[sysfs_path]}/reservation_size"
    return 1
  }
  assert_eq "free_blocks after failed overflow" "${s[free_blocks]}" "$free_before" || {
    printf '%s\n' "$DEFAULT_RESERVATION_WINDOW" >"${s[sysfs_path]}/reservation_size"
    return 1
  }
  assert_eq "max_file_size after failed overflow" "${s[max_file_size]}" "$expected_sz" || {
    printf '%s\n' "$DEFAULT_RESERVATION_WINDOW" >"${s[sysfs_path]}/reservation_size"
    return 1
  }
  assert_block_accounting s || {
    printf '%s\n' "$DEFAULT_RESERVATION_WINDOW" >"${s[sysfs_path]}/reservation_size"
    return 1
  }

  printf '%s\n' "$DEFAULT_RESERVATION_WINDOW" >"${s[sysfs_path]}/reservation_size"
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
# Usage: $bin <file|open fd> <ctl device> [defrag]
# Without a third argument the binary issues OUICHEFS_IOC_GET_EXTENTS.
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

  rm -f "$device_ref"
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
	unsigned long request = OUICHEFS_IOC_GET_EXTENTS;

	if (argc < 3) return 1;

	if (argc > 3 && argv[3][0] == '\''d'\'')
		request = OUICHEFS_IOC_DEFRAG_FILE;

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
	if (ioctl(ctl, request, &fd) < 0) {
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

# Verifies that defragmentation merges the extents of a fragmented sparse file.
#
# Two files are written alternately so that file B splits file A's physical
# runs; A additionally gets a hole. Every write closes its fd, otherwise A's
# leftover reservation window would absorb B's allocation and A would stay
# contiguous. Layout of A:
#
#   [data 2][data 1][hole 1][data 1]              → 4 extents
#   defrag: the two data runs are copied together → 3 extents
#            [data 3][hole 1][data 1]
#
# The hole stops the merge, so the trailing data run stays its own extent.
test_defrag_fragmented_file() {
  local device ioctl_test_bin
  local file_a="$MNT/defrag_a"
  local file_b="$MNT/defrag_b"
  local pattern="/tmp/ouiche_defrag_pat"
  local ref="/tmp/ouiche_defrag_ref"
  local got="/tmp/ouiche_defrag_got"
  cleanup_later "$file_a" "$file_b" "$pattern" "$ref" "$got"

  local -A base=() s=()
  load_stats base || return 1

  if ! setup_ioctl_test device ioctl_test_bin; then
    return 1
  fi

  # 4 distinct data blocks so a defrag that loses or reorders data is caught
  dd if=/dev/urandom of="$pattern" bs="$BLOCK_SIZE" count=4 2>/dev/null

  # A: logical blocks 0-1
  dd if="$pattern" of="$file_a" bs=$((2 * BLOCK_SIZE)) count=1 2>/dev/null || {
    pr_err "failed to write first two blocks of A"
    return 1
  }
  # B: takes the blocks right behind A, breaking A's contiguity
  dd if=/dev/zero of="$file_b" bs="$BLOCK_SIZE" count=1 2>/dev/null || {
    pr_err "failed to write B"
    return 1
  }
  # A: logical block 2, now in a second physical run
  dd if="$pattern" of="$file_a" bs="$BLOCK_SIZE" skip=2 seek=2 count=1 conv=notrunc 2>/dev/null || {
    pr_err "failed to append third block of A"
    return 1
  }
  # A: logical block 4, leaving block 3 as a hole
  dd if="$pattern" of="$file_a" bs="$BLOCK_SIZE" skip=3 seek=4 count=1 conv=notrunc 2>/dev/null || {
    pr_err "failed to write A past the hole"
    return 1
  }

  local -i expected_sz=$((5 * BLOCK_SIZE))
  local actual_size
  actual_size=$(stat -c '%s' "$file_a")
  if [[ "$actual_size" -ne "$expected_sz" ]]; then
    pr_err "Expected size $expected_sz for A, got $actual_size"
    return 1
  fi

  local -i n_ext
  n_ext=$(count_file_extents "$file_a" "$device" "$ioctl_test_bin") || return 1
  if [[ "$n_ext" -ne 4 ]]; then
    pr_err "Expected 4 extents for the fragmented file, got $n_ext"
    dmesg | grep 'start=' || true
    return 1
  fi

  # A contributes 4 extents, B a single one
  local -i expect_files=$((base[files] + 2))
  local -i expect_extents=$((base[total_extents] + 5))
  load_stats s || return 1
  assert_eq "files before defrag" "${s[files]}" "$expect_files" || return 1
  assert_eq "total_extents before defrag" "${s[total_extents]}" "$expect_extents" || return 1
  assert_eq "fragmentation before defrag" "${s[fragmentation]}" "$((expect_extents * 100 / expect_files))" || return 1

  if ! "$ioctl_test_bin" "$file_a" "$device" defrag; then
    pr_err "defrag ioctl failed"
    return 1
  fi

  n_ext=$(count_file_extents "$file_a" "$device" "$ioctl_test_bin") || return 1
  if [[ "$n_ext" -ne 3 ]]; then
    pr_err "Expected 3 extents after defrag, got $n_ext"
    dmesg | grep 'start=' || true
    return 1
  fi

  # The two data runs of A collapsed into one; B is untouched.
  expect_extents=$((base[total_extents] + 4))
  load_stats s || return 1
  assert_eq "files after defrag" "${s[files]}" "$expect_files" || return 1
  assert_eq "total_extents after defrag" "${s[total_extents]}" "$expect_extents" || return 1
  assert_eq "fragmentation after defrag" "${s[fragmentation]}" "$((expect_extents * 100 / expect_files))" || return 1

  actual_size=$(stat -c '%s' "$file_a")
  if [[ "$actual_size" -ne "$expected_sz" ]]; then
    pr_err "Expected size $expected_sz after defrag, got $actual_size"
    return 1
  fi

  # Reference: blocks 0-2 of the pattern, a zero-filled block, then block 3.
  dd if="$pattern" of="$ref" bs="$BLOCK_SIZE" count=3 2>/dev/null
  dd if="$pattern" of="$ref" bs="$BLOCK_SIZE" skip=3 seek=4 count=1 conv=notrunc 2>/dev/null
  if ! dd if="$file_a" of="$got" bs="$BLOCK_SIZE" 2>/dev/null; then
    pr_err "failed to read A back after defrag"
    return 1
  fi
  if ! cmp -s "$ref" "$got"; then
    pr_err "content of A changed during defrag"
    return 1
  fi

  echo "Confirmed: defrag reduced A from 4 to $n_ext extent(s)"
}

# Verifies that a fully mergeable layout reaches a fragmentation of 400 and that
# defragmentation brings it back down to 100.
#
# A and B are appended to alternately, one block at a time, and every write
# closes its fd so the leftover reservation window is released. Each append
# therefore lands behind the other file's newest block and has to start a new
# extent:
#
#   A: [1][1][1][1]   B: [1][1][1][1]   → 8 extents / 2 files → fragmentation 400
#
# No holes are involved, so nothing stops the merge: each file collapses into a
# single extent → 2 extents / 2 files → fragmentation 100.
test_defrag_mergeable_fragmentation() {
  local device ioctl_test_bin
  local file_a="$MNT/frag400_a"
  local file_b="$MNT/frag400_b"
  local pattern="/tmp/ouiche_frag400_pat"
  local ref_a="/tmp/ouiche_frag400_ref_a"
  local ref_b="/tmp/ouiche_frag400_ref_b"
  local got="/tmp/ouiche_frag400_got"
  cleanup_later "$file_a" "$file_b" "$pattern" "$ref_a" "$ref_b" "$got"

  local -A base=() s=()
  load_stats base || return 1

  if ! setup_ioctl_test device ioctl_test_bin; then
    return 1
  fi

  # One extent per block, so 4 blocks per file give the 8 extents we want.
  local -i blocks_per_file=4
  local -i total_blocks=$((2 * blocks_per_file))
  dd if=/dev/urandom of="$pattern" bs="$BLOCK_SIZE" count="$total_blocks" 2>/dev/null
  : >"$ref_a"
  : >"$ref_b"

  # A takes the even pattern blocks, B the odd ones; the references are built
  # from the same blocks so a defrag that reorders data is caught later on.
  local -i i
  for ((i = 0; i < blocks_per_file; i++)); do
    if ! dd if="$pattern" of="$file_a" bs="$BLOCK_SIZE" skip=$((2 * i)) seek="$i" count=1 conv=notrunc 2>/dev/null ||
      ! dd if="$pattern" of="$ref_a" bs="$BLOCK_SIZE" skip=$((2 * i)) seek="$i" count=1 conv=notrunc 2>/dev/null; then
      pr_err "failed to append block $i of A"
      return 1
    fi
    if ! dd if="$pattern" of="$file_b" bs="$BLOCK_SIZE" skip=$((2 * i + 1)) seek="$i" count=1 conv=notrunc 2>/dev/null ||
      ! dd if="$pattern" of="$ref_b" bs="$BLOCK_SIZE" skip=$((2 * i + 1)) seek="$i" count=1 conv=notrunc 2>/dev/null; then
      pr_err "failed to append block $i of B"
      return 1
    fi
  done

  local -i expected_sz=$((blocks_per_file * BLOCK_SIZE))
  local actual_size
  local f
  for f in "$file_a" "$file_b"; do
    actual_size=$(stat -c '%s' "$f")
    if [[ "$actual_size" -ne "$expected_sz" ]]; then
      pr_err "Expected size $expected_sz for $f, got $actual_size"
      return 1
    fi
  done

  local -i n_ext_a n_ext_b
  n_ext_a=$(count_file_extents "$file_a" "$device" "$ioctl_test_bin") || return 1
  n_ext_b=$(count_file_extents "$file_b" "$device" "$ioctl_test_bin") || return 1
  if [[ "$n_ext_a" -ne "$blocks_per_file" || "$n_ext_b" -ne "$blocks_per_file" ]]; then
    pr_err "Expected $blocks_per_file extents per file, got A=$n_ext_a B=$n_ext_b"
    return 1
  fi

  local -i expect_files=$((base[files] + 2))
  local -i expect_extents=$((base[total_extents] + total_blocks))
  local -i clean=0
  if [[ "${base[files]}" -eq 0 && "${base[total_extents]}" -eq 0 ]]; then
    clean=1
  fi

  load_stats s || return 1
  assert_eq "files before defrag" "${s[files]}" "$expect_files" || return 1
  assert_eq "total_extents before defrag" "${s[total_extents]}" "$expect_extents" || return 1
  assert_eq "fragmentation before defrag" "${s[fragmentation]}" "$((expect_extents * 100 / expect_files))" || return 1
  if [[ "$clean" -eq 1 ]]; then
    assert_eq "fragmentation of 8 extents over 2 files" "${s[fragmentation]}" 400 || return 1
    # every extent holds a single block
    assert_eq "avg_extent_size before defrag" "${s[avg_extent_size]}" "$((total_blocks * 100 / expect_extents))" || return 1
  fi
  assert_block_accounting s || return 1
  local -i frag_before=${s[fragmentation]}

  # Defragmenting A must not touch B.
  if ! "$ioctl_test_bin" "$file_a" "$device" defrag; then
    pr_err "defrag ioctl on A failed"
    return 1
  fi

  n_ext_a=$(count_file_extents "$file_a" "$device" "$ioctl_test_bin") || return 1
  n_ext_b=$(count_file_extents "$file_b" "$device" "$ioctl_test_bin") || return 1
  if [[ "$n_ext_a" -ne 1 || "$n_ext_b" -ne "$blocks_per_file" ]]; then
    pr_err "After defrag of A expected A=1 B=$blocks_per_file extents, got A=$n_ext_a B=$n_ext_b"
    return 1
  fi

  expect_extents=$((base[total_extents] + blocks_per_file + 1))
  load_stats s || return 1
  assert_eq "total_extents after defrag of A" "${s[total_extents]}" "$expect_extents" || return 1
  assert_eq "fragmentation after defrag of A" "${s[fragmentation]}" "$((expect_extents * 100 / expect_files))" || return 1
  assert_block_accounting s || return 1

  if ! "$ioctl_test_bin" "$file_b" "$device" defrag; then
    pr_err "defrag ioctl on B failed"
    return 1
  fi

  n_ext_a=$(count_file_extents "$file_a" "$device" "$ioctl_test_bin") || return 1
  n_ext_b=$(count_file_extents "$file_b" "$device" "$ioctl_test_bin") || return 1
  if [[ "$n_ext_a" -ne 1 || "$n_ext_b" -ne 1 ]]; then
    pr_err "After defrag of both expected 1 extent each, got A=$n_ext_a B=$n_ext_b"
    return 1
  fi

  expect_extents=$((base[total_extents] + 2))
  load_stats s || return 1
  assert_eq "files after defrag" "${s[files]}" "$expect_files" || return 1
  assert_eq "total_extents after defrag" "${s[total_extents]}" "$expect_extents" || return 1
  assert_eq "fragmentation after defrag" "${s[fragmentation]}" "$((expect_extents * 100 / expect_files))" || return 1
  if [[ "$clean" -eq 1 ]]; then
    assert_eq "fragmentation of 2 extents over 2 files" "${s[fragmentation]}" 100 || return 1
    # defrag moves blocks around but must not change the accumulated count
    assert_eq "avg_extent_size after defrag" "${s[avg_extent_size]}" "$((total_blocks * 100 / expect_extents))" || return 1
  fi
  assert_block_accounting s || return 1

  # Content must have survived the block copying; cmp also catches a size change.
  if ! dd if="$file_a" of="$got" bs="$BLOCK_SIZE" 2>/dev/null || ! cmp -s "$ref_a" "$got"; then
    pr_err "content of A changed during defrag"
    return 1
  fi
  if ! dd if="$file_b" of="$got" bs="$BLOCK_SIZE" 2>/dev/null || ! cmp -s "$ref_b" "$got"; then
    pr_err "content of B changed during defrag"
    return 1
  fi

  echo "Confirmed: fragmentation $frag_before -> ${s[fragmentation]} after defragmenting both files"
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
  assert_eq "clean committed_blocks" "${s[committed_blocks]}" "$INITIAL_COMMITTED_BLOCKS" || return 1
  assert_eq "clean reserved_blocks" "${s[reserved_blocks]}" 0 || return 1
  assert_eq "clean files" "${s[files]}" 0 || return 1
  assert_eq "clean total_extents" "${s[total_extents]}" 0 || return 1
  assert_eq "clean avg_extent_size" "${s[avg_extent_size]}" 0 || return 1
  assert_eq "clean max_file_size" "${s[max_file_size]}" 0 || return 1
  assert_eq "clean fragmentation" "${s[fragmentation]}" 0 || return 1
  assert_block_accounting s || return 1
}

# reservation_size is read-write.
test_stats_reservation_size() {
  local -A s=()
  load_stats s || return 1

  local initial=${s[reservation_size]}
  local new_window=16
  if [[ "$initial" -eq 16 ]]; then
    new_window=32
  fi

  if ! printf '%s\n' "$new_window" >"${s[sysfs_path]}/reservation_size"; then
    pr_err "failed to write reservation_size"
    return 1
  fi
  load_stats s || return 1
  assert_eq "reservation_size after store" "${s[reservation_size]}" "$new_window" || return 1

  printf '%s\n' "$initial" >"${s[sysfs_path]}/reservation_size"
  load_stats s || return 1
  assert_eq "reservation_size restored" "${s[reservation_size]}" "$initial" || return 1
}

# Small-file block accounting: create (−2 free), in-block append (unchanged), unlink (≥2 freed).
test_stats_file_blocks() {
  local -A base=() s=()
  load_stats base || return 1

  local file="$MNT/stats_small"
  cleanup_later "$file"

  local content="Hello stats!"
  local content_len=${#content}
  prf "$content" >"$file"

  load_stats s || return 1
  assert_eq "free_blocks after small file" "${s[free_blocks]}" "$((base[free_blocks] - 2))" || return 1
  assert_eq "committed_blocks after small file" "${s[committed_blocks]}" "$((base[committed_blocks] + 2))" || return 1
  assert_eq "reserved_blocks after close" "${s[reserved_blocks]}" 0 || return 1
  assert_eq "files after small file" "${s[files]}" "$((base[files] + 1))" || return 1
  assert_eq "total_extents after small file" "${s[total_extents]}" "$((base[total_extents] + 1))" || return 1
  assert_eq "max_file_size after small file" "${s[max_file_size]}" "$(max_of "$content_len" "${base[max_file_size]}")" || return 1
  assert_eq "fragmentation after small file" "${s[fragmentation]}" "$((${s[total_extents]} * 100 / ${s[files]}))" || return 1
  if [[ "${base[total_extents]}" -eq 0 ]]; then
    assert_eq "avg_extent_size after small file" "${s[avg_extent_size]}" 100 || return 1
  fi
  assert_block_accounting s || return 1

  local free_before=${s[free_blocks]}
  local committed_before=${s[committed_blocks]}
  prf "!" >>"$file"
  load_stats s || return 1
  assert_eq "free_blocks after in-block append" "${s[free_blocks]}" "$free_before" || return 1
  assert_eq "committed_blocks after in-block append" "${s[committed_blocks]}" "$committed_before" || return 1
  assert_eq "max_file_size after in-block append" "${s[max_file_size]}" "$(max_of "$((content_len + 1))" "${base[max_file_size]}")" || return 1

  free_before=${s[free_blocks]}
  rm -f "$file"
  load_stats s || return 1
  local freed=$((${s[free_blocks]} - free_before))
  if [[ "$freed" -lt 2 ]]; then
    pr_err "expected at least 2 blocks freed on unlink, got $freed"
    return 1
  fi
  assert_eq "blocks freed for small file" "$freed" 2 || return 1
  assert_eq "free_blocks after delete" "${s[free_blocks]}" "${base[free_blocks]}" || return 1
  assert_eq "files after delete" "${s[files]}" "${base[files]}" || return 1
  assert_eq "max_file_size after delete" "${s[max_file_size]}" "${base[max_file_size]}" || return 1
  assert_block_accounting s || return 1
}

# reserved_blocks tracks the open-fd reservation window leftover; close releases it.
test_stats_reserved_blocks() {
  local -A base=() s=()
  load_stats base || return 1

  local file="$MNT/stats_reserved"
  cleanup_later "$file"

  printf '%s\n' "$DEFAULT_RESERVATION_WINDOW" >"${base[sysfs_path]}/reservation_size"

  exec 3>"$file"
  trap 'exec 3>&-' RETURN
  dd if=/dev/zero bs="$BLOCK_SIZE" count=1 >&3 2>/dev/null

  load_stats s || return 1
  assert_eq "reserved_blocks while open" "${s[reserved_blocks]}" "$DEFAULT_RESERVATION_WINDOW" || return 1
  assert_eq "committed_blocks while open" "${s[committed_blocks]}" "$((base[committed_blocks] + 2))" || return 1
  assert_eq "free_blocks while open" "${s[free_blocks]}" "$((base[free_blocks] - 2 - DEFAULT_RESERVATION_WINDOW))" || return 1
  assert_block_accounting s || return 1

  exec 3>&-
  trap - RETURN

  load_stats s || return 1
  assert_eq "reserved_blocks after close" "${s[reserved_blocks]}" 0 || return 1
  assert_eq "free_blocks after close" "${s[free_blocks]}" "$((base[free_blocks] - 2))" || return 1
  assert_block_accounting s || return 1
}

# total_extents / avg_extent_size / fragmentation for contiguous and fragmented layouts.
test_stats_extents() {
  local -A base=() s=()
  load_stats base || return 1

  local file="$MNT/stats_ext"
  local other="$MNT/stats_ext_other"
  cleanup_later "$file" "$other"

  local -i multi_blocks=3
  local -i multi_bytes=$((multi_blocks * BLOCK_SIZE))

  dd if=/dev/zero of="$file" bs="$multi_bytes" count=1 2>/dev/null
  load_stats s || return 1
  assert_eq "free_blocks after 3-block file" "${s[free_blocks]}" "$((base[free_blocks] - 1 - multi_blocks))" || return 1
  assert_eq "files after 3-block file" "${s[files]}" "$((base[files] + 1))" || return 1
  assert_eq "total_extents after 3-block file" "${s[total_extents]}" "$((base[total_extents] + 1))" || return 1
  assert_eq "max_file_size after 3-block file" "${s[max_file_size]}" "$(max_of "$multi_bytes" "${base[max_file_size]}")" || return 1
  assert_eq "fragmentation after 3-block file" "${s[fragmentation]}" "$((${s[total_extents]} * 100 / ${s[files]}))" || return 1
  if [[ "${base[total_extents]}" -eq 0 ]]; then
    assert_eq "avg_extent_size after 3-block file" "${s[avg_extent_size]}" "$((multi_blocks * 100))" || return 1
  fi

  # Disable reservations so the spacer file sits on the next physical block and
  # the append cannot coalesce into the first extent.
  printf '%s\n' 0 >"${s[sysfs_path]}/reservation_size"
  rm -f "$file"
  dd if=/dev/zero of="$file" bs="$multi_bytes" count=1 2>/dev/null
  dd if=/dev/zero of="$other" bs="$BLOCK_SIZE" count=1 2>/dev/null
  dd if=/dev/zero of="$file" bs="$BLOCK_SIZE" seek="$multi_blocks" count=1 conv=notrunc 2>/dev/null
  printf '%s\n' "$DEFAULT_RESERVATION_WINDOW" >"${s[sysfs_path]}/reservation_size"

  load_stats s || return 1
  assert_eq "files with two files" "${s[files]}" "$((base[files] + 2))" || return 1
  # file: 2 extents (3+1), other: 1 extent
  assert_eq "total_extents fragmented" "${s[total_extents]}" "$((base[total_extents] + 3))" || return 1
  assert_eq "fragmentation fragmented" "${s[fragmentation]}" "$((${s[total_extents]} * 100 / ${s[files]}))" || return 1
  assert_eq "max_file_size after append" "${s[max_file_size]}" "$(max_of "$(((multi_blocks + 1) * BLOCK_SIZE))" "${base[max_file_size]}")" || return 1
  if [[ "${base[total_extents]}" -eq 0 ]]; then
    assert_eq "avg_extent_size fragmented" "${s[avg_extent_size]}" $((5 * 100 / 3)) || return 1
  fi
  assert_block_accounting s || return 1
}

# max_file_size tracks the largest file and is recomputed when it is removed.
test_stats_max_file_size() {
  local -A base=() s=()
  load_stats base || return 1

  local small="$MNT/stats_max_small"
  local large="$MNT/stats_max_large"
  cleanup_later "$small" "$large"

  local -i small_sz=$((2 * BLOCK_SIZE))
  local -i large_sz=$((5 * BLOCK_SIZE))

  dd if=/dev/zero of="$small" bs="$small_sz" count=1 2>/dev/null
  load_stats s || return 1
  assert_eq "max_file_size after small" "${s[max_file_size]}" "$(max_of "$small_sz" "${base[max_file_size]}")" || return 1

  dd if=/dev/zero of="$large" bs="$large_sz" count=1 2>/dev/null
  load_stats s || return 1
  assert_eq "max_file_size after large" "${s[max_file_size]}" "$(max_of "$large_sz" "${base[max_file_size]}")" || return 1

  rm -f "$large"
  load_stats s || return 1
  assert_eq "max_file_size after removing largest" "${s[max_file_size]}" "$(max_of "$small_sz" "${base[max_file_size]}")" || return 1

  rm -f "$small"
  load_stats s || return 1
  assert_eq "max_file_size after removing all" "${s[max_file_size]}" "${base[max_file_size]}" || return 1
}

# Force a GC pass and verify gc_runs in sysfs increases.
test_stats_gc_runs() {
  local -A s=()
  load_stats s || return 1
  local -i initial_gc=${s[gc_runs]}

  if ! force_ouichefs_gc; then
    pr_err "failed to force a GC pass"
    return 1
  fi

  load_stats s || return 1
  if [[ "${s[gc_runs]}" -le "$initial_gc" ]]; then
    pr_err "gc_runs did not increase (initial=$initial_gc final=${s[gc_runs]})"
    return 1
  fi
  echo "gc_runs $initial_gc -> ${s[gc_runs]}"
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
  committed_blocks
  reserved_blocks
  files
  total_extents
  avg_extent_size
  max_file_size
  fragmentation
  reservation_size
  gc_runs
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

# Print how many extents a file currently has, via GET_EXTENTS + dmesg.
# Usage: count_file_extents <file> <ctl device> <ioctl helper>
count_file_extents() {
  local file=$1
  local device=$2
  local bin=$3

  dmesg -C 2>/dev/null || true
  if ! "$bin" "$file" "$device"; then
    pr_err "ioctl on $file failed"
    return 1
  fi

  local -i n_ext
  n_ext=$(dmesg | grep -c 'start=') || n_ext=0
  printf '%s\n' "$n_ext"
}

# Print the larger of two integers.
max_of() {
  if [[ "$1" -ge "$2" ]]; then
    printf '%s\n' "$1"
  else
    printf '%s\n' "$2"
  fi
}

# Create a sparse file: [1 data block][hole_blocks hole][1 data block].
# Extents: data, hole, data. Physical: index + 2 data blocks.
create_hole_file() {
  local file=$1
  local -i hole_blocks=$2

  dd if=/dev/zero of="$file" bs="$BLOCK_SIZE" count=1 2>/dev/null || return 1
  dd if=/dev/zero of="$file" bs="$BLOCK_SIZE" seek=$((1 + hole_blocks)) count=1 conv=notrunc 2>/dev/null || return 1
}

# Extents added by filling @alloc blocks of a @hole-block hole at offset @off
# with a single write(). Holes are never coalesced with adjacent data extents.
#   [0, hole)    → hole disappears, extent reused          → +0
#   [0, alloc)   → data | hole_suffix                      → +1
#   [off, hole)  → hole_prefix | data                      → +1
#   middle       → hole_prefix | data | hole_suffix        → +2
hole_extent_delta() {
  local -i hole=$1
  local -i off=$2
  local -i alloc=$3

  if [[ "$off" -eq 0 ]]; then
    if [[ "$alloc" -lt "$hole" ]]; then
      printf '%s\n' 1
    else
      printf '%s\n' 0
    fi
  else
    if [[ $((off + alloc)) -eq "$hole" ]]; then
      printf '%s\n' 1
    else
      printf '%s\n' 2
    fi
  fi
}

# Compile the single-write helper. dd retries short writes, which would spill
# past the hole, so an oversized write() needs a dedicated one-syscall tool.
# Usage: $bin <file> <byte offset> <length> <pattern file> → prints bytes written.
setup_single_write_tool() {
  local -n bin_ref=$1
  local src="/tmp/ouichefs_single_write.c"
  bin_ref="/tmp/ouichefs_single_write"

  printf '%s\n' '
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	if (argc < 5)
		return 1;

	off_t off = strtoll(argv[2], NULL, 10);
	size_t len = strtoull(argv[3], NULL, 10);

	char *buf = malloc(len);
	if (!buf)
		return 1;

	int src = open(argv[4], O_RDONLY);
	if (src < 0) {
		perror("open pattern");
		return 1;
	}

	size_t filled = 0;
	while (filled < len) {
		ssize_t r = read(src, buf + filled, len - filled);
		if (r <= 0)
			break;
		filled += (size_t)r;
	}
	close(src);
	if (filled != len)
		return 1;

	int fd = open(argv[1], O_RDWR);
	if (fd < 0) {
		perror("open file");
		return 1;
	}
	if (lseek(fd, off, SEEK_SET) < 0) {
		perror("lseek");
		close(fd);
		return 1;
	}

	ssize_t written = write(fd, buf, len);
	if (written < 0) {
		perror("write");
		close(fd);
		return 1;
	}
	close(fd);

	printf("%zd\n", written);
	return 0;
}
' >"$src"

  if ! gcc -o "$bin_ref" "$src"; then
    pr_err "can't compile single-write helper"
    rm -f "$src"
    return 1
  fi
  cleanup_later "$src" "$bin_ref"
}

# Run smaller / equal / bigger-than-hole writes at a fixed hole offset.
# position: label for error messages (begin|middle|end)
# hole_offset: -1 means "end of hole" and is recomputed per write size.
#
# Every case is a single write(). A request reaching past the hole must be
# short: only the blocks left in the hole are allocated, and the trailing data
# block and the file size stay untouched.
_test_write_into_hole() {
  local position=$1
  local -i hole_blocks=$2
  local -i hole_offset=$3

  local -a sizes=($((hole_blocks / 2)) "$hole_blocks" $((hole_blocks + 2)))
  local -a size_labels=(smaller equal bigger)
  local -i i

  local single_write_bin
  setup_single_write_tool single_write_bin || return 1

  for i in 0 1 2; do
    local size_label=${size_labels[$i]}
    local -i write_blocks=${sizes[$i]}
    local file="$MNT/hole_${position}_${size_label}"
    local pattern="/tmp/ouiche_hole_pat_${position}_${size_label}"
    cleanup_later "$file" "$pattern"

    local -A base=() s=()
    load_stats base || return 1

    create_hole_file "$file" "$hole_blocks" || {
      pr_err "$position/$size_label: failed to create sparse file"
      return 1
    }

    local -i expected_sz=$(((2 + hole_blocks) * BLOCK_SIZE))
    local actual_size
    actual_size=$(stat -c '%s' "$file")
    if [[ "$actual_size" -ne "$expected_sz" ]]; then
      pr_err "$position/$size_label: Expected size $expected_sz after create, got $actual_size"
      return 1
    fi

    # Baseline after sparse create: index + 2 data, extents data|hole|data
    load_stats s || return 1
    assert_eq "$position/$size_label free after create" "${s[free_blocks]}" "$((base[free_blocks] - 3))" || return 1
    assert_eq "$position/$size_label committed after create" "${s[committed_blocks]}" "$((base[committed_blocks] + 3))" || return 1
    assert_eq "$position/$size_label extents after create" "${s[total_extents]}" "$((base[total_extents] + 3))" || return 1
    assert_eq "$position/$size_label files after create" "${s[files]}" "$((base[files] + 1))" || return 1
    assert_eq "$position/$size_label max_file_size after create" "${s[max_file_size]}" "$(max_of "$expected_sz" "${base[max_file_size]}")" || return 1
    assert_eq "$position/$size_label fragmentation after create" "${s[fragmentation]}" "$((${s[total_extents]} * 100 / ${s[files]}))" || return 1
    if [[ "${base[total_extents]}" -eq 0 ]]; then
      assert_eq "$position/$size_label avg after create" "${s[avg_extent_size]}" "$(((2 + hole_blocks) * 100 / 3))" || return 1
    fi
    assert_block_accounting s || return 1

    local -i off=$hole_offset
    if [[ "$off" -lt 0 ]]; then
      # End of hole: land on the tail when the request fits; else last block.
      if [[ "$write_blocks" -lt "$hole_blocks" ]]; then
        off=$((hole_blocks - write_blocks))
      else
        off=$((hole_blocks - 1))
      fi
    fi

    local -i seek_block=$((1 + off))
    local -i remaining=$((hole_blocks - off))
    local -i expect_alloc=$write_blocks
    if [[ "$expect_alloc" -gt "$remaining" ]]; then
      expect_alloc=$remaining
    fi

    local -i shift_by
    shift_by=$(hole_extent_delta "$hole_blocks" "$off" "$expect_alloc")

    local -i extents_before=${s[total_extents]}
    local -i committed_before=${s[committed_blocks]}
    local -i free_before=${s[free_blocks]}
    local -i files_now=${s[files]}
    local -i expect_extents=$((extents_before + shift_by))
    local -i expect_committed=$((committed_before + expect_alloc))
    local -i expect_free=$((free_before - expect_alloc))
    local -i expect_frag=$((expect_extents * 100 / files_now))
    local -i accum_blocks=$((2 + hole_blocks))
    local -i expect_avg=$((accum_blocks * 100 / expect_extents))

    # Pattern covers the request size, which may exceed what fits in the hole.
    dd if=/dev/urandom of="$pattern" bs="$BLOCK_SIZE" count="$write_blocks" 2>/dev/null || {
      pr_err "$position/$size_label: failed to create pattern"
      return 1
    }

    # A single write(): the FS caps it to the blocks left in the hole.
    local -i seek_bytes=$((seek_block * BLOCK_SIZE))
    local -i req_bytes=$((write_blocks * BLOCK_SIZE))
    local -i expect_bytes=$((expect_alloc * BLOCK_SIZE))
    local -i written
    written=$("$single_write_bin" "$file" "$seek_bytes" "$req_bytes" "$pattern") || {
      pr_err "$position/$size_label: hole write failed"
      return 1
    }
    if [[ "$written" -ne "$expect_bytes" ]]; then
      pr_err "$position/$size_label: expected write of $expect_bytes bytes, got $written"
      return 1
    fi

    actual_size=$(stat -c '%s' "$file")
    if [[ "$actual_size" -ne "$expected_sz" ]]; then
      pr_err "$position/$size_label: Expected size $expected_sz after hole write, got $actual_size"
      return 1
    fi

    # Written region must match the pattern (only expect_alloc blocks)
    local got="/tmp/ouiche_hole_got_${position}_${size_label}"
    cleanup_later "$got"
    dd if="$file" of="$got" bs="$BLOCK_SIZE" skip="$seek_block" count="$expect_alloc" 2>/dev/null || {
      pr_err "$position/$size_label: failed to read back written hole region"
      return 1
    }
    if ! cmp -s "$got" "$pattern" --bytes=$((expect_alloc * BLOCK_SIZE)); then
      pr_err "$position/$size_label: written hole data mismatch"
      return 1
    fi

    # Leading data block untouched
    if ! dd if="$file" bs="$BLOCK_SIZE" count=1 2>/dev/null |
      cmp -s /dev/zero - --bytes="$BLOCK_SIZE"; then
      pr_err "$position/$size_label: leading data block corrupted"
      return 1
    fi

    # Trailing data block untouched
    if ! dd if="$file" bs="$BLOCK_SIZE" skip=$((1 + hole_blocks)) count=1 2>/dev/null |
      cmp -s /dev/zero - --bytes="$BLOCK_SIZE"; then
      pr_err "$position/$size_label: trailing data block corrupted"
      return 1
    fi

    # Remaining hole prefix (before write) still zeros
    if [[ "$off" -gt 0 ]]; then
      if ! dd if="$file" bs="$BLOCK_SIZE" skip=1 count="$off" 2>/dev/null |
        cmp -s /dev/zero - --bytes=$((off * BLOCK_SIZE)); then
        pr_err "$position/$size_label: hole prefix is not zeros"
        return 1
      fi
    fi

    # Remaining hole suffix (after write) still zeros
    local -i suffix_off=$((off + expect_alloc))
    local -i suffix_len=$((hole_blocks - suffix_off))
    if [[ "$suffix_len" -gt 0 ]]; then
      if ! dd if="$file" bs="$BLOCK_SIZE" skip=$((1 + suffix_off)) count="$suffix_len" 2>/dev/null |
        cmp -s /dev/zero - --bytes=$((suffix_len * BLOCK_SIZE)); then
        pr_err "$position/$size_label: hole suffix is not zeros"
        return 1
      fi
    fi

    load_stats s || return 1
    assert_eq "$position/$size_label free after write" "${s[free_blocks]}" "$expect_free" || return 1
    assert_eq "$position/$size_label committed after write" "${s[committed_blocks]}" "$expect_committed" || return 1
    assert_eq "$position/$size_label extents after write" "${s[total_extents]}" "$expect_extents" || return 1
    assert_eq "$position/$size_label max_file_size after write" "${s[max_file_size]}" "$(max_of "$expected_sz" "${base[max_file_size]}")" || return 1
    assert_eq "$position/$size_label fragmentation after write" "${s[fragmentation]}" "$expect_frag" || return 1
    if [[ "${base[total_extents]}" -eq 0 ]]; then
      assert_eq "$position/$size_label avg after write" "${s[avg_extent_size]}" "$expect_avg" || return 1
    fi
    assert_block_accounting s || return 1

    echo "$position/$size_label: wrote $expect_alloc/$write_blocks blocks into hole (shift_by=$shift_by)"
    rm -f "$file"
  done
}

# Assert free + committed + reserved == NR_BLOCKS using a loaded stats array.
assert_block_accounting() {
  local -n stats_ref=$1
  local sum=$((stats_ref[free_blocks] + stats_ref[committed_blocks] + stats_ref[reserved_blocks]))
  if [[ "$sum" -ne "$NR_BLOCKS" ]]; then
    pr_err "block accounting: free(${stats_ref[free_blocks]})+committed(${stats_ref[committed_blocks]})+reserved(${stats_ref[reserved_blocks]})=$sum, expected $NR_BLOCKS"
    return 1
  fi
}

# Fill the partition while reservation holders keep leftover windows, then
# force an allocating write that must trigger GC. Used by test_stats_gc_runs.
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
