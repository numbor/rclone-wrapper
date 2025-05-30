#!/bin/bash

# Function to mount a single remote
mount_single_remote() {
    local remote_name="$1"
    local mount_point="$2"

    # Check if remote is already mounted
    current_mount=$(get_current_mount "$remote_name")
    if [ -n "$current_mount" ]; then
        echo "Skipping $remote_name: already mounted at $current_mount"
        return 0
    fi

    # Create mount point if it doesn't exist
    sudo mkdir -p "$mount_point"

    # Check if mount point is already in use
    if mount | grep -q " on $mount_point "; then
        echo "Error: Mount point '$mount_point' is already in use"
        return 1
    fi

    echo "Mounting $remote_name to $mount_point..."
    
    # Mount with common options
    rclone mount "$remote_name": "$mount_point" \
        --daemon \
        --vfs-cache-mode full \
        --vfs-cache-max-age 24h \
        --dir-cache-time 24h \
        --buffer-size 32M

    echo "Remote $remote_name mounted at $mount_point"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to ensure required dependencies are installed
install_dependencies() {
    local packages=("curl" "unzip")
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

# Function to run rclone config in interactive mode
run_config() {
    if ! command_exists rclone; then
        echo "Error: rclone is not installed. Please run '$0 install' first."
        exit 1
    fi
    
    echo "Starting rclone configuration in interactive mode..."
    rclone config
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
    local config_file="/home/develop/.config/rclone/rclone.conf"
    if [ ! -f "$config_file" ]; then
        echo "Error: rclone configuration file not found. Please run '$0 config' first."
        exit 1
    fi

    # Get list of available remotes
    local remotes=($(rclone listremotes | sed 's/://g'))
    if [ ${#remotes[@]} -eq 0 ]; then
        echo "No remotes found in configuration. Please run '$0 config' to set up a remote."
        exit 1
    fi

    # Check if all required arguments are provided
    if [ -z "$2" ]; then
        echo "Usage: $0 mount <remote-name> [mount-path]"
        echo "  remote-name: Name of the remote to mount (use 'all' to mount all remotes)"
        echo "  mount-path: Directory where the remote will be mounted"
        echo "             (required unless remote-name is 'all')"
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
            mount_single_remote "$remote" "/mnt/rclone/$remote"
        done
        exit 0
    fi

    # For single remote, mount-path is required
    if [ -z "$3" ]; then
        echo "Error: mount-path is required when mounting a single remote"
        exit 1
    fi

    # Check if specified remote exists
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

    # Check if remote is already mounted
    current_mount=$(get_current_mount "$remote_name")
    if [ -n "$current_mount" ]; then
        echo "Error: Remote '$remote_name' is already mounted at $current_mount"
        exit 1
    fi

    # Set mount point from provided path
    local mount_point="$3"

    # Create mount point if it doesn't exist
    sudo mkdir -p "$mount_point"

    # Check if mount point is already in use
    if mount | grep -q " on $mount_point "; then
        echo "Error: Mount point '$mount_point' is already in use"
        exit 1
    fi

    echo "Mounting $remote_name to $mount_point..."
    
    # Mount with common options
    rclone mount "$remote_name": "$mount_point" \
        --daemon \
        --vfs-cache-mode full \
        --vfs-cache-max-age 24h \
        --dir-cache-time 24h \
        --buffer-size 32M

    echo "Remote $remote_name mounted at $mount_point"
}

# Function to list all configured remotes and their mount status
list_remotes() {
    if ! command_exists rclone; then
        echo "Error: rclone is not installed. Please run '$0 install' first."
        exit 1
    fi

    # Check if config file exists
    local config_file="/home/develop/.config/rclone/rclone.conf"
    if [ ! -f "$config_file" ]; then
        echo "Error: rclone configuration file not found. Please run '$0 config' first."
        exit 1
    fi

    # Get list of available remotes
    local remotes=($(rclone listremotes | sed 's/://g'))
    if [ ${#remotes[@]} -eq 0 ]; then
        echo "No remotes found in configuration. Please run '$0 config' to set up a remote."
        exit 1
    fi

    echo "Configured remotes:"
    echo "-----------------"
    for remote in "${remotes[@]}"; do
        current_mount=$(get_current_mount "$remote")
        if [ -n "$current_mount" ]; then
            echo "✓ $remote (mounted at $current_mount)"
        else
            echo "✗ $remote (not mounted)"
        fi
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
    local config_file="/home/develop/.config/rclone/rclone.conf"
    if [ ! -f "$config_file" ]; then
        echo "Error: rclone configuration file not found. Please run '$0 config' first."
        exit 1
    fi

    # Get list of available remotes
    local remotes=($(rclone listremotes | sed 's/://g'))

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

# Function to show help
show_help() {
    cat << EOF
Usage: $0 <command> [options]

Commands:
    install
        Install or update rclone on the system
        No additional options required

    config
        Run rclone configuration in interactive mode
        Configure new remotes or modify existing ones
        No additional options required

    list
        Show all configured remotes and their mount status
        Displays whether each remote is mounted and its mount point
        No additional options required

    mount <remote-name> [mount-path]
        Mount a remote at the specified location
        Arguments:
            remote-name  : Name of the remote to mount (required)
                          Use 'all' to mount all configured remotes
            mount-path   : Directory where the remote will be mounted
                          (required unless remote-name is 'all')
        Example:
            $0 mount all          # Mounts all remotes to /mnt/rclone/<remote-name>
            $0 mount gdrive1 /custom/mount/point

    unmount <remote-name>
        Unmount a previously mounted remote
        Arguments:
            remote-name  : Name of the remote to unmount (required)
        Example:
            $0 unmount gdrive1

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
    "config")
        run_config
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
        ;;
esac
