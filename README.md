# Localpen

A writing assistant that lives in your Mac's notch and runs locally with llama.cpp.

Select some text, press Control + Option + Space, and pick what you want to do with
it. Proofread, polish, change the tone, shorten it, or draft a reply. You can review
the changes before pasting them back. Open it without a selection to ask questions,
search your notes, or jot something down.

I built this for myself. It's still experimental, setup is manual, and Localpen is
a working name. The UI is designed around notched MacBooks.

## What else it does

- Keeps conversations so you can follow up, and learns your writing style from local history.
- Searches a Markdown vault and pulls relevant passages into answers.
- Lets you add context from files, your calendar, mail, or text on screen.
- Can update vault notes and suggest changes for review. Keep a backup of your vault.

## Running it

You'll need macOS 14 or later, full Xcode, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen). Apple Silicon is the main target.
Command Line Tools alone won't build the app.

### Set up llama-server

Build a compatible [llama.cpp server](https://github.com/ggml-org/llama.cpp/tree/master/tools/server)
following the [build instructions](https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md).
A static build (`-DBUILD_SHARED_LIBS=OFF`) saves you from packaging llama.cpp's
shared libraries separately. Then copy the executable into the repo:

```sh
cp /path/to/llama.cpp/build/bin/llama-server Localpen/Resources/llama-server
chmod +x Localpen/Resources/llama-server
Localpen/Resources/llama-server --version
```

The server and model weights aren't checked in. If you use a dynamically linked
server, its libraries need to be available at runtime too. I haven't pinned or
automated the llama.cpp build yet. Check that your version supports the flags in
`Localpen/Services/LlamaServerController.swift`.

### Build the app

From the repo root:

```sh
xcodegen generate
open Localpen.xcodeproj
```

Choose the Localpen scheme and build. Xcode resolves the Swift packages for you.
The default is ad-hoc signing, so you don't need a development team or certificate.
For a stable signed installation, set up your own signing identity locally.

On first launch, grant Accessibility access and download Qwen 2.5 7B Instruct.
The weights take about 4.7 GB of disk space, and you'll need RAM to run the model.
The model catalog is in `Localpen/Resources/models.toml`.

### Tests

```sh
xcodebuild test -project Localpen.xcodeproj -scheme Localpen -destination 'platform=macOS'
```

The regular tests use temporary fixtures. Tests against a real vault are off by
default. To run those, set `LOCALPEN_RUN_VAULT_TESTS=1` in the test process
environment. You'll also need the private vault, local evaluation data, and an
embedding server. Inference benchmarks are in [`scripts/bench/`](scripts/bench/).

## Your data

The model runs on your Mac. Downloads come from Hugging Face, and optional calendar
feeds are fetched directly from the URLs you add. There's no cloud model backend
or analytics service.

Chats and interactions are saved in `~/Library/Application Support/Localpen/`.
Logs go in `~/Library/Logs/Localpen/`. These files can contain private data. You can
export or clear history in Settings.

Localpen uses Accessibility permission to copy selected text and paste results
back. Clipboard managers may keep copies of that text. Mail and screen context
need their own macOS privacy permissions.

Vault search is off by default. Set your vault path in Settings before turning it
on. It defaults to `~/Documents/cxkb`. The search index is a local cache of your
Markdown files, but curation can write to the files themselves. Keep backups or
use version control.

## License

I haven't picked a license yet.
