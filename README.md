# homelab-scripts
Welcome to my [homelab-scripts](https://github.com/sendmebits/homelab-scripts/) repository! This is a collection of scripts I’ve put together to streamline various tasks in my homelab. While their primary purpose is to help me with automation, backup and version control, I figured they might be useful to others too, so feel free to explore and adapt them.

## Categories

### 🛠️ General Scripts
These scripts are versatile and can be used on any Linux system, including Proxmox hosts. Useful for a variety of common tasks.

- `general/check_images.py`: Scans docker compose files and checks running containers for available updates.
- `general/cleanup.sh`: General Linux cleanup script for Debian/Ubuntu that performs comprehensive system cleanup.
- `general/disk-health.sh`: Checks the health of specified disks using SMART data and logs errors or sends alerts.
- `general/disk-host-full.sh`: Checks if disks are reaching a specified usage threshold and sends an email alert.

### 📦 LXC Scripts
Scripts specifically designed for use within Proxmox LXC containers. Configuring, managing, and automating tasks inside containers.

- `lxc/lxc-post-install.sh`: Post install script for Proxmox LXC's to automatically apply customizations after deployment.

### 🖥️ Proxmox Scripts
These scripts are tailored for Proxmox VE hosts. While some may work in other environments with minor tweaks, they’re primarily focused on Proxmox-specific use cases.

- `proxmox/disk-lxc-full.sh`: Checks all running LXC containers to ensure their disks aren't critically full.
- `proxmox/disk-lxc-warning.sh`: Checks all running LXC containers to ensure their disks aren't getting full.
- `proxmox/disk-lxk-trim.sh`: Performs a disk trim operation for all LXC containers to reclaim unused space.
- `proxmox/pve_backup.sh`: Backs up PVE config data and key scripts to the backup directory.

---

Feel free to fork, tweak, and break things—just don’t @ me when you accidentally nuke your homelab. Kidding (mostly). If you have improvements or ideas, open a PR or drop an issue. Sharing ideas is always welcome, many of these scripts were created to solve a problem quickly and I'm sure there are more creative solutions.

Happy scripting! 🚀
