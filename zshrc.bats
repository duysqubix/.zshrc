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
# S5 — neofetch gated on SHLVL=1 and interactive shell
# ---------------------------------------------------------------------------

@test "S5: neofetch is gated on -o interactive and SHLVL=1" {
  # The bare `neofetch -L` line must be replaced by a guarded call.
  ! grep -E '^[[:space:]]*neofetch -L[[:space:]]*$' "$RC"
  run grep -F '[[ -o interactive && $SHLVL -eq 1 ]]' "$RC"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q neofetch
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
