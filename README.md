# breeze-kit

Public installer and signed release assets for [breeze-go](https://github.com/nth-prime/breeze-go).

---

## What is Breeze?

Breeze is a self-hosted file sync server. The Go source lives in the private `nth-prime/breeze-go` repository. The CI pipeline there builds Linux binaries for `amd64` and `arm64`, signs them with [cosign](https://github.com/sigstore/cosign) using keyless OIDC via Sigstore, and publishes signed release assets here to `nth-prime/breeze-kit` GitHub Releases. End users install with a single `curl` command — no personal access token or account required.

---

## Install

### One-liner (latest release)

```sh
curl -sSL https://raw.githubusercontent.com/nth-prime/breeze-kit/main/install.sh | bash
```

The installer:
- Detects your architecture (`amd64` or `arm64`).
- Fetches the latest signed release from this repository.
- Verifies the SHA256 checksum of the downloaded tarball.
- Downloads `cosign` if not already on PATH, verifies it against a pinned SHA256, then uses it to verify the release signature.
- Installs `breeze-go` in system mode (`/usr/local/bin`) if you are root, or user mode (`~/.local/bin`) otherwise.
- Drops systemd service and timer units and enables them.

### System install (as root)

```sh
curl -sSL https://raw.githubusercontent.com/nth-prime/breeze-kit/main/install.sh | sudo bash
```

Installs to `/usr/local/bin/breeze-go`. Systemd units go to `/etc/systemd/system/`.

### User install (no root)

```sh
curl -sSL https://raw.githubusercontent.com/nth-prime/breeze-kit/main/install.sh | bash -s -- --install-mode user
```

Installs to `~/.local/bin/breeze-go`. Systemd units go to `~/.config/systemd/user/`.

> **Note:** User-mode installs require systemd user lingering to survive logout. Enable it with:
> ```sh
> loginctl enable-linger $USER
> ```

### Install a specific version

```sh
curl -sSL https://raw.githubusercontent.com/nth-prime/breeze-kit/main/install.sh | bash -s -- --version v0.1.0
```

### Non-interactive / CI install

```sh
curl -sSL https://raw.githubusercontent.com/nth-prime/breeze-kit/main/install.sh | bash -s -- --yes
```

When stdin is not a TTY (e.g., piped from `curl`), the installer automatically runs non-interactively. The `--yes` flag makes this explicit.

### Force downgrade

```sh
curl -sSL https://raw.githubusercontent.com/nth-prime/breeze-kit/main/install.sh | bash -s -- --version v0.0.9 --force-downgrade
```

---

## Update

### Manual update

```sh
breeze-go update
```

### Automatic update

The installer drops a systemd timer (`breeze-go-update.timer`) that runs `breeze-go update` daily. The update path follows the same SHA256 + cosign verification as the initial install.

Check the timer status:

```sh
# System mode
systemctl status breeze-go-update.timer

# User mode
systemctl --user status breeze-go-update.timer
```

---

## Uninstall

```sh
curl -sSL https://raw.githubusercontent.com/nth-prime/breeze-kit/main/install.sh | bash -s -- --uninstall
```

Removes the binary and systemd units. Config files are preserved by default.

To also remove config:

```sh
curl -sSL https://raw.githubusercontent.com/nth-prime/breeze-kit/main/install.sh | bash -s -- --uninstall --wipe-config
```

---

## Troubleshooting

### `breeze-go doctor --selftest` reports FAIL

Run the full prerequisite check:

```sh
breeze-go doctor
```

This checks OS, architecture, systemd availability, network reachability, and (for user-mode installs) lingering status. Failures print actionable messages.

### Viewing logs

```sh
# System mode
journalctl -u breeze-go -f

# User mode
journalctl --user -u breeze-go -f
```

### Sigstore endpoint requirement

Signature verification requires network access to:
- `https://fulcio.sigstore.dev`
- `https://rekor.sigstore.dev`

If either endpoint is unreachable, `cosign verify-blob` will fail and the installer will abort. This is by design — breeze-go does not install unverified binaries. Check network connectivity and firewall rules if verification fails.

### Signature verification fails

Possible causes:
- Sigstore endpoints unreachable (see above).
- Downloaded assets are incomplete or corrupted — re-run the installer.
- The release was not produced by the expected GitHub Actions workflow. Check `nth-prime/breeze-go` for release workflow details.

### Service does not start after reboot (user mode)

Enable lingering:

```sh
loginctl enable-linger $USER
```

---

## Security

All release assets are signed using [cosign keyless OIDC signing](https://docs.sigstore.dev/cosign/keyless/). Signing happens inside the `nth-prime/breeze-go` GitHub Actions release workflow using a short-lived identity token. No private key is generated or stored.

The installer verifies:
1. SHA256 checksum of the downloaded tarball against `SHA256SUMS`.
2. cosign bundle signature against the embedded OIDC identity and issuer.

If either check fails, the installer exits non-zero and does not install.

---

## License

MIT. See [LICENSE](LICENSE).
