# Localpen

A native macOS notch writing assistant and knowledge tool with local AI inference.

Select text in an app, press **Control + Option + Space**, and proofread, polish,
change tone, shorten, or draft a reply. Without a selection, the notch opens a hub
for questions, notes, people, and quick captures.

**Experimental.** Built for personal use and designed around notched MacBooks.
Setup requires a local build and a compatible llama.cpp server. Localpen is a
working name.

## What it does

- Rewrites selected text and lets you review changes before pasting it back.
- Supports follow-up conversations and learns a writing-style profile from local history.
- Searches a local Markdown vault and uses relevant passages to ground answers.
- Offers optional file, calendar, mail, and screen-text context.
- Can curate vault notes and queue suggestions for review. Use a backed-up vault.

## Build from source

You need macOS 14 or later, full Xcode with its macOS SDK, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen). Apple Silicon is the primary
hardware target. Command Line Tools alone are not enough to build the app.

### 1. Supply llama-server

Build a compatible [llama.cpp server](https://github.com/ggml-org/llama.cpp/tree/master/tools/server)
using its [build instructions](https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md).
A static build (`-DBUILD_SHARED_LIBS=OFF`) avoids having to package llama.cpp's
shared libraries separately. Copy the executable into the resource directory:

```sh
cp /path/to/llama.cpp/build/bin/llama-server Localpen/Resources/llama-server
chmod +x Localpen/Resources/llama-server
Localpen/Resources/llama-server --version
```

The server and model weights are not checked in. If using a dynamically linked
server, its dependent libraries must also be available at runtime. The project
does not currently pin or automate the llama.cpp build. Check compatibility with
the flags in `Localpen/Services/LlamaServerController.swift`.

### 2. Generate and build the Xcode project

From the repository root:

```sh
xcodegen generate
open Localpen.xcodeproj
```

Select the **Localpen** scheme and build in Xcode. Dependencies resolve through
Swift Package Manager. The default configuration uses ad-hoc signing, without a
personal development team or certificate. For a stable signed installation,
configure your own signing identity locally.

On first launch, grant Accessibility access and download the default Qwen 2.5 7B
Instruct model. Allow roughly 4.7 GB for its weights, plus working memory.
The model catalog is `Localpen/Resources/models.toml`.

### 3. Run tests

```sh
xcodebuild test -project Localpen.xcodeproj -scheme Localpen -destination 'platform=macOS'
```

Personal-vault integration tests are disabled by default. They require explicit
`LOCALPEN_RUN_VAULT_TESTS=1` in the test process environment, a private vault,
local evaluation data, and an embedding server. The ordinary tests use temporary
fixtures. See [`scripts/bench/`](scripts/bench/) for inference benchmarks.

## Data and permissions

Inference runs on this Mac. Model downloads access Hugging Face. Optional calendar
feeds are fetched directly from the URLs you configure. There is no cloud model
backend or analytics service.

Localpen saves interactions and conversations under
`~/Library/Application Support/Localpen/`. Logs are under
`~/Library/Logs/Localpen/`. These files can contain private data. History settings
provide export and clear controls.

Accessibility enables clipboard-based selection capture and paste-back.
Clipboard managers may retain the text copied during those operations. Optional
mail and screen context require the corresponding macOS privacy grants.

The knowledge feature is off by default. Configure its vault path in Settings
before enabling it. The current default is `~/Documents/cxkb`. The search index is
a local cache of your Markdown files. Curation can write to those files, so keep
backups or version control.

## Repository contents

The published tree contains app and CLI source, tests, and build scripts. Internal
specs, plans, design notes, agent settings, personal evaluation data, and local
signing configuration are excluded. Existing Git history has not been scrubbed
and still contains earlier internal files.

No project license has been selected yet.
