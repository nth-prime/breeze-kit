#!/usr/bin/env bash
# install.sh — Breeze one-liner installer for linux/amd64 and linux/arm64
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/nth-prime/breeze-kit/main/install.sh | bash
#   curl -sSL https://raw.githubusercontent.com/nth-prime/breeze-kit/main/install.sh | bash -s -- --version v0.1.0
#   curl -sSL https://raw.githubusercontent.com/nth-prime/breeze-kit/main/install.sh | bash -s -- --uninstall
#
# Flags:
#   --version <vX.Y.Z>          Install a specific version (default: latest)
#   --install-mode system|user  Override install mode (default: system if UID=0, user otherwise)
#   --install-dir <path>        Override install directory
#   --yes / --non-interactive   Skip all prompts (also set automatically when stdin is not a tty)
#   --uninstall                 Remove breeze-go and its systemd units
#   --wipe-config               Also remove config files (only valid with --uninstall)
#   --force-downgrade           Allow installing an older version over a newer one
#   --help                      Print this message and exit 0
#
# Cosign pin:
#   cosign v2.4.1 linux/amd64
#   SHA256: TODO: cosign v2.4.1 linux/amd64 SHA256 = <paste from https://github.com/sigstore/cosign/releases>
#   cosign v2.4.1 linux/arm64
#   SHA256: TODO: cosign v2.4.1 linux/arm64 SHA256 = <paste from https://github.com/sigstore/cosign/releases>
#   Update procedure: see docs/cosign-pins.md
#
# Offline cosign verification:
#   cosign verify-blob --bundle REQUIRES Sigstore TLog/CA connectivity.
#   This installer is NOT fully offline-capable; it requires network access to
#   fulcio.sigstore.dev and rekor.sigstore.dev for signature verification.
#   If those endpoints are unreachable, signature verification will fail.
#
# shellcheck-clean: Run `shellcheck install.sh` before each release.
# TODO: shellcheck-clean before release. Run: shellcheck install.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

GITHUB_ORG="nth-prime"
GITHUB_REPO_KIT="breeze-kit"
GITHUB_REPO_GO="breeze-go"
BINARY_NAME="breeze-go"
RELEASES_API="https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO_KIT}/releases/latest"
RELEASES_BASE="https://github.com/${GITHUB_ORG}/${GITHUB_REPO_KIT}/releases/download"

# Cosign OIDC identity embedded per design constraint.
COSIGN_CERT_IDENTITY_REGEXP="^https://github.com/${GITHUB_ORG}/${GITHUB_REPO_GO}/.github/workflows/release.yml@refs/tags/v"
COSIGN_OIDC_ISSUER="https://token.actions.githubusercontent.com"

# Pinned cosign version for self-download fallback.
COSIGN_VERSION="v2.4.1"
# TODO: cosign v2.4.1 linux/amd64 SHA256 = <paste from https://github.com/sigstore/cosign/releases>
COSIGN_SHA256_AMD64="PLACEHOLDER_PASTE_FROM_SIGSTORE_RELEASE_PAGE"
# TODO: cosign v2.4.1 linux/arm64 SHA256 = <paste from https://github.com/sigstore/cosign/releases>
COSIGN_SHA256_ARM64="PLACEHOLDER_PASTE_FROM_SIGSTORE_RELEASE_PAGE"

COSIGN_DOWNLOAD_BASE="https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}"

# Sigstore endpoints checked for P1 reachability (parity with pkg/prereq.CheckSigstoreReach).
SIGSTORE_FULCIO="https://fulcio.sigstore.dev"
SIGSTORE_REKOR="https://rekor.sigstore.dev"

MARKER_FILENAME=".breeze-install-mode"

# ---------------------------------------------------------------------------
# Globals (set by arg parsing or tty detection)
# ---------------------------------------------------------------------------

TARGET_VERSION=""
INSTALL_MODE=""
INSTALL_DIR=""
NON_INTERACTIVE=0
DO_UNINSTALL=0
WIPE_CONFIG=0
FORCE_DOWNGRADE=0

TMPDIR_WORK=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log_info()  { printf '[INFO]  %s\n' "$*"; }
log_warn()  { printf '[WARN]  %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

die() {
    log_error "$*"
    exit 1
}

cleanup_tmpdir() {
    if [[ -n "${TMPDIR_WORK:-}" && -d "${TMPDIR_WORK}" ]]; then
        rm -rf "${TMPDIR_WORK}"
    fi
}

prompt_confirm() {
    local prompt="$1"
    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
        return 0
    fi
    local reply
    read -r -p "${prompt} [y/N] " reply
    case "${reply}" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                print_usage
                exit 0
                ;;
            --version)
                [[ $# -ge 2 ]] || die "--version requires an argument"
                TARGET_VERSION="$2"
                shift 2
                ;;
            --install-mode)
                [[ $# -ge 2 ]] || die "--install-mode requires an argument"
                INSTALL_MODE="$2"
                case "${INSTALL_MODE}" in
                    system|user) ;;
                    *) die "--install-mode must be 'system' or 'user', got: ${INSTALL_MODE}" ;;
                esac
                shift 2
                ;;
            --install-dir)
                [[ $# -ge 2 ]] || die "--install-dir requires an argument"
                INSTALL_DIR="$2"
                shift 2
                ;;
            --yes|--non-interactive)
                NON_INTERACTIVE=1
                shift
                ;;
            --uninstall)
                DO_UNINSTALL=1
                shift
                ;;
            --wipe-config)
                WIPE_CONFIG=1
                shift
                ;;
            --force-downgrade)
                FORCE_DOWNGRADE=1
                shift
                ;;
            *)
                die "Unknown flag: $1  (run with --help to see usage)"
                ;;
        esac
    done
}

print_usage() {
    cat <<'EOF'
Breeze Installer — install or remove breeze-go on Linux (amd64, arm64)

USAGE
  # Install latest
  curl -sSL https://raw.githubusercontent.com/nth-prime/breeze-kit/main/install.sh | bash

  # Install specific version
  install.sh --version v0.1.0

  # User-mode install (no root)
  install.sh --install-mode user

  # Non-interactive (safe for CI and pipe usage)
  install.sh --yes

  # Uninstall
  install.sh --uninstall

  # Uninstall and remove config
  install.sh --uninstall --wipe-config

  # Force downgrade to an older version
  install.sh --version v0.0.9 --force-downgrade

FLAGS
  --version <vX.Y.Z>          Version to install (default: latest GitHub release)
  --install-mode system|user  Install mode (default: system if UID=0, user otherwise)
  --install-dir <path>        Override installation directory
  --yes / --non-interactive   Skip prompts; P1 warnings print but do not block
  --uninstall                 Remove breeze-go binary and systemd units
  --wipe-config               Also delete config directory (with --uninstall)
  --force-downgrade           Allow installing an older version over a newer one
  --help                      Print this message and exit
EOF
}

# ---------------------------------------------------------------------------
# TTY detection — must run before any `read` call
# ---------------------------------------------------------------------------

detect_tty() {
    if [[ ! -t 0 ]]; then
        NON_INTERACTIVE=1
    fi
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------

check_os() {
    local os
    os="$(uname -s 2>/dev/null || true)"
    if [[ "${os}" != "Linux" ]]; then
        die "P0 FAIL: This installer requires Linux. Detected OS: ${os:-unknown}"
    fi
    log_info "P0 PASS: OS is Linux"
}

check_arch() {
    local raw_arch
    raw_arch="$(uname -m 2>/dev/null || true)"
    case "${raw_arch}" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *)
            die "P0 FAIL: Unsupported architecture: ${raw_arch}. Only linux/amd64 and linux/arm64 are supported."
            ;;
    esac
    log_info "P0 PASS: Architecture is ${raw_arch} (${ARCH})"
}

check_systemd() {
    if ! systemctl --version >/dev/null 2>&1; then
        die "P0 FAIL: systemd is required but 'systemctl --version' failed. Breeze uses systemd for service and timer management."
    fi
    log_info "P0 PASS: systemd is available"
}

check_tools() {
    local missing=()
    for tool in curl tar sha256sum; do
        if ! command -v "${tool}" >/dev/null 2>&1; then
            missing+=("${tool}")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "P0 FAIL: Required tools not found: ${missing[*]}. Install them and re-run the installer."
    fi
    log_info "P0 PASS: curl, tar, sha256sum are available"
}

check_install_dir_writable() {
    local dir="$1"
    if [[ ! -d "${dir}" ]]; then
        # We will attempt to create it later; check parent is writable.
        local parent
        parent="$(dirname "${dir}")"
        if [[ ! -w "${parent}" ]]; then
            die "P0 FAIL: Install directory ${dir} does not exist and parent ${parent} is not writable."
        fi
    elif [[ ! -w "${dir}" ]]; then
        die "P0 FAIL: Install directory ${dir} is not writable. Run as root or choose a different directory with --install-dir."
    fi
    log_info "P0 PASS: Install directory ${dir} is writable"
}

check_sigstore_reach() {
    # P1: warn if Sigstore endpoints are unreachable. Does not block install but
    # cosign verification will fail if these are unreachable.
    local ok=1
    if ! curl --silent --head --max-time 5 --output /dev/null "${SIGSTORE_FULCIO}" 2>/dev/null; then
        log_warn "P1 WARN: ${SIGSTORE_FULCIO} is unreachable (5s timeout). Signature verification requires this endpoint."
        ok=0
    fi
    if ! curl --silent --head --max-time 5 --output /dev/null "${SIGSTORE_REKOR}" 2>/dev/null; then
        log_warn "P1 WARN: ${SIGSTORE_REKOR} is unreachable (5s timeout). Signature verification requires this endpoint."
        ok=0
    fi
    if [[ "${ok}" -eq 1 ]]; then
        log_info "P1 PASS: Sigstore endpoints (fulcio.sigstore.dev, rekor.sigstore.dev) are reachable"
    else
        log_warn "P1 WARN: One or more Sigstore endpoints unreachable. If cosign verification fails, check network access to fulcio.sigstore.dev and rekor.sigstore.dev."
    fi
}

check_user_lingering() {
    # P1: only relevant for user-mode install.
    if [[ "${INSTALL_MODE}" != "user" ]]; then
        return 0
    fi
    local linger_output
    linger_output="$(loginctl show-user "$(id -un)" 2>/dev/null || true)"
    if echo "${linger_output}" | grep -q "Linger=yes"; then
        log_info "P1 PASS: systemd user lingering is enabled"
    else
        log_warn "P1 WARN: systemd user lingering is not enabled. The breeze-go user service may not start on boot."
        log_warn "         Enable it with: loginctl enable-linger $(id -un)"
    fi
}

run_prereq_checks() {
    log_info "Running prerequisite checks..."
    check_os
    check_arch
    check_systemd
    check_tools
    check_install_dir_writable "${INSTALL_DIR}"
    check_sigstore_reach
    check_user_lingering
    log_info "Prerequisite checks complete."
}

# ---------------------------------------------------------------------------
# Resolve install mode and directory
# ---------------------------------------------------------------------------

resolve_install_mode() {
    if [[ -z "${INSTALL_MODE}" ]]; then
        if [[ "$(id -u)" -eq 0 ]]; then
            INSTALL_MODE="system"
        else
            INSTALL_MODE="user"
        fi
    fi
    log_info "Install mode: ${INSTALL_MODE}"
}

resolve_install_dir() {
    if [[ -n "${INSTALL_DIR}" ]]; then
        return 0
    fi
    if [[ "${INSTALL_MODE}" == "system" ]]; then
        INSTALL_DIR="/usr/local/bin"
    else
        INSTALL_DIR="${HOME}/.local/bin"
    fi
    log_info "Install directory: ${INSTALL_DIR}"
}

# ---------------------------------------------------------------------------
# Version resolution
# ---------------------------------------------------------------------------

resolve_version() {
    if [[ -n "${TARGET_VERSION}" ]]; then
        log_info "Target version: ${TARGET_VERSION} (from --version flag)"
        return 0
    fi
    log_info "Fetching latest release version from GitHub..."
    local api_response
    api_response="$(curl --silent --fail --max-time 30 "${RELEASES_API}" 2>/dev/null)" \
        || die "Failed to fetch latest release from ${RELEASES_API}. Check network connectivity."
    TARGET_VERSION="$(printf '%s' "${api_response}" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
    if [[ -z "${TARGET_VERSION}" ]]; then
        die "Could not parse tag_name from GitHub API response. Response snippet: ${api_response:0:200}"
    fi
    log_info "Latest version: ${TARGET_VERSION}"
}

# ---------------------------------------------------------------------------
# Idempotency check
# ---------------------------------------------------------------------------

read_installed_version() {
    local binary="${INSTALL_DIR}/${BINARY_NAME}"
    if [[ ! -x "${binary}" ]]; then
        printf ''
        return 0
    fi
    "${binary}" --version 2>/dev/null | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+[^ ]*' || true
}

read_marker() {
    local marker="${INSTALL_DIR}/${MARKER_FILENAME}"
    if [[ -f "${marker}" ]]; then
        cat "${marker}"
    else
        printf ''
    fi
}

semver_gt() {
    # Returns 0 (true) if $1 is strictly greater than $2.
    # Strips leading 'v', then compares with sort -V.
    local a="${1#v}" b="${2#v}"
    [[ "$(printf '%s\n%s\n' "${a}" "${b}" | sort -V | tail -1)" == "${a}" && "${a}" != "${b}" ]]
}

determine_install_action() {
    local installed_version="$1"
    local target_version="$2"

    if [[ -z "${installed_version}" ]]; then
        INSTALL_ACTION="fresh"
        return 0
    fi

    local binary="${INSTALL_DIR}/${BINARY_NAME}"
    # Repair: binary exists but --version fails.
    if ! "${binary}" --version >/dev/null 2>&1; then
        INSTALL_ACTION="repair"
        return 0
    fi

    if [[ "${installed_version}" == "${target_version}" ]]; then
        INSTALL_ACTION="noop"
        return 0
    fi

    if semver_gt "${target_version}" "${installed_version}"; then
        INSTALL_ACTION="upgrade"
        return 0
    fi

    # Target is older than installed.
    if [[ "${FORCE_DOWNGRADE}" -eq 1 ]]; then
        INSTALL_ACTION="force_downgrade"
    else
        INSTALL_ACTION="abort_downgrade"
    fi
}

check_idempotency() {
    local installed_version
    installed_version="$(read_installed_version)"
    INSTALL_ACTION=""
    determine_install_action "${installed_version}" "${TARGET_VERSION}"

    case "${INSTALL_ACTION}" in
        fresh)
            log_info "Fresh install: no existing ${BINARY_NAME} found."
            ;;
        noop)
            log_info "Already installed at version ${TARGET_VERSION}. Nothing to do."
            if [[ "${NON_INTERACTIVE}" -eq 0 ]]; then
                prompt_confirm "Reinstall anyway?" || exit 0
            else
                exit 0
            fi
            INSTALL_ACTION="fresh"
            ;;
        upgrade)
            log_info "Upgrade: installed=${installed_version} → target=${TARGET_VERSION}"
            ;;
        repair)
            log_warn "Repair: existing binary at ${INSTALL_DIR}/${BINARY_NAME} failed --version check. Reinstalling."
            ;;
        force_downgrade)
            log_warn "Downgrade: installed=${installed_version} → target=${TARGET_VERSION} (--force-downgrade)"
            ;;
        abort_downgrade)
            die "ABORT: installed version (${installed_version}) is newer than target (${TARGET_VERSION}). Use --force-downgrade to proceed."
            ;;
        *)
            die "Internal error: unknown INSTALL_ACTION=${INSTALL_ACTION}"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Download release assets
# ---------------------------------------------------------------------------

download_release() {
    TMPDIR_WORK="$(mktemp -d)"
    trap cleanup_tmpdir EXIT

    local version="${TARGET_VERSION}"
    local tarball="breeze-go_${version}_linux_${ARCH}.tar.gz"
    local bundle="${tarball}.bundle"
    local sums="SHA256SUMS"
    local base_url="${RELEASES_BASE}/${version}"

    log_info "Downloading release assets for ${version} linux/${ARCH}..."
    curl --silent --fail --location --max-time 120 \
        --output "${TMPDIR_WORK}/${tarball}" \
        "${base_url}/${tarball}" \
        || die "Failed to download tarball: ${base_url}/${tarball}"

    curl --silent --fail --location --max-time 30 \
        --output "${TMPDIR_WORK}/${bundle}" \
        "${base_url}/${bundle}" \
        || die "Failed to download bundle: ${base_url}/${bundle}"

    curl --silent --fail --location --max-time 30 \
        --output "${TMPDIR_WORK}/${sums}" \
        "${base_url}/${sums}" \
        || die "Failed to download SHA256SUMS: ${base_url}/${sums}"

    ASSET_TARBALL="${TMPDIR_WORK}/${tarball}"
    ASSET_BUNDLE="${TMPDIR_WORK}/${bundle}"
    ASSET_SUMS="${TMPDIR_WORK}/${sums}"

    log_info "Download complete."
}

# ---------------------------------------------------------------------------
# SHA256 verification
# ---------------------------------------------------------------------------

verify_sha256() {
    local tarball_path="$1"
    local sums_path="$2"
    local tarball_name
    tarball_name="$(basename "${tarball_path}")"

    log_info "Verifying SHA256 checksum..."
    local expected_line
    expected_line="$(grep "${tarball_name}" "${sums_path}" || true)"
    if [[ -z "${expected_line}" ]]; then
        die "SHA256 checksum not found for ${tarball_name} in SHA256SUMS."
    fi

    local expected_hash
    expected_hash="$(printf '%s' "${expected_line}" | awk '{print $1}')"
    local actual_hash
    actual_hash="$(sha256sum "${tarball_path}" | awk '{print $1}')"

    if [[ "${expected_hash}" != "${actual_hash}" ]]; then
        die "SHA256 mismatch for ${tarball_name}. Expected: ${expected_hash}  Got: ${actual_hash}"
    fi
    log_info "SHA256 PASS: ${tarball_name}"
}

# ---------------------------------------------------------------------------
# cosign self-download and verification
# ---------------------------------------------------------------------------

ensure_cosign() {
    if command -v cosign >/dev/null 2>&1; then
        COSIGN_BIN="$(command -v cosign)"
        log_info "Using system cosign at ${COSIGN_BIN}"
        return 0
    fi

    log_info "cosign not found on PATH. Downloading pinned cosign ${COSIGN_VERSION}..."

    local cosign_filename="cosign-linux-${ARCH}"
    local cosign_url="${COSIGN_DOWNLOAD_BASE}/${cosign_filename}"
    local cosign_dest="${TMPDIR_WORK}/cosign"

    curl --silent --fail --location --max-time 60 \
        --output "${cosign_dest}" \
        "${cosign_url}" \
        || die "Failed to download cosign from ${cosign_url}. Check network connectivity to github.com."

    # Verify cosign binary SHA256 before using it.
    local expected_sha256
    if [[ "${ARCH}" == "amd64" ]]; then
        expected_sha256="${COSIGN_SHA256_AMD64}"
    else
        expected_sha256="${COSIGN_SHA256_ARM64}"
    fi

    if [[ "${expected_sha256}" == PLACEHOLDER_* ]]; then
        log_warn "WARNING: cosign SHA256 is a placeholder (not yet filled in)."
        log_warn "         This build is NOT production-safe. Update COSIGN_SHA256_${ARCH^^} in install.sh."
        log_warn "         See docs/cosign-pins.md for instructions."
        if [[ "${NON_INTERACTIVE}" -eq 0 ]]; then
            prompt_confirm "Continue anyway (NOT recommended for production)?" \
                || die "Aborted. Fill in the cosign SHA256 before deploying."
        fi
    else
        local actual_sha256
        actual_sha256="$(sha256sum "${cosign_dest}" | awk '{print $1}')"
        if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
            die "cosign binary SHA256 mismatch. Expected: ${expected_sha256}  Got: ${actual_sha256}. Do not proceed — the downloaded binary may be tampered."
        fi
        log_info "cosign binary SHA256 verified."
    fi

    chmod +x "${cosign_dest}"
    COSIGN_BIN="${cosign_dest}"
    log_info "cosign ${COSIGN_VERSION} ready at ${COSIGN_BIN}"
}

# ---------------------------------------------------------------------------
# Signature verification
# ---------------------------------------------------------------------------

verify_signature() {
    local tarball_path="$1"
    local bundle_path="$2"

    log_info "Verifying cosign signature..."
    # NOTE: cosign verify-blob --bundle requires network access to Sigstore TLog/CA.
    # This is NOT offline-capable. If fulcio.sigstore.dev or rekor.sigstore.dev
    # are unreachable, this step will fail with a Sigstore connectivity error.
    "${COSIGN_BIN}" verify-blob \
        --bundle "${bundle_path}" \
        --certificate-identity-regexp="${COSIGN_CERT_IDENTITY_REGEXP}" \
        --certificate-oidc-issuer="${COSIGN_OIDC_ISSUER}" \
        "${tarball_path}" \
        || die "Signature verification FAILED. Possible causes:
  - Network access required to fulcio.sigstore.dev and rekor.sigstore.dev
  - Release assets may have been tampered with
  - Bundle was produced by a different identity or workflow
  Do NOT install an unverified binary."
    log_info "Signature PASS."
}

# ---------------------------------------------------------------------------
# Systemd unit installation (placeholder units for Sprint 16)
# Sprint 17 will replace these with breeze-go-rendered units once
# the 'breeze-go install --system/--user' subcommand lands.
# ---------------------------------------------------------------------------

install_systemd_units_system() {
    local bin_path="$1"
    local unit_dir="/etc/systemd/system"

    log_info "Installing systemd units (system mode)..."

    cat > "${unit_dir}/breeze-go.service" <<EOF
[Unit]
Description=Breeze Go sync server
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${bin_path} serve
Restart=on-failure
RestartSec=5
EnvironmentFile=-/etc/breeze-go/env

[Install]
WantedBy=multi-user.target
EOF

    cat > "${unit_dir}/breeze-go-update.service" <<EOF
[Unit]
Description=Breeze Go self-update (oneshot)
After=network.target

[Service]
Type=oneshot
ExecStart=${bin_path} update
EnvironmentFile=-/etc/breeze-go/env
EOF

    cat > "${unit_dir}/breeze-go-update.timer" <<EOF
[Unit]
Description=Breeze Go daily self-update timer

[Timer]
OnCalendar=daily
Persistent=true
Unit=breeze-go-update.service

[Install]
WantedBy=timers.target
EOF

    log_info "systemd units written to ${unit_dir}"
}

install_systemd_units_user() {
    local bin_path="$1"
    local unit_dir="${HOME}/.config/systemd/user"
    mkdir -p "${unit_dir}"

    log_info "Installing systemd units (user mode)..."

    cat > "${unit_dir}/breeze-go.service" <<EOF
[Unit]
Description=Breeze Go sync server (user)
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${bin_path} serve
Restart=on-failure
RestartSec=5
EnvironmentFile=-${HOME}/.config/breeze-go/env

[Install]
WantedBy=default.target
EOF

    cat > "${unit_dir}/breeze-go-update.service" <<EOF
[Unit]
Description=Breeze Go self-update oneshot (user)
After=network.target

[Service]
Type=oneshot
ExecStart=${bin_path} update
EnvironmentFile=-${HOME}/.config/breeze-go/env
EOF

    cat > "${unit_dir}/breeze-go-update.timer" <<EOF
[Unit]
Description=Breeze Go daily self-update timer (user)

[Timer]
OnCalendar=daily
Persistent=true
Unit=breeze-go-update.service

[Install]
WantedBy=timers.target
EOF

    log_info "systemd units written to ${unit_dir}"
}

# ---------------------------------------------------------------------------
# EnvironmentFile scaffold (write if absent; preserve if present)
# ---------------------------------------------------------------------------

ensure_env_file() {
    local env_file
    if [[ "${INSTALL_MODE}" == "system" ]]; then
        env_file="/etc/breeze-go/env"
        mkdir -p /etc/breeze-go
    else
        env_file="${HOME}/.config/breeze-go/env"
        mkdir -p "${HOME}/.config/breeze-go"
    fi

    if [[ ! -f "${env_file}" ]]; then
        cat > "${env_file}" <<'EOF'
# Breeze Go environment configuration
# SERVER_PORT=8443
# LOG_LEVEL=info
EOF
        log_info "Created environment file: ${env_file}"
    else
        log_info "Environment file already exists, preserving: ${env_file}"
    fi
}

# ---------------------------------------------------------------------------
# Install (system mode)
# ---------------------------------------------------------------------------

install_system_mode() {
    local tarball_path="$1"
    local bin_dest="${INSTALL_DIR}/${BINARY_NAME}"

    log_info "Installing ${BINARY_NAME} to ${bin_dest} (system mode)..."
    mkdir -p "${INSTALL_DIR}"

    local extract_dir="${TMPDIR_WORK}/extract"
    mkdir -p "${extract_dir}"
    tar -xzf "${tarball_path}" -C "${extract_dir}"

    local extracted_bin
    extracted_bin="$(find "${extract_dir}" -type f -name "${BINARY_NAME}" | head -1)"
    [[ -n "${extracted_bin}" ]] || die "Binary '${BINARY_NAME}' not found in tarball."

    install -m 0755 "${extracted_bin}" "${bin_dest}"
    log_info "Binary installed: ${bin_dest}"

    # Write mode marker.
    printf 'system\n' > "${INSTALL_DIR}/${MARKER_FILENAME}"

    ensure_env_file
    install_systemd_units_system "${bin_dest}"

    log_info "Running daemon-reload and enabling units..."
    systemctl daemon-reload
    systemctl enable --now breeze-go.service breeze-go-update.timer \
        || log_warn "systemctl enable failed — you may need to run this manually."

    log_info "Install complete (system mode). Run 'systemctl status breeze-go' to verify."
}

# ---------------------------------------------------------------------------
# Install (user mode)
# ---------------------------------------------------------------------------

install_user_mode() {
    local tarball_path="$1"
    local bin_dest="${INSTALL_DIR}/${BINARY_NAME}"

    log_info "Installing ${BINARY_NAME} to ${bin_dest} (user mode)..."
    mkdir -p "${INSTALL_DIR}"

    local extract_dir="${TMPDIR_WORK}/extract"
    mkdir -p "${extract_dir}"
    tar -xzf "${tarball_path}" -C "${extract_dir}"

    local extracted_bin
    extracted_bin="$(find "${extract_dir}" -type f -name "${BINARY_NAME}" | head -1)"
    [[ -n "${extracted_bin}" ]] || die "Binary '${BINARY_NAME}' not found in tarball."

    install -m 0755 "${extracted_bin}" "${bin_dest}"
    log_info "Binary installed: ${bin_dest}"

    # Write mode marker.
    printf 'user\n' > "${INSTALL_DIR}/${MARKER_FILENAME}"

    ensure_env_file
    install_systemd_units_user "${bin_dest}"

    log_info "Running user daemon-reload and enabling units..."
    systemctl --user daemon-reload
    systemctl --user enable --now breeze-go.service breeze-go-update.timer \
        || log_warn "systemctl --user enable failed — ensure lingering is enabled: loginctl enable-linger $(id -un)"

    log_info "Install complete (user mode). Run 'systemctl --user status breeze-go' to verify."
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

determine_uninstall_mode() {
    local marker="${INSTALL_DIR}/${MARKER_FILENAME}"

    if [[ -f "${marker}" ]]; then
        UNINSTALL_MODE="$(cat "${marker}")"
        case "${UNINSTALL_MODE}" in
            system|user) ;;
            *)
                log_warn "Unrecognized marker content: '${UNINSTALL_MODE}'. Attempting auto-detect."
                UNINSTALL_MODE=""
                ;;
        esac
    fi

    if [[ -z "${UNINSTALL_MODE:-}" ]]; then
        # Marker absent: probe systemctl to determine mode.
        log_warn "Marker file not found at ${marker}. Probing systemctl to determine install mode..."
        if systemctl is-active --quiet breeze-go.service 2>/dev/null; then
            log_info "Detected system-mode install via 'systemctl is-active breeze-go.service'."
            UNINSTALL_MODE="system"
        elif systemctl --user is-active --quiet breeze-go.service 2>/dev/null; then
            log_info "Detected user-mode install via 'systemctl --user is-active breeze-go.service'."
            UNINSTALL_MODE="user"
        else
            log_error "Could not detect install mode: marker file absent and both 'systemctl is-active breeze-go.service' and 'systemctl --user is-active breeze-go.service' indicate the service is not active."
            log_error "If breeze-go is installed, run: breeze-go uninstall"
            log_error "If it is not installed, there is nothing to remove."
            exit 1
        fi
    fi
}

remove_systemd_units_system() {
    log_info "Stopping and disabling system units..."
    systemctl stop breeze-go.service breeze-go-update.timer 2>/dev/null || true
    systemctl disable breeze-go.service breeze-go-update.timer 2>/dev/null || true
    rm -f /etc/systemd/system/breeze-go.service
    rm -f /etc/systemd/system/breeze-go-update.service
    rm -f /etc/systemd/system/breeze-go-update.timer
    systemctl daemon-reload 2>/dev/null || true
    log_info "System units removed."
}

remove_systemd_units_user() {
    log_info "Stopping and disabling user units..."
    systemctl --user stop breeze-go.service breeze-go-update.timer 2>/dev/null || true
    systemctl --user disable breeze-go.service breeze-go-update.timer 2>/dev/null || true
    rm -f "${HOME}/.config/systemd/user/breeze-go.service"
    rm -f "${HOME}/.config/systemd/user/breeze-go-update.service"
    rm -f "${HOME}/.config/systemd/user/breeze-go-update.timer"
    systemctl --user daemon-reload 2>/dev/null || true
    log_info "User units removed."
}

uninstall() {
    log_info "Uninstalling breeze-go..."

    resolve_install_mode
    resolve_install_dir

    UNINSTALL_MODE=""
    determine_uninstall_mode

    local bin_dest="${INSTALL_DIR}/${BINARY_NAME}"
    local marker="${INSTALL_DIR}/${MARKER_FILENAME}"

    if [[ "${UNINSTALL_MODE}" == "system" ]]; then
        remove_systemd_units_system
    else
        remove_systemd_units_user
    fi

    if [[ -f "${bin_dest}" ]]; then
        rm -f "${bin_dest}"
        log_info "Removed binary: ${bin_dest}"
    fi

    if [[ -f "${marker}" ]]; then
        rm -f "${marker}"
        log_info "Removed marker: ${marker}"
    fi

    if [[ "${WIPE_CONFIG}" -eq 1 ]]; then
        if [[ "${UNINSTALL_MODE}" == "system" ]]; then
            rm -rf /etc/breeze-go
            log_info "Removed config directory: /etc/breeze-go"
        else
            rm -rf "${HOME}/.config/breeze-go"
            log_info "Removed config directory: ${HOME}/.config/breeze-go"
        fi
    else
        log_info "Config directory preserved. Use --wipe-config to remove it."
    fi

    log_info "Uninstall complete."
}

# ---------------------------------------------------------------------------
# Main install flow
# ---------------------------------------------------------------------------

do_install() {
    resolve_install_mode
    resolve_install_dir
    run_prereq_checks
    resolve_version
    check_idempotency

    if [[ -z "${TMPDIR_WORK}" ]]; then
        TMPDIR_WORK="$(mktemp -d)"
        trap cleanup_tmpdir EXIT
    fi

    download_release
    verify_sha256 "${ASSET_TARBALL}" "${ASSET_SUMS}"
    ensure_cosign
    verify_signature "${ASSET_TARBALL}" "${ASSET_BUNDLE}"

    if [[ "${INSTALL_MODE}" == "system" ]]; then
        install_system_mode "${ASSET_TARBALL}"
    else
        install_user_mode "${ASSET_TARBALL}"
    fi
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
    detect_tty
    parse_args "$@"

    if [[ "${DO_UNINSTALL}" -eq 1 ]]; then
        if [[ "${WIPE_CONFIG}" -eq 1 && "${NON_INTERACTIVE}" -eq 0 ]]; then
            prompt_confirm "This will also remove your breeze-go configuration. Continue?" \
                || die "Aborted."
        fi
        uninstall
    else
        do_install
    fi
}

main "$@"
