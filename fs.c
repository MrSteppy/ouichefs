// SPDX-License-Identifier: GPL-2.0
/*
 * ouiche_fs - a simple educational filesystem for Linux
 *
 * Copyright (C) 2018  Redha Gouicem <redha.gouicem@lip6.fr>
 */

#include <linux/buffer_head.h>
#include <linux/file.h>

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/fs.h>

#include "ouichefs.h"
#include "extent_ioctl.h"

static int major;

static long ouichefs_unlocked_ioctl(struct file *f,
				    const unsigned int request_nr,
				    const unsigned long buf)
{
	int ret = 0;
	if (request_nr == OUICHEFS_IOC_GET_EXTENTS) {
		unsigned int kernel_fd;

		if (copy_from_user(&kernel_fd, (unsigned int __user *)buf,
				   sizeof(kernel_fd))) {
			pr_err("Failed to read file descriptor from userspace\n");
			return -EFAULT;
		}

		struct file *file = fget(kernel_fd);
		if (!file) {
			pr_err("Failed to open file\n");
			return -EBADF;
		}

		//ensure the file is a ouichefs file
		if (file->f_op != &ouichefs_file_ops) {
			pr_err("File is not a ouichefs file\n");
			ret = -EINVAL;
			goto out_fput;
		}

		const struct inode *inode = file->f_inode;
		const struct ouichefs_inode_info *ci = OUICHEFS_INODE(inode);

		struct super_block *sb = inode->i_sb;
		struct buffer_head *bh_index = sb_bread(sb, ci->index_block);

		if (!bh_index) {
			pr_err("Failed to read index block\n");
			ret = -EIO;
			goto out_fput;
		}

		const struct ouichefs_file_index_block *index =
			(struct ouichefs_file_index_block *)bh_index->b_data;

		//count the number of used extents
		int extent_count = 0;
		const struct ouichefs_extent *extents = index->extents;
		while (extents[extent_count].count != 0 &&
		       extent_count < OUICHEFS_MAX_EXTENTS)
			extent_count++;

		pr_info("ouichefs: extents for inode %ld: %d extent(s)\n",
			inode->i_ino, extent_count);

		for (size_t extent_index = 0;
		     extents[extent_index].count != 0 &&
		     extent_index < OUICHEFS_MAX_EXTENTS;
		     extent_index++) {
			const struct ouichefs_extent extent =
				extents[extent_index];
			const uint32_t start = le32_to_cpu(extent.start);
			const uint32_t count = le32_to_cpu(extent.count);
			pr_info("[%lu] start=%d count=%d  (blocks %d–%d)\n",
				extent_index, start, count, start,
				start + count - 1);
		}

		brelse(bh_index);
		fput(file);
		return 0;

out_fput:
		fput(file);
		return ret;
	}

	return -ENOTTY;
}

static struct file_operations ouichefs_ioctl_fops = {
	.owner = THIS_MODULE,
	.unlocked_ioctl = ouichefs_unlocked_ioctl,
};

/*
 * Mount a ouiche_fs partition
 */
static struct dentry *ouichefs_mount(struct file_system_type *fs_type,
				     const int flags, const char *dev_name,
				     void *data)
{
	struct dentry *dentry = NULL;

	dentry =
		mount_bdev(fs_type, flags, dev_name, data, ouichefs_fill_super);
	if (IS_ERR(dentry))
		pr_err("'%s' mount failure\n", dev_name);
	else
		pr_info("'%s' mount success\n", dev_name);

	return dentry;
}

/*
 * Unmount a ouiche_fs partition
 */
static void ouichefs_kill_sb(struct super_block *sb)
{
	kill_block_super(sb);

	pr_info("unmounted disk\n");
}

static struct file_system_type ouichefs_file_system_type = {
	.owner = THIS_MODULE,
	.name = "ouichefs",
	.mount = ouichefs_mount,
	.kill_sb = ouichefs_kill_sb,
	.fs_flags = FS_REQUIRES_DEV,
	.next = NULL,
};

static int __init ouichefs_init(void)
{
	int ret = ouichefs_init_inode_cache();
	if (ret) {
		pr_err("inode cache creation failed\n");
		goto err;
	}

	ret = register_filesystem(&ouichefs_file_system_type);
	if (ret) {
		pr_err("register_filesystem() failed\n");
		goto err_inode;
	}

	major = register_chrdev(0, "ouichefs", &ouichefs_ioctl_fops);

	if (major < 0) {
		ret = major;
		goto err_inode;
	}

	pr_info("module loaded\n");
	return 0;

err_inode:
	ouichefs_destroy_inode_cache();
err:
	return ret;
}

static void __exit ouichefs_exit(void)
{
	unregister_chrdev(major, "ouichefs");

	const int ret = unregister_filesystem(&ouichefs_file_system_type);
	if (ret)
		pr_err("unregister_filesystem() failed\n");

	ouichefs_destroy_inode_cache();

	pr_info("module unloaded\n");
}

module_init(ouichefs_init);
module_exit(ouichefs_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Redha Gouicem, <redha.gouicem@rwth-aachen.de>");
MODULE_DESCRIPTION("ouichefs, a simple educational filesystem for Linux");
