# ArcLatch

**Fire up local AI on your Mac.**

ArcLatch is a native macOS control panel for **Ollama, Splash, MLX-LM, and llama.cpp**. Pick an existing local model, start its server, send a test request, and copy the API URL into your coding agent or other client. The window also shows estimated system RAM usage and macOS memory pressure while models load and run.

## What you can do

- **Set up providers from the app.** Use Mac file pickers to locate an executable or model, then save the setup for next time.
- **Start, test, and stop servers.** See when a server is ready to accept requests, then use **Test model** to confirm it can generate a response.
- **Connect another client.** Copy the local API URL for the selected provider from its endpoint row once the server is ready.
- **Watch system memory.** See estimated RAM used against physical RAM, with a separate pressure indicator for how well macOS is handling the load.
- **Reuse what you have.** ArcLatch uses separately installed engines and your existing model files. It ships without model weights.

## Requirements

- An **Apple silicon Mac**. The app targets macOS 14 or later. Each provider has its own hardware and OS requirements.
- **Apple Command Line Tools with Swift 6.4 or later** to build from source (this project is built against the 6.4.2 CLT). Tests use Swift Testing, which the CLT provides; XCTest is not required.
- At least one of the providers below installed, with a compatible model already on disk.

## Build from source

From the root of your ArcLatch checkout, run:

```sh
./build_app.sh
open build/ArcLatch.app
```

The script creates `build/ArcLatch.app`. Open it from Finder, Spotlight, or `open` — all take the same path, and the model library is listed on first launch. For everyday use, start servers and change settings from the app. The build is ad-hoc signed (`codesign --sign -`): it runs on the Mac that built it, and Gatekeeper will ask you to approve it on another Mac.

Command-line entry points, also from the repository root:

| Command | What it does |
| --- | --- |
| `make build` | Compile the library and app targets. |
| `make test` | Run the test suite. |
| `make check` | `swift package clean`, then build, then test — the path a fresh checkout takes. |
| `make check-fallback` | Same from clean, with `SWIFT_ENABLE_EXPLICIT_MODULES=NO`, for the case where a Command Line Tools update drops the Swift Testing macro plugin symlink (see [Package.swift](Package.swift)). |

## Set up a provider

1. Select a provider in the sidebar.
2. If ArcLatch shows **Needs setup**, choose an existing model or use **Advanced settings → Locate executable…** to point it at your installed server.
3. Click **Start**. Once the status reads **Server ready**, click **Test model** to check generation.
4. Copy the URL from the endpoint row (the small **Copy** button beside the address; **More** lists any alternate endpoints). Click **Stop** when you’re done with a server ArcLatch manages.

| Provider | What to select | Default local API URL |
| --- | --- | --- |
| **Ollama** | Install the Homebrew formula and select an installed model tag. ArcLatch uses the Homebrew service and reads its configured port. [Homebrew formula](https://formulae.brew.sh/formula/ollama) | `http://127.0.0.1:11434` |
| **Splash** | Pick an installed Splash preset, or choose compatible local model files and a draft under **Advanced settings**. Splash always launches offline from local files. [Splash local model setup](https://github.com/incoai/splash#models) | `http://127.0.0.1:8000/v1` |
| **MLX-LM** | Locate `mlx_lm.server` in your Python environment and choose a local MLX model folder. For models that load custom Python, enable **Allow custom code for this model** only if you trust the files. [MLX-LM](https://github.com/ml-explore/mlx-lm) | `http://127.0.0.1:8081/v1` |
| **llama.cpp** | Locate `llama-server` and choose a compatible local `.gguf` file. [llama.cpp server](https://github.com/ggml-org/llama.cpp/tree/master/tools/server) | `http://127.0.0.1:8082/v1` |

The Ollama URL above is for its native API. The other URLs are OpenAI-compatible base URLs. Use the URL ArcLatch copies if your port differs from the default.

## The model library

ArcLatch lists models by walking one folder tree, the **model library**, and classifying what it finds by format rather than by folder convention. Anything you drop into that tree appears under every provider that can serve it.

- **First launch.** With nothing saved yet, ArcLatch uses **`~/AI/models`** when that folder exists and can be read — models in its subfolders are found too. It never walks the whole home folder on its own. If there is no `~/AI/models`, nothing is scanned: the sidebar says **No folder chosen** and each provider offers **Choose Model Folder…**.
- **Your choice wins.** A folder you pick in **Settings → Choose folder…** (or from a provider's **Choose Model Folder…**) is saved and reused; the automatic pick is not written to your settings, so it never overwrites a preference. **Use ~ (whole home folder)** is there if you want the broad scan.
- **Older builds saved `~` even when you never chose it.** That choice is still honored rather than silently replaced — nothing disappears on update — and Settings explains it and offers **Switch to ~/AI/models** as one click.
- **A folder that goes away stays selected.** An unmounted volume or sleeping disk shows its saved path with **Retry** beside it (in Settings and in the provider); ArcLatch does not swap in a different library behind your back.
- **Active folder, always visible.** The sidebar footer and Settings both show the folder in use, in full in Settings and selectable for copying.
- **Formats.** A `.gguf` file is offered to llama.cpp and as Splash files; a folder holding `config.json` plus `.safetensors` is offered to MLX-LM. `mmproj*` and `ggml-vocab*` files are accessories, not models, and split GGUFs (`Name-00002-of-00004.gguf`) are listed once, at their first shard.
- **Skipped folders.** Hidden folders and trees other tools manage are skipped at any depth: `ollama`, `huggingface-hub`, `blobs`, `snapshots`, `refs`, `library`, `node_modules`, `venv`, `venvs`, `site-packages`, `__pycache__`, `build`, `dist`, `comfyui`, `benchmarks`, `model-backups`, and similar.
- **Skipped bundles.** Folder *packages* — `*.photoslibrary`, `*.musiclibrary`, `*.library`, `*.app`, `*.bundle`, `*.framework`, `*.plugin`, … — are never model folders and are never opened. That is not a style rule: opening a Photos library can block inside the kernel while a background daemon holds it, which on a real Mac froze a home-folder scan and left every provider below it showing an empty list.
- **Budgets.** The walk stops 5 folders deep, after 30,000 folders, and after a 15-second wall clock. The time budget is checked **between** folder reads: it bounds a walk over slow or spinning storage, but it cannot interrupt a call that is already blocked in the kernel — which is what the bundle exclusions are for. A scan that stops early is labeled as partial next to the model count instead of looking complete.
- **Blocked vs empty.** If a folder refused to open, the detail says so (“ArcLatch cannot open the model folders in …”) and puts **Retry**, **Choose Model Folder…**, and **Use ~/AI/models** next to the words, rather than reporting an empty library. A model you picked by hand stays listed while the folder browse is blocked.
- **Parallel startup.** Every provider bootstraps at the same time, so one provider walking a slow tree cannot keep the others from listing their models.
- **Rescan.** The **Rescan** button forces one fresh walk of the library — a single walk for the whole app, not one per provider — and then refreshes every provider that lists library models, which is how a model you just added, renamed, or deleted shows up (or disappears). The button reads **Scanning…** while it runs and repeated clicks coalesce into one extra walk rather than stacking scans; automatic background refreshes reuse the last scan so they stay cheap. Discovery runs off the UI thread, and if you change folders while a walk is running, its results are discarded instead of landing in the wrong list.
- **Not scanned.** Provider-owned stores stay with their provider: Ollama tags come from the Ollama API, and Splash presets come from Splash’s own install records.

## Splash: relaunching an installed preset

The **Model** picker lists validated GGUF bundles from Splash’s own install records. Bundles that link to the same assets appear once. Vision and text-only configurations appear separately when both are installed.

A Splash preset that is already on disk is relaunched **from those files**, with no Hub access. ArcLatch reads Splash’s resolved-bundle manifest for the installed model id, then passes the local route:

```
splash serve \
  --model ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:IQ3_S \
  --model-dir /Users/you/AI/models/strata/IQ3_S \
  --offline --host 127.0.0.1 \
  --mmproj /Users/you/AI/models/strata/mmproj-Qwen3.8-Flash-Next-BF16.gguf \
  --max-context 65536 --port 8000
```

- `--model` stays the model id clients expect on that port; with `--model-dir` present, Splash takes the files from `--model-dir` and reports that id on the API. Nothing resolves a remote repository, so a cold **Start** works offline.
- `--mmproj` and `--draft-model` are passed only when the bundle (or your **Advanced settings** choice) actually has those local files. `--revision` is never combined with `--model-dir`.
- **Before** launching, ArcLatch checks the bundle’s files. If a shard, projector, or the model folder itself is gone, the setup checklist and the area beside **Start** name the missing path and offer the recovery action (**Choose model files…**, **Use preset**); the raw engine output stays under **Recent logs**.
- The **Extra arguments** field cannot override these invariants. Reserved flags (`--model`, `--model-dir`, `--offline`, `--host`, `--port`, `--max-context`, `--max-memory`, `--draft-model`, `--mmproj`, `--revision`, …) are rejected with a list of what to remove.

## Ollama: the Homebrew service

- **Start** and **Stop** run `brew services start ollama` and `brew services stop ollama`. ArcLatch never runs `ollama serve` itself.
- The service is recognized by its **LaunchAgent identity** — `homebrew.mxcl.ollama` (older Homebrew releases used `sh.brew.ollama`), queried as `launchctl print gui/<uid>/homebrew.mxcl.ollama` — not by whether the port answers. A port says a server is up; registration says the service still exists, which is the question that matters while it is still starting or stopping.
- Ownership is kept **until the service manager confirms the agent is gone**. If a stop request completes while the agent is still registered or still stopping, ArcLatch says so, keeps the provider under **Stop**, and a quit is refused rather than leaving a half-stopped service behind.
- A service ArcLatch did not start is left alone: cancel, a failed start, and quit never stop it. An explicit **Stop** is offered only for a service ArcLatch recognizes as the Homebrew one.
- The port comes from the service’s own configuration (`OLLAMA_HOST`, else Ollama’s default `11434`) and is read-only in ArcLatch.

## Runtime options

Structured fields under **Advanced settings** map to each server’s own flags:

| Provider | Options ArcLatch sets |
| --- | --- |
| **Splash** | context length → `--max-context`, memory cap → `--max-memory <n>G`, model folder → `--model-dir`, projector → `--mmproj`, draft → `--draft-model` |
| **llama.cpp** | context → `-c`, GPU layers → `-ngl`, threads → `-t` |
| **MLX-LM** | max tokens → `--max-tokens`, temperature → `--temp`, approved custom code → `--trust-remote-code` |
| **Ollama** | none: tags and service configuration belong to Ollama |

Every field starts **empty**, which means the engine’s own default: ArcLatch never writes a number into a profile by itself. Under those fields, **Runtime options** offers what ArcLatch would suggest for the model you have selected on this Mac, with **Use recommended** and **Use engine defaults** beside it. Each field’s hint shows its recommended number, and the line above the buttons says where it came from. Applying a recommendation sets every field that provider shows — empty where the advice is “leave this to the engine” — and each value then goes through the same validation as a typed one.

| Provider | What is suggested, and why |
| --- | --- |
| **Splash** | context length, plus a `--max-memory` budget measured from the preset bundle’s own manifest (target shards, projector, draft) with cache and 25% headroom. No budget is offered when the model is larger than 75% of RAM or its files cannot be measured: a cap smaller than the model turns a start that would work into an out-of-memory failure, so the safer advice is to leave it to Splash. |
| **llama.cpp** | context length only. `-c` defaults to the model’s own context, which for a 262K-context model means an enormous cache; `-ngl` and `-t` stay on auto, which this build sizes better than a fixed count. |
| **MLX-LM** | 1,024 tokens per reply and temperature 0.7. |
| **Ollama** | nothing: those options live in the Homebrew service’s own environment. |

Suggestions are measured, not looked up: weights come from the selected model’s files, RAM from the machine, and the cache cost from the same 0.15 MB/token estimate the “may not fit” line uses. Suggested context is the largest of 32,768 / 16,384 / 8,192 / 4,096 / 2,048 whose cache stays under 35% of RAM and which, with the weights, stays under 80%. Change the model and the suggestion changes with it; press **Use recommended** and it lands in your saved profile.

## Server behavior

ArcLatch uses loopback addresses by default. An existing server ArcLatch recognizes is shown as running externally; ArcLatch can test it and copy its URL. The memory-fit estimate (“may not fit”) appears **before** a server is up; once a server is running or ready, the detail pane shows server state and the last test result instead. A passing test is reported with the short model name (**Test passed · Qwen3-8B**), with the full path or model id in the selectable line beneath it.

Profiles are saved in `~/Library/Application Support/ArcLatch/profiles.json`. Defaults are the same on every Mac; use the file pickers and Settings to point ArcLatch at your own installation.

### Troubleshooting

- **No models found.** Read the line under the model list. **No model folder chosen yet** means pick one (**Choose Model Folder…**, or **Settings**). “No models found in …” means that folder really holds nothing that provider can serve — check the folder, and remember models must sit within 5 folders of it. “ArcLatch cannot open the model folders in …” means macOS withheld them or the disk is not mounted: press **Retry**, grant access under System Settings → Privacy & Security → Files and Folders, or choose another folder. “Partial scan” means the walk ran out of its time budget: press **Rescan**.
- **Needs setup.** Check the executable and model paths. For Splash, follow the message beside **Start**: it names the missing file or folder, and **Choose model files…** re-points at a local bundle.
- **Port in use.** Check whether the provider is already running. If an unrelated app holds the port, choose a different port under **Advanced settings** where supported. Ollama’s Homebrew-managed port is read-only in ArcLatch.
- **Server ready, test failed.** The API is reachable, but the model may have failed to load or generate. Check the test message and **Recent logs**. For large models, check the RAM strip and try one model at a time.
- **A service will not stop.** If ArcLatch reports that a service is still registered, use **Stop** again or stop it through Homebrew; ArcLatch keeps the provider in view until the cleanup is confirmed.

## Development

ArcLatch uses SwiftUI for the interface and AppKit for the window and application lifecycle. Provider adapters, process management, and memory sampling live in [ArcLatchCore](Sources/ArcLatchCore). The app and its command-line verification entry point live in [ArcLatchApp](Sources/ArcLatchApp).

```sh
make test    # or: swift test
```

The suite is portable and hermetic: it needs **no provider installed or running**, no personal model folders or saved settings, and no calls to `brew` or `launchctl` (the service manager sits behind an injectable shim, and launch fixtures are the standard `/bin/sh` and `/bin/sleep` helpers). Fixtures live under `/private/tmp`, and listeners use high test ports. Nothing requires a Mac that matches the development machine.

Two checks do contact a real Splash installation and are skipped unless you ask for them:

```sh
ARC_LATCH_LIVE=1 make test    # or: ARC_LATCH_LIVE=1 swift test
```

An empty model list is otherwise indistinguishable from a healthy start, so a scan trace is available for bug reports. It prints the startup order, each folder the walk enters at the top level, every folder that refused to open, and the scan totals:

```sh
ARC_LATCH_DEBUG_SCAN=1 open --stderr /tmp/arclatch-scan.log build/ArcLatch.app
```

If a Command Line Tools update removes the Swift Testing macro plugin symlink, build tests with `make check-fallback` instead; [Package.swift](Package.swift) keeps the flag that makes that work and is otherwise left alone.

A passing suite covers simulated lifecycle failures, offline launch planning, memory sampling, and library scanning. A provider is still treated as verified only after a real local generation: start it with **Start** in the app and run **Test model** against your own model.
