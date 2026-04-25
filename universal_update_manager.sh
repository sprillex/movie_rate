#!/bin/bash

TARGET_DIR="/home/dietpi"

# Collect flags and optionally a target folder name
FLAGS=()
TARGET_FOLDER=""

show_help() {
    echo "Usage: $0 [FOLDER_NAME] [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -u, --update    Passes the update flag to the target script"
    echo "  -m, --main      Passes the main branch flag to the target script"
    echo "  -n, --newest    Passes the newest branch flag to the target script"
    echo "  -c, --settings  Passes the settings flag to the target script"
    echo "  -s, --status    Passes the status flag to the target script"
    echo "  -l, --logs      Passes the logs flag to the target script"
    echo "  -r, --restart   Passes the restart flag to the target script"
    echo "  -h, --help      Displays this help message"
    echo ""
    echo "If FOLDER_NAME is provided, the script skips the menu and executes directly in that folder."
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--update|-m|--main|-n|--newest|-c|--settings|-s|--status|-l|--logs|-r|--restart)
            FLAGS+=("$1")
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            echo "Unknown flag: $1"
            show_help
            exit 1
            ;;
        *)
            if [ -z "$TARGET_FOLDER" ]; then
                TARGET_FOLDER="$1"
            else
                echo "Warning: Extra positional argument ignored: $1"
            fi
            shift
            ;;
    esac
done

# 1. Find all update.sh files and store full paths
mapfile -t full_paths < <(find "$TARGET_DIR" -maxdepth 3 -name "update.sh" 2>/dev/null)

if [ ${#full_paths[@]} -eq 0 ]; then
    echo "No 'update.sh' files found in $TARGET_DIR."
    exit 1
fi

# 2. Check if a valid target folder was provided to bypass the menu
if [ -n "$TARGET_FOLDER" ]; then
    found_path=""
    for path in "${full_paths[@]}"; do
        folder=$(dirname "$path")
        clean_folder=${folder#"$TARGET_DIR/"}
        if [ "$clean_folder" == "$TARGET_FOLDER" ]; then
            found_path="$path"
            break
        fi
    done

    if [ -n "$found_path" ]; then
        selected_dir=$(dirname "$found_path")
        echo -e "\nMoving to: $selected_dir"
        echo "Running: update.sh ${FLAGS[*]}..."
        echo "------------------------------------------"
        ( cd "$selected_dir" && bash "./update.sh" "${FLAGS[@]}" )
        exit 0
    else
        echo "Folder '$TARGET_FOLDER' with an 'update.sh' script not found."
        echo "Falling back to menu..."
        echo ""
    fi
fi

# 3. Create a clean list of folder names for the menu
menu_options=()
for path in "${full_paths[@]}"; do
    # Extract the directory and remove the "/home/dietpi/" prefix for a cleaner look
    folder=$(dirname "$path")
    clean_folder=${folder#"$TARGET_DIR/"}

    # If the script is in the root of /home/dietpi, label it clearly
    if [ "$clean_folder" == "$TARGET_DIR" ] || [ -z "$clean_folder" ]; then
        menu_options+=("Root (/home/dietpi)")
    else
        menu_options+=("$clean_folder")
    fi
done

echo "--- Sprillex: Select Folder to Update ---"
echo "------------------------------------------"

# 4. Display the menu using the clean folder names
PS3="Enter number (or ctrl+c to quit): "
select choice in "${menu_options[@]}"; do
    if [ -n "$choice" ]; then
        # Map the choice index back to the full path array
        # ((REPLY-1)) converts the menu number back to a 0-based array index
        selected_path="${full_paths[$((REPLY-1))]}"
        selected_dir=$(dirname "$selected_path")

        echo -e "\nMoving to: $selected_dir"
        echo "Running: update.sh ${FLAGS[*]}..."
        echo "------------------------------------------"

        # Execute in the correct context
        ( cd "$selected_dir" && bash "./update.sh" "${FLAGS[@]}" )

        break
    else
        echo "Invalid selection."
    fi
done
