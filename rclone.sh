#!/bin/bash

# Function to mount a single remote
mount_single_remote() {
    local remote_name="$1"
    local mount_point

    # Check if remote is already mounted
    current_mount=$(get_current_mount "$remote_name")
    if [ -n "$current_mount" ]; then
        echo "Skipping $remote_name: already mounted at $current_mount"
        return 0
    fi

    # Load configuration from settings
    local config_file="$HOME/.config/rclone-wrapper/settings.json"
    local mount_params=()  # Initialize the array
    
    if [ -f "$config_file" ]; then
        # Get mount point and parameters for this remote
        mount_point=$(jq -r ".[\"$remote_name\"].mount_point" "$config_file" 2>/dev/null)
        
        # Load mount parameters if they exist
        while IFS= read -r param; do
            mount_params+=("$param")
        done < <(jq -r ".[\"$remote_name\"].mount_params[]" "$config_file" 2>/dev/null || echo "")
    fi

    # Use default mount point if not configured
    if [ "$mount_point" = "null" ] || [ -z "$mount_point" ]; then
        mount_point="/mnt/rclone/$remote_name"
    fi

    # If GUI mode is enabled, show mount point selection
    if [ "$use_gui" = "true" ]; then
        # Create an array of common mount points
        local mount_options=(
            "/mnt/rclone/$remote_name" "Default mount point"
            "/media/$USER/$remote_name" "Media directory"
            "/home/$USER/mounts/$remote_name" "Home directory"
            "custom" "Specify custom path..."
        )

        # Show mount point selection menu
        selected_option=$(dialog --stdout --title "Select Mount Point" \
            --menu "Choose mount point for $remote_name:" 20 70 10 \
            "${mount_options[@]}")
        
        clear  # Clear screen after dialog

        # Check if user cancelled
        if [ $? -ne 0 ]; then
            echo "Mount point selection cancelled for $remote_name"
            return 1
        fi

        # If custom path selected, ask for it
        if [ "$selected_option" = "custom" ]; then
            # Show input dialog for custom path
            mount_point=$(dialog --stdout --title "Custom Mount Point" \
                --inputbox "Enter custom mount point path for $remote_name:" 10 60 "$mount_point")
            
            clear  # Clear screen after dialog

            # Check if user cancelled
            if [ $? -ne 0 ]; then
                echo "Custom path selection cancelled for $remote_name"
                return 1
            fi
        else
            mount_point="$selected_option"
        fi

        echo "Selected mount point for $remote_name: $mount_point"
    fi

    # Create mount point if it doesn't exist
    sudo mkdir -p "$mount_point"

    # Check if mount point is already in use
    if mount | grep -q " on $mount_point "; then
        echo "Error: Mount point '$mount_point' is already in use"
        return 1
    fi

    echo "Mounting $remote_name to $mount_point..."

    # If no custom parameters, use defaults
    if [ ${#mount_params[@]} -eq 0 ]; then
        mount_params=(
            "--vfs-cache-mode" "full"
            "--vfs-cache-max-age" "1h"
            "--dir-cache-time" "30s"
            "--buffer-size" "32M"
        )
    fi

    # Mount with options
    mkdir $mount_point 2>/dev/null
    sudo chmod 777 $mount_point 2>/dev/null

    rclone mount --daemon ${mount_params[@]} "$remote_name:" "$mount_point"

    echo "Remote $remote_name mounted at $mount_point"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to ensure required dependencies are installed
install_dependencies() {
    local packages=("curl" "unzip" "fuse3" "jq" "rclone" "systemd" "sudo" "dialog")
    local missing_packages=()

    for pkg in "${packages[@]}"; do
        if ! command_exists "$pkg"; then
            missing_packages+=("$pkg")
        fi
    done

    if [ ${#missing_packages[@]} -ne 0 ]; then
        echo "Installing required dependencies: ${missing_packages[*]}"
        if command_exists apt-get; then
            sudo apt-get update
            sudo apt-get install -y "${missing_packages[@]}"
        elif command_exists yum; then
            sudo yum install -y "${missing_packages[@]}"
        elif command_exists dnf; then
            sudo dnf install -y "${missing_packages[@]}"
        elif command_exists pacman; then
            sudo pacman -Sy --noconfirm "${missing_packages[@]}"
        else
            echo "Error: Could not find package manager to install dependencies"
            exit 1
        fi
    fi
}

# Function to install latest rclone version, wrapper script and systemd service
install_rclone() {
    echo "Checking rclone installation..."
    
    # First ensure dependencies are installed
    install_dependencies

    # Copy this script to /usr/local/bin
    local script_path="/usr/local/bin/rclone.sh"
    echo "Installing wrapper script to $script_path..."
    sudo cp "$0" "$script_path"
    sudo chmod 755 "$script_path"
    echo "Wrapper script installed successfully"

    # Create systemd service for auto-mounting at boot
    local service_file="/etc/systemd/system/rclone-automount.service"
    echo "Creating systemd service for auto-mounting..."
    
    # Create the service file with proper configuration
    sudo tee "$service_file" > /dev/null << EOF
[Unit]
Description=RClone Auto-Mount Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/rclone.sh mount all
ExecStop=/usr/local/bin/rclone.sh unmount all
User=$USER

[Install]
WantedBy=multi-user.target
EOF

    # Set proper permissions for the service file
    sudo chmod 644 "$service_file"

    # Reload systemd, enable and start the service
    echo "Enabling and starting rclone auto-mount service..."
    sudo systemctl daemon-reload
    sudo systemctl enable rclone-automount.service
    sudo systemctl start rclone-automount.service
    echo "Auto-mount service installed and enabled successfully"
    
    # Check if rclone is already installed
    if command_exists rclone; then
        echo "rclone is already installed"
        rclone --version
        return 0
    fi

    echo "Installing rclone..."
    
    # Create temporary directory
    temp_dir=$(mktemp -d)
    cd "$temp_dir"

    # Download and unzip latest rclone
    curl -O https://downloads.rclone.org/rclone-current-linux-amd64.zip
    unzip rclone-current-linux-amd64.zip
    cd rclone-*-linux-amd64

    # Copy binary and man pages
    sudo cp rclone /usr/local/bin/
    sudo chown root:root /usr/local/bin/rclone
    sudo chmod 755 /usr/local/bin/rclone
    sudo mkdir -p /usr/local/share/man/man1
    sudo cp rclone.1 /usr/local/share/man/man1/
    sudo mandb

    # Cleanup
    cd
    rm -rf "$temp_dir"

    echo "rclone installation completed"
    rclone --version
}

# Function to run rclone config in interactive mode and collect additional settings
run_config() {
    if ! command_exists rclone; then
        echo "Error: rclone is not installed. Please run '$0 install' first."
        exit 1
    fi

    # Check if force config mode is enabled
    local force_config=false
    if [ "$2" = "-c" ]; then
        force_config=true
    fi
    
    # Check if rclone config exists and get remotes
    local rclone_config="$HOME/.config/rclone/rclone.conf"
    if [ ! -f "$rclone_config" ] || [ "$force_config" = true ]; then
        echo "Starting rclone configuration in interactive mode..."
        rclone config
        
        # Check if configuration was created
        if [ ! -f "$rclone_config" ]; then
            echo "Error: No remotes configured. Please run rclone config and set up at least one remote."
            exit 1
        fi
    fi

    # Create wrapper config directory if it doesn't exist
    local config_dir="$HOME/.config/rclone-wrapper"
    mkdir -p "$config_dir"
    local settings_file="$config_dir/settings.json"

    # Get list of configured remotes
    # Read remotes from rclone config file
    local remotes=($(grep '^\[.*\]$' "$HOME/.config/rclone/rclone.conf" | tr -d '[]'))
    if [ ${#remotes[@]} -eq 0 ]; then
        echo "No remotes found in configuration. Please run 'rclone config' to set up a remote."
        exit 1
    fi

    # Initialize JSON structure
    local json_content="{"
    local first_remote=true

    echo "Configuring mount points and options for each remote..."
    echo "---------------------------------------------"

    # For each remote, ask for mount point and parameters
    for remote in "${remotes[@]}"; do
        echo
        echo "Configuration for remote: $remote"
        echo "--------------------------------"
        
        # Ask for mount point
        local default_mount="/mnt/rclone/$remote"
        read -p "Mount point for $remote [$default_mount]: " mount_point
        mount_point=${mount_point:-$default_mount}

        # Ask for custom parameters
        echo "Enter mount parameters for $remote (one per line, empty line to finish)"
        echo "Examples:"
        echo "  --vfs-cache-mode full"
        echo "  --vfs-cache-max-age 1h"
        echo "  --buffer-size 128M"
        echo "  --dir-cache-time 30s"
        
        local params=()
        while true; do
            read -p "> " param
            [[ -z "$param" ]] && break
            params+=("$param")
        done

        # Add remote to JSON
        if [ "$first_remote" = true ]; then
            first_remote=false
        else
            json_content+=","
        fi

        # Convert params array to JSON array
        local json_params=$(printf '%s\n' "${params[@]}" | jq -R . | jq -s .)
        
        # Add remote configuration to JSON
        json_content+="\"$remote\": {"
        json_content+="\"mount_point\": \"$mount_point\","
        json_content+="\"mount_params\": $json_params"
        json_content+="}"
    done

    # Close main JSON object
    json_content+="}"

    # Save settings to JSON file
    echo "$json_content" | jq '.' > "$settings_file"

    echo
    echo "Settings saved to $settings_file"
    echo "You can edit this file manually or run 'rclone.sh config' again to modify settings"
}

# Function to get current mount point of a remote
get_current_mount() {
    local remote="$1"
    # mount | grep "^rclone.*$remote:" | awk '{print $3}'
    mount | grep "^$remote:" | awk '{print $3}'
}

# Function to mount a remote
mount_remote() {
    if ! command_exists rclone; then
        echo "Error: rclone is not installed. Please run '$0 install' first."
        exit 1
    fi

    # Check if config file exists
    local config_file="$HOME/.config/rclone/rclone.conf"
    if [ ! -f "$config_file" ]; then
        echo "Error: rclone configuration file not found. Please run '$0 config' first."
        exit 1
    fi

    # Get list of available remotes
    # local remotes=($(rclone listremotes | sed 's/://g'))
    local remotes=($(grep '^\[.*\]$' "$config_file" | tr -d '[]'))
    if [ ${#remotes[@]} -eq 0 ]; then
        echo "No remotes found in configuration. Please run '$0 config' to set up a remote."
        exit 1
    fi

    # Check if GUI mode is requested
    if [ "$2" = "gui" ]; then
        # Check if dialog is available
        if ! command_exists dialog; then
            echo "Error: dialog is not installed. Please run '$0 install' first."
            exit 1
        fi

        # Create remote selection menu
        local menu_options=()
        for remote in "${remotes[@]}"; do
            current_mount=$(get_current_mount "$remote")
            if [ -n "$current_mount" ]; then
                menu_options+=("$remote" "Currently mounted at $current_mount" "off")
            else
                menu_options+=("$remote" "Not mounted" "on")
            fi
        done

        # Show remote selection dialog
        selected_remotes=$(dialog --stdout --title "Select Remotes" \
            --checklist "Choose remotes to mount:" 20 70 10 \
            "${menu_options[@]}")
        
        clear  # Clear screen after dialog

        # Check if user cancelled
        if [ $? -ne 0 ]; then
            echo "Operation cancelled by user"
            exit 0
        fi

        # Convert selected_remotes from space-separated to array
        read -ra selected_array <<< "$selected_remotes"

        # Mount selected remotes with terminal UI mount point selection
        for remote in "${selected_array[@]}"; do
            mount_single_remote "$remote" "true"
        done
        exit 0
    fi

    # Check if all required arguments are provided
    if [ -z "$2" ]; then
        echo "Usage: $0 mount <remote-name>"
        echo "  remote-name: Name of the remote to mount (use 'all' to mount all remotes)"
        echo "Available remotes:"
        for remote in "${remotes[@]}"; do
            current_mount=$(get_current_mount "$remote")
            if [ -n "$current_mount" ]; then
                echo "  $remote (currently mounted at $current_mount)"
            else
                echo "  $remote (not mounted)"
            fi
        done
        exit 1
    fi

    # Handle mounting all remotes
    if [ "$2" = "all" ]; then
        echo "Mounting all available remotes..."
        for remote in "${remotes[@]}"; do
            mount_single_remote "$remote"
        done
        exit 0
    fi

    # Handle single remote mount
    local remote_name="$2"
    if [[ ! " ${remotes[@]} " =~ " ${remote_name} " ]]; then
        echo "Error: Remote '$remote_name' not found in configuration."
        echo "Available remotes:"
        for remote in "${remotes[@]}"; do
            current_mount=$(get_current_mount "$remote")
            if [ -n "$current_mount" ]; then
                echo "  $remote (currently mounted at $current_mount)"
            else
                echo "  $remote (not mounted)"
            fi
        done
        exit 1
    fi

    # Mount the single remote using mount_single_remote function
    mount_single_remote "$remote_name"
}

# Function to list all configured remotes and their mount status
list_remotes() {
    if ! command_exists rclone; then
        echo "Error: rclone is not installed. Please run '$0 install' first."
        exit 1
    fi

    # Check if config file exists
    local config_file="$HOME/.config/rclone/rclone.conf"
    if [ ! -f "$config_file" ]; then
        echo "Error: rclone configuration file not found. Please run '$0 config' first."
        exit 1
    fi

    # Get list of available remotes
    local remotes=($(grep '^\[.*\]$' "$config_file" | tr -d '[]'))
    if [ ${#remotes[@]} -eq 0 ]; then
        echo "No remotes found in configuration. Please run '$0 config' to set up a remote."
        exit 1
    fi

    # Load configuration
    local config_file="$HOME/.config/rclone-wrapper/settings.json"
    
    echo "Configured remotes:"
    echo "-----------------"
    for remote in "${remotes[@]}"; do
        current_mount=$(get_current_mount "$remote")
        
        # Get configured mount point from JSON
        if [ -f "$config_file" ]; then
            mount_point=$(jq -r ".[\"$remote\"].mount_point" "$config_file" 2>/dev/null)
            mount_params=$(jq -r ".[\"$remote\"].mount_params | join(\" \")" "$config_file" 2>/dev/null)
        fi
        
        # Use default if not configured
        if [ "$mount_point" = "null" ] || [ -z "$mount_point" ]; then
            mount_point="/mnt/rclone/${remote}"
        fi
        
        # Show status and configuration
        if [ -n "$current_mount" ]; then
            echo "✓ $remote"
            echo "  Current mount point: $current_mount"
        else
            echo "✗ $remote"
            echo "  Will mount at: $mount_point"
        fi
        
        # Show mount parameters if configured
        if [ -n "$mount_params" ] && [ "$mount_params" != "null" ]; then
            echo "  Mount parameters: $mount_params"
        fi
        echo
    done
}

# Function to unmount a single remote
unmount_single_remote() {
    local remote_name="$1"
    
    # Get current mount point
    current_mount=$(get_current_mount "$remote_name")
    if [ -z "$current_mount" ]; then
        echo "Skipping $remote_name: not mounted"
        return 0
    fi

    echo "Unmounting $remote_name from $current_mount..."
    
    # Unmount using fusermount
    fusermount -u "$current_mount"
    
    # Check if successfully unmounted
    if ! mount | grep -q "^rclone.*$remote_name:"; then
        echo "Remote $remote_name successfully unmounted"
        # Optionally remove the mount point directory if it was the default one
        if [[ "$current_mount" == "/mnt/rclone/$remote_name" ]]; then
            sudo rmdir "$current_mount" 2>/dev/null
        fi
    else
        echo "Error: Failed to unmount $remote_name"
        return 1
    fi
}

# Function to unmount a remote
unmount_remote() {
    if ! command_exists rclone; then
        echo "Error: rclone is not installed. Please run '$0 install' first."
        exit 1
    fi

    # Check if config file exists
    local config_file="$HOME/.config/rclone/rclone.conf"
    if [ ! -f "$config_file" ]; then
        echo "Error: rclone configuration file not found. Please run '$0 config' first."
        exit 1
    fi

    # Get list of available remotes
    # local remotes=($(rclone listremotes | sed 's/://g'))
    local remotes=($(grep '^\[.*\]$' "$config_file" | tr -d '[]'))

    # Check if GUI mode is requested
    if [ "$2" = "gui" ]; then
        # Check if dialog is available
        if ! command_exists dialog; then
            echo "Error: dialog is not installed. Please run '$0 install' first."
            exit 1
        fi

        # Create a list of mounted remotes for the menu
        local menu_options=()
        local mounted_count=0
        for remote in "${remotes[@]}"; do
            current_mount=$(get_current_mount "$remote")
            if [ -n "$current_mount" ]; then
                menu_options+=("$remote" "Mounted at $current_mount" "on")
                ((mounted_count++))
            fi
        done

        # Check if there are any mounted remotes
        if [ $mounted_count -eq 0 ]; then
            dialog --msgbox "No remotes are currently mounted." 8 40
            clear
            exit 0
        fi

        # Show remote selection dialog
        selected_remotes=$(dialog --stdout --title "Select Remotes to Unmount" \
            --checklist "Choose remotes to unmount:" 20 70 10 \
            "${menu_options[@]}")
        
        clear  # Clear screen after dialog

        # Check if user cancelled
        if [ $? -ne 0 ]; then
            echo "Operation cancelled by user"
            exit 0
        fi

        # Convert selected_remotes from space-separated to array
        read -ra selected_array <<< "$selected_remotes"

        # Unmount selected remotes
        local success=true
        for remote in "${selected_array[@]}"; do
            if ! unmount_single_remote "$remote"; then
                success=false
            fi
        done

        if [ "$success" = true ]; then
            echo "All selected remotes successfully unmounted"
        else
            echo "Warning: Some remotes could not be unmounted"
            exit 1
        fi
        exit 0
    fi

    # If no remote specified, show mounted remotes
    if [ -z "$2" ]; then
        echo "Usage: $0 unmount <remote-name>"
        echo "  remote-name: Name of the remote to unmount (use 'all' to unmount all)"
        echo "Currently mounted remotes:"
        for remote in "${remotes[@]}"; do
            current_mount=$(get_current_mount "$remote")
            if [ -n "$current_mount" ]; then
                echo "  $remote (mounted at $current_mount)"
            fi
        done
        exit 1
    fi

    # Handle unmounting all remotes
    if [ "$2" = "all" ]; then
        echo "Unmounting all mounted remotes..."
        local success=true
        for remote in "${remotes[@]}"; do
            if ! unmount_single_remote "$remote"; then
                success=false
            fi
        done
        if [ "$success" = true ]; then
            echo "All remotes successfully unmounted"
        else
            echo "Warning: Some remotes could not be unmounted"
            exit 1
        fi
        exit 0
    fi

    # Check if specified remote exists
    local remote_name="$2"
    if [[ ! " ${remotes[@]} " =~ " ${remote_name} " ]]; then
        echo "Error: Remote '$remote_name' not found in configuration."
        exit 1
    fi

    # Get current mount point
    current_mount=$(get_current_mount "$remote_name")
    if [ -z "$current_mount" ]; then
        echo "Remote '$remote_name' is not mounted."
        exit 1
    fi

    echo "Unmounting $remote_name from $current_mount..."
    
    # Unmount using fusermount
    fusermount -u "$current_mount"
    
    # Check if successfully unmounted
    if ! mount | grep -q "^rclone.*$remote_name:"; then
        echo "Remote $remote_name successfully unmounted"
        # Optionally remove the mount point directory if it was the default one
        if [[ "$current_mount" == "/mnt/rclone/$remote_name" ]]; then
            sudo rmdir "$current_mount" 2>/dev/null
        fi
    else
        echo "Error: Failed to unmount $remote_name"
        exit 1
    fi
}

# Function to update the script from git repository
update_script() {
    echo "Checking for updates..."
    local temp_file=$(mktemp)
    local current_file="$0"
    local update_url="http://git.home.lan:3000/marco/rclone/raw/branch/main/rclone.sh"

    # Download new version
    if ! curl -s -f "$update_url" -o "$temp_file"; then
        echo "Error: Failed to download update from $update_url"
        rm -f "$temp_file"
        exit 1
    fi

    # Check if the downloaded file is different
    if diff -q "$current_file" "$temp_file" >/dev/null; then
        echo "Script is already up to date"
        rm -f "$temp_file"
        return 0
    fi

    # Backup current script
    local backup_file="$current_file.backup"
    sudo cp "$current_file" "$backup_file"
    
    # Replace current script with new version
    if sudo cp "$temp_file" "$current_file"; then
        sudo chmod 755 "$current_file"
        echo "Script updated successfully"
        echo "Previous version backed up to $backup_file"
    else
        echo "Error: Failed to update script"
        echo "The downloaded version is in $temp_file"
        exit 1
    fi

    # Cleanup
    rm -f "$temp_file"
}

# Function to show help
show_help() {
    cat << EOF
Usage: $0 <command> [options]

Commands:
    install
        Install or update rclone on the system
        No additional options required

    update
        Update this script to the latest version
        Downloads from git repository and replaces current script
        No additional options required

    config [-c]
        Run rclone configuration in interactive mode
        Configure new remotes or modify existing ones
        Options:
            -c  : Force rclone configuration mode even if config exists

    list
        Show all configured remotes and their mount status
        Displays whether each remote is mounted and its mount point
        No additional options required

    mount <remote-name|all|gui>
        Mount remotes at the configured or selected location
        Arguments:
            remote-name  : Name of the remote to mount
            all         : Mount all remotes at configured locations
            gui         : Interactive terminal UI for selecting remotes and mount points
        Example:
            $0 mount all          # Mounts all remotes at configured locations
            $0 mount gui          # Interactive mount with terminal UI
            $0 mount gdrive1      # Mounts single remote at configured location

    unmount <remote-name|all|gui>
        Unmount remotes from their current locations
        Arguments:
            remote-name  : Name of the remote to unmount
            all         : Unmount all currently mounted remotes
            gui         : Interactive terminal UI for selecting remotes to unmount
        Example:
            $0 unmount all          # Unmounts all mounted remotes
            $0 unmount gui          # Interactive unmount with terminal UI
            $0 unmount gdrive1      # Unmounts single remote

Options for mounted remotes:
    --vfs-cache-mode full    : Cache all files for better performance
    --dir-cache-time 24h    : Cache directory listings for 24 hours
    --buffer-size 32M       : Buffer size for streaming
    --daemon               : Run in background

For more detailed information about rclone, visit:
    https://rclone.org/docs/
EOF
}

# Main script
case "$1" in
    "install")
        install_rclone
        ;;
    "update")
        update_script
        ;;
    "config")
        run_config "$@"
        ;;
    "mount")
        mount_remote "$@"
        ;;
    "unmount")
        unmount_remote "$@"
        ;;
    "list")
        list_remotes
        ;;
    "help"|"-h"|"--help")
        show_help
        ;;
    *)
        show_help
        exit 1
esac
