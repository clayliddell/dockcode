# OpenCode + OpenRouter Docker Sandbox

Custom Docker Sandbox template for running [OpenCode](https://opencode.ai) with [OpenRouter](https://openrouter.ai) as the LLM provider.

## Why

Docker Sandboxes' built-in credential proxy only supports a fixed set of providers (OpenAI, Anthropic, Google, xAI, Groq, AWS). OpenRouter isn't one of them, so the proxy strips its Authorization header. This template works around that by:

1. Bypassing the MITM proxy for OpenRouter domains
2. Injecting the API key via OpenCode's `auth.json`

## Prerequisites

- Docker Desktop for Linux (with `docker sandbox` CLI)
- An OpenRouter API key

## Quick Start

```bash
# Set your API key (or use a custom env var name — see AUTH_KEY_ENV_VAR below)
export DOCKCODE_OR_API_KEY=sk-or-v1-...

# Launch from any project directory
cd ~/my-project
./setup.sh launch
```

## Usage

```
Usage: setup.sh <command> [args...]

Commands:
  config show                          Print config file paths
  config update <key> <value>          Update a config value

      Keys:
        opencode.json    Path to opencode.json
        auth.json        Path to auth.json
        AUTH_KEY_ENV_VAR Environment variable name for API key
                         (default: DOCKCODE_OR_API_KEY)

  launch [-n name] [-w workspace]      Launch or create a sandbox

      -n    Sandbox name (default: current directory name)
      -w    Workspace directory (default: current directory)
```

## Config Management

Settings are stored in `~/.config/dockcode/config`:

| Key | Default | Description |
|---|---|---|
| `OPENCODE_CONFIG` | `~/.config/dockcode/opencode.json` | Path to OpenCode config |
| `AUTH_CONFIG` | `~/.config/dockcode/auth.json` | Path to auth template |
| `AUTH_KEY_ENV_VAR` | `DOCKCODE_OR_API_KEY` | Env var name for API key |

### Show current config

```bash
./setup.sh config show
```

### Update config values

```bash
# Use a different env var name for the API key
./setup.sh config update AUTH_KEY_ENV_VAR MY_CUSTOM_API_KEY

# Use a custom opencode.json
./setup.sh config update opencode.json ~/my-opencode.json

# Use a custom auth.json
./setup.sh config update auth.json ~/my-auth.json
```

### First-run behavior

The `launch` command is non-interactive. On first run:

1. If `~/.config/dockcode/opencode.json` doesn't exist, the project default is used
2. If `~/.config/dockcode/auth.json` doesn't exist, one is generated from the `AUTH_KEY_ENV_VAR` setting
3. If neither project defaults nor host configs exist, an error is shown

## Launch Command

```bash
# Launch in current directory (sandbox named after directory)
cd ~/my-project
./setup.sh launch

# Launch with custom name and workspace
./setup.sh launch -n my-sandbox -w ~/other-project

# Re-launch existing sandbox (no rebuild)
./setup.sh launch -n my-sandbox
```

If a sandbox with the given name already exists, it is launched directly. Otherwise, a new sandbox is created with proxy bypass and auth injection.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Extends `docker/sandbox-templates:opencode` with OpenCode config and auth template |
| `opencode.json` | Default OpenCode config (OpenRouter models, permissions) |
| `auth.json` | Default auth template (reference; generated from `AUTH_KEY_ENV_VAR` at build time) |
| `setup.sh` | CLI with config management and sandbox launch |

## Configuration

### Models

Edit `~/.config/dockcode/opencode.json` to change the default models:

```json
{
  "model": "openrouter/anthropic/claude-sonnet-4-5",
  "small_model": "openrouter/anthropic/claude-haiku-4-5",
  "provider": {
    "openrouter": {
      "models": {
        "anthropic/claude-sonnet-4-5": {},
        "openai/gpt-4.1": {}
      }
    }
  }
}
```

### Permissions

Edit the `permission` section to restrict agent capabilities:

```json
{
  "permission": {
    "bash": "ask",
    "edit": "allow",
    "read": "allow"
  }
}
```

### Custom API key env var

If you don't want to use `DOCKCODE_OR_API_KEY`:

```bash
./setup.sh config update AUTH_KEY_ENV_VAR MY_API_KEY
export MY_API_KEY=sk-or-v1-...
./setup.sh launch
```

The Dockerfile bakes the env var *name* into the image at build time. At runtime, the script reads the actual *value* from the env var and injects it into the sandbox.

## How It Works

1. **Build** — The Dockerfile generates `auth.json` in the image using the `AUTH_KEY_ENV_VAR` build arg. The env var name (not value) is baked in.
2. **Create** — A sandbox is created with the custom template, and OpenRouter domains are bypassed from the MITM proxy.
3. **Inject** — At sandbox creation, the script reads the env var value and substitutes it into `auth.json` inside the sandbox.

The API key is never stored in the image — only the env var *name* is baked in.

## Troubleshooting

**"Missing Authentication header"** — The proxy bypass isn't configured. Run:
```bash
docker sandbox network proxy <sandbox-name> --bypass-host api.openrouter.ai
```

**"User not found"** — The API key is invalid. Verify your key at [openrouter.ai/settings/keys](https://openrouter.ai/settings/keys).

**"OpenRouter API key is missing"** — The env var referenced by `AUTH_KEY_ENV_VAR` is not set. Check:
```bash
./setup.sh config show   # see which env var is configured
echo $DOCKCODE_OR_API_KEY # verify it's set
```
