// SPDX-License-Identifier: GPL-2.0
/*
 * ouiche_fs - a simple educational filesystem for Linux
 *
 * Copyright (C) 2018 Redha Gouicem <redha.gouicem@lip6.fr>
 */

#include "asm-generic/errno-base.h"
#include "asm-generic/fcntl.h"
#include "linux/types.h"
#define pr_fmt(fmt) "%s:%s: " fmt, KBUILD_MODNAME, __func__

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/fs.h>
#include <linux/buffer_head.h>

#include "ouichefs.h"
#include "bitmap.h"

uint32_t ouichefs_calculate_max_file_size(struct super_block *sb)
{
	spin_lock(&sb->s_inode_list_lock);
	uint32_t max_file_size = 0;
	struct inode *inode;
	int inode_count = 0;

	list_for_each_entry(inode, &sb->s_inodes, i_sb_list) {
		if (!S_ISREG(inode->i_mode))
			continue;

		inode_count++;
		if (inode->i_size > max_file_size) {
			max_file_size = inode->i_size;
		}
	}
	spin_unlock(&sb->s_inode_list_lock);

	return max_file_size;
}

static int ouichefs_get_extent_of_logical_block(
	const struct ouichefs_extent *extents, const uint32_t logical_block,
	unsigned int *parent_extent_index, unsigned int *inner_extent_offset)
{
	uint32_t accumulated_count = 0;

	struct ouichefs_extent extend = {};

	for (uint32_t extents_index = 0; extents_index < OUICHEFS_MAX_EXTENTS;
	     extents_index++) {
		extend = extents[extents_index];

		if (extend.count == 0) {
			*parent_extent_index = extents_index;
			*inner_extent_offset = 0;
			return OUICHEFS_EXTENT_TYPE_INSERT_AT_END;
		}

		if (accumulated_count + le32_to_cpu(extend.count) >
		    logical_block) {
			*parent_extent_index = extents_index;
			*inner_extent_offset =
				logical_block - accumulated_count;

			return OUICHEFS_EXTENT_TYPE_FOUND;
		}

		accumulated_count += le32_to_cpu(extend.count);
	}

	return OUICHEFS_EXTENT_TYPE_OUT_OF_SPACE;
}

/*
 * Reclaim unused reserved blocks from every inode on this superblock except
 * @skip (the allocator that ran out of space). Called when contiguous
 * allocation fails because reserved-but-unused blocks still sit in other
 * files' reservation windows.
 */
void ouichefs_collect_garbage(const struct inode *skip)
{
	struct super_block *sb = skip->i_sb;
	struct ouichefs_sb_info *sb_info = OUICHEFS_SB(sb);
	struct inode *iter_node;

	sb_info->gc_count++;

	spin_lock(&sb->s_inode_list_lock);
	list_for_each_entry(iter_node, &sb->s_inodes, i_sb_list) {
		if (iter_node == skip) {
			/* skip caller: no reservation left to free, avoid
			 * nested locking if we already hold related state */
			continue;
		}
		spin_lock(&iter_node->i_lock);
		if (ouichefs_release_reservations(iter_node))
			pr_warn("Failed to release reservations for inode %lu\n",
				iter_node->i_ino);
		spin_unlock(&iter_node->i_lock);
	}
	spin_unlock(&sb->s_inode_list_lock);
}

/**
 * Attempts to allocate a certain number of blocks and writes the physical
 * block number into `bno`.
 * @param inode The inode for which the blocks will be allocated
 * @param nr How many blocks to allocate
 * @param bno Ptr to which the physical block number is written
 * @return How many blocks where actually allocated or -ENOSPC when no blocks
 *	   could be allocated at all
 */
static int ouichefs_allocate_blocks(const struct inode *inode,
				    const unsigned int nr, uint32_t *bno)
{
	const struct super_block *sb = inode->i_sb;
	uint32_t nob = ouichefs_alloc_contiguous(sb, nr, bno);

	if (!nob) {
		ouichefs_collect_garbage(inode);

		//retry once
		nob = ouichefs_alloc_contiguous(sb, nr, bno);
		if (!nob) {
			return -ENOSPC;
		}
	}

	return (int)nob;
}

static void ouichefs_update_inode_time(struct inode *inode)
{
	inode->i_mtime = inode_set_ctime_current(inode);
	mark_inode_dirty(inode);
}

static int
ouichefs_read_index_block_from_disk(const struct inode *inode,
				    struct buffer_head **bh,
				    struct ouichefs_file_index_block **index)
{
	*bh = sb_bread(inode->i_sb, OUICHEFS_INODE(inode)->index_block);
	if (!*bh)
		return -EIO;
	*index = (struct ouichefs_file_index_block *)(*bh)->b_data;
	return 0;
}

/**
 * Attempts to merge contiguous data extents into a single extent
 * @return 0 when all extents have been merged into a single extent, err otherwise
 */
static int ouichefs_merge_data_extents(struct inode *inode,
				       struct ouichefs_extent *extents,
				       const unsigned int merge_start_index,
				       const unsigned int nr_extents,
				       const unsigned int new_head_index,
				       const unsigned int nr_needed_blocks)
{
	int ret = 0;

	if (nr_extents <= 1)
		goto out;

	struct super_block *sb = inode->i_sb;
	struct ouichefs_sb_info *sbi = OUICHEFS_SB(sb);

	uint32_t bno;
	const int nr_allocated_blocks =
		ouichefs_allocate_blocks(inode, nr_needed_blocks, &bno);
	if (nr_allocated_blocks < 0) {
		ret = nr_allocated_blocks;
		goto out;
	}
	if (nr_allocated_blocks < nr_needed_blocks) {
		ret = -ENOSPC;
		goto out_free;
	}

	struct ouichefs_extent new_extent;

	new_extent.start = cpu_to_le32(bno);
	new_extent.count = cpu_to_le32(nr_allocated_blocks);
	unsigned int blocks_copied = 0;

	for (int i = 0; i < nr_extents; i++) {
		const struct ouichefs_extent *extent =
			&extents[merge_start_index + i];
		const uint32_t start = le32_to_cpu(extent->start);
		const uint32_t count = le32_to_cpu(extent->count);

		for (int j = 0; j < count; j++) {
			struct buffer_head *orig_data_bh =
				sb_bread(sb, start + j);
			if (!orig_data_bh) {
				ret = -EIO;
				goto out_shift;
			}

			struct buffer_head *new_data_bh =
				sb_bread(sb, bno + blocks_copied + j);
			if (!new_data_bh) {
				ret = -EIO;
				brelse(orig_data_bh);
				goto out_shift;
			}

			memcpy(new_data_bh->b_data, orig_data_bh->b_data,
			       sb->s_blocksize);

			mark_buffer_dirty(new_data_bh);
			sync_dirty_buffer(new_data_bh);

			brelse(new_data_bh);
			brelse(orig_data_bh);
		}
		blocks_copied += count;
	}

	// Free the old data blocks
	for (int i = 0; i < nr_extents; i++) {
		const struct ouichefs_extent *extent =
			&extents[merge_start_index + i];
		ouichefs_free_contiguous(sb, le32_to_cpu(extent->start),
					 le32_to_cpu(extent->count));
	}

	extents[new_head_index] = new_extent;
	sbi->nr_total_extents -= nr_extents - 1;
	ouichefs_update_inode_time(inode);

	return 0;

out_shift:
	for (int k = 0; k < nr_extents; k++) {
		extents[new_head_index + k] = extents[merge_start_index + k];
	}
out_free:
	ouichefs_free_contiguous(sb, bno, nr_allocated_blocks);
out:
	return ret;
}

static int ouichefs_merge_hole_extents(struct inode *inode,
				       struct ouichefs_extent *extents,
				       const unsigned int nr_extents,
				       const unsigned int new_head_index,
				       const unsigned int nr_needed_blocks)
{
	const int ret = 0;

	if (nr_extents <= 1)
		goto out;

	const struct super_block *sb = inode->i_sb;
	struct ouichefs_sb_info *sbi = OUICHEFS_SB(sb);

	extents[new_head_index].start = 0;
	extents[new_head_index].count = cpu_to_le32(nr_needed_blocks);
	ouichefs_update_inode_time(inode);
	sbi->nr_total_extents -= nr_extents - 1;

out:
	return ret;
}

static int ouichefs_merge_extents(struct inode *inode,
				  struct ouichefs_extent *extents,
				  const unsigned int merge_start_index,
				  const unsigned int nr_extents,
				  const unsigned int new_head_index,
				  const unsigned int nr_needed_blocks)
{
	if (!nr_extents)
		return 0;

	// If there is only one extent, we don't need to merge it
	// but rather we just move it to the new head slot
	if (nr_extents == 1) {
		if (new_head_index != merge_start_index) {
			extents[new_head_index] = extents[merge_start_index];
			ouichefs_update_inode_time(inode);
		}
		return 0;
	}

	if (extents[merge_start_index].start == 0) {
		return ouichefs_merge_hole_extents(inode, extents, nr_extents,
						   new_head_index,
						   nr_needed_blocks);
	}

	return ouichefs_merge_data_extents(inode, extents, merge_start_index,
					   nr_extents, new_head_index,
					   nr_needed_blocks);
}

void ouichefs_superblock_defragment(struct super_block *sb)
{
	struct inode *iter_node;
	struct inode *toput_inode = NULL;

	spin_lock(&sb->s_inode_list_lock);
	list_for_each_entry(iter_node, &sb->s_inodes, i_sb_list) {
		/* only regular files have an extent index block */
		if (!S_ISREG(iter_node->i_mode))
			continue;
		if (!igrab(iter_node))
			continue;
		spin_unlock(&sb->s_inode_list_lock);

		if (ouichefs_file_defragment(iter_node))
			pr_warn("Failed to defragment inode %lu\n",
				iter_node->i_ino);

		iput(toput_inode);
		toput_inode = iter_node;

		spin_lock(&sb->s_inode_list_lock);
	}
	spin_unlock(&sb->s_inode_list_lock);
	iput(toput_inode);
}

int ouichefs_file_defragment(struct inode *inode)
{
	int ret = 0;
	struct buffer_head *bh_index;
	struct ouichefs_file_index_block *index;

	ret = ouichefs_read_index_block_from_disk(inode, &bh_index, &index);
	if (ret) {
		goto out;
	}
	struct ouichefs_extent *extents = index->extents;

	unsigned int nr_used_blocks = 0;
	unsigned int nr_extents = 0;
	int tracking_data = 1;
	unsigned int new_head_index = 0;
	unsigned int extent_index;

	for (extent_index = 0; extent_index < OUICHEFS_MAX_EXTENTS;
	     extent_index++) {
		const struct ouichefs_extent *extent = &extents[extent_index];
		const uint32_t start = le32_to_cpu(extent->start);
		const uint32_t count = le32_to_cpu(extent->count);

		if (!count)
			break;

		//tracking_data & !start || !tracking_data & start -> switch
		if (tracking_data != !!start) {
			//the group that just ended is complete, flush it
			if (nr_extents) {
				ret = ouichefs_merge_extents(
					inode, extents,
					extent_index - nr_extents, nr_extents,
					new_head_index, nr_used_blocks);
				if (ret) {
					//we try to ignore errors and continue,
					// number of extents stayed the same
					new_head_index += nr_extents;
				} else {
					//all extents have been merged into one
					new_head_index++;
				}
			}

			tracking_data = !tracking_data;
			nr_extents = 1;
			nr_used_blocks = count;
		} else {
			nr_extents++;
			nr_used_blocks += count;
		}
	}

	//flush the trailing group; an empty file has none
	if (nr_extents) {
		const unsigned int last_merge_start_index =
			extent_index - nr_extents;
		ret = ouichefs_merge_extents(inode, extents,
					     last_merge_start_index, nr_extents,
					     new_head_index, nr_used_blocks);
		if (ret) {
			new_head_index += nr_extents;
		} else {
			new_head_index++;
		}
	}

	//zero after head
	memset(extents + new_head_index, 0,
	       (extent_index - new_head_index) *
		       sizeof(struct ouichefs_extent));

	mark_buffer_dirty(bh_index);
	brelse(bh_index);
out:
	return ret;
}

static int ouichefs_file_get_allocated_blocks(const struct inode *inode,
					      const sector_t iblock,
					      const unsigned int nr,
					      struct buffer_head *bh_result)
{
	struct super_block *sb = inode->i_sb;
	int ret = 0;

	struct buffer_head *bh_index;
	struct ouichefs_file_index_block *index;

	ret = ouichefs_read_index_block_from_disk(inode, &bh_index, &index);
	if (ret) {
		goto out;
	}

	unsigned int extent_index = 0;
	unsigned int inner_extent_offset = 0;

	const struct ouichefs_extent *extents = index->extents;
	const int result = ouichefs_get_extent_of_logical_block(
		extents, iblock, &extent_index, &inner_extent_offset);

	if (result == OUICHEFS_EXTENT_TYPE_FOUND) {
		const struct ouichefs_extent *extent = &extents[extent_index];

		const uint32_t start = le32_to_cpu(extent->start);
		const uint32_t count = le32_to_cpu(extent->count);

		ret = min_t(unsigned int, count - inner_extent_offset, nr);
		if (start) {
			const uint32_t bno = start + inner_extent_offset;
			/* Map the physical block to the given buffer_head */
			map_bh(bh_result, sb, bno);
		} else {
			//we are reading a hole
			bh_result->b_blocknr = 0;
			bh_result->b_size = sb->s_blocksize;
		}
	} else if (result == OUICHEFS_EXTENT_TYPE_OUT_OF_SPACE) {
		ret = -EFBIG;
	} else {
		ret = 0;
	}

	brelse(bh_index);
out:
	return ret;
}

//Shift the extent array. Always pass the whole extent array.
static int ouichefs_shift_extents(struct ouichefs_extent *extents,
				  const unsigned int shift_after,
				  const char shift_by)
{
	unsigned int nr_free = 0;

	for (int i = OUICHEFS_MAX_EXTENTS - 1; i > shift_after; i--) {
		const struct ouichefs_extent *extent = &extents[i];

		if (!extent->count) {
			nr_free++;
			continue;
		}

		if (nr_free < shift_by) {
			return -ENOSPC;
		}

		extents[i + shift_by].start = extent->start;
		extents[i + shift_by].count = extent->count;
	}
	return 0;
}

static int ouichefs_file_allocate_blocks(struct inode *inode,
					 const sector_t iblock,
					 const unsigned int nr,
					 struct buffer_head *bh_result)
{
	if (!nr)
		return 0;

	struct super_block *sb = inode->i_sb;
	struct ouichefs_sb_info *sbi = OUICHEFS_SB(sb);
	struct ouichefs_inode_info *inode_info = OUICHEFS_INODE(inode);
	int ret = 0;

	struct buffer_head *bh_index;
	struct ouichefs_file_index_block *index;

	ret = ouichefs_read_index_block_from_disk(inode, &bh_index, &index);
	if (ret) {
		goto out;
	}

	unsigned int extent_index = 0;
	unsigned int inner_extent_offset = 0;

	struct ouichefs_extent *extents = index->extents;
	const int result = ouichefs_get_extent_of_logical_block(
		extents, iblock, &extent_index, &inner_extent_offset);

	uint32_t bno;

	if (result == OUICHEFS_EXTENT_TYPE_INSERT_AT_END) {
		// if not reserve_present:
		//   allocate to reserve
		// use reserve
		// update extent array

		if (!inode_info->i_reserved_count) {
			//one large allocation call, to fight fragmentation;
			//might allocate less, but that is fine
			//we reserve number + reservation since we don't want to
			//exhaust reservation window in this write directly
			const unsigned int nob_to_allocate =
				reservation_size + nr;
			const int nob = ouichefs_allocate_blocks(
				inode, nob_to_allocate, &bno);
			if (nob < 0) {
				ret = nob;
				goto brelse_index;
			}

			//allocate everything to reserve; there is realistically no limit
			inode_info->i_reserved_count = nob;
			inode_info->i_reserved_start = bno;
			sbi->nr_reserved_blocks += nob;
		}

		//use reserve
		const uint32_t nob =
			min_t(uint32_t, nr, inode_info->i_reserved_count);
		bno = inode_info->i_reserved_start;

		inode_info->i_reserved_count -= nob;
		sbi->nr_reserved_blocks -= nob;
		sbi->nr_committed_blocks += nob;
		inode_info->i_reserved_start += nob;

		//check if we can append to existing extent
		int extent_initialized = 0;

		if (extent_index > 0) {
			struct ouichefs_extent *parent_extent =
				&extents[extent_index - 1];
			if (le32_to_cpu(parent_extent->start) +
				    le32_to_cpu(parent_extent->count) ==
			    bno) {
				parent_extent->count = cpu_to_le32(
					le32_to_cpu(parent_extent->count) +
					nob);
				sbi->accumulated_extents_count += nob;
				extent_initialized = 1;
			}
		}
		if (!extent_initialized) {
			extents[extent_index].start = cpu_to_le32(bno);
			extents[extent_index].count = cpu_to_le32(nob);
			sbi->accumulated_extents_count += nob;
			sbi->nr_total_extents += 1;
		}

		inode->i_blocks += nob;

		mark_inode_dirty(inode);
		mark_buffer_dirty(bh_index);
		/* Map the physical block to the given buffer_head */
		map_bh(bh_result, sb, bno);
		ret = (int)nob;
	} else if (result == OUICHEFS_EXTENT_TYPE_FOUND) {
		//index here is the extent index because we found an extent
		struct ouichefs_extent *extent = &extents[extent_index];
		const u32 start = le32_to_cpu(extent->start);
		const u32 count = le32_to_cpu(extent->count);

		if (start == 0) {
			//cases:
			// allocate whole hole: nr >= count
			// allocate start of hole: inner_offset == 0
			// allocate end of hole: inner_offset + nr >= count
			// allocate in the middle: we may land here anyways ._.
			unsigned int nr_blocks_to_allocate;
			unsigned char shift_by = 0;
			//we are allocating in a hole
			if (nr >= count) {
				nr_blocks_to_allocate = count;
			} else if (inner_extent_offset + nr >= count) {
				nr_blocks_to_allocate =
					count - inner_extent_offset;
			} else {
				nr_blocks_to_allocate = nr;
			}
			const int nr_allocated_blocks =
				ouichefs_allocate_blocks(
					inode, nr_blocks_to_allocate, &bno);
			if (nr_allocated_blocks < 0) {
				ret = nr_allocated_blocks;
				goto brelse_index;
			}

			if (inner_extent_offset + nr_allocated_blocks ==
			    count) {
				if (inner_extent_offset) {
					// offset > 0  && offset + gotten == count:
					//   extent.start = 0,
					//   extent.count = offset ;
					//   extent[+].start = bno,
					//   extent[+].count = gotten;
					//   >> 1
					shift_by = 1;
					if (ouichefs_shift_extents(extents,
								   extent_index,
								   shift_by)) {
						ouichefs_free_contiguous(
							sb, bno,
							nr_allocated_blocks);
						ret = -ENOSPC;
						goto brelse_index;
					}

					extent->start = 0;
					extent->count = cpu_to_le32(
						inner_extent_offset);
					extents[extent_index + 1].start =
						cpu_to_le32(bno);
					extents[extent_index + 1].count =
						cpu_to_le32(
							nr_allocated_blocks);
				} else {
					// offset == 0 && gotten  == count:
					//   extent.start = bno
					extent->start = cpu_to_le32(bno);
				}
			} else {
				if (inner_extent_offset) {
					// offset > 0  && offset + gotten < count:
					//   extent.start = 0,
					//   extent.count = offset ;
					//   extent[+].start = bno,
					//   extent[+].count = gotten;
					//   extent[++].start = 0,
					//   extent[++].count = count - gotten - offset
					//   >> 2
					shift_by = 2;
					if (ouichefs_shift_extents(extents,
								   extent_index,
								   shift_by)) {
						ouichefs_free_contiguous(
							sb, bno,
							nr_allocated_blocks);
						ret = -ENOSPC;
						goto brelse_index;
					}

					extent->start = 0;
					extent->count = cpu_to_le32(
						inner_extent_offset);
					extents[extent_index + 1].start =
						cpu_to_le32(bno);
					extents[extent_index + 1].count =
						cpu_to_le32(
							nr_allocated_blocks);
					extents[extent_index + 2].start = 0;
					extents[extent_index + 2].count =
						cpu_to_le32(
							count -
							nr_allocated_blocks -
							inner_extent_offset);
				} else {
					// offset == 0 && gotten  <  count:
					//   extent.start = bno,
					//   extent.count = gotten,
					//   extent[+].start = 0,
					//   extent[+].count = count - gotten;
					//   >> 1
					shift_by = 1;
					if (ouichefs_shift_extents(extents,
								   extent_index,
								   shift_by)) {
						ouichefs_free_contiguous(
							sb, bno,
							nr_allocated_blocks);
						ret = -ENOSPC;
						goto brelse_index;
					}

					extent->start = cpu_to_le32(bno);
					extent->count = cpu_to_le32(
						nr_allocated_blocks);
					extents[extent_index + 1].start = 0;
					extents[extent_index + 1].count =
						cpu_to_le32(
							count -
							nr_allocated_blocks);
				}
			}

			mark_buffer_dirty(bh_index);
			mark_inode_dirty(inode);
			inode->i_blocks += nr_allocated_blocks;
			sbi->nr_total_extents += shift_by;
			sbi->nr_committed_blocks += nr_allocated_blocks;
			map_bh(bh_result, sb, bno);
			ret = nr_allocated_blocks;
		} else {
			ret = -EEXIST;
		}
	} else {
		ret = -ENOSPC;
	}

brelse_index:
	brelse(bh_index);
out:
	return ret;
}

static void ouichefs_file_increase_size(struct inode *inode,
					const loff_t new_size)
{
	const struct super_block *sb = inode->i_sb;
	struct ouichefs_sb_info *sbi = OUICHEFS_SB(sb);

	i_size_write(inode, new_size);
	mark_inode_dirty(inode);

	//we increased the size, so we need to update the time
	ouichefs_update_inode_time(inode);

	if (inode->i_size > sbi->max_file_size) {
		sbi->max_file_size = inode->i_size;
	}
}

static int ouichefs_file_append_holes(struct inode *inode,
				      const unsigned int nr)
{
	struct buffer_head *bh_index;
	struct ouichefs_file_index_block *index;
	int ret = 0;
	const struct super_block *sb = inode->i_sb;
	struct ouichefs_sb_info *sbi = OUICHEFS_SB(sb);

	ret = ouichefs_read_index_block_from_disk(inode, &bh_index, &index);
	if (ret) {
		goto out;
	}

	struct ouichefs_extent *extents = index->extents;

	//find index where the next extent will be added
	int next_extent_index = -1;

	for (int i = 0; i < OUICHEFS_MAX_EXTENTS; i++) {
		if (extents[i].count == 0) {
			next_extent_index = i;
			break;
		}
	}

	if (next_extent_index == -1) {
		ret = -ENOSPC;
		goto out_brelse_index;
	}

	//check if predecessor happens to be hole which we can extent
	if (next_extent_index > 0 &&
	    le32_to_cpu(extents[next_extent_index - 1].start) == 0) {
		extents[next_extent_index - 1].count = cpu_to_le32(
			le32_to_cpu(extents[next_extent_index - 1].count) + nr);
	} else {
		extents[next_extent_index].start = 0;
		extents[next_extent_index].count = cpu_to_le32(nr);
		sbi->nr_total_extents++;
	}
	sbi->accumulated_extents_count += nr;

	const loff_t new_size = (loff_t)sb->s_blocksize * nr + inode->i_size;

	ouichefs_file_increase_size(inode, new_size);

	mark_buffer_dirty(bh_index);

out_brelse_index:
	brelse(bh_index);
out:
	return ret;
}

// ReSharper disable once CppParameterMayBeConstPtrOrRef
static ssize_t ouichefs_read(struct file *file, char __user *buf, size_t count,
			     loff_t *pos)
{
	// Nothing to read
	// Just return 0
	if (count == 0)
		return 0;

	const struct inode *inode = file->f_inode;
	struct super_block *sb = inode->i_sb;
	const size_t blocksize = sb->s_blocksize;

	// If we try to read more than the file has,
	// just return 0
	if (*pos >= inode->i_size) {
		return 0;
	}

	// if the request is for more data than the file has,
	// adjust the count to the available data
	count = min_t(size_t, count, inode->i_size - *pos);

	// The logical index of the block to read for the current position
	const sector_t iblock = *pos >> sb->s_blocksize_bits;

	// Modulo operation to get the offset within the block
	// (only works for powers of 2)
	// ReSharper disable once CppRedundantParentheses
	unsigned int offset = *pos & (blocksize - 1);

	// superblock has the field s_blocksize and s_blocksize_bits
	// s_blocksize is the size of a block in the filesystem (the same as OUICHEFS_BLOCK_SIZE) = 4096
	// s_blocksize_bits is the number of bits in the size of a block log2(OUICHEFS_BLOCK_SIZE) = 12
	// the index block is a field on the ouichefs inode info.
	// The index block field is a physical block number that contains the index block for the file.

	struct buffer_head result_bh = {};

	const size_t blocks_to_read = (count + offset - 1) / blocksize + 1;
	ssize_t ret = ouichefs_file_get_allocated_blocks(
		inode, iblock, blocks_to_read, &result_bh);
	if (ret < 0)
		goto out;

	// If the block is not allocated, return an error
	if (ret == 0) {
		ret = -EIO;
		goto out;
	}

	const unsigned int num_allocated_blocks = ret;
	const size_t bytes_available =
		num_allocated_blocks * blocksize - offset;
	count = min_t(size_t, count, bytes_available);

	ssize_t bytes_read = 0;
	struct buffer_head *data_bh;

	if (!result_bh.b_blocknr) {
		//we are reading a hole
		const unsigned long bytes_not_copied = clear_user(buf, count);

		bytes_read = (ssize_t)(count - bytes_not_copied);
		if (bytes_not_copied == count) {
			ret = -EFAULT;
			goto out;
		}
	} else {
		for (int block_offset = 0; block_offset < num_allocated_blocks;
		     ++block_offset) {
			data_bh = sb_bread(sb,
					   result_bh.b_blocknr + block_offset);

			if (!data_bh) {
				ret = bytes_read ? bytes_read : -EIO;
				goto out;
			}

			const size_t bytes_remaining = count - bytes_read;
			const size_t bytes_to_read = min_t(
				ssize_t, bytes_remaining, blocksize - offset);

			const unsigned long bytes_not_copied = copy_to_user(
				buf + bytes_read, data_bh->b_data + offset,
				bytes_to_read);

			const unsigned long bytes_copied =
				bytes_to_read - bytes_not_copied;

			// Release the data block buffer head
			// We don't need it anymore
			brelse(data_bh);

			// Only case we fail atp is really when the
			// user space buffer is not valid
			if (bytes_not_copied == bytes_to_read) {
				ret = bytes_read ? bytes_read : -EFAULT;
				goto out;
			}

			bytes_read += (ssize_t)bytes_copied;
			offset = 0;
		}
	}

	*pos += bytes_read;

	return bytes_read;
out:
	pr_err("error in out\n");
	return ret;
}

// ReSharper disable once CppParameterMayBeConstPtrOrRef
static ssize_t ouichefs_write(struct file *file, const char __user *buf,
			      size_t count, loff_t *pos)
{
	ssize_t ret = 0;

	// Nothing to write
	// Just return 0
	if (count == 0)
		return 0;

	struct inode *inode = file->f_inode;
	// Can't write more than the max file size
	if (inode->i_size + count > OUICHEFS_MAX_FILESIZE) {
		return -EFBIG;
	}

	// Check if the Append flag is set
	if (file->f_flags & O_APPEND) {
		*pos = inode->i_size;
	}

	struct super_block *sb = inode->i_sb;
	const struct ouichefs_sb_info *sbi = OUICHEFS_SB(sb);

	const unsigned long blocksize = sb->s_blocksize;
	const unsigned char blocksize_bits = sb->s_blocksize_bits;
	// The logical index of the block to write for the current position
	const sector_t iblock = *pos >> blocksize_bits;
	// index of logical block of current eof
	const sector_t old_iblock = inode->i_size >> blocksize_bits;

	// Modulo operation to get the offset within the block
	// (only works for powers of 2)
	// ReSharper disable once CppRedundantParentheses
	unsigned int offset = *pos & (blocksize - 1);
	// ReSharper disable once CppRedundantParentheses
	const unsigned int eof_offset = inode->i_size & (blocksize - 1);

	//handle hole append case
	size_t nr_bytes_to_zero_before_pos = 0;
	struct buffer_head result_bh = {};
	struct buffer_head *data_bh;

	if (*pos > inode->i_size) {
		size_t nr_bytes_to_zero_after_eof = 0;
		unsigned int nr_holes_to_create = 0;

		if (old_iblock == iblock) {
			nr_bytes_to_zero_after_eof = *pos - inode->i_size;
		} else if (eof_offset == 0 && inode->i_size > 0) {
			/*
			 * EOF is already on a block boundary. old_iblock is the
			 * first block past EOF (not a partial block to zero),
			 * so every block in [old_iblock, iblock) is a hole.
			 */
			nr_bytes_to_zero_before_pos = offset;
			nr_holes_to_create = iblock - old_iblock;
		} else {
			/* Partial last block: zero the tail, then hole the gap. */
			nr_bytes_to_zero_after_eof = blocksize - eof_offset;
			nr_bytes_to_zero_before_pos = offset;
			nr_holes_to_create = iblock - old_iblock - 1;
		}

		if (nr_bytes_to_zero_after_eof) {
			int nr_allocated_blocks =
				ouichefs_file_get_allocated_blocks(
					inode, old_iblock, 1, &result_bh);
			if (nr_allocated_blocks < 0) {
				ret = nr_allocated_blocks;
				goto out;
			}
			if (result_bh.b_blocknr == 0) {
				nr_allocated_blocks =
					ouichefs_file_allocate_blocks(
						inode, old_iblock, 1,
						&result_bh);
				if (nr_allocated_blocks <= 0) {
					ret = nr_allocated_blocks ?
						      nr_allocated_blocks :
						      -ENOSPC;
					goto out;
				}
			}
			data_bh = sb_bread(sb, result_bh.b_blocknr);
			if (!data_bh)
				goto out;

			memset(data_bh->b_data + eof_offset, 0,
			       nr_bytes_to_zero_after_eof);

			mark_buffer_dirty(data_bh);
			sync_dirty_buffer(data_bh);
			brelse(data_bh);

			/*
			 * Only advance size to the end of this block when we
			 * still have later hole blocks to append. Same-block
			 * past-EOF writes leave size to the data copy below.
			 */
			if (old_iblock != iblock) {
				ouichefs_file_increase_size(
					inode, ((loff_t)old_iblock + 1)
						       << blocksize_bits);
			}
		}

		if (nr_holes_to_create) {
			ret = ouichefs_file_append_holes(inode,
							 nr_holes_to_create);
			if (ret) {
				goto out;
			}
		}
	}

	// Get the blocks and allocate them if they're not allocated
	const size_t nr_blocks_needed = (count + offset - 1) / blocksize + 1;

	int nr_allocated_blocks = 0;
	const int extent_size = ouichefs_file_get_allocated_blocks(
		inode, iblock, nr_blocks_needed, &result_bh);
	if (extent_size < 0) {
		ret = extent_size;
		goto out;
	}
	if (extent_size > 0 && result_bh.b_blocknr == 0) {
		//we want to write into a hole, so allocate it
		const int nr_blocks_to_allocate_from_hole =
			min_t(int, extent_size, nr_blocks_needed);
		nr_allocated_blocks = ouichefs_file_allocate_blocks(
			inode, iblock, nr_blocks_to_allocate_from_hole,
			&result_bh);
	} else if (extent_size == 0) {
		nr_allocated_blocks = ouichefs_file_allocate_blocks(
			inode, iblock, nr_blocks_needed, &result_bh);
	} else {
		nr_allocated_blocks = extent_size;
	}
	if (nr_allocated_blocks < 0) {
		ret = nr_allocated_blocks;
		goto out;
	}

	// Adjust the count to the available data in the blocks
	// We can't write more data than the blocks have
	const size_t bytes_available = nr_allocated_blocks * blocksize - offset;

	count = min_t(size_t, count, bytes_available);

	ssize_t written_bytes = 0;

	for (int block_offset = 0; block_offset < nr_allocated_blocks;
	     ++block_offset) {
		data_bh = sb_bread(sb, result_bh.b_blocknr + block_offset);
		if (!data_bh) {
			ret = written_bytes ? written_bytes : -EIO;
			goto out_truncate;
		}

		if (nr_bytes_to_zero_before_pos) {
			memset(data_bh->b_data, 0, nr_bytes_to_zero_before_pos);
			ouichefs_file_increase_size(inode, *pos);
			mark_buffer_dirty(data_bh);
			nr_bytes_to_zero_before_pos = 0;
		}

		const size_t bytes_remaining = count - written_bytes;
		const size_t bytes_to_write =
			min_t(ssize_t, bytes_remaining, blocksize - offset);
		const size_t bytes_not_copied =
			copy_from_user(data_bh->b_data + offset,
				       buf + written_bytes, bytes_to_write);

		const size_t bytes_copied = bytes_to_write - bytes_not_copied;

		if (bytes_not_copied == bytes_to_write) {
			ret = written_bytes ? written_bytes : -EFAULT;
			goto out_sync; //zero bytes might have been written
		}

		*pos += (loff_t)bytes_copied;
		if (*pos > inode->i_size) {
			ouichefs_file_increase_size(inode, *pos);
		}

		// Mark the block as dirty
		mark_buffer_dirty(data_bh);
		sync_dirty_buffer(data_bh);

		ouichefs_update_inode_time(inode);

		brelse(data_bh);

		written_bytes += (ssize_t)bytes_copied;
		offset = 0;
	}

	if (calculate_fragmentation(sbi) > fragmentation_threshold) {
		pr_info("fragmentation threshold reached, triggering defragmentation\n");
		ouichefs_superblock_defragment(sb);
	}

	return written_bytes;
out_sync:
	sync_dirty_buffer(data_bh);
	// out_brelse:
	brelse(data_bh);
out_truncate:
	if (ouichefs_truncate(inode) < 0)
		pr_err("%s:%d: truncate failed\n", __func__, __LINE__);
out:
	return ret;
}

int ouichefs_release_reservations(const struct inode *inode)
{
	struct ouichefs_inode_info *inode_info = OUICHEFS_INODE(inode);

	if (!inode_info->i_reserved_count)
		return 0;

	const int ret = ouichefs_free_contiguous(inode->i_sb,
						 inode_info->i_reserved_start,
						 inode_info->i_reserved_count);
	if (ret)
		return ret;

	struct ouichefs_sb_info *sbi = OUICHEFS_SB(inode->i_sb);

	sbi->nr_reserved_blocks -= inode_info->i_reserved_count;
	inode_info->i_reserved_start = 0;
	inode_info->i_reserved_count = 0;

	return 0;
}

// ReSharper disable once CppParameterMayBeConstPtrOrRef
// ReSharper disable once CppParameterNeverUsed
static int ouichefs_release(struct inode *inode, struct file *file)
{
	return ouichefs_release_reservations(inode);
}

const struct file_operations
	ouichefs_file_ops /* NOLINT(*-interfaces-global-init)*/
	= {
		  .owner = THIS_MODULE,
		  .llseek = generic_file_llseek,
		  .read = ouichefs_read,
		  .write = ouichefs_write,
		  .read_iter = generic_file_read_iter,
		  .fsync = generic_file_fsync,
		  .release = ouichefs_release,
	  };

int ouichefs_truncate(struct inode *inode)
{
	int ret;
	struct super_block *sb = inode->i_sb;
	struct ouichefs_sb_info *sbi = OUICHEFS_SB(sb);
	const struct ouichefs_inode_info *inode_info = OUICHEFS_INODE(inode);
	size_t next_num_blocks;

	struct buffer_head *bh = sb_bread(sb, inode_info->index_block);

	if (!bh) {
		ret = -EIO;
		goto out;
	}

	struct ouichefs_file_index_block *index =
		(struct ouichefs_file_index_block *)bh->b_data;

	next_num_blocks = (inode->i_size + sb->s_blocksize - 1) >>
			  sb->s_blocksize_bits;

	/*
	 * The extent array is indexed by extent, not by logical block, so look
	 * up which extent holds the first block past the new end of file. Its
	 * inner offset is the number of blocks that extent keeps.
	 */
	unsigned int first_extent_index = 0;
	unsigned int nr_blocks_to_keep = 0;

	if (ouichefs_get_extent_of_logical_block(index->extents,
						 next_num_blocks,
						 &first_extent_index,
						 &nr_blocks_to_keep) !=
	    OUICHEFS_EXTENT_TYPE_FOUND) {
		/* nothing is mapped past the new size */
		goto out_brelse;
	}

	// Iterate over all extents reaching past the new size
	for (size_t i = first_extent_index; i < OUICHEFS_MAX_EXTENTS; ++i) {
		struct ouichefs_extent *extent = &index->extents[i];
		const unsigned int count = le32_to_cpu(extent->count);
		const unsigned int start = le32_to_cpu(extent->start);

		if (!count)
			break;

		/* only the first extent may keep a head, the rest go away */
		const unsigned int keep =
			i == first_extent_index ? nr_blocks_to_keep : 0;
		const unsigned int drop = count - keep;

		if (start) {
			ouichefs_free_contiguous(sb, start + keep, drop);
			inode->i_blocks -= drop;
			sbi->nr_committed_blocks -= drop;
		}

		sbi->accumulated_extents_count -= drop;

		if (keep) {
			extent->count = cpu_to_le32(keep);
		} else {
			sbi->nr_total_extents -= 1;

			// 0 is the same in big and little endian
			extent->start = 0;
			extent->count = 0;
		}
	}

out_brelse:
	mark_buffer_dirty(bh);
	brelse(bh);

	mark_inode_dirty(inode);
	sbi->max_file_size = ouichefs_calculate_max_file_size(sb);

	return 0;

out:
	return ret;
}
