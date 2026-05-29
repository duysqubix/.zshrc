# =============================================================================
# ZSH Configuration File
# =============================================================================
#
# This configuration file provides:
# - Automatic Oh My Zsh installation and configuration
# - Docker availability checking with optional installation
# - Remote .zshrc synchronization with the GitHub repo (raw on master)
# - Essential command installation (git, wget, shfmt, ripgrep, bat, etc.)
# - Delta (git diff tool) installation for supported architectures
# - Bat-extras installation for enhanced file viewing
# - FZF installation for fuzzy finding
# - Docker test environment for .zshrc testing
# - Various aliases and utility functions
#
# Environment Variables:
# - ZSH_DEBUG: Enable debug logging (set to any value)
# - ZSH_FORCE_UPDATE: Force update .zshrc from remote (set to any value)
#
# Usage:
# - Set ZSH_DEBUG=1 to see debug output during shell startup
# - Set ZSH_FORCE_UPDATE=1 to automatically update from remote
# - Run 'update_zshrc' to manually update from remote
# - Run 'install-docker' to install Docker (if not found)
# - Run 'testohmyzsh' to test .zshrc in Docker container
#
# =============================================================================

set -o pipefail

# Recompile the rc when the source has changed (or .zwc is missing).
# Subsequent shell starts will source the bytecode cache and skip the parse.
if [[ ! -f $HOME/.zshrc.zwc || $HOME/.zshrc -nt $HOME/.zshrc.zwc ]]; then
  zcompile $HOME/.zshrc 2>/dev/null
fi

RED="\e[0;31m"
GREEN="\e[0;32m"
YELLOW="\e[0;33m"
CYAN="\e[0;36m"
WHITE="\e[0;37m"
RESET="\e[0m"

ZSH_LOG_LEVEL=${ZSH_LOG_LEVEL:-info}

panic(){
  echo "${RED}Error occured${RESET}"
  echo "${RED}$1${RESET}"
  exit 1
}

typeset -A _LOG_LEVELS=( [debug]=1 [info]=2 [warn]=3 [error]=4 )
_LOG_LEVEL=$_LOG_LEVELS[$ZSH_LOG_LEVEL]


zlog() {
  # If no input from a pipe, do normal argument-based log.
  if [[ -t 0 ]]; then  # stdin is a terminal (not a pipe)
    local level=$1
    local msg=$2

    if [[ -z $_LOG_LEVEL ]]; then
      echo "${RED}LOG LEVEL NOT SET: [$_LOG_LEVEL]${RESET}" >&2
      return 1
    fi

    if [[ -z $2 ]]; then
      msg=$level
      level='info'
    fi

    case $level in
      debug) [[ $_LOG_LEVEL -le 1 ]] && echo "${RED}-->${RESET} ${WHITE}[DEBUG]:${RESET} $msg" ;;
      info) [[ $_LOG_LEVEL -le 2 ]] && echo "${RED}-->${RESET} ${CYAN}[INFO]:${RESET} $msg" ;;
      warn) [[ $_LOG_LEVEL -le 3 ]] && echo "${RED}-->${RESET} ${YELLOW}[WARN]:${RESET} $msg" ;;
      error) [[ $_LOG_LEVEL -le 4 ]] && echo "${RED}-->${RESET} ${RED}[ERROR]:${RESET} $msg" ;;
      *) zlog "${RED}********* DEFAULT CASE STMT SHOULD NOT BE CALLED ************${RESET}" && echo "level: $level msg: $msg"; panic ;;
    esac
  else
    # Read from pipe, default to info, allow override with env if desired.
    local level=${1:-info}
    if [[ -z $_LOG_LEVEL ]]; then
      echo "${RED}LOG LEVEL NOT SET: [$_LOG_LEVEL]${RESET}" >&2
      return 1
    fi

    local prefix
    local should_echo=0
    case $level in
      debug) prefix="${WHITE}[DEBUG]:${RESET}"; [[ $_LOG_LEVEL -le 1 ]] && should_echo=1 ;;
      info)  prefix="${CYAN}[INFO]:${RESET}"; [[ $_LOG_LEVEL -le 2 ]] && should_echo=1 ;;
      warn)  prefix="${YELLOW}[WARN]:${RESET}"; [[ $_LOG_LEVEL -le 3 ]] && should_echo=1 ;;
      error) prefix="${RED}[ERROR]:${RESET}"; [[ $_LOG_LEVEL -le 4 ]] && should_echo=1 ;;
      *)     prefix="${RED}[LOG]:${RESET}"; should_echo=1 ;;
    esac

    while IFS= read -r line; do
      [[ $should_echo -eq 1 ]] && echo "${RED}-->${RESET} ${prefix} $line"
    done
  fi
}

pathadd(){
  if [ -d "$1" ] && [[ ":$PATH:" != *":$1"* ]]; then
    PATH="${PATH:+"$PATH:"}$1"
  fi
}

# Docker test environment
testohmyzsh() {
  if ! command_exists docker; then
    panic "Docker is not available"
  fi
  build_test_zsh || return $?
  zlog "Running testohmyzsh in Docker container"
  docker run --rm -it -v $HOME/.zshrc:/root/.zshrc-orig  -e HOME=/root -e ZSH_LOG_LEVEL=debug testohmyzsh/zsh:bats -c "cp /root/.zshrc-orig /root/.zshrc && source /root/.zshrc"
}

# BATS test runner: same image as testohmyzsh, runs zshrc.bats inside.
# Usage: test_zshrc [--with-sudo]
# ZSHRC_BATS env var overrides the bats file location.
test_zshrc() {
  if ! command_exists docker; then
    panic "Docker is not available; cannot run test_zshrc"
  fi

  local with_sudo=0
  if [[ "${1:-}" == "--with-sudo" ]]; then
    with_sudo=1
    shift
  fi

  build_test_zsh || return $?

  local bats_file=""
  if [[ -n ${ZSHRC_BATS:-} && -f $ZSHRC_BATS ]]; then
    bats_file=$ZSHRC_BATS
  elif [[ -L $HOME/.zshrc ]]; then
    bats_file="$(dirname "$(readlink -f "$HOME/.zshrc")")/zshrc.bats"
  fi
  if [[ -z $bats_file || ! -f $bats_file ]]; then
    bats_file="$HOME/zshrc.bats"
  fi
  if [[ ! -f $bats_file ]]; then
    panic "Cannot locate zshrc.bats (set ZSHRC_BATS, or place at \$HOME/zshrc.bats, or symlink \$HOME/.zshrc into a repo containing it)"
  fi

  local -a docker_args
  docker_args=(--rm
    -v "$HOME/.zshrc:/srv/zshrc-orig:ro"
    -v "$bats_file:/srv/zshrc.bats:ro"
    -e "ZSH_LOG_LEVEL=${ZSH_LOG_LEVEL:-info}")

  # The bats suite reads the rc from $RC and the immutable copy from
  # $ZSH_RC_ORIG. setup() copies $ZSH_RC_ORIG → $RC before each test so
  # destructive tests (e.g. update_zshrc) cannot leak across cases.
  if [[ $with_sudo -eq 1 ]]; then
    zlog "Running test_zshrc (--with-sudo, non-root) in container"
    docker run "${docker_args[@]}" testohmyzsh/zsh:bats -c "
      install -m 0644 -o tester -g tester /srv/zshrc-orig /home/tester/.zshrc-orig
      install -m 0644 -o tester -g tester /srv/zshrc-orig /home/tester/.zshrc
      install -m 0644 -o tester -g tester /srv/zshrc.bats /home/tester/zshrc.bats
      su tester -c 'cd /home/tester && RC=/home/tester/.zshrc ZSH_RC_ORIG=/home/tester/.zshrc-orig bats /home/tester/zshrc.bats'
    "
  else
    zlog "Running test_zshrc (root, no sudo) in container"
    docker run "${docker_args[@]}" testohmyzsh/zsh:bats -c "
      cp /srv/zshrc-orig /root/.zshrc-orig
      cp /srv/zshrc-orig /root/.zshrc
      cp /srv/zshrc.bats /root/zshrc.bats
      cd /root && RC=/root/.zshrc ZSH_RC_ORIG=/root/.zshrc-orig bats /root/zshrc.bats
    "
  fi
}

# Self-update source of truth: the .zshrc tracked in the GitHub repo (raw on the
# default branch). Update this if the repo/branch ever moves.
_zshrc_remote_url="https://raw.githubusercontent.com/duysqubix/.zshrc/master/.zshrc"

update_zshrc() {
  zlog debug "Updating .zshrc from remote"
  curl -s $_zshrc_remote_url -o $HOME/.zshrc \
    || panic "Unable to read remote .zshrc from the repo"
  local _fetch_hash=$(_zshrc_sha256 < $HOME/.zshrc)
  print -r -- $_fetch_hash > $HOME/.zshrc-hash-remote
  print -r -- $_fetch_hash > $HOME/.zshrc-hash
  # Force the install gauntlet to re-run on next shell start.
  rm -f $HOME/.zshrc-bootstrapped
  # Regenerate the bytecode cache so the next shell start picks up the new rc.
  zcompile $HOME/.zshrc 2>/dev/null
}

zshrc_diff(){
  zlog debug "Checking diff between local and remote .zshrc"
  curl -o /tmp/.zshrc-remote $_zshrc_remote_url | zlog || panic "Unable to read remote .zshrc from the repo"

  if command_exists delta; then
    zlog debug "using 'delta' to find differences"
    delta /tmp/.zshrc-remote $HOME/.zshrc
  else
    zlog debug "'${GREEN}delta${RESET}' command not found, defaulting to '${RED}diff${RESET}'"
    diff /tmp/.zshrc-remote $HOME/.zshrc
  fi
}

zshrc_check_for_updates(){

  # Check for .zshrc updates
  zlog debug "Fetching remote .zshrc hash"
  local remote_hash=$(curl -s $_zshrc_remote_url | _zshrc_sha256)
  local local_hash=$(_zshrc_sha256 < $HOME/.zshrc)

  if [[ $local_hash != $remote_hash ]]; then
    zlog warn "Local '${RED}.zshrc${RESET}' out of sync with remote"
    zlog "${YELLOW}!!!!!!!!!!!!!!!${RED}**${CYAN}-${GREEN}Current .zshrc is out of sync with remote${CYAN}-${RED}**${YELLOW}!!!!!!!!!!!!!!!${RESET}"
    zlog "Check differences with '${GREEN}'zshrc_diff'${RESET} command"
    zlog "Sync with remote with '${GREEN}'update_zshrc'${RESET} command"
    zlog debug "Remote Hash: ${GREEN}${remote_hash}${RESET}"
    zlog debug "Local Hash: ${GREEN}${local_hash}${RESET}"
  fi

}

command_exists() {
  command -v "$1" > /dev/null 2>&1
}

# Portable SHA-256 of stdin: prints the lowercase hex digest only. Linux ships
# sha256sum (GNU coreutils); macOS ships shasum -a 256 instead. Both emit the
# same hex, only the binary name differs.
_zshrc_sha256() {
  if command_exists sha256sum; then
    sha256sum | awk '{print $1}'
  elif command_exists shasum; then
    shasum -a 256 | awk '{print $1}'
  else
    panic "no sha256sum or shasum available for hashing"
  fi
}

directory_exists() {
  [[ -d "$1" ]]
}

# OS-detection seam. Honors the ZSHRC_OS env override first (so the bats suite
# can force a branch inside the Linux container), otherwise derives the OS from
# $OSTYPE: darwin* -> macos, anything else -> linux. Every cross-platform branch
# in this rc dispatches on this single function.
_zshrc_os() {
  if [[ -n ${ZSHRC_OS:-} ]]; then
    print -r -- "$ZSHRC_OS"
    return 0
  fi
  case ${OSTYPE:-} in
    darwin*) print -r -- macos ;;
    *)       print -r -- linux ;;
  esac
}

# Daily-rebuild idiom: full compinit when .zcompdump is missing or > 24h old,
# otherwise compinit -C (skip security audit). Saves the OMZ-startup compinit
# tax on every shell launch.
_zshrc_compinit() {
  emulate -L zsh -o extended_glob
  autoload -Uz compinit
  if [[ ! -f $HOME/.zcompdump || -n $HOME/.zcompdump(#qN.mh+24) ]]; then
    compinit
  else
    compinit -C
  fi
}

# Install gauntlet: all install/check branches consolidated.
# Skipped on subsequent shell starts via $HOME/.zshrc-bootstrapped marker.
# ZSH_FORCE_UPDATE=1 bypasses the marker (re-runs presence checks).
# update_zshrc removes the marker so a remote bump re-bootstraps next start.
_zshrc_install_gauntlet() {
  if [[ -f $HOME/.zshrc-bootstrapped && -z ${ZSH_FORCE_UPDATE:-} ]]; then
    zlog debug "Bootstrap marker present; skipping install gauntlet"
    return 0
  fi
  zlog debug "Running install gauntlet"

  # Warn (don't panic) if sudo will need a password later — the apt-get calls
  # below will prompt the user. Linux-only: macOS Homebrew never needs sudo, so
  # a sudo probe there would be pointless (and would prompt unnecessarily).
  if [[ -n $SUDO_CMD ]] && [[ "$(_zshrc_os)" == linux ]]; then
    sudo -n true 2>/dev/null || zlog warn "sudo will prompt for password during install steps"
  fi

  local _os="$(_zshrc_os)"

  # Fail loud on an unrecognized OS (e.g. a typo'd ZSHRC_OS override) instead of
  # silently skipping every install branch and still writing the bootstrap
  # marker, which would falsely mark the machine as provisioned.
  case "$_os" in
    linux|macos) ;;
    *) panic "unsupported OS '$_os' (check \$ZSHRC_OS / \$OSTYPE)" ;;
  esac

  # Package install, dispatched by OS. Both branches batch into a single
  # update + single install (one transaction instead of N).
  case "$_os" in
    linux)
      # Collect all missing apt packages and install in one batched apt-get call.
      local -a needs_apt
      needs_apt=()

      zlog debug "Checking required commands..."
      typeset -A required_commands=( [git]=git [wget]=wget [ps]=procps )
      for cmd in ${(k)required_commands}; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
          zlog info "Missing command: ${RED}${cmd}${RESET}"
          needs_apt+=$required_commands[$cmd]
        fi
      done

      if ! command_exists fzf; then
        zlog debug "fzf missing, queuing for apt batch"
        needs_apt+=fzf
      fi

      if (( ${#needs_apt[@]} > 0 )); then
        zlog debug "Installing apt packages: ${needs_apt[*]}"
        ${=SUDO_CMD} apt-get update -qq \
          || panic "apt-get update failed"
        ${=SUDO_CMD} apt-get install -y "${needs_apt[@]}" \
          || panic "could not install apt packages: ${needs_apt[*]}"
      fi
      ;;
    macos)
      command_exists brew \
        || panic "Homebrew is required on macOS — install it from https://brew.sh"

      # Collect all missing formulae and install in one batched brew call. ps
      # ships with macOS (no procps formula); bat/ripgrep/bat-extras/uv all have
      # first-class formulae, so macOS skips the cargo/rustup/git-clone paths.
      local -a needs_brew
      needs_brew=()

      zlog debug "Checking required commands..."
      typeset -A required_commands=( [git]=git [wget]=wget [fastfetch]=fastfetch )
      for cmd in ${(k)required_commands}; do
        if ! command_exists "$cmd"; then
          zlog info "Missing command: ${RED}${cmd}${RESET}"
          needs_brew+=$required_commands[$cmd]
        fi
      done

      command_exists fzf    || { zlog debug "fzf missing, queuing for brew batch";        needs_brew+=fzf; }
      command_exists bat    || { zlog debug "bat missing, queuing for brew batch";        needs_brew+=bat; }
      command_exists rg     || { zlog debug "ripgrep missing, queuing for brew batch";    needs_brew+=ripgrep; }
      command_exists batman || { zlog debug "bat-extras missing, queuing for brew batch"; needs_brew+=bat-extras; }
      command_exists uv     || { zlog debug "uv missing, queuing for brew batch";         needs_brew+=uv; }

      if (( ${#needs_brew[@]} > 0 )); then
        zlog debug "Installing brew formulae: ${needs_brew[*]}"
        brew update -q \
          || panic "brew update failed"
        HOMEBREW_NO_AUTO_UPDATE=1 brew install "${needs_brew[@]}" \
          || panic "could not install brew formulae: ${needs_brew[*]}"
      fi
      ;;
  esac

  zlog debug "Checking Oh My Zsh installation"
  if ! [[ -d $HOME/.oh-my-zsh ]]; then
    zlog warn "Oh My Zsh is not installed. Installing..."
    RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended | zlog || panic "Could not install Oh-My-Zsh"
  fi

  zlog debug "Checking Docker availability"
  if ! command_exists docker; then
    zlog error "Docker not found"
    if [[ ! -f $HOME/.docker_install_skipped ]]; then
      zlog info "Docker not found. Run '${GREEN}install-docker${RESET}' to install it."
      alias install-docker="curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh && sudo usermod -aG docker \$USER && touch \$HOME/.docker_install_skipped && echo 'Docker installed. Please log out and back in.'"
    else
      zlog info "Docker install skipped (flag file exists)"
    fi
  fi

  # Linux installs bat/ripgrep/bat-extras/uv from cargo/source/curl; macOS got
  # them from the brew batch above, so this whole block is linux-only.
  case "$_os" in
    linux)
      if ! command_exists cargo; then
        zlog warn "cargo not installed. Installing latest rustup toolset"
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup.sh \
          || panic "could not download rust installer file"
        chmod +x /tmp/rustup.sh || panic "could not chmod rust installer file"
        /tmp/rustup.sh -y --profile minimal || panic "Could not install Rust toolchain"
        pathadd $HOME/.cargo/bin
      fi
      if ! command_exists bat; then
        zlog "Compiling '${RED}bat${RESET}'..."
        cargo install bat
      fi
      if ! command_exists rg; then
        zlog "Compiling '${RED}ripgrep${RESET}'..."
        cargo install ripgrep
      fi

      zlog debug "Checking bat-extras installation"
      if ! directory_exists $HOME/.repos/bat-extras; then
        (mkdir -p $HOME/.repos && \
          zlog "Installing bat-extras..." && \
          git clone --depth=1 https://github.com/eth-p/bat-extras.git $HOME/.repos/bat-extras && \
          pushd $HOME/.repos/bat-extras && \
          ${=SUDO_CMD} ./build.sh --install --no-verify && \
          eval "$(batman --export-env)" && \
          eval "$(batpipe)" && \
          popd
        ) | zlog  || panic "Unable to install bat-extras"
      fi

      zlog debug "Checking uv installation"
      if ! command_exists uv; then
        zlog "Installing uv..."
        (curl -LsSf https://astral.sh/uv/install.sh | ${=SUDO_CMD} env UV_INSTALL_DIR="/usr/bin" sh) | zlog \
          || panic "Unable to install UV"
      else
        zlog debug "UV already installed"
      fi

      # fastfetch is not in the Debian/Ubuntu apt repos before 25.04, so install
      # the official prebuilt .deb release (architecture-aware) instead of a PPA.
      if ! command_exists fastfetch; then
        local _ff_arch=""
        case "$(uname -m)" in
          x86_64|amd64)  _ff_arch=amd64 ;;
          aarch64|arm64) _ff_arch=aarch64 ;;
        esac
        if [[ -n $_ff_arch ]]; then
          zlog "Installing fastfetch (.deb, $_ff_arch)..."
          local _ff_deb="/tmp/fastfetch-linux-$_ff_arch.deb"
          curl -fsSL "https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-$_ff_arch.deb" -o "$_ff_deb" \
            && ${=SUDO_CMD} apt-get install -y "$_ff_deb" \
            || panic "Unable to install fastfetch from the .deb release"
        else
          zlog warn "Unknown architecture $(uname -m); skipping fastfetch install"
        fi
      fi
      ;;
    macos)
      : # bat, ripgrep, bat-extras, uv were installed via the brew batch above
      ;;
  esac

  touch $HOME/.zshrc-bootstrapped
}

build_test_zsh(){
  if ! command_exists docker; then
    zlog warn "Docker not available; skipping test image build"
    return 1
  fi
  local img_name="testohmyzsh/zsh:bats"
  zlog "Checking for Docker image: $img_name"
  if ! docker image inspect $img_name >/dev/null 2>&1; then
    zlog "Building Docker image: $img_name"
    mkdir -p /tmp/tomz
  cat <<'EOF' > /tmp/tomz/Dockerfile
FROM ubuntu:22.04
WORKDIR /root
RUN apt-get update && \
  apt-get install -y --no-install-recommends curl ca-certificates zsh git bats sudo procps && \
  rm -rf /var/lib/apt/lists/* && \
  useradd -m -s /bin/zsh -u 1000 tester && \
  echo 'tester ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/tester

ENTRYPOINT ["/bin/zsh"]
EOF
    docker build -t $img_name /tmp/tomz/
  else
    zlog "Docker image $img_name already exists"
  fi
}


run(){
  zlog debug "${RED}DEBUGGING${RESET} ${GREEN}ENABLED${RESET}"

  # Sudo alias for root or systems without sudo
  zlog debug "User Info: $(id)"
  zlog debug "Configuring sudo alias"
  if [ "$(id -u)" -eq 0 ] || ! command -v sudo > /dev/null 2>&1; then
    SUDO_CMD=''
    zlog debug "Setting SUDO_CMD to empty (running as root or sudo not installed)"
  else
    SUDO_CMD='sudo'
    zlog debug "Setting SUDO_CMD to 'sudo' (running as non-root with sudo available)"
  fi

  # On macOS, put Homebrew on PATH before anything else (and on every shell
  # start, so brew-installed tools resolve). Apple Silicon uses /opt/homebrew,
  # Intel uses /usr/local. Disable per-command auto-update for snappy startup.
  if [[ "$(_zshrc_os)" == macos ]]; then
    if [[ -x /opt/homebrew/bin/brew && ":$PATH:" != *":/opt/homebrew/bin:"* ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew && ":$PATH:" != *":/usr/local/bin:"* ]]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
    export HOMEBREW_NO_AUTO_UPDATE=1
  fi

  # Only the top-level interactive shell checks the remote for updates; nested
  # shells, tmux panes and subshells skip it (less startup work, no repeat noise).
  [[ -o interactive && $SHLVL -eq 1 ]] && zshrc_check_for_updates

  _zshrc_install_gauntlet

  # Oh My Zsh configuration
  zlog debug "Configuring Oh My Zsh"
  export ZSH="$HOME/.oh-my-zsh"
  ZSH_THEME="random"
  zstyle ':omz:update' mode reminder
  #ENABLE_CORRECTION="true"
  plugins=(git colored-man-pages)

  _zshrc_compinit

  zlog debug "Sourcing Oh My Zsh"
  source $ZSH/oh-my-zsh.sh || panic "Unable to source $ZSH/oh-my-zsh.sh"

  # Environment variables
  zlog debug "Setting environment variables"
  export LANG=en_US.UTF-8

  # Editor configuration
  zlog debug "Configuring editor based on SSH connection"
  if [[ -n $SSH_CONNECTION ]]; then
    export EDITOR='vim'
    zlog debug "Using vim (SSH connection detected)"
  else
    export EDITOR='nvim'
    zlog debug "Using nvim (local session)"
  fi

  # Compilation flags
  export ARCHFLAGS="-arch $(uname -m)"


  # Bat configuration and aliases
  zlog debug "Configuring bat aliases and settings"

  alias cat=bat
  BAT_PAGER="less -RFK"
  alias bathelp='bat --plain --language=help'
  alias watch="batwatch"

  # Docker aliases
  zlog debug "Setting up Docker aliases"
  alias clam="docker run -it --rm --workdir /scandir -v clam_db:/var/lib/clamav -v .:/scandir clamav/clamav:unstable_base"
  alias ssh="kitten ssh"
  alias sqlcmd="docker run --rm -it mcr.microsoft.com/mssql-tools /opt/mssql-tools/bin/sqlcmd"
  alias bcp="docker run --rm -it mcr.microsoft.com/mssql-tools /opt/mssql-tools/bin/bcp"
  alias lazydocker='docker run --rm -it -v /var/run/docker.sock:/var/run/docker.sock -v $PWD/.lazydocker/config:/.config/jesseduffield/lazydocker lazyteam/lazydocker'
  alias dclint='docker run -t --rm -v .:/app zavoloklom/dclint'
  # pbcopy is native on macOS; only alias it to xclip on Linux (X11). Aliasing
  # it unconditionally would shadow and break the real macOS pbcopy.
  if [[ "$(_zshrc_os)" == linux ]]; then
    alias pbcopy='xclip -sel c'
  fi

  # load local specific stuff, if it exists.

  if [[ -f $HOME/.zshrc_local ]]; then
    zlog "Found ${RED}zshrc_local${RESET} file. Sourcing now..."

    source $HOME/.zshrc_local
  fi

  zlog "Zsh configuration loaded successfully"
  # Show the fastfetch splash on every interactive shell start.
  [[ -o interactive ]] && command_exists fastfetch && fastfetch
}

dockerps() {
    emulate -L zsh
    setopt err_exit nounset pipefail

    local usage
    usage=$(
        cat <<'EOF'
Usage: dockerps [--compose] [docker ps args...]

  --compose   Use "docker compose ps" instead of "docker ps".
              Additional arguments after --compose are forwarded
  to "docker compose ps".
  -h, --help  Show this help message.
EOF
    )

    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        printf '%s\n' "$usage"
        return 0
    fi

    if ! command -v docker >/dev/null 2>&1; then
        echo "docker command not found in PATH." >&2
        return 1
    fi

    local -a ps_cmd
    if [[ "${1:-}" == "--compose" ]]; then
        shift
        ps_cmd=(docker compose ps --format '{{.Name}}\t{{.Publishers}}\t{{.State}}')
    else
        ps_cmd=(docker ps --format '{{.Names}}\t{{.Ports}}\t{{.Status}}')
    fi

    local header_color=$'\033[1;36m'
    local name_color=$'\033[1;32m'
    local ports_color=$'\033[1;33m'
    local status_up_color=$'\033[1;32m'
    local status_down_color=$'\033[1;31m'
    local status_other_color=$'\033[1;35m'
    local reset_color=$'\033[0m'

    local -a rows
    rows=("${(@f)$( "${(@)ps_cmd}" "$@" )}")

    local header_names="NAMES"
    local header_ports="PORTS"
    local header_status="STATUS"

    local name_width=${#header_names}
    local ports_width=${#header_ports}
    local status_width=${#header_status}

    local row name ports state
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r name ports state <<<"$row"
        ports=${ports:-"-"}
        [[ ${#name} -gt $name_width ]] && name_width=${#name}
        [[ ${#ports} -gt $ports_width ]] && ports_width=${#ports}
        [[ ${#state} -gt $status_width ]] && status_width=${#state}
    done

    local separator_length separator
    separator_length=$((name_width + ports_width + status_width + 4))
    printf -v separator '%*s' "$separator_length" ''
    separator=${separator// /-}

    printf '%b%-*s%b  %b%-*s%b  %b%-*s%b\n' \
        "$header_color" "$name_width" "$header_names" "$reset_color" \
        "$header_color" "$ports_width" "$header_ports" "$reset_color" \
        "$header_color" "$status_width" "$header_status" "$reset_color"
    printf '%b%s%b\n' "$header_color" "$separator" "$reset_color"

    if [[ ${#rows[@]} -eq 0 ]]; then
        printf 'No containers found.\n'
        return 0
    fi

    for row in "${rows[@]}"; do
        IFS=$'\t' read -r name ports state <<<"$row"
        ports=${ports:-"-"}

        local status_color=$status_other_color
        if [[ $state == Up* ]]; then
            status_color=$status_up_color
        elif [[ $state == Exited* || $state == "exited" || $state == "stopped" ]]; then
            status_color=$status_down_color
        fi

        printf '%b%-*s%b  %b%-*s%b  %b%-*s%b\n' \
            "$name_color" "$name_width" "$name" "$reset_color" \
            "$ports_color" "$ports_width" "$ports" "$reset_color" \
            "$status_color" "$status_width" "$state" "$reset_color"
    done
}

[[ -n ${ZSH_TESTING:-} ]] || run
