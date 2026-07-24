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
#include <linux/mpage.h>

#include "ouichefs.h"
#include "bitmap.h"

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

// static uint32_t ouichefs_extent_get_block(struct ouichefs_extent *extents,
// 					  uint32_t logical_block)
// {
// 	int parent_extent_index = 0;
// 	int last_extent_index = 0;

// 	int ret = ouichefs_get_extent_of_logical_block(extents, logical_block,
// 						       &parent_extent_index,
// 						       &last_extent_index);
// 	if (ret != OUICHEFS_EXTENT_TYPE_FOUND)
// 		return 0;

// 	return le32_to_cpu(extents[parent_extent_index].start) +
// 	       last_extent_index;
// }

static int ouichefs_file_get_allocated_blocks(struct inode *inode,
					      const sector_t iblock,
					      const unsigned int nr,
					      struct buffer_head *bh_result)
{
	struct super_block *sb = inode->i_sb;
	const struct ouichefs_inode_info *ci = OUICHEFS_INODE(inode);
	int ret = 0;

	/* Read index block from disk */
	struct buffer_head *bh_index = sb_bread(sb, ci->index_block);
	if (!bh_index)
		return -EIO;
	const struct ouichefs_file_index_block *index =
		(struct ouichefs_file_index_block *)bh_index->b_data;

	unsigned int parent_extent_index = 0;
	unsigned int inner_extent_offset = 0;

	const int result = ouichefs_get_extent_of_logical_block(
		index->extents, iblock, &parent_extent_index,
		&inner_extent_offset);

	if (result == OUICHEFS_EXTENT_TYPE_FOUND) {
		const struct ouichefs_extent *parent_extent =
			&index->extents[parent_extent_index];
		const int bno =
			le32_to_cpu(parent_extent->start) + inner_extent_offset;
		ret = min_t(unsigned int,
			    parent_extent->count - inner_extent_offset, nr);

		/* Map the physical block to the given buffer_head */
		map_bh(bh_result, sb, bno);
	} else if (result == OUICHEFS_EXTENT_TYPE_OUT_OF_SPACE) {
		ret = -EFBIG;
	} else {
		ret = 0;
	}

	brelse(bh_index);
	return ret;
}

static int ouichefs_file_allocate_blocks(struct inode *inode,
					 const sector_t iblock,
					 const unsigned int nr,
					 struct buffer_head *bh_result)
{
	struct super_block *sb = inode->i_sb;
	const struct ouichefs_inode_info *ci = OUICHEFS_INODE(inode);
	int ret = 0;
	uint32_t bno;

	/* Read index block from disk */
	struct buffer_head *bh_index = sb_bread(sb, ci->index_block);
	if (!bh_index)
		return -EIO;
	struct ouichefs_file_index_block *index =
		(struct ouichefs_file_index_block *)bh_index->b_data;

	unsigned int parent_extent_index = 0;
	unsigned int inner_extent_offset = 0;

	struct ouichefs_extent *parent_extent;
	const int result = ouichefs_get_extent_of_logical_block(
		index->extents, iblock, &parent_extent_index,
		&inner_extent_offset);

	if (result == OUICHEFS_EXTENT_TYPE_INSERT_AT_END) {
		const uint32_t nob = ouichefs_alloc_contiguous(sb, nr, &bno);
		pr_info("Requested to allocate %d blocks and got %d\n", nr,
			nob);
		if (!nob) {
			ret = -ENOSPC;
			goto brelse_index;
		}

		//check if we can append to existing extent
		int extent_initialized = 0;
		if (parent_extent_index > 0) {
			parent_extent =
				&index->extents[parent_extent_index - 1];
			if (le32_to_cpu(parent_extent->start) +
				    le32_to_cpu(parent_extent->count) ==
			    bno) {
				parent_extent->count = cpu_to_le32(
					le32_to_cpu(parent_extent->count) +
					nob);
				extent_initialized = 1;
			}
		}
		if (!extent_initialized) {
			index->extents[parent_extent_index].start =
				cpu_to_le32(bno);
			index->extents[parent_extent_index].count =
				cpu_to_le32(nob);
		}

		inode->i_blocks += nob;

		mark_inode_dirty(inode);
		mark_buffer_dirty(bh_index);
		/* Map the physical block to the given buffer_head */
		map_bh(bh_result, sb, bno);
		ret = (int)nob;
	} else if (result == OUICHEFS_EXTENT_TYPE_FOUND) {
		ret = -EEXIST;
	} else {
		ret = -ENOSPC;
	}

brelse_index:
	brelse(bh_index);
	return ret;
}

/*
 * Map the buffer_head passed in argument with the iblock-th block of the file
 * represented by inode. If the requested block is not allocated and create is
 * true, allocate a new block on disk and map it.
 */
static int ouichefs_file_get_block(struct inode *inode, sector_t iblock,
				   struct buffer_head *bh_result, int create)
{
	int res =
		ouichefs_file_get_allocated_blocks(inode, iblock, 1, bh_result);
	if (res == 0 && create) {
		res = ouichefs_file_allocate_blocks(inode, iblock, 1,
						    bh_result);
	}

	if (res > 0)
		res = 0;
	return res;
}

/*
 * Called by the page cache to read a page from the physical disk and map it in
 * memory.
 */
static void ouichefs_readahead(struct readahead_control *rac)
{
	mpage_readahead(rac, ouichefs_file_get_block);
}

/*
 * Called by the page cache to write a dirty page to the physical disk (when
 * sync is called or when memory is needed).
 */
static int ouichefs_writepage(struct page *page, struct writeback_control *wbc)
{
	return block_write_full_page(page, ouichefs_file_get_block, wbc);
}

/*
 * Called by the VFS when a write() syscall occurs on file before writing the
 * data in the page cache. This functions checks if the write will be able to
 * complete and allocates the necessary blocks through block_write_begin().
 */
static int ouichefs_write_begin(struct file *file,
				struct address_space *mapping, loff_t pos,
				unsigned int len, struct page **pagep,
				void **fsdata)
{
	int err;

	/* prepare the write */
	err = block_write_begin(mapping, pos, len, pagep,
				ouichefs_file_get_block);
	/* if this failed, reclaim newly allocated blocks */
	if (err < 0) {
		truncate_pagecache(file->f_inode, file->f_inode->i_size);
		if (ouichefs_truncate(file->f_inode) < 0)
			pr_err("%s:%d: truncate failed\n", __func__, __LINE__);
		goto out;
	}

	return 0;

out:
	return err;
}

/*
 * Called by the VFS after writing data from a write() syscall to the page
 * cache. This functions updates inode metadata and truncates the file if
 * necessary.
 */
static int ouichefs_write_end(struct file *file, struct address_space *mapping,
			      loff_t pos, unsigned int len, unsigned int copied,
			      struct page *page, void *fsdata)
{
	int ret;
	struct inode *inode = file->f_inode;

	/* Complete the write() */
	ret = generic_write_end(file, mapping, pos, len, copied, page, fsdata);
	if (ret < len) {
		pr_err("%s:%d: wrote less than asked... what do I do? nothing for now...\n",
		       __func__, __LINE__);
	} else {
		/* Update inode metadata */
		inode->i_mtime = inode_set_ctime_current(inode);
		mark_inode_dirty(inode);
	}

	return ret;
}

static ssize_t ouichefs_read(struct file *file, char __user *buf, size_t count,
			     loff_t *pos)
{
	int ret;
	// Nothing to read
	// Just return 0
	if (count == 0)
		return 0;

	// If we try to read more than the file has,
	// just return 0
	if (*pos >= file->f_inode->i_size) {
		return 0;
	}

	// if the request is for more data than the file has,
	// adjust the count to the available data
	count = min_t(size_t, count, file->f_inode->i_size - *pos);

	// The logical index of the block to read for the current position
	int iblock = *pos >> file->f_inode->i_sb->s_blocksize_bits;

	// Modulo operation to get the offset within the block
	// (only works for powers of 2)
	int offset = *pos & (file->f_inode->i_sb->s_blocksize - 1);

	// Adjust the count to the available data in the block
	// We can't read more data than the block has
	count = min_t(size_t, count, file->f_inode->i_sb->s_blocksize - offset);

	// superblock has the field s_blocksize and s_blocksize_bits
	// s_blocksize is the size of a block in the filesystem (the same as OUICHEFS_BLOCK_SIZE) = 4096
	// s_blocksize_bits is the number of bits in the size of a block log2(OUICHEFS_BLOCK_SIZE) = 12
	// the index block is a field on the ouichefs inode info.
	// The index block field is a physical block number that contains the index block for the file.

	struct buffer_head result_bh = {};

	ret = ouichefs_file_get_block(file->f_inode, iblock, &result_bh, 0);
	if (ret < 0)
		goto out;

	// If the block is not allocated, return an error
	if (result_bh.b_blocknr == 0) {
		ret = -EIO;
		goto out;
	}

	struct buffer_head *data_bh =
		sb_bread(file->f_inode->i_sb, result_bh.b_blocknr);

	if (!data_bh) {
		ret = -EIO;
		goto out;
	}

	int bytes_not_copied =
		copy_to_user(buf, data_bh->b_data + offset, count);

	int bytes_copied = count - bytes_not_copied;

	// Release the data block buffer head
	// We don't need it anymore
	brelse(data_bh);

	// Only case we fail atp is really when the
	// user space buffer is not valid
	if (!bytes_copied) {
		ret = -EFAULT;
		goto out;
	}

	*pos += bytes_copied;

	return bytes_copied;

// out_brelse:
// 	pr_err("error in out_brelse\n");
// 	brelse(bh_index);
out:
	pr_err("error in out\n");
	return ret;
}

static ssize_t ouichefs_write(struct file *file, const char __user *buf,
			      size_t count, loff_t *pos)
{
	ssize_t ret = 0;
	pr_info("Got a request to write %lu bytes\n", count);

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
	// The logical index of the block to write for the current position
	sector_t iblock = *pos >> sb->s_blocksize_bits;

	unsigned long s_blocksize = sb->s_blocksize;
	// Modulo operation to get the offset within the block
	// (only works for powers of 2)
	int offset = *pos & (s_blocksize - 1);

	struct buffer_head result_bh = {};

	// Get the block and allocate it if it's not allocated
	size_t num_blocks = (count + offset - 1) / s_blocksize + 1;
	int num_allocated_blocks = ouichefs_file_get_allocated_blocks(
		inode, iblock, num_blocks, &result_bh);
	if (num_allocated_blocks == 0) {
		num_allocated_blocks = ouichefs_file_allocate_blocks(
			inode, iblock, num_blocks, &result_bh);
	}
	if (num_allocated_blocks < 0) {
		ret = num_allocated_blocks;
		goto out;
	}

	// Adjust the count to the available data in the blocks
	// We can't write more data than the blocks have
	const size_t bytes_available =
		num_allocated_blocks * s_blocksize - offset;
	count = min_t(size_t, count, bytes_available);

	ssize_t written_bytes = 0;
	struct buffer_head *data_bh;
	for (int block_offset = 0; block_offset < num_allocated_blocks;
	     ++block_offset) {
		data_bh = sb_bread(sb, result_bh.b_blocknr + block_offset);
		if (!data_bh) {
			ret = written_bytes ? written_bytes : -EIO;
			goto out_truncate;
		}

		const size_t bytes_remaining = count - written_bytes;
		const size_t bytes_to_write =
			min_t(ssize_t, bytes_remaining, s_blocksize - offset);
		const size_t bytes_not_copied = copy_from_user(
			data_bh->b_data + offset, buf, bytes_to_write);

		const size_t bytes_copied = bytes_to_write - bytes_not_copied;
		if (bytes_not_copied == bytes_to_write) {
			ret = written_bytes ? written_bytes : -EFAULT;
			goto out_brelse;
		}

		*pos += (loff_t)bytes_copied;
		if (*pos > inode->i_size) {
			i_size_write(inode, *pos);
			mark_inode_dirty(inode);
		}

		// Mark the block as dirty
		mark_buffer_dirty(data_bh);
		sync_dirty_buffer(data_bh);

		inode->i_mtime = inode_set_ctime_current(inode);

		brelse(data_bh);

		written_bytes += (ssize_t)bytes_copied;
		offset = 0;
	}

	return written_bytes;
out_brelse:
	pr_err("error in out\n");
	brelse(data_bh);
out_truncate:
	if (ouichefs_truncate(inode) < 0)
		pr_err("%s:%d: truncate failed\n", __func__, __LINE__);
out:
	return ret;
}

const struct address_space_operations ouichefs_aops = {
	.readahead = ouichefs_readahead,
	.writepage = ouichefs_writepage,
	.write_begin = ouichefs_write_begin,
	.write_end = ouichefs_write_end
};

const struct file_operations ouichefs_file_ops = {
	.owner = THIS_MODULE,
	.llseek = generic_file_llseek,
	.read = ouichefs_read,
	.write = ouichefs_write,
	.read_iter = generic_file_read_iter,
	.write_iter = generic_file_write_iter,
	.fsync = generic_file_fsync,
};

int ouichefs_truncate(struct inode *inode)
{
	int ret;
	struct super_block *sb = inode->i_sb;
	struct ouichefs_sb_info *sbi = OUICHEFS_SB(sb);
	struct ouichefs_inode_info *inode_info = OUICHEFS_INODE(inode);
	struct buffer_head *bh;
	size_t next_num_blocks;

	bh = sb_bread(sb, inode_info->index_block);
	if (!bh) {
		ret = -EIO;
		goto out;
	}

	ret = block_truncate_page(inode->i_mapping, inode->i_size,
				  ouichefs_file_get_block);
	if (ret < 0)
		goto out_brelse;

	struct ouichefs_file_index_block *index =
		(struct ouichefs_file_index_block *)bh->b_data;

	next_num_blocks = (inode->i_size + sb->s_blocksize - 1) >>
			  sb->s_blocksize_bits;
	// Iterate over all extents
	for (size_t i = next_num_blocks; i < OUICHEFS_MAX_EXTENTS; ++i) {
		unsigned int count = le32_to_cpu(index->extents[i].count);

		// Iterate over all blocks in the extent
		for (int j = 0; j < count; ++j) {
			put_block(sbi,
				  le32_to_cpu(index->extents[i].start) + j);
			--inode->i_blocks;
		}

		// 0 is the same in big and little endian
		index->extents[i].start = 0;
		index->extents[i].count = 0;
	}

	mark_buffer_dirty(bh);
	brelse(bh);

	mark_inode_dirty(inode);

	return 0;

out_brelse:
	brelse(bh);
out:
	return ret;
}
