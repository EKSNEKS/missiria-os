# Backup Sender

Companion script to `site-auto-backup.sh`.  
Ships local backup runs to one or more remote servers via **rsync over SSH**.

---

## How It Works

```
[This Server]                         [Remote Server(s)]
  /var/backups/missiria-auto/
    20240501_030000/        ──rsync──▶  /var/backups/remote/20240501_030000/
      example.com/                        example.com/
        files.tar.gz                        files.tar.gz
        mydb.sql.gz                         mydb.sql.gz
        backup-info.txt                     backup-info.txt
```

The remote directory structure mirrors the local one exactly.  
You can configure **any number of remote servers** in a single config file.

---

## Requirements

| Tool     | Purpose                              | Install                |
|----------|--------------------------------------|------------------------|
| `rsync`  | File transfer                        | `apt install rsync`    |
| `ssh`    | Transport (key auth)                 | included in OpenSSH    |
| `sshpass`| Password auth (optional, less secure)| `apt install sshpass`  |

**SSH key authentication is strongly recommended** for automated/cron use.

---

## Step 1 — Create the Config Directory

```bash
mkdir -p /etc/missiria
chmod 700 /etc/missiria
```

---

## Step 2 — Create the Server Config File

```bash
nano /etc/missiria/backup-sender.conf
```

**Format:** one server per line, pipe-separated:

```
# ALIAS|HOST|PORT|USER|REMOTE_PATH|SSH_KEY
# ─────────────────────────────────────────────────────────────────────────────
# ALIAS        Short name for this server (letters, digits, dash, underscore)
# HOST         Hostname or IP address of the remote server
# PORT         SSH port (usually 22)
# USER         SSH username on the remote server
# REMOTE_PATH  Absolute path on the remote server to store backups
# SSH_KEY      Absolute path to your private SSH key
#              Use - (dash) for password auth instead of key auth
```

**Example with multiple servers:**

```
prod-vps|185.100.200.50|22|backupuser|/var/backups/sites|/root/.ssh/id_rsa_prod
staging|staging.mysite.com|2222|ubuntu|/home/ubuntu/backups|/root/.ssh/id_rsa_staging
hetzner|65.21.100.200|22|root|/mnt/backup-volume/sites|/root/.ssh/id_rsa_hetzner
ovh-vps|51.75.200.100|22|debian|/var/backups/remote|/root/.ssh/id_rsa_ovh
```

Blank lines and lines starting with `#` are ignored.

---

## Step 3 — Set Up SSH Key Authentication (Recommended)

Do this **once per remote server**:

```bash
# 1. Generate a dedicated backup SSH key (no passphrase for automation)
ssh-keygen -t ed25519 -C "backup-sender@$(hostname)" -f /root/.ssh/id_rsa_prod -N ""

# 2. Copy the public key to the remote server
ssh-copy-id -i /root/.ssh/id_rsa_prod.pub -p 22 backupuser@185.100.200.50

# 3. Verify it works without a password prompt
ssh -i /root/.ssh/id_rsa_prod -p 22 backupuser@185.100.200.50 "echo OK"
```

Repeat for each server with its corresponding key and alias.

### Restrict the backup user on the remote server (optional but recommended)

On the remote server, create a restricted backup user:

```bash
# On the REMOTE server:
useradd -m -s /bin/bash backupuser
mkdir -p /var/backups/sites
chown backupuser:backupuser /var/backups/sites

# Restrict to rsync-only by adding this to /home/backupuser/.ssh/authorized_keys:
command="rsync --server --sender -logDtpre.iLsfxCIvu . /var/backups/sites/",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding ssh-ed25519 AAAA...your-public-key...
```

---

## Step 4 — Password Auth (Alternative, Less Secure)

If SSH keys are not an option, use password auth:

1. Set `SSH_KEY` to `-` in the config file:
   ```
   myserver|192.168.1.100|22|ubuntu|/var/backups/remote|-
   ```

2. Set the password using one of these methods:

   **Option A — Environment variable (best for cron):**
   ```bash
   # Variable name: SSHPASS_<ALIAS_UPPERCASED>
   # Dashes and dots in the alias become underscores
   export SSHPASS_MYSERVER="your-password-here"
   ```

   **Option B — Passwords file:**
   ```bash
   nano /etc/missiria/backup-sender-passwords.conf
   chmod 600 /etc/missiria/backup-sender-passwords.conf
   ```
   ```
   # alias=password
   myserver=your-password-here
   staging-vps=another-password
   ```

> **Note:** `sshpass` must be installed: `apt install sshpass`

---

## Usage

```bash
# Make executable (first time only)
chmod +x /home/missiria/linux-terminal-tools/batches/backup-sender.sh

# Send the latest backup run to all servers
./backup-sender.sh

# Send to a specific server only
./backup-sender.sh --server prod-vps

# Send to multiple specific servers
./backup-sender.sh --server prod-vps --server staging

# Send all backup runs (useful for initial sync)
./backup-sender.sh --all

# Send a specific run by timestamp
./backup-sender.sh --run 20240501_030000

# List available runs and configured servers
./backup-sender.sh --list

# Preview what would be transferred without sending
./backup-sender.sh --dry-run

# Dry run for a specific server and run
./backup-sender.sh --dry-run --server prod-vps --run 20240501_030000
```

---

## Cron Job Setup

### Recommended Schedule

Run the backup sender **after** the auto-backup script has finished.

```bash
crontab -e
```

```cron
# ─────────────────────────────────────────────────────────────────────────────
# Site auto-backup: runs at 02:00 every day
# ─────────────────────────────────────────────────────────────────────────────
0 2 * * * /home/missiria/linux-terminal-tools/batches/site-auto-backup.sh >> /var/log/site-auto-backup.log 2>&1

# ─────────────────────────────────────────────────────────────────────────────
# Backup sender: runs at 03:00 every day (1 hour after backup completes)
# ─────────────────────────────────────────────────────────────────────────────
0 3 * * * /home/missiria/linux-terminal-tools/batches/backup-sender.sh >> /var/log/backup-sender.log 2>&1
```

> Leave enough time between the two jobs for the backup to complete.
> For large sites, adjust the gap accordingly.

### With Password Auth in Cron

If you're using password auth, export the variable in the cron job:

```cron
0 3 * * * SSHPASS_MYSERVER="secret" /home/missiria/linux-terminal-tools/batches/backup-sender.sh >> /var/log/backup-sender.log 2>&1
```

Or source a secrets file (chmod 600) at the top of a wrapper script:

```bash
#!/usr/bin/env bash
# /usr/local/bin/run-backup-sender.sh
source /etc/missiria/backup-env-secrets   # contains: export SSHPASS_MYSERVER=...
exec /home/missiria/linux-terminal-tools/batches/backup-sender.sh "$@"
```

```cron
0 3 * * * /usr/local/bin/run-backup-sender.sh >> /var/log/backup-sender.log 2>&1
```

---

## Environment Variables Reference

All variables can be set in the environment or exported before running the script.

| Variable              | Default                                       | Description                              |
|-----------------------|-----------------------------------------------|------------------------------------------|
| `BACKUP_BASE_DIR`     | `/var/backups/missiria-auto`                  | Local backup root directory              |
| `SENDER_CONFIG`       | `/etc/missiria/backup-sender.conf`            | Path to the server config file           |
| `SENDER_PASSWORDS`    | `/etc/missiria/backup-sender-passwords.conf`  | Path to the passwords file               |
| `CONNECT_TIMEOUT`     | `15`                                          | SSH connection timeout in seconds        |
| `RSYNC_TIMEOUT`       | `300`                                         | rsync I/O timeout in seconds             |
| `MAX_RETRIES`         | `3`                                           | Retry attempts per server on failure     |
| `RETRY_DELAY`         | `10`                                          | Seconds to wait between retries          |
| `DRY_RUN`             | `0`                                           | Set to `1` to preview without sending    |
| `RSYNC_DELETE`        | `0`                                           | Set to `1` to delete files on remote that no longer exist locally |
| `SSHPASS_<ALIAS>`     | *(none)*                                      | Password for a server using `-` as key   |

**Example with custom paths:**

```bash
BACKUP_BASE_DIR=/mnt/backups \
SENDER_CONFIG=/opt/myconfig.conf \
MAX_RETRIES=5 \
./backup-sender.sh --server prod-vps
```

---

## Adding a New Server

1. Generate or reuse an SSH key pair.
2. Copy the public key to the remote server: `ssh-copy-id -i ~/.ssh/id_rsa_newserver.pub user@host`
3. Add one line to `/etc/missiria/backup-sender.conf`:
   ```
   newserver|1.2.3.4|22|backupuser|/var/backups/sites|/root/.ssh/id_rsa_newserver
   ```
4. Test: `./backup-sender.sh --server newserver --dry-run`
5. First real sync: `./backup-sender.sh --all --server newserver`

---

## File Structure on Remote Servers

```
REMOTE_PATH/
├── 20240501_030000/          ← one directory per backup run
│   ├── example.com/
│   │   ├── files.tar.gz
│   │   ├── mydb.sql.gz
│   │   └── backup-info.txt
│   └── myapp.com/
│       ├── files.tar.gz
│       └── backup-info.txt
├── 20240502_030000/
│   └── ...
└── 20240503_030000/
    └── ...
```

---

## Troubleshooting

### Connection refused / timeout
- Check that SSH is running on the remote: `ssh -p PORT user@host`
- Verify firewall allows the SSH port
- Increase `CONNECT_TIMEOUT`: `CONNECT_TIMEOUT=30 ./backup-sender.sh`

### Host key verification failed
The remote server's SSH key changed. If expected, update known_hosts:
```bash
ssh-keygen -R [hostname]:port
ssh -i /root/.ssh/id_rsa_prod -p 22 backupuser@host  # accept new key
```

### Permission denied (publickey)
- Confirm the public key is in `~/.ssh/authorized_keys` on the remote
- Check key permissions: `chmod 600 /root/.ssh/id_rsa_prod`
- Test manually: `ssh -v -i /root/.ssh/id_rsa_prod -p 22 user@host`

### rsync: failed to set times on remote
The remote user doesn't own the destination directory. Fix on the remote:
```bash
chown -R backupuser:backupuser /var/backups/sites
```

### sshpass: not found
```bash
apt install sshpass   # Debian/Ubuntu
yum install sshpass   # CentOS/RHEL
```

### No backup runs found
Ensure `site-auto-backup.sh` has run at least once and check:
```bash
ls /var/backups/missiria-auto/
```

---

## Security Notes

- SSH keys are always preferred over passwords.
- Store the passwords file at `chmod 600` — readable only by root.
- Never commit the passwords file or private keys to git.
- Use `StrictHostKeyChecking=accept-new` (the default) — it auto-accepts new host keys but will fail if a known host key changes, protecting against MITM.
- Consider creating a restricted `backupuser` on remote servers with no shell access.
