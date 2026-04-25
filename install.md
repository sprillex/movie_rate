# Python Service Manager

A generic, self-healing installer for deploying Python scripts as systemd services on Linux.

## Features
* **Interactive Setup:** Prompts for service name, user, and description.
* **Virtual Environments:** Automatically manages `venv` for both testing and production.
* **Secret Management:** Securely handles API keys using `example.env` templates.
* **Self-Updating:** The installer checks for updates to itself during the upgrade process.
* **Git Integration:** Supports deploying specific branches (Main, Newest, or Custom).
* **Universal Update Manager Compatibility:** Built to be invoked automatically by `universal_update_manager.sh`.

## Universal Update Manager

The file `universal_update_manager.sh` is an external manager script (typically placed in the user's home directory or a subfolder). Its purpose is to index subfolders and automatically discover compliance standard `update.sh` (formerly `manage_service.sh` or `upgrade.sh`) files across multiple installed services.

If you are building a new project based on this template, you should ensure that your service's `update.sh` complies with the `universal_update_manager.sh` features. Specifically, your `update.sh` should be prepared to receive standard CLI flags (`--update`, `--main`, `--newest`, `--settings`, `--status`, `--logs`, `--help`) to facilitate cross-service mass updates and management without user intervention.

## Prerequisites
* Linux (Mint, Ubuntu, Debian, Raspbian)
* Python 3 installed (`sudo apt install python3-venv`)
* Git

## Quick Start

1.  **Prepare your project:**
    Ensure your folder contains:
    * `update.sh` (The installer / service manager)
    * `main.py` (Your python script)
    * `requirements.txt` (Dependencies)
    * `example.env` (Optional: List of required API keys)

2.  **Make executable:**
    ```bash
    chmod +x update.sh
    ```

3.  **Run the menu:**
    ```bash
    ./update.sh
    ```

## Workflow
1.  **Test:** Select **Run Test**. This creates a temporary local environment and runs your script.
2.  **Cleanup:** Select **Cleanup Test** to remove the temporary files.
3.  **Install:** Select **Install Service**. This requires `sudo`. It will prompt you for configuration and create a persistent service in `/opt`.
4.  **Upgrade:** When you update your code on GitHub, run **Upgrade Service**. It will pull the latest code and restart the service.

## Configuration Files
* `service_config.env`: Stores non-sensitive installation settings (Service Name, Path, User).
* `secrets.env`: Stores sensitive API keys. **This file is never committed to Git.**
* `example.env`: A template file you create to tell the installer which keys to ask for.

## Uninstalling
Run the script and select **Uninstall**. This will:
1.  Stop the systemd service.
2.  Remove the unit file from `/etc/systemd/system`.
3.  (Optionally) Delete the installation directory and all data.
