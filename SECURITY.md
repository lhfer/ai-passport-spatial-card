# Privacy and security

The public repository contains a synthetic profile, original sample artwork, and a trained reference object with its embedded source USDZ removed. It does not require the author's account, network address, signing team, or device identifiers.

## Keep your local setup local

- `hub/data/` holds browser sessions, cookies, cached notes, images and diagnostics. It is ignored by Git; never upload it to an issue or pull request.
- After personalizing `card.json`, the screen images, firmware C arrays, avatar layers and visionOS bundle copies may also contain your identity. Replacing only the JSON is not sufficient before republishing.
- `Resources/hub.json` is empty by default. Do not commit your personal LAN host, Apple signing team, certificates or device IDs.
- Firmware backups may contain device configuration; store them outside the public tree.
- The Extended package has no embedded preview images. Its learned weights were preserved, not retrained; see the model documentation for the precise boundary.

## Network use

`pnpm demo` binds to loopback, uses sample files, never opens a serial port and does not scrape remote websites. The real-device `pnpm hub start` mode is a trusted-LAN tool with unauthenticated HTTP / WebSocket control. Do not expose it to the internet or untrusted networks.

Before publishing a fork, run `python3 tools/check-public-release.py` and a secret scanner such as `gitleaks git --redact`; also inspect images, archives and videos. Automated scanning cannot guarantee that every private detail is absent.

## Reporting a vulnerability

Use this repository's GitHub private vulnerability reporting when available. Do not post credentials, browser sessions, personal screenshots or live account data in public issues. A minimal reproduction with synthetic data is enough to start.
