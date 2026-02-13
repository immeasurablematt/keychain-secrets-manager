#!/bin/bash
# ──────────────────────────────────────────────────────────────────────
# secrets-manager.sh — Interactive manager for macOS Keychain secrets
#
# Stores API keys, tokens, and credentials in macOS Keychain (encrypted
# at rest) and exports them to .env files for your projects.
#
# Usage:   secrets-manager [config-file]
#          secrets-manager                      # uses ~/.secrets.conf
#          secrets-manager ~/myapp/secrets.conf  # custom config
#
# Features:
#   1. Store secrets in macOS Keychain (encrypted at rest)
#   2. List all secrets and their status
#   3. Export secrets to a global .env and per-project .env files
#   4. Import existing plaintext .env files into Keychain
#   5. Remove secrets from Keychain
#
# Compatible with macOS bash 3.2+ (no bash 4+ features used)
# ──────────────────────────────────────────────────────────────────────
set -eo pipefail

# ── Resolve config file ──────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${1:-}"

if [ -z "$CONFIG_FILE" ]; then
    # Look for config in standard locations
    if [ -f "$HOME/.secrets.conf" ]; then
        CONFIG_FILE="$HOME/.secrets.conf"
    elif [ -f "$SCRIPT_DIR/secrets.conf" ]; then
        CONFIG_FILE="$SCRIPT_DIR/secrets.conf"
    else
        echo "Error: No config file found."
        echo ""
        echo "Create one by copying the example:"
        echo "  cp $SCRIPT_DIR/secrets.conf.example ~/.secrets.conf"
        echo ""
        echo "Or specify a path:"
        echo "  secrets-manager /path/to/secrets.conf"
        exit 1
    fi
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

# ── Parse config file ────────────────────────────────────────────────

KEYCHAIN_SERVICE=""
ENV_FILE=""
LOG_FILE=""

# Parallel arrays for secrets (bash 3.2 compatible — no associative arrays)
SECRET_NAMES=()
SECRET_ENV_VARS=()
SECRET_DESCS=()
SECRET_COUNT=0

# Parallel arrays for projects
PROJECT_PATHS=()
PROJECT_VARS=()
PROJECT_COUNT=0

parse_config() {
    local section=""
    while IFS= read -r line || [ -n "$line" ]; do
        # Strip leading/trailing whitespace
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Skip empty lines and comments
        case "$line" in
            ""|\#*) continue ;;
        esac

        # Detect section headers
        case "$line" in
            \[settings\]) section="settings"; continue ;;
            \[secrets\])  section="secrets";  continue ;;
            \[projects\]) section="projects"; continue ;;
            \[*\])        section="unknown";  continue ;;
        esac

        case "$section" in
            settings)
                local key val
                key=$(echo "$line" | cut -d'=' -f1 | sed 's/[[:space:]]*$//')
                val=$(echo "$line" | cut -d'=' -f2- | sed 's/^[[:space:]]*//')
                # Expand ~ to $HOME
                val=$(echo "$val" | sed "s|^~|$HOME|")
                case "$key" in
                    service)  KEYCHAIN_SERVICE="$val" ;;
                    env_file) ENV_FILE="$val" ;;
                    log_file) LOG_FILE="$val" ;;
                esac
                ;;
            secrets)
                # Format: keychain-name | ENV_VAR_NAME | Description
                local kc_name env_var desc
                kc_name=$(echo "$line" | cut -d'|' -f1 | sed 's/[[:space:]]*$//')
                env_var=$(echo "$line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                desc=$(echo "$line" | cut -d'|' -f3- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                if [ -n "$kc_name" ] && [ -n "$env_var" ]; then
                    SECRET_NAMES+=("$kc_name")
                    SECRET_ENV_VARS+=("$env_var")
                    SECRET_DESCS+=("${desc:-$env_var}")
                    SECRET_COUNT=$((SECRET_COUNT + 1))
                fi
                ;;
            projects)
                # Format: /path/to/project | ENV_VAR1, ENV_VAR2, ...
                local path vars
                path=$(echo "$line" | cut -d'|' -f1 | sed 's/[[:space:]]*$//')
                vars=$(echo "$line" | cut -d'|' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                # Expand ~ to $HOME
                path=$(echo "$path" | sed "s|^~|$HOME|")
                if [ -n "$path" ] && [ -n "$vars" ]; then
                    PROJECT_PATHS+=("$path")
                    PROJECT_VARS+=("$vars")
                    PROJECT_COUNT=$((PROJECT_COUNT + 1))
                fi
                ;;
        esac
    done < "$CONFIG_FILE"

    # Defaults
    if [ -z "$KEYCHAIN_SERVICE" ]; then
        KEYCHAIN_SERVICE="secrets-manager"
    fi
    if [ -z "$ENV_FILE" ]; then
        ENV_FILE="$HOME/.env"
    fi
    if [ -z "$LOG_FILE" ]; then
        LOG_FILE="/tmp/secrets-manager-export.log"
    fi
}

parse_config

if [ "$SECRET_COUNT" -eq 0 ]; then
    echo "Error: No secrets defined in config file: $CONFIG_FILE"
    echo "Add a [secrets] section with at least one entry."
    exit 1
fi

# ── Colors ────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# ── Keychain helpers ──────────────────────────────────────────────────

get_secret() {
    local account="$1"
    security find-generic-password \
        -s "$KEYCHAIN_SERVICE" \
        -a "$account" \
        -w 2>/dev/null || echo ""
}

set_secret() {
    local account="$1"
    local value="$2"
    security delete-generic-password \
        -s "$KEYCHAIN_SERVICE" \
        -a "$account" 2>/dev/null || true
    security add-generic-password \
        -s "$KEYCHAIN_SERVICE" \
        -a "$account" \
        -w "$value" 2>/dev/null
}

delete_secret() {
    local account="$1"
    security delete-generic-password \
        -s "$KEYCHAIN_SERVICE" \
        -a "$account" 2>/dev/null
}

mask_value() {
    local val="$1"
    local len=${#val}
    if [ "$len" -le 8 ]; then
        echo "****"
    else
        local start="${val:0:4}"
        local end
        end=$(echo "$val" | tail -c 5 | head -c 4)
        echo "${start}...${end} ($len chars)"
    fi
}

# Lookup: given a keychain name, return the env var name
env_var_for() {
    local kc_name="$1"
    local i=0
    while [ "$i" -lt "$SECRET_COUNT" ]; do
        if [ "${SECRET_NAMES[$i]}" = "$kc_name" ]; then
            echo "${SECRET_ENV_VARS[$i]}"
            return
        fi
        i=$((i + 1))
    done
    # Fallback: convert keychain-name to ENV_VAR_NAME
    echo "$kc_name" | tr '[:lower:]-' '[:upper:]_'
}

# Lookup: given an env var name, return the keychain name
kc_name_for() {
    local env_var="$1"
    local i=0
    while [ "$i" -lt "$SECRET_COUNT" ]; do
        if [ "${SECRET_ENV_VARS[$i]}" = "$env_var" ]; then
            echo "${SECRET_NAMES[$i]}"
            return
        fi
        i=$((i + 1))
    done
    echo ""
}

# ── Logging ───────────────────────────────────────────────────────────

log() {
    local dir
    dir=$(dirname "$LOG_FILE")
    mkdir -p "$dir" 2>/dev/null || true
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $*" >> "$LOG_FILE" 2>/dev/null || true
}

# ── UI ────────────────────────────────────────────────────────────────

print_header() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   🔐 Keychain Secrets Manager                    ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo -e "  ${DIM}Config: $CONFIG_FILE${NC}"
    echo -e "  ${DIM}Keychain service: $KEYCHAIN_SERVICE${NC}"
    echo ""
}

print_menu() {
    echo -e "${BLUE}What would you like to do?${NC}"
    echo ""
    echo "  1) Store a secret in Keychain"
    echo "  2) List stored secrets"
    echo "  3) Export secrets to .env files"
    echo "  4) Import secrets from existing .env files"
    echo "  5) Remove a secret from Keychain"
    echo "  6) Quit"
    echo ""
}

# ── 1. Store a secret ────────────────────────────────────────────────

do_store() {
    echo ""
    echo -e "${BOLD}Store a secret in Keychain${NC}"
    echo -e "${YELLOW}Choose a secret to store:${NC}"
    echo ""

    local i=0
    while [ "$i" -lt "$SECRET_COUNT" ]; do
        local name="${SECRET_NAMES[$i]}"
        local desc="${SECRET_DESCS[$i]}"
        local num=$((i + 1))
        local existing
        existing=$(get_secret "$name")
        local status=""
        if [ -n "$existing" ]; then
            status=" ${GREEN}(already stored)${NC}"
        fi
        echo -e "  $num) $name — $desc$status"
        i=$((i + 1))
    done
    local custom_num=$((SECRET_COUNT + 1))
    echo "  $custom_num) Custom name (advanced)"
    echo ""

    read -rp "Enter number: " choice

    local secret_name=""
    if [ "$choice" -eq "$custom_num" ] 2>/dev/null; then
        read -rp "Enter custom secret name: " secret_name
    elif [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$SECRET_COUNT" ] 2>/dev/null; then
        secret_name="${SECRET_NAMES[$((choice - 1))]}"
    else
        echo -e "${RED}Invalid choice${NC}"
        return
    fi

    echo ""
    echo -e "Storing: ${BOLD}$secret_name${NC}"

    local existing
    existing=$(get_secret "$secret_name")
    if [ -n "$existing" ]; then
        echo -e "${YELLOW}⚠️  This secret already exists: $(mask_value "$existing")${NC}"
        read -rp "Replace it? (y/n): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo "Cancelled."
            return
        fi
    fi

    echo -e "${YELLOW}Paste the secret value below (it won't be shown):${NC}"
    read -rs secret_value
    echo ""

    if [ -z "$secret_value" ]; then
        echo -e "${RED}Empty value — nothing stored.${NC}"
        return
    fi

    set_secret "$secret_name" "$secret_value"
    echo -e "${GREEN}✅ Stored '$secret_name' in Keychain ($(mask_value "$secret_value"))${NC}"
    echo ""
    echo -e "${YELLOW}💡 Run option 3 (Export) to push this to your .env files.${NC}"
}

# ── 2. List secrets ──────────────────────────────────────────────────

do_list() {
    echo ""
    echo -e "${BOLD}Secrets in Keychain (service: $KEYCHAIN_SERVICE)${NC}"
    echo ""

    local found=0
    local i=0
    while [ "$i" -lt "$SECRET_COUNT" ]; do
        local name="${SECRET_NAMES[$i]}"
        local env_var="${SECRET_ENV_VARS[$i]}"
        local val
        val=$(get_secret "$name")
        if [ -n "$val" ]; then
            echo -e "  ${GREEN}✅${NC} $name ${DIM}→ $env_var${NC} — $(mask_value "$val")"
            found=$((found + 1))
        else
            echo -e "  ${RED}❌${NC} $name ${DIM}→ $env_var${NC} — ${YELLOW}not set${NC}"
        fi
        i=$((i + 1))
    done

    echo ""
    echo -e "  ${BOLD}$found${NC} of ${BOLD}$SECRET_COUNT${NC} secrets configured"

    if [ "$PROJECT_COUNT" -gt 0 ]; then
        echo ""
        echo -e "  ${DIM}Projects receiving .env exports:${NC}"
        local p=0
        while [ "$p" -lt "$PROJECT_COUNT" ]; do
            local path="${PROJECT_PATHS[$p]}"
            if [ -d "$path" ]; then
                echo -e "    ${GREEN}✅${NC} $path"
            else
                echo -e "    ${DIM}⏭️  $path (not found — skipped during export)${NC}"
            fi
            p=$((p + 1))
        done
    fi
    echo ""
}

# ── 3. Export ─────────────────────────────────────────────────────────

do_export() {
    echo ""
    echo -e "${BOLD}Exporting secrets from Keychain to .env files...${NC}"
    echo ""

    log "=== Export started ==="

    # Read all secrets into shell variables
    local i=0
    local found=0
    while [ "$i" -lt "$SECRET_COUNT" ]; do
        local kc_name="${SECRET_NAMES[$i]}"
        local env_var="${SECRET_ENV_VARS[$i]}"
        local val
        val=$(get_secret "$kc_name")
        # Store in a shell variable named after the env var
        eval "$env_var=\"\$val\""
        if [ -n "$val" ]; then
            found=$((found + 1))
        fi
        i=$((i + 1))
    done

    log "Read $found of $SECRET_COUNT secrets from Keychain"

    # Write global .env
    local env_dir
    env_dir=$(dirname "$ENV_FILE")
    mkdir -p "$env_dir" 2>/dev/null || true

    {
        echo "# Auto-generated by keychain-secrets-manager — DO NOT EDIT"
        echo "# Secrets are stored in macOS Keychain. Run secrets-manager to update."
        echo "# Last exported: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        i=0
        while [ "$i" -lt "$SECRET_COUNT" ]; do
            local env_var="${SECRET_ENV_VARS[$i]}"
            local val=""
            eval "val=\"\${$env_var:-}\""
            if [ -n "$val" ]; then
                echo "$env_var=$val"
            fi
            i=$((i + 1))
        done
    } > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    log "Wrote $ENV_FILE"
    echo -e "  ${GREEN}✅${NC} $ENV_FILE ${DIM}($found secrets)${NC}"

    # Write per-project .env files
    local p=0
    while [ "$p" -lt "$PROJECT_COUNT" ]; do
        local path="${PROJECT_PATHS[$p]}"
        local vars="${PROJECT_VARS[$p]}"

        if [ ! -d "$path" ]; then
            echo -e "  ${DIM}⏭️  $path (not found — skipped)${NC}"
            p=$((p + 1))
            continue
        fi

        local env_file="$path/.env"
        local proj_found=0
        {
            echo "# Auto-generated by keychain-secrets-manager — DO NOT EDIT"
            echo "# Run secrets-manager to update. Last exported: $(date '+%Y-%m-%d %H:%M:%S')"
            echo ""
            # Split comma-separated var names
            local old_ifs="$IFS"
            IFS=','
            for var in $vars; do
                # Trim whitespace
                var=$(echo "$var" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                local val=""
                eval "val=\"\${$var:-}\""
                if [ -n "$val" ]; then
                    echo "$var=$val"
                    proj_found=$((proj_found + 1))
                fi
            done
            IFS="$old_ifs"
        } > "$env_file"
        chmod 600 "$env_file"
        log "Wrote $env_file"

        local proj_name
        proj_name=$(basename "$path")
        echo -e "  ${GREEN}✅${NC} $proj_name/.env ${DIM}($proj_found keys)${NC}"

        p=$((p + 1))
    done

    echo ""
    echo -e "${GREEN}✅ Export complete.${NC}"
    log "=== Export complete ==="
}

# ── 4. Import from existing .env files ────────────────────────────────

do_import() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   📦 Import: .env files → Keychain               ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "This will scan your project directories for .env files and import"
    echo "any matching secrets into macOS Keychain (encrypted)."
    echo ""
    read -rp "Continue? (y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Cancelled."
        return
    fi

    echo ""
    local imported=0
    local skipped=0

    # Collect all .env files to scan
    local env_files=()

    # Global .env
    if [ -f "$ENV_FILE" ]; then
        env_files+=("$ENV_FILE")
    fi

    # Project .env files
    local p=0
    while [ "$p" -lt "$PROJECT_COUNT" ]; do
        local env_path="${PROJECT_PATHS[$p]}/.env"
        if [ -f "$env_path" ]; then
            env_files+=("$env_path")
        fi
        p=$((p + 1))
    done

    if [ ${#env_files[@]} -eq 0 ]; then
        echo -e "${YELLOW}No .env files found in configured paths.${NC}"
        return
    fi

    local f=0
    while [ "$f" -lt "${#env_files[@]}" ]; do
        local env_path="${env_files[$f]}"
        echo -e "  📄 Scanning ${DIM}$env_path${NC}"

        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            case "$key" in
                \#*|"") continue ;;
            esac
            key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

            if [ -z "$value" ]; then
                continue
            fi

            # Look up the keychain name for this env var
            local kc_name
            kc_name=$(kc_name_for "$key")
            if [ -z "$kc_name" ]; then
                continue
            fi

            # Check if already in Keychain
            local existing
            existing=$(get_secret "$kc_name")
            if [ -n "$existing" ]; then
                echo -e "    ${YELLOW}⏭️${NC}  $kc_name ${DIM}(already in Keychain)${NC}"
                skipped=$((skipped + 1))
            else
                set_secret "$kc_name" "$value"
                echo -e "    ${GREEN}✅${NC} Imported $kc_name ${DIM}($(mask_value "$value"))${NC}"
                imported=$((imported + 1))
            fi
        done < "$env_path"

        f=$((f + 1))
    done

    echo ""
    echo -e "${BOLD}Import summary:${NC}"
    echo -e "  ${GREEN}Imported: $imported${NC}"
    echo -e "  ${YELLOW}Skipped (already in Keychain): $skipped${NC}"
    echo ""

    if [ "$imported" -gt 0 ]; then
        echo -e "${YELLOW}Would you like to export secrets to .env files now?${NC}"
        read -rp "(y/n): " do_export_now
        if [ "$do_export_now" = "y" ] || [ "$do_export_now" = "Y" ]; then
            do_export
        fi
    fi

    echo ""
    echo -e "${GREEN}🎉 Import complete! Your secrets are now encrypted in macOS Keychain.${NC}"
}

# ── 5. Remove a secret ──────────────────────────────────────────────

do_remove() {
    echo ""
    echo -e "${BOLD}Remove a secret from Keychain${NC}"
    echo ""

    local found_names=()
    local found_count=0
    local i=0
    while [ "$i" -lt "$SECRET_COUNT" ]; do
        local name="${SECRET_NAMES[$i]}"
        local val
        val=$(get_secret "$name")
        if [ -n "$val" ]; then
            found_names+=("$name")
            found_count=$((found_count + 1))
            echo "  $found_count) $name — $(mask_value "$val")"
        fi
        i=$((i + 1))
    done

    if [ "$found_count" -eq 0 ]; then
        echo -e "${YELLOW}No secrets stored in Keychain.${NC}"
        return
    fi

    echo ""
    read -rp "Enter number to remove (or 0 to cancel): " choice

    if [ "$choice" = "0" ]; then
        echo "Cancelled."
        return
    fi

    if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$found_count" ] 2>/dev/null; then
        local secret_name="${found_names[$((choice - 1))]}"
        echo ""
        echo -e "${RED}⚠️  This will permanently remove '$secret_name' from Keychain.${NC}"
        read -rp "Are you sure? (y/n): " confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            delete_secret "$secret_name"
            echo -e "${GREEN}✅ Removed '$secret_name' from Keychain.${NC}"
        else
            echo "Cancelled."
        fi
    else
        echo -e "${RED}Invalid choice${NC}"
    fi
}

# ── Main loop ─────────────────────────────────────────────────────────

print_header

while true; do
    print_menu
    read -rp "Enter choice (1-6): " choice

    case "$choice" in
        1) do_store ;;
        2) do_list ;;
        3) do_export ;;
        4) do_import ;;
        5) do_remove ;;
        6) echo -e "\n${GREEN}Goodbye! 🔐${NC}\n"; exit 0 ;;
        *) echo -e "${RED}Invalid choice. Pick 1-6.${NC}" ;;
    esac

    echo ""
    echo -e "${BLUE}─────────────────────────────────────────${NC}"
done
