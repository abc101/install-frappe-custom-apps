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

### 🧱 Building Your Own Image

If you want to build a custom Docker image with your own app versions, use the following script instead:

```bash
./docker-builder-frappe-apps.sh
```

and then set `CUSTOM_IMAGE` with your docker image repository in your `user.env` for `install=frappe-apps.sh`.
