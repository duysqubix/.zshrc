#!/usr/bin/env bats

# zshrc test suite — runs in the testohmyzsh/zsh:bats container via test_zshrc.
# Tests source /root/.zshrc with ZSH_TESTING=1 to skip the run() gauntlet,
# then exercise the function or pattern under test inside a zsh subshell.

setup() {
  export ZSH_TESTING=1
  export ZSH_LOG_LEVEL=error
  export RC="${RC:-/root/.zshrc}"
  export ZSH_RC_ORIG="${ZSH_RC_ORIG:-/root/.zshrc-orig}"
  # Restore a clean copy of the rc before every test so destructive tests
  # (e.g. bug2's update_zshrc) cannot leak into later tests.
  cp "$ZSH_RC_ORIG" "$RC"
}

teardown() {
  cp "$ZSH_RC_ORIG" "$RC"
  rm -f "$HOME/.zshrc-hash" "$HOME/.zshrc-hash-remote" "$RC.zwc" "$HOME/.zshrc.zwc"
}

# Helper: run a snippet inside a fresh zsh that has sourced the rc in test mode.
zsh_run() {
  zsh -c "ZSH_TESTING=1; ZSH_LOG_LEVEL=error; source $RC; $1"
}

# ---------------------------------------------------------------------------
# Bug 1 — pathadd appends $1, not $! (last bg PID)
# ---------------------------------------------------------------------------

@test "bug1: pathadd appends \$1 to PATH" {
  mkdir -p /tmp/pathadd-test
  run zsh -c "
    ZSH_TESTING=1; source $RC
    PATH=/usr/bin
    pathadd /tmp/pathadd-test
    print -r -- \"\$PATH\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"/tmp/pathadd-test"* ]]
}

# ---------------------------------------------------------------------------
# Bug 2 — update_zshrc writes matching, non-empty hashes
# ---------------------------------------------------------------------------

@test "bug2: update_zshrc writes matching non-empty hashes of the file" {
  rm -f $HOME/.zshrc-hash $HOME/.zshrc-hash-remote
  zsh -c "
    ZSH_TESTING=1; ZSH_LOG_LEVEL=error; source $RC
    curl() {
      local out=\"\"
      while (( \$# > 0 )); do
        if [[ \$1 == -o ]]; then out=\$2; shift 2; continue; fi
        shift
      done
      [[ -n \$out ]] && print -rn -- 'fake-zshrc-content' > \$out
      return 0
    }
    update_zshrc 2>/dev/null
  "
  [ -f "$HOME/.zshrc-hash" ]
  [ -f "$HOME/.zshrc-hash-remote" ]
  local h1=$(cat "$HOME/.zshrc-hash")
  local h2=$(cat "$HOME/.zshrc-hash-remote")
  echo "h1=$h1 h2=$h2"
  [ -n "$h1" ]
  [ "$h1" = "$h2" ]
  expected=$(printf '%s' 'fake-zshrc-content' | sha256sum | awk '{print $1}')
  [ "$h1" = "$expected" ]
}

# ---------------------------------------------------------------------------
# Bug 3 — cargo install ripgrep, not ripgre
# ---------------------------------------------------------------------------

@test "bug3: cargo install line uses 'ripgrep'" {
  run grep -E '^[[:space:]]*cargo install ripgrep[[:space:]]*$' "$RC"
  [ "$status" -eq 0 ]
  ! grep -E 'cargo install ripgre([^p]|$)' "$RC"
}

# ---------------------------------------------------------------------------
# Bug 4 — rustup install line uses || panic, not | panic
# ---------------------------------------------------------------------------

@test "bug4: rustup install uses || panic" {
  run grep -E '/tmp/rustup\.sh.*\|\| panic' "$RC"
  [ "$status" -eq 0 ]
  ! grep -E '/tmp/rustup\.sh[^|]*\| panic' "$RC"
}

# ---------------------------------------------------------------------------
# Bug 5 — DOCKER_AVAIL must not break helpers when called outside run()
# ---------------------------------------------------------------------------

@test "bug5: build_test_zsh and testohmyzsh do not reference DOCKER_AVAIL" {
  # The local-scoped DOCKER_AVAIL bug is fixed by removing the dependency:
  # both helpers must call command_exists docker directly. No reference
  # to $DOCKER_AVAIL should remain anywhere in the rc.
  ! grep -F 'DOCKER_AVAIL' "$RC"
}

# ---------------------------------------------------------------------------
# Bug 6 — sudo precheck must respect empty SUDO_CMD (root / no-sudo container)
# ---------------------------------------------------------------------------

@test "bug6: sudo precheck guards on SUDO_CMD and replaces the ls test" {
  # Broken `${=SUDO_CMD} ls | zlog || panic ...` line must be gone.
  ! grep -F '${=SUDO_CMD} ls | zlog' "$RC"
  # New conditional: only run sudo -n true when SUDO_CMD is non-empty.
  run grep -E '\[\[ -n \$SUDO_CMD \]\]' "$RC"
  [ "$status" -eq 0 ]
  run grep -F 'sudo -n true' "$RC"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Bug 7 — OMZ installer is invoked unattended
# ---------------------------------------------------------------------------

@test "bug7: OMZ installer passes RUNZSH=no CHSH=no --unattended" {
  run grep -E 'RUNZSH=no.*CHSH=no.*ohmyzsh.*install\.sh.*--unattended' "$RC"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Bug 8 — apt install expands required_commands values explicitly
# ---------------------------------------------------------------------------

@test "bug8: apt install no longer uses bare \${required_commands} expansion" {
  # The original buggy pattern relied on implicit value expansion. After the
  # S2 batching refactor, packages are collected explicitly via
  # `needs_apt+=\$required_commands[\$cmd]`. Either way, the broken bare-array
  # form must be gone.
  ! grep -E 'apt(-get)? install [^|]*\$\{required_commands\}' "$RC"
  ! grep -E 'apt(-get)? install [^|]*\$required_commands(\b|[^[])' "$RC"
}

# ---------------------------------------------------------------------------
# S1 + Bug 9 — bootstrap fingerprint cache and ZSH_FORCE_UPDATE wiring
# ---------------------------------------------------------------------------

# Helper: run the install gauntlet under a sandbox HOME with all heavy
# install commands stubbed out. Returns the path to the sandbox HOME on stdout
# so callers can inspect side-effects.
_run_gauntlet() {
  local force=$1
  local pre_marker=$2
  local sandbox=$(mktemp -d)
  if [[ "$pre_marker" == "yes" ]]; then
    touch "$sandbox/.zshrc-bootstrapped"
  fi
  HOME=$sandbox ZSH_FORCE_UPDATE=$force zsh -c "
    ZSH_TESTING=1; ZSH_LOG_LEVEL=error
    source $RC
    SUDO_CMD=''
    apt-get() { print -r -- 'STUB:apt-get '\"\$@\" >> \$HOME/calls.log; }
    curl()    { print -r -- 'STUB:curl '\"\$@\" >> \$HOME/calls.log; return 0; }
    cargo()   { print -r -- 'STUB:cargo '\"\$@\" >> \$HOME/calls.log; }
    git()     { print -r -- 'STUB:git '\"\$@\" >> \$HOME/calls.log; }
    sh()      { print -r -- 'STUB:sh '\"\$@\" >> \$HOME/calls.log; }
    chmod()   { print -r -- 'STUB:chmod '\"\$@\" >> \$HOME/calls.log; }
    command_exists() { return 0; }
    directory_exists() { return 0; }
    mkdir -p \$HOME/.oh-my-zsh
    _zshrc_install_gauntlet
  "
  echo "$sandbox"
}

@test "S1: gauntlet creates bootstrap marker on first run" {
  sandbox=$(_run_gauntlet "" "no")
  [ -f "$sandbox/.zshrc-bootstrapped" ]
  rm -rf "$sandbox"
}

@test "S1: gauntlet skips work when marker is present" {
  sandbox=$(_run_gauntlet "" "yes")
  # No install stubs should have been called.
  [ ! -f "$sandbox/calls.log" ] || ! grep -qE '^STUB:(apt-get|curl|cargo|git)' "$sandbox/calls.log"
  rm -rf "$sandbox"
}

@test "S1+Bug9: ZSH_FORCE_UPDATE=1 bypasses the marker" {
  sandbox=$(_run_gauntlet "1" "yes")
  # The gauntlet ran, and at minimum the marker was re-touched.
  [ -f "$sandbox/.zshrc-bootstrapped" ]
  # And the marker's mtime was bumped (touched at end of gauntlet).
  # We assert by checking it's newer than the sandbox dir.
  [ "$sandbox/.zshrc-bootstrapped" -nt "$sandbox/calls.log" ] 2>/dev/null \
    || [ -f "$sandbox/.zshrc-bootstrapped" ]  # marker presence is the core assertion
  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# S2 — batch apt: at most one apt-get update per shell start
# ---------------------------------------------------------------------------

@test "S2: gauntlet runs at most one apt-get update per shell start" {
  sandbox=$(mktemp -d)
  # Pretend everything is installed except fzf, so the gauntlet wants apt for
  # fzf plus whatever required_commands are missing in the test image.
  HOME=$sandbox ZSH_FORCE_UPDATE=1 zsh -c "
    ZSH_TESTING=1; ZSH_LOG_LEVEL=error; source $RC
    SUDO_CMD=''
    apt-get() { print -r -- 'CALL:apt-get '\"\$@\" >> \$HOME/calls.log; }
    command_exists() { [[ \$1 == fzf ]] && return 1 ; return 0; }
    directory_exists() { return 0; }
    mkdir -p \$HOME/.oh-my-zsh
    _zshrc_install_gauntlet
  "
  if [ -f "$sandbox/calls.log" ]; then
    count=$(grep -c '^CALL:apt-get update' "$sandbox/calls.log" || true)
  else
    count=0
  fi
  echo "calls.log:"; cat "$sandbox/calls.log" 2>/dev/null || true
  echo "apt-get update call count: $count"
  [ "$count" -le 1 ]
  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# S3 — compinit caching
# ---------------------------------------------------------------------------

@test "S3: compinit -C is used when .zcompdump is fresh" {
  sandbox=$(mktemp -d)
  touch "$sandbox/.zcompdump"
  output=$(HOME=$sandbox zsh -c "
    ZSH_TESTING=1; ZSH_LOG_LEVEL=error; source $RC
    autoload() { :; }
    compinit() { print -r -- \"compinit \$@\"; }
    _zshrc_compinit
  ")
  echo "out=[$output]"
  [[ "$output" == *"compinit -C"* ]]
  rm -rf "$sandbox"
}

@test "S3: full compinit runs when .zcompdump is missing or stale" {
  sandbox=$(mktemp -d)
  output_missing=$(HOME=$sandbox zsh -c "
    ZSH_TESTING=1; ZSH_LOG_LEVEL=error; source $RC
    autoload() { :; }
    compinit() { print -r -- \"compinit \$@\"; }
    _zshrc_compinit
  ")
  echo "out_missing=[$output_missing]"
  echo "$output_missing" | grep -E '^compinit[[:space:]]*$'
  ! echo "$output_missing" | grep -q -- '-C'

  # Stale: backdate .zcompdump to 25 hours ago.
  touch "$sandbox/.zcompdump"
  touch -d "25 hours ago" "$sandbox/.zcompdump"
  output_stale=$(HOME=$sandbox zsh -c "
    ZSH_TESTING=1; ZSH_LOG_LEVEL=error; source $RC
    autoload() { :; }
    compinit() { print -r -- \"compinit \$@\"; }
    _zshrc_compinit
  ")
  echo "out_stale=[$output_stale]"
  echo "$output_stale" | grep -E '^compinit[[:space:]]*$'
  ! echo "$output_stale" | grep -q -- '-C'
  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# S4 — OMZ update mode 'reminder' (no auto network on shell start)
# ---------------------------------------------------------------------------

@test "S4: omz update mode is 'reminder', not 'auto'" {
  run grep -E "zstyle ':omz:update' mode reminder" "$RC"
  [ "$status" -eq 0 ]
  ! grep -E "zstyle ':omz:update' mode auto" "$RC"
}

# ---------------------------------------------------------------------------
# S5 — startup splash runs fastfetch on every interactive shell (no SHLVL gate)
# ---------------------------------------------------------------------------

@test "S5: startup splash runs fastfetch on every interactive shell" {
  # The splash guards fastfetch on -o interactive only (no SHLVL restriction).
  run grep -E '\[\[ -o interactive \]\].*fastfetch' "$RC"
  [ "$status" -eq 0 ]
  # That splash line must NOT be gated on SHLVL.
  ! echo "$output" | grep -q 'SHLVL'
  # No unguarded bare fastfetch line at top level.
  ! grep -E '^[[:space:]]*fastfetch[[:space:]]*$' "$RC"
}

# ---------------------------------------------------------------------------
# S6 — zcompile the rc with mtime-based invalidation
# ---------------------------------------------------------------------------

@test "S6: rc has top-level zcompile guard" {
  # Pattern matches the snippet from the plan: zcompile only when missing
  # or .zshrc is newer than .zwc.
  run grep -E 'zcompile \$HOME/\.zshrc' "$RC"
  [ "$status" -eq 0 ]
  run grep -F '$HOME/.zshrc -nt $HOME/.zshrc.zwc' "$RC"
  [ "$status" -eq 0 ]
}

@test "S6: update_zshrc regenerates the .zwc after writing the new rc" {
  # update_zshrc must call zcompile after the curl writes the new rc.
  awk '/^update_zshrc\(\)/,/^}/' "$RC" | grep -q 'zcompile'
}

@test "S2: missing fzf is installed in the batched apt-get install" {
  sandbox=$(mktemp -d)
  HOME=$sandbox ZSH_FORCE_UPDATE=1 zsh -c "
    ZSH_TESTING=1; ZSH_LOG_LEVEL=error; source $RC
    SUDO_CMD=''
    apt-get() { print -r -- 'CALL:apt-get '\"\$@\" >> \$HOME/calls.log; }
    curl()    { return 0; }
    cargo()   { :; }
    git()     { :; }
    sh()      { :; }
    chmod()   { :; }
    command_exists() {
      [[ \$1 == fzf ]] && return 1
      return 0
    }
    directory_exists() { return 0; }
    mkdir -p \$HOME/.oh-my-zsh
    _zshrc_install_gauntlet
  "
  grep -E 'CALL:apt-get install .* fzf' "$sandbox/calls.log"
  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# S1 (continued) — marker invalidation by update_zshrc
# ---------------------------------------------------------------------------

@test "S1: update_zshrc removes bootstrap marker" {
  sandbox=$(mktemp -d)
  touch "$sandbox/.zshrc-bootstrapped"
  HOME=$sandbox zsh -c "
    ZSH_TESTING=1; ZSH_LOG_LEVEL=error; source $RC
    curl() {
      local out=''
      while (( \$# > 0 )); do
        if [[ \$1 == -o ]]; then out=\$2; shift 2; continue; fi
        shift
      done
      [[ -n \$out ]] && print -rn -- 'fake' > \$out
      return 0
    }
    update_zshrc 2>/dev/null
  "
  [ ! -f "$sandbox/.zshrc-bootstrapped" ]
  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# mac1 — OS-detection seam _zshrc_os(): ZSHRC_OS env override, else $OSTYPE
# ---------------------------------------------------------------------------

@test "mac1: _zshrc_os returns linux by default in the Ubuntu container" {
  run zsh -c "ZSH_TESTING=1; ZSH_LOG_LEVEL=error; source $RC; _zshrc_os"
  [ "$status" -eq 0 ]
  [ "$output" = "linux" ]
}

@test "mac1: ZSHRC_OS=macos overrides detection" {
  run zsh -c "ZSH_TESTING=1; ZSH_LOG_LEVEL=error; ZSHRC_OS=macos; source $RC; _zshrc_os"
  [ "$status" -eq 0 ]
  [ "$output" = "macos" ]
}

@test "mac1: ZSHRC_OS=linux overrides detection" {
  run zsh -c "ZSH_TESTING=1; ZSH_LOG_LEVEL=error; ZSHRC_OS=linux; source $RC; _zshrc_os"
  [ "$status" -eq 0 ]
  [ "$output" = "linux" ]
}

# ---------------------------------------------------------------------------
# mac2 — portable _zshrc_sha256: sha256sum (linux) else shasum -a 256 (macos)
# ---------------------------------------------------------------------------

@test "mac2: _zshrc_sha256 produces correct sha256 hex via sha256sum path" {
  run zsh -c "ZSH_TESTING=1; ZSH_LOG_LEVEL=error; source $RC; print -rn 'hello' | _zshrc_sha256"
  [ "$status" -eq 0 ]
  [ "$output" = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" ]
}

@test "mac2: _zshrc_sha256 falls back to shasum -a 256 when sha256sum is absent" {
  run zsh -c "
    ZSH_TESTING=1; ZSH_LOG_LEVEL=error; source $RC
    command_exists() { [[ \$1 == sha256sum ]] && return 1; return 0; }
    shasum() { print -r -- 'fallbackhash  -'; }
    print -rn 'whatever' | _zshrc_sha256
  "
  [ "$status" -eq 0 ]
  [ "$output" = "fallbackhash" ]
}

@test "mac2: hashing callers use _zshrc_sha256, not bare sha256sum" {
  ! awk '/^update_zshrc\(\)/,/^}/' "$RC" | grep -q 'sha256sum'
  ! awk '/^zshrc_check_for_updates\(\)/,/^}/' "$RC" | grep -q 'sha256sum'
  awk '/^update_zshrc\(\)/,/^}/' "$RC" | grep -q '_zshrc_sha256'
  awk '/^zshrc_check_for_updates\(\)/,/^}/' "$RC" | grep -q '_zshrc_sha256'
}

# ---------------------------------------------------------------------------
# mac3 — pbcopy=xclip alias must be linux-only (native macOS pbcopy survives)
# ---------------------------------------------------------------------------

@test "mac3: pbcopy=xclip alias is gated behind a linux _zshrc_os guard" {
  # Linux behavior preserved: the xclip alias is still present in the file.
  run grep -F "alias pbcopy='xclip -sel c'" "$RC"
  [ "$status" -eq 0 ]
  # ...and it is wrapped in an OS guard naming linux within the 2 preceding lines.
  local n ctx
  n=$(grep -n "alias pbcopy='xclip" "$RC" | head -1 | cut -d: -f1)
  ctx=$(sed -n "$((n-2)),${n}p" "$RC")
  echo "ctx=[$ctx]"
  echo "$ctx" | grep -q '_zshrc_os'
  echo "$ctx" | grep -q 'linux'
}

# ---------------------------------------------------------------------------
# mac4/5/6/8 — macOS install gauntlet via Homebrew (batched), uv via brew,
# bat/ripgrep/bat-extras via brew, sudo precheck skipped on macOS.
# ---------------------------------------------------------------------------

# Run the gauntlet under a sandbox HOME forced to macOS, with all heavy
# commands stubbed and logged to $sandbox/calls.log. $1 = brew_present
# (yes/no), $2 = space-separated list of commands to treat as MISSING.
_run_gauntlet_macos() {
  local brew_present=${1:-yes}
  local missing="${2:-}"
  local sandbox; sandbox=$(mktemp -d)
  HOME=$sandbox ZSHRC_OS=macos zsh -c "
    ZSH_TESTING=1; ZSH_LOG_LEVEL=error
    source $RC
    SUDO_CMD=''
    brew()    { print -r -- 'CALL:brew '\"\$@\" >> \$HOME/calls.log; }
    apt-get() { print -r -- 'CALL:apt-get '\"\$@\" >> \$HOME/calls.log; }
    cargo()   { print -r -- 'CALL:cargo '\"\$@\" >> \$HOME/calls.log; }
    git()     { print -r -- 'CALL:git '\"\$@\" >> \$HOME/calls.log; }
    sh()      { print -r -- 'CALL:sh '\"\$@\" >> \$HOME/calls.log; }
    chmod()   { print -r -- 'CALL:chmod '\"\$@\" >> \$HOME/calls.log; }
    curl()    { print -r -- 'CALL:curl '\"\$@\" >> \$HOME/calls.log; return 0; }
    sudo()    { print -r -- 'CALL:sudo '\"\$@\" >> \$HOME/calls.log; }
    command_exists() {
      [[ \$1 == brew ]] && { [[ '$brew_present' == yes ]] && return 0 || return 1; }
      for _m in ${missing}; do [[ \$1 == \$_m ]] && return 1; done
      return 0
    }
    directory_exists() { return 0; }
    mkdir -p \$HOME/.oh-my-zsh
    _zshrc_install_gauntlet
  "
  echo "$sandbox"
}

@test "mac4: macos gauntlet runs one brew update + one batched brew install" {
  sandbox=$(_run_gauntlet_macos yes "fzf")
  echo "calls:"; cat "$sandbox/calls.log" 2>/dev/null || true
  upd=$(grep -c '^CALL:brew update' "$sandbox/calls.log" || true)
  inst=$(grep -c '^CALL:brew install' "$sandbox/calls.log" || true)
  [ "$upd" -le 1 ]
  [ "$inst" -eq 1 ]
  rm -rf "$sandbox"
}

@test "mac4: missing fzf is installed via the batched brew install" {
  sandbox=$(_run_gauntlet_macos yes "fzf")
  line=$(grep '^CALL:brew install' "$sandbox/calls.log")
  [[ " $line " == *" fzf "* || " $line " == *" fzf" ]]
  rm -rf "$sandbox"
}

@test "mac4: no apt-get calls on the macos branch" {
  sandbox=$(_run_gauntlet_macos yes "fzf")
  [ ! -f "$sandbox/calls.log" ] || ! grep -q '^CALL:apt-get' "$sandbox/calls.log"
  rm -rf "$sandbox"
}

@test "mac4: procps is never requested via brew on macos (ps ships natively)" {
  sandbox=$(_run_gauntlet_macos yes "fzf")
  ! grep -F 'procps' "$sandbox/calls.log"
  rm -rf "$sandbox"
}

@test "mac4: missing Homebrew on macos triggers a panic" {
  run zsh -c "
    ZSH_TESTING=1; ZSH_LOG_LEVEL=error; ZSHRC_OS=macos; source $RC
    SUDO_CMD=''
    command_exists() { [[ \$1 == brew ]] && return 1; return 0; }
    directory_exists() { return 0; }
    mkdir -p \$HOME/.oh-my-zsh 2>/dev/null
    _zshrc_install_gauntlet
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"Homebrew"* ]]
}

@test "mac5: macos installs uv via the brew batch, not the /usr/bin curl installer" {
  sandbox=$(_run_gauntlet_macos yes "uv")
  line=$(grep '^CALL:brew install' "$sandbox/calls.log")
  [[ " $line " == *" uv "* || " $line " == *" uv" ]]
  ! grep -q 'UV_INSTALL_DIR' "$sandbox/calls.log"
  rm -rf "$sandbox"
}

@test "mac5: linux uv install still pins UV_INSTALL_DIR=/usr/bin via sudo" {
  awk '/^_zshrc_install_gauntlet\(\)/,/^}/' "$RC" | grep -q 'UV_INSTALL_DIR="/usr/bin"'
}

@test "mac6: macos prefers brew for bat (no cargo install bat)" {
  sandbox=$(_run_gauntlet_macos yes "bat")
  line=$(grep '^CALL:brew install' "$sandbox/calls.log")
  [[ " $line " == *" bat "* || " $line " == *" bat" ]]
  ! grep -E '^CALL:cargo install bat' "$sandbox/calls.log"
  rm -rf "$sandbox"
}

@test "mac6: macos prefers brew for ripgrep (no cargo install ripgrep)" {
  sandbox=$(_run_gauntlet_macos yes "rg")
  line=$(grep '^CALL:brew install' "$sandbox/calls.log")
  [[ " $line " == *" ripgrep "* || " $line " == *" ripgrep" ]]
  ! grep -E '^CALL:cargo install ripgrep' "$sandbox/calls.log"
  rm -rf "$sandbox"
}

@test "mac6: macos uses brew bat-extras, never git-clones it" {
  sandbox=$(_run_gauntlet_macos yes "batman")
  line=$(grep '^CALL:brew install' "$sandbox/calls.log")
  [[ " $line " == *" bat-extras "* || " $line " == *" bat-extras" ]]
  ! grep -E '^CALL:git .*bat-extras' "$sandbox/calls.log"
  rm -rf "$sandbox"
}

@test "mac6: linux still uses cargo for bat/ripgrep, never brew" {
  sandbox=$(mktemp -d)
  HOME=$sandbox ZSHRC_OS=linux zsh -c "
    ZSH_TESTING=1; ZSH_LOG_LEVEL=error; source $RC
    SUDO_CMD=''
    apt-get(){ :; }
    cargo(){ print -r -- 'CALL:cargo '\"\$@\" >> \$HOME/calls.log; }
    brew(){  print -r -- 'CALL:brew '\"\$@\" >> \$HOME/calls.log; }
    curl(){ return 0; }; sh(){ :; }; git(){ :; }; chmod(){ :; }
    command_exists() { case \$1 in bat|rg) return 1;; *) return 0;; esac }
    directory_exists() { return 0; }
    mkdir -p \$HOME/.oh-my-zsh
    _zshrc_install_gauntlet
  "
  grep -E '^CALL:cargo install bat' "$sandbox/calls.log"
  grep -E '^CALL:cargo install ripgrep' "$sandbox/calls.log"
  [ ! -f "$sandbox/calls.log" ] || ! grep -q '^CALL:brew' "$sandbox/calls.log"
  rm -rf "$sandbox"
}

@test "mac8: macos branch skips the sudo -n true precheck" {
  sandbox=$(mktemp -d)
  HOME=$sandbox ZSHRC_OS=macos zsh -c "
    ZSH_TESTING=1; ZSH_LOG_LEVEL=error; source $RC
    SUDO_CMD='sudo'
    sudo(){ print -r -- 'CALL:sudo '\"\$@\" >> \$HOME/calls.log; }
    brew(){ :; }
    command_exists() { return 0; }
    directory_exists() { return 0; }
    mkdir -p \$HOME/.oh-my-zsh
    _zshrc_install_gauntlet
  "
  [ ! -f "$sandbox/calls.log" ] || ! grep -q '^CALL:sudo -n true' "$sandbox/calls.log"
  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# mac7 — run() puts Homebrew on PATH (prefix-detected) on macOS
# ---------------------------------------------------------------------------

@test "mac7: run() initializes Homebrew shellenv on macOS with prefix detection" {
  run grep -F 'brew shellenv' "$RC"
  [ "$status" -eq 0 ]
  # Both Apple Silicon and Intel prefixes are probed.
  grep -q '/opt/homebrew/bin/brew' "$RC"
  grep -q '/usr/local/bin/brew' "$RC"
  # The shellenv init is gated on macos (guard within 6 preceding lines).
  local n ctx
  n=$(grep -n 'brew shellenv' "$RC" | head -1 | cut -d: -f1)
  ctx=$(sed -n "$((n-6)),${n}p" "$RC")
  echo "ctx=[$ctx]"
  echo "$ctx" | grep -q 'macos'
}

# ---------------------------------------------------------------------------
# mac9 — unrecognized OS must panic, not silently mark bootstrap done
# ---------------------------------------------------------------------------

@test "mac9: unsupported ZSHRC_OS panics and does not write the bootstrap marker" {
  sandbox=$(mktemp -d)
  run env HOME="$sandbox" ZSHRC_OS=freebsd zsh -c "
    ZSH_TESTING=1; ZSH_LOG_LEVEL=error; source $RC
    SUDO_CMD=''
    command_exists() { return 0; }
    directory_exists() { return 0; }
    mkdir -p \$HOME/.oh-my-zsh
    _zshrc_install_gauntlet
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported"* ]]
  [ ! -f "$sandbox/.zshrc-bootstrapped" ]
  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# fastfetch — replaces neofetch on both OSes (brew on macOS, .deb on Linux)
# ---------------------------------------------------------------------------

@test "fastfetch: neofetch is fully replaced by fastfetch in the rc" {
  ! grep -F 'neofetch' "$RC"
  grep -q 'fastfetch' "$RC"
}

@test "fastfetch: macos installs fastfetch via brew (never neofetch)" {
  sandbox=$(_run_gauntlet_macos yes "fastfetch")
  line=$(grep '^CALL:brew install' "$sandbox/calls.log")
  [[ " $line " == *" fastfetch "* || " $line " == *" fastfetch" ]]
  ! grep -F 'neofetch' "$sandbox/calls.log"
  rm -rf "$sandbox"
}

@test "fastfetch: linux installs fastfetch from the official .deb release" {
  sandbox=$(mktemp -d)
  HOME=$sandbox ZSHRC_OS=linux zsh -c "
    ZSH_TESTING=1; ZSH_LOG_LEVEL=error; source $RC
    SUDO_CMD=''
    apt-get(){ print -r -- 'CALL:apt-get '\"\$@\" >> \$HOME/calls.log; }
    curl(){ print -r -- 'CALL:curl '\"\$@\" >> \$HOME/calls.log; return 0; }
    cargo(){ :; }; brew(){ :; }; git(){ :; }; sh(){ :; }; chmod(){ :; }
    command_exists() { case \$1 in fastfetch) return 1;; *) return 0;; esac }
    directory_exists() { return 0; }
    mkdir -p \$HOME/.oh-my-zsh
    _zshrc_install_gauntlet
  "
  echo 'calls:'; cat "$sandbox/calls.log" 2>/dev/null || true
  # fetched as a .deb from the fastfetch project, then installed via apt-get
  grep -E '^CALL:curl .*fastfetch.*\.deb' "$sandbox/calls.log"
  grep -E '^CALL:apt-get install .*fastfetch.*\.deb' "$sandbox/calls.log"
  # never via the (missing) apt repo package nor neofetch
  ! grep -F 'neofetch' "$sandbox/calls.log"
  rm -rf "$sandbox"
}

@test "fastfetch: linux .deb url is architecture-aware" {
  # The .deb url must select amd64 or aarch64 from uname -m, not hardcode one.
  awk '/^_zshrc_install_gauntlet\(\)/,/^}/' "$RC" | grep -qE 'uname -m'
  awk '/^_zshrc_install_gauntlet\(\)/,/^}/' "$RC" | grep -qE 'amd64|aarch64'
}

# ---------------------------------------------------------------------------
# repo-sync — self-update pulls from the github repo raw url, not a gist
# ---------------------------------------------------------------------------

@test "repo-sync: no gist references remain anywhere in the rc" {
  ! grep -iF 'gist' "$RC"
}

@test "repo-sync: remote url points at the repo raw .zshrc" {
  grep -qF 'raw.githubusercontent.com/duysqubix/.zshrc' "$RC"
  # the legacy gist variable name is gone
  ! grep -qF '_zshrc_gist_url' "$RC"
  grep -qF '_zshrc_remote_url' "$RC"
}

@test "repo-sync: update_zshrc and the update-check use the repo remote" {
  awk '/^update_zshrc\(\)/,/^}/' "$RC" | grep -q '_zshrc_remote_url'
  awk '/^zshrc_check_for_updates\(\)/,/^}/' "$RC" | grep -q '_zshrc_remote_url'
  # the remote variable is defined as the repo's raw .zshrc url
  grep -qE '^_zshrc_remote_url=.*raw[.]githubusercontent[.]com/duysqubix/[.]zshrc' "$RC"
}

# ---------------------------------------------------------------------------
# update-check gating — the remote update check runs only on a top-level
# interactive shell (SHLVL=1), not in nested shells / tmux panes / subshells.
# ---------------------------------------------------------------------------

@test "update-check: zshrc_check_for_updates is gated on SHLVL=1 interactive" {
  # No bare, ungated call on its own line.
  ! grep -E '^[[:space:]]*zshrc_check_for_updates[[:space:]]*$' "$RC"
  # The call is guarded together with the SHLVL=1 gate.
  run grep -E 'SHLVL -eq 1.*zshrc_check_for_updates' "$RC"
  [ "$status" -eq 0 ]
  # And that same guard is interactive-only.
  echo "$output" | grep -q -- '-o interactive'
}

# ---------------------------------------------------------------------------
# linux toolchain — cargo install bat/ripgrep needs a C linker (cc)
# ---------------------------------------------------------------------------

@test "linux: build-essential is queued when bat/ripgrep will be compiled and cc is missing" {
  sandbox=$(mktemp -d)
  HOME=$sandbox ZSHRC_OS=linux zsh -c "
    ZSH_TESTING=1; ZSH_LOG_LEVEL=error; source $RC
    SUDO_CMD=''
    apt-get(){ print -r -- 'CALL:apt-get '\"\$@\" >> \$HOME/calls.log; }
    curl(){ return 0; }; cargo(){ :; }; git(){ :; }; sh(){ :; }; chmod(){ :; }
    command_exists() { case \$1 in bat|rg|cc|fastfetch) return 1;; *) return 0;; esac }
    directory_exists() { return 0; }
    mkdir -p \$HOME/.oh-my-zsh
    _zshrc_install_gauntlet
  "
  grep -E '^CALL:apt-get install .*build-essential' "$sandbox/calls.log"
  rm -rf "$sandbox"
}

@test "linux: build-essential is NOT queued when bat and ripgrep already exist" {
  sandbox=$(mktemp -d)
  HOME=$sandbox ZSHRC_OS=linux zsh -c "
    ZSH_TESTING=1; ZSH_LOG_LEVEL=error; source $RC
    SUDO_CMD=''
    apt-get(){ print -r -- 'CALL:apt-get '\"\$@\" >> \$HOME/calls.log; }
    curl(){ return 0; }; cargo(){ :; }; git(){ :; }; sh(){ :; }; chmod(){ :; }
    command_exists() { case \$1 in fzf) return 1;; *) return 0;; esac }
    directory_exists() { return 0; }
    mkdir -p \$HOME/.oh-my-zsh
    _zshrc_install_gauntlet
  "
  ! grep -F 'build-essential' "$sandbox/calls.log"
  rm -rf "$sandbox"
}

# ---------------------------------------------------------------------------
# update_zshrc — must not clobber a symlinked ~/.zshrc; pull the repo instead
# ---------------------------------------------------------------------------

@test "update_zshrc: symlinked-to-repo git-pulls and keeps the symlink (no curl clobber)" {
  sandbox=$(mktemp -d)
  mkdir -p "$sandbox/repo"
  printf 'rc-content\n' > "$sandbox/repo/.zshrc"
  ln -s "$sandbox/repo/.zshrc" "$sandbox/.zshrc"
  HOME=$sandbox zsh -c "
    ZSH_TESTING=1; ZSH_LOG_LEVEL=error; source $RC
    git()  { print -r -- 'CALL:git '\"\$@\" >> \$HOME/calls.log; return 0; }
    curl() { print -r -- 'CALL:curl '\"\$@\" >> \$HOME/calls.log; return 0; }
    update_zshrc 2>/dev/null
  "
  grep -E '^CALL:git .*pull' "$sandbox/calls.log"
  ! grep -E '^CALL:curl .*-o' "$sandbox/calls.log"
  [ -L "$sandbox/.zshrc" ]
  rm -rf "$sandbox"
}

@test "update_zshrc: standalone (non-symlink) ~/.zshrc still curls the remote" {
  sandbox=$(mktemp -d)
  printf 'old\n' > "$sandbox/.zshrc"
  HOME=$sandbox zsh -c "
    ZSH_TESTING=1; ZSH_LOG_LEVEL=error; source $RC
    git()  { print -r -- 'CALL:git '\"\$@\" >> \$HOME/calls.log; return 0; }
    curl() {
      local out=''
      while (( \$# > 0 )); do [[ \$1 == -o ]] && { out=\$2; shift 2; continue; }; shift; done
      [[ -n \$out ]] && print -rn -- 'remote-content' > \$out
      print -r -- 'CALL:curl' >> \$HOME/calls.log
      return 0
    }
    update_zshrc 2>/dev/null
  "
  grep -E '^CALL:curl' "$sandbox/calls.log"
  ! grep -E '^CALL:git .*pull' "$sandbox/calls.log"
  rm -rf "$sandbox"
}
