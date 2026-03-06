# Shell Scripts Collection

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A collection of packaged shell and Perl scripts for macOS and Linux, distributed via [Homebrew](https://brew.sh/) and [APT](https://jmerhar.github.io/apt-scripts/).

## Available Scripts

| Script | Description | Directory |
|--------|-------------|-----------|
| [`local-backup`](scripts/system/) | Incremental rsync backups with automatic pruning and RAID awareness. | `scripts/system/` |
| [`photo-backup`](scripts/photography/#photo-backupsh) | Multi-source photo backup to a remote server with deletion protection. | `scripts/photography/` |
| [`remove-sidecars`](scripts/photography/#remove-sidecarspl) | Clean up sidecar JPEG files from RAW+JPEG photo libraries. | `scripts/photography/` |
| [`unlock-pdf`](scripts/utility/) | Decrypt a password-protected PDF file. | `scripts/utility/` |

## Repository Structure

```
scripts/          User-facing scripts, organized by topic
  system/           System administration (backups)
  utility/          General-purpose utilities
  photography/      Photography workflow automation
  lib/              Shared library (sourced at dev time, inlined at build time)
bin/              Internal CI/CD tooling (not published as packages)
conf/             Configuration file templates shipped with packages
```

## Installation

The recommended approach is to use a package manager, which handles dependencies and updates automatically.

### macOS (Homebrew)

```bash
brew tap jmerhar/scripts
brew install unlock-pdf        # or any script name from the table above
```

### Debian / Ubuntu (APT)

```bash
# Add the GPG key
wget -qO- https://jmerhar.github.io/apt-scripts/public.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/jmerhar-scripts.gpg

# Add the repository source
echo "deb [arch=all signed-by=/etc/apt/keyrings/jmerhar-scripts.gpg] https://jmerhar.github.io/apt-scripts/ stable main" \
  | sudo tee /etc/apt/sources.list.d/jmerhar-scripts.list

# Install
sudo apt-get update
sudo apt-get install unlock-pdf   # or any script name from the table above
```

### Manual

```bash
git clone https://github.com/jmerhar/scripts.git
cd scripts
chmod +x scripts/utility/unlock-pdf.sh
./scripts/utility/unlock-pdf.sh
```

## Contributing

Contributions are welcome. Open an issue to discuss changes or submit a pull request.

## License

Distributed under the [MIT License](LICENSE).
