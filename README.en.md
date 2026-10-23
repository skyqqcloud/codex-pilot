# Codex Pilot

[简体中文](README.md) · [Download](https://github.com/skyqqcloud/codex-pilot/releases/latest)

A native macOS menu bar utility for Codex API output speed, account switching, and remaining quotas. Built with SwiftUI and AppKit. This is an independent community project and is not affiliated with OpenAI.

## Features

- Compact two-line menu bar: the latest TPS for the selected model, followed by the active account's remaining quota. Uses the lower known quota when multiple windows exist.
- Latest-request and recent-five averages; up to 100 captured requests per model, grouped by initiating message with collapsible follow-up calls.
- Request usage, timing, explicit Fast markers, and locally associated output or tool summaries.
- Save and switch logins, reorder accounts, and refresh account plans and quotas.
- Event-driven updates, incremental history indexing, reusable workers, and separate background/interactive QoS.

<img src="docs/images/main-light.png" width="380" alt="Native Codex Pilot panel using synthetic accounts and sample measurements">

The screenshots use synthetic data and are not performance benchmarks.

## Install

Requires Apple Silicon, macOS 14+, a signed-in Codex desktop client, and Python 3.9+ in a supported installation location such as Homebrew or Command Line Tools. No third-party Python packages are needed.

Download `Codex-Pilot-macOS-arm64.dmg` from [Releases](https://github.com/skyqqcloud/codex-pilot/releases/latest), drag the app into Applications, and open it. The current build uses ad-hoc signing and is not notarized. macOS may require approval in Privacy & Security on first launch.

Save the current login from the menu bar panel. Enable the two-line status display in Settings. To collect new speed measurements, enable local capture and **restart Codex**. Old requests cannot be reconstructed without their original timing events.

Account switching asks Codex to quit normally before replacing the login file and reopening it. Finish work you need to keep before switching.

## Measurement boundary

```text
TPS = (API output tokens - reasoning tokens) / observed non-reasoning output-stage duration
```

This is a client-observed output-stage rate, not a server-side GPU benchmark or an exact visible-text token rate. Tool arguments and API formatting tokens may be included. Missing or ambiguous timing produces an unknown rate, never an estimate. The recent-five average uses valid rates within the five most recent captured completions, without backfilling older requests.

See [the full measurement definition](docs/throughput.md) and the historical audit reports linked in the [Chinese README](README.md).

## Privacy

Login files and quotas are stored locally under `~/.codex-swap/`. Saved logins contain full credentials protected by filesystem permissions, not Keychain encryption. The local telemetry receiver binds only to `127.0.0.1:45417` and requires a random token. Measurements do not proxy model requests or send conversations to the maintainer. Quota refreshes and credential renewal contact the relevant OpenAI endpoints.

The local telemetry cache may include conversation identifiers and bounded message previews. Full request text is read locally when requested. Do not publish credentials, caches, conversation logs, or unredacted screenshots. See [SECURITY.md](SECURITY.md).

## Build and contribute

```bash
git clone https://github.com/skyqqcloud/codex-pilot.git
cd codex-pilot
bash scripts/check.sh
bash scripts/build-dmg.sh
# Optional native offscreen layout checks:
bash scripts/check-scroll-layout.sh
```

Requires macOS, a Swift compiler and macOS SDK from Xcode or Command Line Tools, and Python 3.9+. Outputs are `dist/Codex Pilot.app` and `dist/Codex Pilot.dmg`. Set `CODEX_PILOT_SDK` to override SDK selection. The scripts prefer an installed macOS 26 SDK and otherwise use `xcrun`; select a compatible SDK/full Xcode if the CLI toolchain lacks SwiftUI macro plugins.

`Package.swift` defines telemetry checks, not the entire app. Default checks use synthetic data and do not call a real model. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[Apache-2.0](LICENSE). Telemetry components derived from [OPL Fleet Agent](https://github.com/gaofeng21cn/opl-fleet-agent) retain their upstream copyright, license and modification notice under `ThirdParty/OPLFleetAgent/`. See [NOTICE](NOTICE).
