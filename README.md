# Rclone Wrapper Script

A convenient Bash wrapper script for managing rclone mounts with enhanced features and systemd integration.

## Features

- Easy installation of rclone and all dependencies
- Automatic mount/unmount of remote storage
- Configuration management via JSON file
- Custom mount parameters for each remote
- Auto-mounting at system boot via systemd
- Easy updates via git repository
- Multiple mount points support

## Installation

```bash
# Download the script
curl -O https://raw.githubusercontent.com/numbor/rclone/main/rclone.sh
chmod +x rclone.sh

# Install rclone and setup the service
./rclone.sh install
```

## Usage

### Configure remotes
```bash
./rclone.sh config
```

### List configured remotes
```bash
./rclone.sh list
```

### Mount a remote
```bash
./rclone.sh mount remote_name
# Or mount all remotes
./rclone.sh mount all
```

### Unmount a remote
```bash
./rclone.sh unmount remote_name
# Or unmount all remotes
./rclone.sh unmount all
```

### Update the script
```bash
./rclone.sh update
```

## Configuration

The script uses two configuration files:
- `~/.config/rclone/rclone.conf` - Standard rclone configuration
- `~/.config/rclone-wrapper/settings.json` - Wrapper-specific settings including:
  - Custom mount points for each remote
  - Mount parameters
  - Default mount options

Example settings.json:
```json
{
  "gdrive": {
    "mount_point": "/mnt/gdrive",
    "mount_params": [
      "--vfs-cache-mode", "full",
      "--vfs-cache-max-age", "1h",
      "--buffer-size", "128M",
      "--dir-cache-time", "30s"
    ]
  }
}
```

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Support My Work

If you find this script useful, consider buying me a coffee:

[![Buy Me A Coffee](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://buymeacoffee.com/numbor)

