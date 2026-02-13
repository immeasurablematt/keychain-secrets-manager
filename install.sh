#!/bin/bash
# ──────────────────────────────────────────────────────────────────────
# install.sh — Install keychain-secrets-manager
#
# Usage:   bash install.sh
#          bash install.sh --uninstall
# ──────────────────────────────────────────────────────────────────────
set -eo pipefail

INSTALL_DIR="$HOME/.keychain-secrets-manager"
BIN_LINK="/usr/local/bin/secrets-manager"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Uninstall ─────────────────────────────────────────────────────────

if [ "${1:-}" = "--uninstall" ]; then
    echo ""
    echo -e "${BOLD}Uninstalling keychain-secrets-manager...${NC}"
    echo ""
    echo -e "${YELLOW}Note: This removes the tool, NOT your Keychain secrets.${NC}"
    echo "Your secrets remain safely in macOS Keychain."
    echo ""

    if [ -L "$BIN_LINK" ]; then
        rm "$BIN_LINK"
        echo -e "  ${GREEN}✅${NC} Removed $BIN_LINK"
    fi

    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
        echo -e "  ${GREEN}✅${NC} Removed $INSTALL_DIR"
    fi

    echo ""
    echo -e "${GREEN}Uninstalled. Your Keychain secrets are untouched.${NC}"
    echo ""
    exit 0
fi

# ── Pre-flight checks ────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   🔐 Installing Keychain Secrets Manager         ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# Check macOS
if [ "$(uname)" != "Darwin" ]; then
    echo -e "${RED}Error: This tool requires macOS (uses Keychain).${NC}"
    exit 1
fi

# Check security command
if ! command -v security &>/dev/null; then
    echo -e "${RED}Error: 'security' command not found. Is this macOS?${NC}"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Install ───────────────────────────────────────────────────────────

echo "This will:"
echo "  1. Copy files to $INSTALL_DIR"
echo "  2. Create a symlink at $BIN_LINK"
echo "  3. Create a starter config at ~/.secrets.conf (if it doesn't exist)"
echo ""
read -rp "Continue? (y/n): " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "Cancelled."
    exit 0
fi

echo ""

# Copy files
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/secrets-manager.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/secrets.conf.example" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/secrets-manager.sh"
echo -e "  ${GREEN}✅${NC} Installed to $INSTALL_DIR"

# Create symlink
if [ -L "$BIN_LINK" ] || [ -f "$BIN_LINK" ]; then
    rm "$BIN_LINK"
fi
ln -s "$INSTALL_DIR/secrets-manager.sh" "$BIN_LINK"
echo -e "  ${GREEN}✅${NC} Linked secrets-manager → $BIN_LINK"

# Create starter config
if [ ! -f "$HOME/.secrets.conf" ]; then
    cp "$SCRIPT_DIR/secrets.conf.example" "$HOME/.secrets.conf"
    echo -e "  ${GREEN}✅${NC} Created ~/.secrets.conf (edit this to define your secrets)"
else
    echo -e "  ${YELLOW}⏭️${NC}  ~/.secrets.conf already exists (not overwritten)"
fi

# ── Shell integration (optional) ─────────────────────────────────────

echo ""
echo -e "${BOLD}Optional: Auto-load secrets into your shell${NC}"
echo ""
echo "Add this to your ~/.zshrc or ~/.bashrc to make all secrets"
echo "available as environment variables in every terminal session:"
echo ""
echo -e "  ${DIM}# Load secrets from Keychain-exported .env${NC}"
echo -e "  ${DIM}if [ -f \"\$HOME/.env\" ]; then${NC}"
echo -e "  ${DIM}    set -a; source \"\$HOME/.env\"; set +a${NC}"
echo -e "  ${DIM}fi${NC}"
echo ""

# Detect shell rc file
local_rc=""
if [ -f "$HOME/.zshrc" ]; then
    local_rc="$HOME/.zshrc"
elif [ -f "$HOME/.bashrc" ]; then
    local_rc="$HOME/.bashrc"
fi

if [ -n "$local_rc" ]; then
    # Check if already added
    if grep -q "Load secrets from Keychain" "$local_rc" 2>/dev/null; then
        echo -e "  ${YELLOW}⏭️${NC}  Shell integration already in $local_rc"
    else
        read -rp "Add this to $local_rc now? (y/n): " add_shell
        if [ "$add_shell" = "y" ] || [ "$add_shell" = "Y" ]; then
            echo "" >> "$local_rc"
            echo "# Load secrets from Keychain-exported .env (keychain-secrets-manager)" >> "$local_rc"
            echo 'if [ -f "$HOME/.env" ]; then' >> "$local_rc"
            echo '    set -a; source "$HOME/.env"; set +a' >> "$local_rc"
            echo 'fi' >> "$local_rc"
            echo -e "  ${GREEN}✅${NC} Added to $local_rc"
        fi
    fi
fi

# ── Done ──────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   🎉 Installation complete!                      ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "Next steps:"
echo "  1. Edit ~/.secrets.conf to define your secrets and projects"
echo "  2. Run: secrets-manager"
echo "  3. Store your keys (option 1) then export (option 3)"
echo ""
echo -e "  ${DIM}Run 'secrets-manager --help' for usage info${NC}"
echo -e "  ${DIM}Run 'bash install.sh --uninstall' to remove${NC}"
echo ""
