# Localpen

A macOS notch writing assistant powered by llama.cpp.

Select text and press Control + Option + Space to proofread, polish, change tone,
shorten, or draft a reply. Review the diff, then paste back into the source app.

- Follow-up conversations and a writing-style profile learned from local history.
- Markdown vault search, with relevant passages included in answers.
- Optional context from files, calendar feeds, mail, and screen text.
- Note capture and vault curation.

## Build

Requires macOS 14 or later, full Xcode, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen). Apple Silicon is the primary target.

Build a compatible [llama.cpp server](https://github.com/ggml-org/llama.cpp/tree/master/tools/server)
using the [build instructions](https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md).
Use `-DBUILD_SHARED_LIBS=OFF` to avoid packaging llama.cpp's shared libraries separately.

```sh
cp /path/to/llama.cpp/build/bin/llama-server Localpen/Resources/llama-server
chmod +x Localpen/Resources/llama-server
Localpen/Resources/llama-server --version
```

The binary and model weights are not included. Dynamic builds require their shared
libraries at runtime. Check server compatibility with the flags in
`Localpen/Services/LlamaServerController.swift`.

From the repository root:

```sh
xcodegen generate
open Localpen.xcodeproj
```

Build the Localpen scheme. The default configuration uses ad-hoc signing.
First launch requires Accessibility access and a Qwen 2.5 7B Instruct download
(about 4.7 GB). The model catalog is `Localpen/Resources/models.toml`.

## Tests

```sh
xcodebuild test -project Localpen.xcodeproj -scheme Localpen -destination 'platform=macOS'
```

Real-vault tests require `LOCALPEN_RUN_VAULT_TESTS=1` in the test process environment,
a private vault, local evaluation data, and an embedding server. They are disabled
by default. Inference benchmarks are in [`scripts/bench/`](scripts/bench/).

## Data and permissions

Inference runs locally. Model downloads access Hugging Face. Optional calendar
feeds are fetched from configured URLs. There is no cloud model backend or analytics.

Conversations and interactions are stored in `~/Library/Application Support/Localpen/`.
Logs are stored in `~/Library/Logs/Localpen/`. History can be exported or cleared
in Settings. Both history and logs can contain private data.

Accessibility enables clipboard-based capture and paste-back. Clipboard managers
may retain copied text. Mail and screen context require separate macOS permissions.

Vault search is off by default. Configure the path in Settings before enabling it
(default `~/Documents/cxkb`). Curation writes to vault files. Keep backups or use
version control.
