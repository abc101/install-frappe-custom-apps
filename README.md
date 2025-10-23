![status](https://img.shields.io/badge/Status-Development-orange?style=for-the-badge&logo=github)

> ⚠️ **Warning — Development Version**
>
> This branch is currently under active development and has not yet been fully tested.  
> Please use this version **only for testing and feedback** until it’s merged into `main`.

### 🐳 Docker Setup for Frappe Apps (Without Traefik)

Use this script to deploy **Frappe (without Traefik)** along with its associated applications — **ERPNext**, **HRMS**, and **Payments** — in your Docker environment.

This installation automatically pulls pre-packaged Git dependencies from the container registry:
`ghcr.io/abc101/frappe-custom-apps`

> ⚙️ The Docker image tag (version) **must match** the image version specified in `frappe_docker/pwd.yml`.

---

### 🚀 Quick Start

1. Copy the example environment file:

   ```bash
   cp example.env user.env
   ```
2. Run the installation script:

   ```bash
   ./install-frappe-apps.sh
   ```
3. Sit back — your Frappe environment is now ready!

---

### ⚙️ User Configuration (`user.env`)

When running `install-frappe-apps.sh`, the installer now detects whether a `user.env` configuration file exists in the same directory as the script.

#### 📁 If `user.env` exists:
You will be prompted to choose one of the following options:

| Option | Action |
|---------|---------|
| **U** (Default) | Use the existing `user.env` configuration for installation. |
| **D** | Discard `user.env` and proceed with built-in default settings. |
| **C** | Cancel installation. |

#### 📄 If `user.env` does **not** exist:
The installer offers you the following choices:

| Option | Action |
|---------|---------|
| **D** (Default) | Continue with built-in defaults (no `user.env` loaded). |
| **G** | Generate a new `user.env` template and exit, so you can edit it before re-running the script. |
| **C** | Cancel installation. |

#### ⚙️ Non-interactive usage
For automated or CI environments, you can control this behavior using environment variables:

| Variable | Description | Example |
|-----------|--------------|----------|
| `SKIP_CONFIRM=yes` | Skip all prompts (non-interactive mode). | |
| `USE_DEFAULT=yes` | Ignore existing `user.env` and use defaults. | `USE_DEFAULT=yes SKIP_CONFIRM=yes ./install-frappe-apps.sh` |
| `NEW_USER_ENV=create` | Automatically generate a new `user.env` from template (if none exists). | `NEW_USER_ENV=create SKIP_CONFIRM=yes ./install-frappe-apps.sh` |

---

> 💡 *Tip:* Your `user.env` defines project-specific variables such as `EMAIL`, `DB_PASSWORD`, `BENCH`, and `SITES`.  
> You can safely keep multiple `user.env` files in different directories to manage different Frappe installations.

---

### ⚙️ Upgrade and Version Management

Starting from this release, `install-frappe-apps.sh` automatically detects existing deployments and handles upgrades safely.

#### 🧭 How it works

1. **Version Gate**  
   Before proceeding, the script compares the currently installed ERPNext version with the target version defined in `frappe_docker/pwd.yml` or `FRAPPE_ERPNEXT_VERSION`.  
   - If the target version is **newer**, the upgrade continues automatically.  
   - If the versions are **identical or older**, the script stops to prevent unnecessary redeployment.  
   - You can override this behavior with:
     ```bash
     FORCE_UPGRADE=yes ./install-frappe-apps.sh
     ```

2. **Upgrade Modes**
   - **Default (Upgrade in-place)** — preserves all existing data (database, files, and sites).  
     The script automatically performs:
       - Full backup (DB + files)
       - Maintenance mode
       - `docker compose pull && up -d`
       - Database migration (`bench migrate`)
       - Asset rebuild (`bench build --production`)
       - Restart and maintenance off  
   - **Fresh Reinstall (Destroy everything)** — removes all containers and volumes before reinstalling.  
     You can explicitly choose this mode interactively or run:
     ```bash
     INSTALL_MODE=fresh SKIP_CONFIRM=yes ./install-frappe-apps.sh
     ```

3. **First-Time Install**
   If no previous installation is detected, the script automatically performs a clean (fresh) installation.

4. **Backups**
   During upgrades, backups are automatically created inside the container and copied to:


---

### 🧪 Advanced Options

| Environment Variable | Description | Default |
|----------------------|--------------|----------|
| `INSTALL_MODE` | `upgrade` (preserve data) or `fresh` (reinstall everything) | `upgrade` if existing, otherwise `fresh` |
| `FORCE_UPGRADE` | Force redeploy even if versions are equal | `no` |
| `SKIP_CONFIRM` | Skip interactive confirmation prompts | unset |
| `HOST_BACKUP_DIR` | Path to store backups on the host | `./backups/<bench>-<timestamp>` |


---


### 🧱 Building Your Own Image

If you want to build a custom Docker image with your own app versions, use the following script instead:

```bash
./docker-builder-frappe-apps.sh
```

and then set `CUSTOM_IMAGE` with your docker image repository in your `user.env` for `install-frappe-apps.sh`.

