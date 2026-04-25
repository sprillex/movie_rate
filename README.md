# Movie Ranker

Movie Ranker is a Python web application built with Flask that synchronizes metadata from a Plex server and uses TMDB and yt-dlp to manage movie trailers. It ranks your movies using an Elo rating system.

## Prerequisites
* Linux (Mint, Ubuntu, Debian, Raspbian)
* Python 3 installed (`sudo apt install python3-venv`)
* Git

## Quick Start

1.  **Clone the repository and enter the directory:**
    ```bash
    git clone https://github.com/your-username/movie_rate.git
    cd movie_rate
    ```

2.  **Make executable:**
    ```bash
    chmod +x update.sh
    ```

3.  **Run the menu:**
    ```bash
    ./update.sh
    ```

## Installation Workflow

This application uses a generic, self-healing installer (`update.sh`) for deploying Python scripts as systemd services on Linux.

1.  **Test:** Select **Run Test**. This creates a temporary local environment and runs your script.
2.  **Cleanup:** Select **Cleanup Test** to remove the temporary files.
3.  **Install:** Select **Install Service**. This requires `sudo`. It will prompt you for configuration (including API keys) and create a persistent service in `/opt`.
4.  **Upgrade:** When you update your code on GitHub, run **Upgrade Service**. It will pull the latest code and restart the service.

### Universal Update Manager
The `universal_update_manager.sh` script is provided to facilitate cross-service mass updates without user intervention.
