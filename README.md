### Docker Setup for Frappe apps without Traefik 

Use this script to deploy **Frappe without Traefik** and its associated applications (**ERPNext, HRMS, Payments**) to your Docker environment. The installation pulls pre-packaged Git dependencies from the container registry: `ghcr.io/abc101/frappe-custom-apps`.

# Quick Start
1. Copy `example.user.env` to a new file named `user.env`.
2. Run the installation file: `install-frappe-apps.sh`.
3. Your setup is complete.
