#!/bin/bash

# echo "/mnt/rclone/onedrive1/"
# ./rclone --vfs-cache-mode full mount onedrive1: /mnt/rclone/onedrive1/ --daemon --vfs-cache-mode full

# echo "/mnt/rclone/gdrive1/"
# ./rclone mount gdrive1: /mnt/rclone/gdrive1/ --daemon

# echo "/mnt/rclone/gdrive2/"
# ./rclone mount gdrive2: /mnt/rclone/gdrive2/ --daemon

# echo "/mnt/rclone/mega1/"
# ./rclone mount mega1: /mnt/rclone/mega1/ --daemon

# echo "/mnt/rclone/realdebrid/"
# ./rclone mount realdebrid: /mnt/rclone/realdebrid/ --daemon --vfs-cache-mode full 


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

# Function to install latest rclone version
install_rclone() {
    echo "Checking rclone installation..."
    
    # First ensure dependencies are installed
    install_dependencies
    
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
    if [ -z "$2" ] || [ -z "$3" ]; then
        echo "Usage: $0 mount <remote-name> <mount-path>"
        echo "  remote-name: Name of the remote to mount"
        echo "  mount-path: Directory where the remote will be mounted"
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
        echo "Currently mounted remotes:"
        for remote in "${remotes[@]}"; do
            current_mount=$(get_current_mount "$remote")
            if [ -n "$current_mount" ]; then
                echo "  $remote (mounted at $current_mount)"
            fi
        done
        exit 1
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

    mount <remote-name> <mount-path>
        Mount a remote at the specified location
        Arguments:
            remote-name  : Name of the remote to mount (required)
            mount-path   : Directory where the remote will be mounted (required)
        Example:
            $0 mount gdrive1 /mnt/rclone/gdrive1
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
