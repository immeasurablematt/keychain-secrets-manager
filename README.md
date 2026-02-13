# 🔐 Keychain Secrets Manager

A simple, config-driven tool that stores your API keys and tokens in **macOS Keychain** (encrypted at rest) and exports them to `.env` files for your projects.

No dependencies. No cloud. No Docker. Just one bash script and macOS Keychain.

## Why

Most developers have API keys scattered across `.env` files in plaintext. If someone gets access to your filesystem, they get all your keys.

Keychain Secrets Manager fixes this:

- **Encrypted at rest** — secrets live in macOS Keychain, protected by your login password
- **One source of truth** — define your keys once, export to as many projects as you need
- **Config-driven** — a single `secrets.conf` file maps keys to projects
- **Zero dependencies** — pure bash, works with the macOS `security` CLI that's already on your Mac
- **Interactive** — a friendly menu for storing, listing, exporting, and importing secrets
- **bash 3.2 compatible** — works on every Mac out of the box (no brew bash needed)

## Install

```bash
git clone https://github.com/yourusername/keychain-secrets-manager.git
cd keychain-secrets-manager
bash install.sh
```

This will:
1. Copy the script to `~/.keychain-secrets-manager/`
2. Symlink `secrets-manager` to `/usr/local/bin/` (so you can run it from anywhere)
3. Create a starter config at `~/.secrets.conf`

## Quick start

**1. Define your secrets** — edit `~/.secrets.conf`:

```ini
[settings]
service = my-app
env_file = ~/.my-app/.env

[secrets]
anthropic-api-key  | ANTHROPIC_API_KEY  | Anthropic Claude API key
openai-api-key     | OPENAI_API_KEY     | OpenAI API key
stripe-secret-key  | STRIPE_SECRET_KEY  | Stripe secret key
database-url       | DATABASE_URL       | PostgreSQL connection string

[projects]
~/projects/my-web-app  | ANTHROPIC_API_KEY, STRIPE_SECRET_KEY, DATABASE_URL
~/projects/my-api      | OPENAI_API_KEY, DATABASE_URL
```

**2. Store your keys:**

```bash
secrets-manager
# Choose option 1, pick a key, paste the value
```

**3. Export to .env files:**

```bash
# Still in the menu — choose option 3
# Or run directly:
secrets-manager export
```

That's it. Your keys are encrypted in Keychain and written to each project's `.env`.

## Config file format

The config file (`~/.secrets.conf`) has three sections:

### `[settings]`

| Key | Description | Default |
|-----|-------------|---------|
| `service` | Keychain service name (groups your secrets) | `secrets-manager` |
| `env_file` | Path to the global `.env` file | `~/.env` |
| `log_file` | Path to the export log | `/tmp/secrets-manager-export.log` |

### `[secrets]`

One secret per line:

```
keychain-name | ENV_VAR_NAME | Description
```

- **keychain-name** — how it's stored in Keychain (lowercase, dashes)
- **ENV_VAR_NAME** — the environment variable name written to `.env` files
- **Description** — shown in the interactive menu

### `[projects]`

One project per line:

```
/path/to/project | ENV_VAR1, ENV_VAR2, ENV_VAR3
```

Each project gets its own `.env` file containing only the secrets it needs. Projects that don't exist on disk are silently skipped.

## How it works

```
┌─────────────┐     ┌─────────────────┐     ┌──────────────┐
│  You paste   │────▶│  macOS Keychain  │────▶│  .env files  │
│  a secret    │     │  (encrypted)     │     │  (per project)│
└─────────────┘     └─────────────────┘     └──────────────┘
                           │
                           ▼
                    ┌──────────────┐
                    │  Global .env │
                    │  (all keys)  │
                    └──────────────┘
```

1. **Store** — your secret goes into macOS Keychain under the service name from your config
2. **Export** — reads each secret from Keychain and writes them to `.env` files
3. **Projects** — each project gets only the keys it needs, as defined in `[projects]`

The global `.env` file contains all secrets and can be sourced in your shell profile for universal access:

```bash
# Add to ~/.zshrc or ~/.bashrc
if [ -f "$HOME/.my-app/.env" ]; then
    set -a; source "$HOME/.my-app/.env"; set +a
fi
```

## Menu options

| Option | What it does |
|--------|-------------|
| **1. Store** | Pick a secret from the list, paste the value — stored in Keychain |
| **2. List** | Show all secrets and their status (stored / not set) |
| **3. Export** | Read Keychain → write `.env` files for all projects |
| **4. Import** | Scan existing `.env` files and import matching secrets into Keychain |
| **5. Remove** | Delete a secret from Keychain |
| **6. Quit** | Exit |

## Shell integration

After exporting, source the global `.env` in your shell to make all secrets available as environment variables everywhere:

```bash
# In ~/.zshrc or ~/.bashrc
if [ -f "$HOME/.my-app/.env" ]; then
    set -a; source "$HOME/.my-app/.env"; set +a
fi
```

The installer can add this for you automatically.

## Importing existing secrets

If you already have `.env` files with real API keys, option 4 (Import) will:

1. Scan your global `.env` and all project `.env` files
2. Match environment variable names to your `[secrets]` config
3. Store each match in Keychain (skips duplicates)
4. Optionally re-export clean `.env` files

This is a one-time migration — after that, Keychain is the source of truth.

## Security model

- **Encrypted at rest** — macOS Keychain uses AES-256 encryption, unlocked by your login password
- **No plaintext storage** — secrets only exist in `.env` files after you explicitly export
- **File permissions** — all generated `.env` files are `chmod 600` (owner read/write only)
- **No network** — nothing leaves your machine. No cloud, no telemetry, no phone-home
- **No root required** — uses the login keychain, not the system keychain

## FAQ

**Q: Does this work on Linux?**
Not yet. It's built on macOS Keychain. A Linux version using `secret-tool` (GNOME Keyring) or `pass` would be a welcome PR.

**Q: What if I delete a secret from Keychain?**
The next export will produce `.env` files without that key. Your projects will see an empty value for that variable.

**Q: Can multiple people share a config?**
Yes. Commit `secrets.conf` to your repo (it contains no secret values, just names and project mappings). Each person stores their own values in their own Keychain.

**Q: Does it work with Docker?**
Yes. Export your secrets, then reference the `.env` file in your `docker-compose.yml`:
```yaml
env_file:
  - .env
```

**Q: What bash version do I need?**
Bash 3.2+ (the version that ships with every Mac since 2007). No Homebrew bash needed.

## Uninstall

```bash
cd keychain-secrets-manager
bash install.sh --uninstall
```

This removes the tool but **not** your Keychain secrets. Your keys stay safe.

## License

MIT — see [LICENSE](LICENSE).
