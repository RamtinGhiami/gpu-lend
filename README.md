# GPU Lend

Run AI models on your PC's graphics card and use them from your own programs, from other devices on your network, or lend
the card to a server you run. A small tray app for **Windows, Linux and macOS**.

- **Standalone (no server needed):** turn on the **Local API** and any OpenAI-compatible program (scripts, editors, chat UIs)
  can use the models on this PC: `POST /v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, `/v1/images/generations`,
  plus `GET /v1/models` and `/health`. Every request needs the API key shown in the app, and the API listens on `127.0.0.1`
  only, unless you allow your network.
- **Lend the card to your own server:** the app dials out over HTTPS (no open ports, works behind NAT), pairs once with a
  code, then takes jobs one at a time and hands them to a local model. The wire format is open: see
  [PROTOCOL.md](PROTOCOL.md). A small reference server is in [reference-server/](reference-server/).
- **Backends** start on demand and only one is kept loaded at a time: [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp)
  `sd-server` for images, [llama.cpp](https://github.com/ggml-org/llama.cpp) `llama-server` for language models, or any program
  you describe.
- A dashboard with a power button, status, jobs done, average time, GPU memory and utilisation, and recent jobs. Settings: when
  to lend (always / at night / on mains only), daily limits, start at sign-in. Lives in the tray, one copy at a time.
- Settings are two-way when paired: change them on the PC or on the server; the server holds the truth and the app follows.
- The device token is stored encrypted with Windows DPAPI (on Linux and macOS in the settings file, readable only by you).

## Download and install

Get the file for your system from the [latest release](../../releases/latest).

| System | File | How |
| --- | --- | --- |
| **Windows 10 / 11** | `GpuLend-Setup-<version>.exe` | Run it. It installs for your user only (no administrator rights). A portable `.zip` is also there. |
| **Linux** (x86-64, GTK 3) | `GpuLend-<version>-linux-x64.tar.gz` | Unpack, run `./install.sh`. Or: `curl -fsSL https://raw.githubusercontent.com/RamtinGhiami/gpu-lend/main/scripts/install-linux.sh \| bash`. The tray icon needs AppIndicator support (GNOME: the "AppIndicator" extension). |
| **macOS** | `GpuLend-<version>-macos.dmg` (or `.zip`) | Drag GPU Lend to Applications. It is not notarized: the first time, right-click it and choose Open, or run `xattr -dr com.apple.quarantine "/Applications/GPU Lend.app"`. |

Windows is the best tested platform. The Linux and macOS builds come from the same code and are built by GitHub Actions; please
report problems in the Issues tab. On a Mac there is no NVIDIA card: the dashboard shows the chip and its shared memory, and
`sd-server` / `llama-server` can use Metal.

## Getting started (standalone)

1. Get a backend program and a model, for example a `llama-server` build from llama.cpp and a `.gguf` model, and/or
   `sd-server` with its model files.
2. Open **Settings**. Under **Workloads** point to the folder with the program and the model files (for a language model add a
   backend of kind "llama" with the paths).
3. On the **Home** page turn on **Serve the models to my programs**. Copy the address and the API key.
4. Use it from any OpenAI-compatible client:

```bash
curl http://127.0.0.1:8765/v1/chat/completions \
  -H "Authorization: Bearer <your key>" -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello"}]}'
```

The first request starts the backend (it can take a while); streaming (`"stream": true`) is passed through.

## Lending to a server

Run any server that implements [PROTOCOL.md](PROTOCOL.md) (the reference server is a good start), open **Server** in the app,
paste the pairing text and press Pair. The server can only have the app call the paths on a local allow-list, and the app only
talks to `https://` servers (or `http://localhost` for testing). Optional: connect to a server IP directly with a pinned
certificate.

## Build from source

Needs Flutter (3.47+) with desktop support for your system. On Windows also Visual Studio Build Tools (C++ workload), CMake, a
Windows SDK and Developer Mode (plugin symlinks). On Linux: `libgtk-3-dev libayatana-appindicator3-dev libkeybinder-3.0-dev
clang cmake ninja-build`.

```
flutter pub get
flutter analyze
flutter test                           # includes the local API and a run against the reference server (needs Python 3)
flutter build windows --release        # or: flutter build linux --release / flutter build macos --release
```

The installer: install [Inno Setup 6](https://jrsoftware.org/isinfo.php) and run `ISCC installer\gpu_lend.iss` after the
Windows build. Releases for all three systems are built by `.github/workflows/release.yml` when a `v*` tag is pushed.

## Layout

```
lib/core   engine (state machine), local API, server client (pinning, direct IP), backends, config store, platform helpers
lib/ui     shell (title bar, rail), dashboard, server (pairing), settings, tools
reference-server/   a minimal server for the protocol (Python, standard library only)
```

Data is kept in `%LOCALAPPDATA%\GpuLend` on Windows, `~/.local/share/GpuLend` on Linux and
`~/Library/Application Support/GpuLend` on macOS (`config.json`, `app.log`, `model-<id>.log`). The backend programs and model files
are looked up in the folders set under Settings (default: `bin` and `models` inside the data folder).

## License

GPL-2.0-or-later, see [LICENSE](LICENSE). Pieces of the UI are reused by [NetMeter](https://github.com/RamtinGhiami/NetMeter).
