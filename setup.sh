#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
IMAGE_NAME="opencode-openrouter"
IMAGE_TAG="v1"
TEMPLATE="${IMAGE_NAME}:${IMAGE_TAG}"
DOCKCODE_CONFIG_DIR="${HOME}/.config/dockcode"
CONFIG_FILE="${DOCKCODE_CONFIG_DIR}/config"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_OPENCODE_CONFIG="${DOCKCODE_CONFIG_DIR}/opencode.json"
DEFAULT_AUTH_CONFIG="${DOCKCODE_CONFIG_DIR}/auth.json"
DEFAULT_AUTH_KEY_ENV_VAR="DOCKCODE_OR_API_KEY"

# ─── Config file I/O ──────────────────────────────────────────────────────────
get_config() {
  local key="$1" default="${2:-}"
  if [ -f "$CONFIG_FILE" ] && grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
    grep "^${key}=" "$CONFIG_FILE" | head -1 | cut -d= -f2-
  else
    echo "$default"
  fi
}

set_config() {
  local key="$1" value="$2"
  mkdir -p "$DOCKCODE_CONFIG_DIR"
  if [ -f "$CONFIG_FILE" ] && grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$CONFIG_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$CONFIG_FILE"
  fi
}

init_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    mkdir -p "$DOCKCODE_CONFIG_DIR"
    printf 'OPENCODE_CONFIG=%s\nAUTH_CONFIG=%s\nAUTH_KEY_ENV_VAR=%s\n' \
      "$DEFAULT_OPENCODE_CONFIG" "$DEFAULT_AUTH_CONFIG" "$DEFAULT_AUTH_KEY_ENV_VAR" \
      > "$CONFIG_FILE"
  fi
}

# ─── Initialize config and resolve values ─────────────────────────────────────
init_config
OPENCODE_CONFIG="$(get_config OPENCODE_CONFIG "$DEFAULT_OPENCODE_CONFIG")"
AUTH_CONFIG="$(get_config AUTH_CONFIG "$DEFAULT_AUTH_CONFIG")"
AUTH_KEY_ENV_VAR="$(get_config AUTH_KEY_ENV_VAR "$DEFAULT_AUTH_KEY_ENV_VAR")"

# ─── Helpers ──────────────────────────────────────────────────────────────────
info() { echo "$*"; }
error() { echo "ERROR: $*" >&2; }

prompt_choice() {
  local prompt="$1"
  shift
  local choice
  while true; do
    echo ""
    echo "$prompt"
    local i=1
    for opt in "$@"; do
      echo "  $i) $opt"
      ((i++))
    done
    printf "\nChoice [1-%d]: " $# >&2
    read -r choice
    if [[ "$choice" =~ ^[1-$#]$ ]]; then
      echo "$choice"
      return
    fi
    echo "Invalid choice. Enter 1-$#." >&2
  done
}

# ─── Resolve config file ─────────────────────────────────────────────────────
# Args: resolve_config <target_path> <default_path> <label> <filename> <quiet>
# quiet=false: prompt user if target doesn't exist
# quiet=true:  fall back to default silently
resolve_config() {
  local target="$1" default="$2" label="$3" filename="$4" quiet="$5"

  if [ -f "$target" ]; then
    return
  fi

  local host_path="${HOME}/.config/opencode/${filename}"
  if [ -f "$host_path" ]; then
    mkdir -p "$(dirname "$target")"
    cp "$host_path" "$target"
    info "Copied ${label} from host: $host_path"
    return
  fi

  if [ "$quiet" = "true" ]; then
    if [ -f "$default" ]; then
      mkdir -p "$(dirname "$target")"
      cp "$default" "$target"
      return
    fi
    error "No ${label} found at $target"
    error "Run: $0 config update ${filename} <path>"
    exit 1
  fi

  mkdir -p "$(dirname "$target")"
  local choice
  choice=$(prompt_choice \
    "No ${label} found at $target. Which would you like to use?" \
    "Use project default (${filename})" \
    "Copy from host (~/.config/opencode/${filename})" \
    "Specify a custom path")

  case "$choice" in
    1)
      if [ -f "$default" ]; then
        cp "$default" "$target"
      else
        error "No project default found."
        exit 1
      fi
      ;;
    2)
      if [ -f "$host_path" ]; then
        cp "$host_path" "$target"
      else
        error "Host file not found: $host_path"
        error "Falling back to project default."
        if [ -f "$default" ]; then
          cp "$default" "$target"
        else
          error "No project default found."
          exit 1
        fi
      fi
      ;;
    3)
      local custom_path
      printf "Enter path: "
      read -r custom_path
      custom_path="${custom_path/#\~/$HOME}"
      if [ ! -f "$custom_path" ]; then
        error "File not found: $custom_path"
        exit 1
      fi
      cp "$custom_path" "$target"
      ;;
  esac
  info "Copied ${label} to $target"
}

# ─── Write project defaults ───────────────────────────────────────────────────
write_default_opencode() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" << 'OPENCODE_EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "openrouter/anthropic/claude-sonnet-4-5",
  "small_model": "openrouter/anthropic/claude-haiku-4-5",
  "provider": {
    "openrouter": {
      "models": {
        "anthropic/claude-sonnet-4-5": {},
        "anthropic/claude-haiku-4-5": {},
        "anthropic/claude-opus-4-5": {},
        "openai/gpt-4.1": {},
        "openai/gpt-4.1-mini": {},
        "google/gemini-2.5-pro": {},
        "google/gemini-2.5-flash": {},
        "deepseek/deepseek-r1": {},
        "deepseek/deepseek-chat-v3-0324": {},
        "moonshotai/kimi-k2": {}
      }
    }
  },
  "permission": {
    "bash": "allow",
    "edit": "allow",
    "read": "allow",
    "glob": "allow",
    "grep": "allow"
  }
}
OPENCODE_EOF
}

write_default_auth() {
  local env_var="$2"
  mkdir -p "$(dirname "$1")"
  printf '{\n  "openrouter": {\n    "type": "api",\n    "key": "%s"\n  }\n}\n' \
    "$env_var" > "$1"
}

# ─── Build image ──────────────────────────────────────────────────────────────
build_image() {
  info "Building custom sandbox image..."
  local build_ctx
  build_ctx=$(mktemp -d)
  cp "$OPENCODE_CONFIG" "${build_ctx}/opencode.json"
  cp "${SCRIPT_DIR}/Dockerfile" "${build_ctx}/Dockerfile"
  docker build -t "$TEMPLATE" "$build_ctx"
  rm -rf "$build_ctx"
}

# ─── Inject auth.json ─────────────────────────────────────────────────────────
inject_auth() {
  local auth_path="$1" sandbox_name="$2" env_var="$3"
  local content
  content=$(cat "$auth_path")

  local env_value="${!env_var:-}"
  if [ -n "$env_value" ]; then
    content="${content//$env_var/$env_value}"
  fi

  docker sandbox exec "$sandbox_name" bash -c "
mkdir -p ~/.local/share/opencode
cat > ~/.local/share/opencode/auth.json << 'INNER_EOF'
${content}
INNER_EOF
chmod 600 ~/.local/share/opencode/auth.json
"
}

# ─── Create and run sandbox ───────────────────────────────────────────────────
create_sandbox() {
  local name="$1" workspace="$2"

  if ! docker context use desktop-linux >/dev/null 2>&1; then
    error "Docker Desktop context 'desktop-linux' not found."
    error "Make sure Docker Desktop is installed and running."
    exit 1
  fi

  build_image

  docker sandbox rm "$name" 2>/dev/null || true

  info "Creating sandbox '$name'..."
  docker sandbox create --name "$name" -t "$TEMPLATE" opencode "$workspace"

  info "Configuring network bypass for OpenRouter..."
  docker sandbox network proxy "$name" \
    --bypass-host api.openrouter.ai \
    --bypass-host openrouter.ai

  info "Injecting auth.json..."
  inject_auth "$AUTH_CONFIG" "$name" "$AUTH_KEY_ENV_VAR"

  echo ""
  echo "Sandbox '$name' is ready."
  echo ""
  echo "  Workspace:  $workspace"
  echo "  Template:   $TEMPLATE"
  echo "  Config:     $OPENCODE_CONFIG"
  echo "  Auth:       $AUTH_CONFIG"
  echo "  Auth env:   \$$AUTH_KEY_ENV_VAR"
}

# ─── Show usage ───────────────────────────────────────────────────────────────
show_usage() {
  cat >&2 << 'EOF'
Usage: setup.sh <command> [args...]

Commands:
  config show                          Print config file paths
  config update <key> <value>          Update a config value

      Keys:
        opencode.json    Path to opencode.json
        auth.json        Path to auth.json
        OR_KEY_ENV_VAR   Env var name for OpenRouter API key
                         - overrides OR API key in auth.json
                         (default: DOCKCODE_OR_API_KEY)

  launch [-n name] [-w workspace]      Launch or create a sandbox

      -n    Sandbox name (default: current directory name)
      -w    Workspace directory (default: current directory)
EOF
  exit 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# SUB-COMMANDS
# ═══════════════════════════════════════════════════════════════════════════════

handle_config_show() {
  echo "opencode.json     $OPENCODE_CONFIG"
  echo "auth.json         $AUTH_CONFIG"
  echo "AUTH_KEY_ENV_VAR  $AUTH_KEY_ENV_VAR"
}

handle_config_update() {
  local key="${1:-}"
  local value="${2:-}"

  if [ -z "$key" ] || [ -z "$value" ]; then
    error "Usage: setup.sh config update <key> <value>"
    exit 1
  fi

  case "$key" in
    opencode.json)
      value="${value/#\~/$HOME}"
      set_config OPENCODE_CONFIG "$value"
      ;;
    auth.json)
      value="${value/#\~/$HOME}"
      set_config AUTH_CONFIG "$value"
      ;;
    AUTH_KEY_ENV_VAR)
      set_config AUTH_KEY_ENV_VAR "$value"
      ;;
    *)
      error "Unknown key: $key"
      error "Valid keys: opencode.json, auth.json, AUTH_KEY_ENV_VAR"
      exit 1
      ;;
  esac

  info "Updated $key = $value"
}

handle_launch() {
  local name="" workspace=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -n) name="$2"; shift 2 ;;
      -w) workspace="$2"; shift 2 ;;
      *) error "Unknown flag: $1"; exit 1 ;;
    esac
  done

  workspace="${workspace:-.}"
  if [ ! -d "$workspace" ]; then
    error "Workspace directory does not exist: $workspace"
    exit 1
  fi
  workspace="$(realpath "$workspace")"

  if [ -z "$name" ]; then
    name="$(basename "$workspace" | tr '.' '-')"
  fi

  # Check if sandbox already exists
  local existing
  existing=$(docker sandbox ls --json 2>/dev/null | \
    grep -o "\"name\": *\"${name}\"" || true)
  if [ -n "$existing" ]; then
    info "Launching existing sandbox '$name'..."
    docker sandbox run "$name"
    return
  fi

  # Resolve configs (non-interactive, use defaults as fallback)
  resolve_config "$OPENCODE_CONFIG" "$SCRIPT_DIR/opencode.json" \
    "opencode.json" "opencode.json" "true"
  resolve_config "$AUTH_CONFIG" "$SCRIPT_DIR/auth.json" \
    "auth.json" "auth.json" "true"

  # Ensure auth.json uses configured env var name
  write_default_auth "$AUTH_CONFIG" "$AUTH_KEY_ENV_VAR"

  create_sandbox "$name" "$workspace"
  echo ""
  echo "Connect with:"
  echo "  docker sandbox run $name"
}

# ═══════════════════════════════════════════════════════════════════════════════
# COMMAND DISPATCH
# ═══════════════════════════════════════════════════════════════════════════════

case "${1:-}" in
  config)
    case "${2:-}" in
      show)  handle_config_show ;;
      update) handle_config_update "${3:-}" "${4:-}" ;;
      *)     show_usage ;;
    esac
    ;;
  launch)
    shift
    handle_launch "$@"
    ;;
  *)
    show_usage
    ;;
esac
