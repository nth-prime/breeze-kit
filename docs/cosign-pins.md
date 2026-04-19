# cosign version pins

This document records the pinned `cosign` version used by `install.sh` and describes the procedure for rotating it.

---

## Current pin

| Field | Value |
|-------|-------|
| cosign version | v2.4.1 |
| linux/amd64 SHA256 | `8b24b946dd5809c6bd93de08033bcf6bc0ed7d336b7785787c080f574b89249b` |
| linux/arm64 SHA256 | `3b2e2e3854d0356c45fe6607047526ccd04742d20bd44afb5be91fa2a6e7cb4a` |
| Source | https://github.com/sigstore/cosign/releases/download/v2.4.1/cosign_checksums.txt |

Values verified on download by `install.sh` before the `cosign` binary is executed. A SHA256 mismatch is a hard fail (`die`), not a warning — the installer refuses to proceed with a tampered verifier.

---

## How to update the pin

1. Go to https://github.com/sigstore/cosign/releases and find the target release.
2. Download the release checksum file: `cosign_<version>_checksums.txt` (or equivalent).
3. Extract the SHA256 for `cosign-linux-amd64` and `cosign-linux-arm64`.
4. Update `COSIGN_SHA256_AMD64` and `COSIGN_SHA256_ARM64` in `install.sh`.
5. Update the `COSIGN_VERSION` variable in `install.sh` to match the new version.
6. Update the table above in this file.
7. Commit the change with a message like: `chore: rotate cosign pin to vX.Y.Z`.
8. Run `shellcheck install.sh` to confirm no regressions.

---

## Why we pin cosign

The installer downloads cosign from Sigstore's official GitHub releases if cosign is not already present on the machine. To prevent a supply-chain attack via a compromised cosign binary, the installer verifies the downloaded cosign binary against a pinned SHA256 before executing it.

This means:
- A compromised `cosign` distribution channel cannot replace the binary silently.
- The pin must be rotated manually when upgrading cosign to pick up security fixes.

---

## Notes

- The cosign binary is downloaded to a temp directory and is not installed permanently on the user's machine.
- If cosign is already on PATH, the pinned download is skipped entirely.
- The embedded OIDC identity and issuer in `install.sh` are separate from the cosign pin and are not expected to change unless the release workflow identity changes.
