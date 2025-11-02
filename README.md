# 🚀 n8n-files Deployment Guide

## 🧩 One-Line Deployment (Ubuntu Server)

Run this command on your **Ubuntu server** (with sudo privileges) to install Git, clone the repository, and start the n8n service.

```bash
sudo apt update && sudo apt install -y git && rm -rf n8n-files && \
git clone https://github.com/atharv-pingle/n8n-files.git && \
cd n8n-files && sudo bash set2.sh start
```

---

## 💾 Backup Data (Server → Local Windows)

Use this command to **back up your n8n data** from the server to your **Windows PC** via WSL.

> ⚙️ **Note:**
>
> * Replace `~/.ssh/ubuntu` with the path to your SSH key.
> * Replace `------` with your server’s IP address.
> * Run this from your **Windows WSL terminal**.

```bash
rsync -avz -e "ssh -i ~/.ssh/ubuntu" ubuntu@<your-ip>:/home/ubuntu/n8n-files/n8n-data/ \
"/mnt/c/Users/athar/Desktop/Devops 2025/n8n backups/n8n-data"
```

---

### 🧠 Notes

* Ensure your server’s SSH access is properly configured.
* Backups will be stored in the specified Windows directory.
* You can modify the `set2.sh` script to customize your n8n setup.
