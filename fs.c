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

uint32_t reservation_size = 8;
module_param(reservation_size, uint, 0644);
MODULE_PARM_DESC(reservation_size,
		 "Reservation size for the contiguous block allocator");

static int major;
static struct kobject *ouichefs_kobj;

// ReSharper disable once CppParameterNeverUsed
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

		const struct ouichefs_sb_info *sbi = OUICHEFS_SB(sb);
		pr_info("ouichefs: extents for inode %ld: %d extent(s), "
			"%d reserved block(s) at %d, gc_count=%u\n",
			inode->i_ino, extent_count, ci->i_reserved_count,
			ci->i_reserved_start, sbi->gc_count);

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

//sysfs stats

static void
ouichefs_stats_warn_on_sanity_fail(const struct ouichefs_sb_info *sbi)
{
	if (sbi->nr_blocks != sbi->nr_free_blocks + sbi->nr_committed_blocks +
				      sbi->nr_reserved_blocks) {
		pr_warn("ouichefs: sanity check failed: nr_blocks=%u, "
			"nr_free_blocks=%u, nr_committed_blocks=%u, "
			"nr_reserved_blocks=%u\n",
			sbi->nr_blocks, sbi->nr_free_blocks,
			sbi->nr_committed_blocks, sbi->nr_reserved_blocks);
	}
}

static ssize_t free_blocks_show(struct kobject *kobj,
				struct kobj_attribute *attr, char *buf)
{
	const struct ouichefs_sb_info *sbi = OUICHEFS_SB_FROM_KOBJ(kobj);
	ouichefs_stats_warn_on_sanity_fail(sbi);
	return sysfs_emit(buf, "%u\n", sbi->nr_free_blocks);
}

static struct kobj_attribute ouichefs_free_blocks_attr = __ATTR_RO(free_blocks);

static ssize_t commited_blocks_show(struct kobject *kobj,
				    struct kobj_attribute *attr, char *buf)
{
	const struct ouichefs_sb_info *sbi = OUICHEFS_SB_FROM_KOBJ(kobj);
	ouichefs_stats_warn_on_sanity_fail(sbi);
	return sysfs_emit(buf, "%u\n", sbi->nr_committed_blocks);
}

static struct kobj_attribute ouichefs_commited_blocks_attr =
	__ATTR_RO(commited_blocks);

static ssize_t reserved_blocks_show(struct kobject *kobj,
				    struct kobj_attribute *attr, char *buf)
{
	const struct ouichefs_sb_info *sbi = OUICHEFS_SB_FROM_KOBJ(kobj);
	ouichefs_stats_warn_on_sanity_fail(sbi);
	return sysfs_emit(buf, "%u\n", sbi->nr_reserved_blocks);
}

static struct kobj_attribute ouichefs_reserved_blocks_attr =
	__ATTR_RO(reserved_blocks);

static ssize_t files_show(struct kobject *kobj, struct kobj_attribute *attr,
			  char *buf)
{
	const struct ouichefs_sb_info *sbi = OUICHEFS_SB_FROM_KOBJ(kobj);
	return sysfs_emit(buf, "%u\n", sbi->nr_regular_files);
}

static struct kobj_attribute ouichefs_files_attr = __ATTR_RO(files);

static ssize_t total_extents_show(struct kobject *kobj,
				  struct kobj_attribute *attr, char *buf)
{
	const struct ouichefs_sb_info *sbi = OUICHEFS_SB_FROM_KOBJ(kobj);
	return sysfs_emit(buf, "%u\n", sbi->nr_total_extents);
}

static struct kobj_attribute ouichefs_total_extents_attr =
	__ATTR_RO(total_extents);

static ssize_t avg_extent_size_show(struct kobject *kobj,
				    struct kobj_attribute *attr, char *buf)
{
	const struct ouichefs_sb_info *sbi = OUICHEFS_SB_FROM_KOBJ(kobj);
	const uint32_t avg_extent_size =
		sbi->nr_total_extents ? sbi->accumulated_extents_size * 100 /
						sbi->nr_total_extents :
					0;
	return sysfs_emit(buf, "%u\n", avg_extent_size);
}

static struct kobj_attribute ouichefs_avg_extent_size_attr =
	__ATTR_RO(avg_extent_size);

static ssize_t max_file_size_show(struct kobject *kobj,
				  struct kobj_attribute *attr, char *buf)
{
	const struct ouichefs_sb_info *sbi = OUICHEFS_SB_FROM_KOBJ(kobj);
	return sysfs_emit(buf, "%u\n", sbi->max_file_size);
}

static struct kobj_attribute ouichefs_max_file_size_attr =
	__ATTR_RO(max_file_size);

static ssize_t fragmentation_show(struct kobject *kobj,
				  struct kobj_attribute *attr, char *buf)
{
	const struct ouichefs_sb_info *sbi = OUICHEFS_SB_FROM_KOBJ(kobj);
	const uint32_t fragmentation =
		sbi->nr_regular_files ?
			sbi->nr_total_extents * 100 / sbi->nr_regular_files :
			0;
	return sysfs_emit(buf, "%u\n", fragmentation);
}

static struct kobj_attribute ouichefs_fragmentation_attr =
	__ATTR_RO(fragmentation);

static ssize_t reservation_window_show(struct kobject *kobj,
				       struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%u\n", reservation_size);
}

static ssize_t reservation_window_store(struct kobject *kobj,
					struct kobj_attribute *attr,
					const char *buf, const size_t count)
{
	if (kstrtou32(buf, 0, &reservation_size)) {
		pr_err("Failed to parse reservation window\n");
	}
	return (ssize_t) count;
}

static struct kobj_attribute ouichefs_reservation_window_attr =
	__ATTR_RW(reservation_window);

static ssize_t gc_count_show(struct kobject *kobj, struct kobj_attribute *attr,
			     char *buf)
{
	const struct ouichefs_sb_info *sbi = OUICHEFS_SB_FROM_KOBJ(kobj);
	return sysfs_emit(buf, "%u\n", sbi->gc_count);
}

static struct kobj_attribute ouichefs_gc_count_attr = __ATTR_RO(gc_count);

static struct attribute *ouichefs_attrs[] = {
	&ouichefs_free_blocks_attr.attr,
	&ouichefs_commited_blocks_attr.attr,
	&ouichefs_reserved_blocks_attr.attr,
	&ouichefs_files_attr.attr,
	&ouichefs_total_extents_attr.attr,
	&ouichefs_avg_extent_size_attr.attr,
	&ouichefs_max_file_size_attr.attr,
	&ouichefs_fragmentation_attr.attr,
	&ouichefs_reservation_window_attr.attr,
	&ouichefs_gc_count_attr.attr,
	NULL,
};

static struct attribute_group ouichefs_stats_attr_group = {
	.attrs = ouichefs_attrs,
};

static struct kobj_type ouichefs_kobj_type = {
	.sysfs_ops = &kobj_sysfs_ops,
};

static int ouichefs_init_stats(struct ouichefs_sb_info *sbi,
			       const char *partition_name)
{
	int ret = kobject_init_and_add(&sbi->partition_kobj,
				       &ouichefs_kobj_type, ouichefs_kobj, "%s",
				       partition_name);

	if (ret) {
		goto out;
	}

	ret = sysfs_create_group(&sbi->partition_kobj,
				 &ouichefs_stats_attr_group);
	if (ret) {
		goto out;
	}
	return 0;
out:
	kobject_put(&sbi->partition_kobj);
	return ret;
}

static int ouichefs_remove_stats(struct ouichefs_sb_info *sbi)
{
	sysfs_remove_group(&sbi->partition_kobj, &ouichefs_stats_attr_group);
	kobject_put(&sbi->partition_kobj);
	return 0;
}

//end sysfs stats

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
	if (IS_ERR(dentry)) {
		pr_err("'%s' mount failure\n", dev_name);
		goto out_mount_failure;
	}

	pr_info("'%s' mount success\n", dev_name);

	const struct super_block *sb = dentry->d_sb;
	struct ouichefs_sb_info *sbi = OUICHEFS_SB(sb);
	const char *partition_name = kbasename(dev_name);
	if (ouichefs_init_stats(sbi, partition_name)) {
		pr_warn("Failed to initialize sysfs-stats for partition %s\n",
			dev_name);
		//no exit here since since mount was still successful and
		// filesystem can be used
	}

	return dentry;
out_mount_failure:
	return dentry;
}

/*
 * Unmount a ouiche_fs partition
 */
static void ouichefs_kill_sb(struct super_block *sb)
{
	ouichefs_remove_stats(OUICHEFS_SB(sb));

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
		goto out;
	}

	ret = register_filesystem(&ouichefs_file_system_type);
	if (ret) {
		pr_err("register_filesystem() failed\n");
		goto out_inode;
	}

	major = register_chrdev(0, "ouichefs", &ouichefs_ioctl_fops);

	if (major < 0) {
		ret = major;
		goto out_inode;
	}

	//create /sys/ouichefs
	ouichefs_kobj = kobject_create_and_add("ouichefs", NULL);
	if (!ouichefs_kobj) {
		ret = -ENOMEM;
		goto out_ioctl;
	}

	pr_info("module loaded\n");
	return 0;
out_ioctl:
	unregister_chrdev(major, "ouichefs");
out_inode:
	ouichefs_destroy_inode_cache();
out:
	return ret;
}

static void __exit ouichefs_exit(void)
{
	kobject_put(ouichefs_kobj);

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
