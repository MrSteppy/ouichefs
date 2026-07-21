// SPDX-License-Identifier: GPL-2.0
/*
 * ouiche_fs - a simple educational filesystem for Linux
 *
 * Copyright (C) 2018  Redha Gouicem <redha.gouicem@lip6.fr>
 */

#include "linux/buffer_head.h"
#include "linux/file.h"

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/fs.h>

#include "ouichefs.h"
#include "extent_ioctl.h"

static unsigned int major;

static long ouiche_unlocked_ioctl(struct file *file, unsigned int request_nr,
				  unsigned long buf)

{
	if (request_nr == OUICHEFS_IOC_GET_EXTENTS) {
		unsigned int kernel_fd;

		if (copy_from_user(&kernel_fd, (unsigned int __user *)buf,
				   sizeof(kernel_fd)))
			return -EFAULT;

		struct file *file = fget(kernel_fd);
		if (!file)
			return -EBADF;

		struct ouichefs_inode_info *inode =
			OUICHEFS_INODE(file->f_inode);

		struct buffer_head *bh_index =
			sb_bread(inode->vfs_inode.i_sb, inode->index_block);

		if (!bh_index)
			return -EIO;

		struct ouichefs_file_index_block *index =
			(struct ouichefs_file_index_block *)bh_index->b_data;

		int iblock = 0;
		int extent_count = 0;
		while (index->extents[iblock].count != 0 &&
		       iblock < OUICHEFS_MAX_EXTENTS) {
			extent_count += 1;
			iblock += 1;
		}

		pr_info("ouichefs: extents for inode %ld: %d extent(s)\n",
			file->f_inode->i_ino, extent_count);

		iblock = 0;
		while (index->extents[iblock].count != 0 &&
		       iblock < OUICHEFS_MAX_EXTENTS) {
			pr_info("[%d] start=%d count=%d  (blocks %d–%d)\n",
				iblock,
				le32_to_cpu(index->extents[iblock].start),
				le32_to_cpu(index->extents[iblock].count),
				le32_to_cpu(index->extents[iblock].start),
				le32_to_cpu(index->extents[iblock].start) +
					le32_to_cpu(
						index->extents[iblock].count) -
					1);
			iblock += 1;
		}

		fput(file);
		return 0;
	} else {
		return -ENOTTY;
	}
}

static struct file_operations ouichefs_ioctl_fops = {
	.unlocked_ioctl = ouiche_unlocked_ioctl,
};

/*
 * Mount a ouiche_fs partition
 */
struct dentry *ouichefs_mount(struct file_system_type *fs_type, int flags,
			      const char *dev_name, void *data)
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
void ouichefs_kill_sb(struct super_block *sb)
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
	int ret;

	ret = ouichefs_init_inode_cache();
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

	pr_info("major number: %d\n", major);

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
	int ret;

	unregister_chrdev(major, "ouichefs");

	ret = unregister_filesystem(&ouichefs_file_system_type);
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
