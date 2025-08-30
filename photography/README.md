# Photography Scripts

This directory contains scripts related to photography workflows, such as backups and organization.

## Scripts

### `photo-backup.sh`

A robust script for backing up photo collections from multiple sources to a remote server using rsync.

#### Features
* **Multi-Source Sync**: Safely syncs two source directories to a single destination.
* **Deletion Protection**: Uses an rsync filter to ensure that files present in either source are not deleted from the destination.
* **Configurable**: All settings can be managed via a config file (`/etc/photo-backup.conf`) or command-line flags.
* **Logging**: Provides detailed logging with support for debug mode and optional log file output.
* **Dry-Run Mode**: Allows testing the sync operation without making any changes.

#### Dependencies
* `rsync`: The core utility for file synchronization.

#### Usage
The script requires several arguments to be provided, either through a configuration file or as command-line options.

```bash
# Example: Run a dry-run backup with debug logging
./photography/photo-backup.sh -1 /Volumes/PhotoStore -2 /Volumes/MorePhotos -H aurora -p /mnt/storage/photos -d -n
```
