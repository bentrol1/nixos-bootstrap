# NixOS Bootstrap: Tailscale SSH + VS Code Remote

Single-command bootstrap for fresh NixOS installations with Tailscale SSH and VS Code Remote editing support.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/bentrol1/nixos-bootstrap/main/setup.sh | bash
```

## What It Does

- ✅ Configures Tailscale with SSH support
- ✅ Enables VS Code Remote SSH compatibility
- ✅ Adds QEMU Guest Agent (for VMs)
- ✅ Safe modular configuration

## After Running

1. Authenticate Tailscale using the provided URL
2. Install "Remote - SSH" extension in VS Code
3. Connect using `user@tailscale-ip`

## Requirements

- Fresh NixOS 25.05
- User with sudo access
- Tailscale account

All changes are in `/etc/nixos/bootstrap-module.nix` and can be easily removed.
