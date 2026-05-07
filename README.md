<p align="center">
  <img src="BadPhotosOut/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="160" alt="BadPhotosOut icon">
</p>

# BadPhotosOut

A native macOS app that walks your Apple Photos library, asks a local Ollama vision model to judge each photo against a free-text criterion you supply, and surfaces the flagged photos with the model's reason. **No automatic deletion** — you review the list and delete in Photos manually.

Nothing leaves the Mac: photos are read via PhotoKit and sent only to a local Ollama server.

> ⚠️ **Disclaimer:** this app is vibe-coded. No warranty, no support, no guarantees about correctness, performance, or your photo library. Use at your own risk — you are solely responsible for any photos you choose to delete based on what this app shows you.

## Setup

### 1. Install Ollama and pull a vision model

```sh
brew install ollama
ollama serve   # in one terminal, leave running
ollama pull llava   # in another terminal; or any other vision model
```

### 2. Generate the Xcode project

```sh
brew install xcodegen   # if not already installed
xcodegen generate
```

This produces `BadPhotosOut.xcodeproj`.

### 3. Build and run

Either open the project in Xcode and hit Run, or from the command line:

```sh
xcodebuild -project BadPhotosOut.xcodeproj -scheme BadPhotosOut -configuration Debug build
open build/Debug/BadPhotosOut.app   # path may differ depending on derived data location
```

On first run macOS will ask for Photos access. Grant it.

### 4. Use it

1. In the sidebar, confirm the Ollama endpoint (`http://localhost:11434`) and pick a model (e.g. `llava:latest`). Click **Test connection** to populate the model dropdown.
2. Type a criterion: e.g. `blurry, dark, or accidental shots`.
3. Choose a scope (last N days / specific album / entire library). For a first try, scope to a small album.
4. Click **Start analysis**. Photos stream into the grid with a colored badge (green = keep, red = flagged, yellow = failed).
5. Click any photo to see the full image and the model's reason. Click **Reveal in Photos** to open Photos.app — the filename is copied to the clipboard so you can paste it into Photos' search.

Results are cached per (asset × prompt × model) under `~/Library/Containers/com.veli.badphotosout/Data/Library/Application Support/BadPhotosOut/cache.json`, so re-running with the same settings is fast.

## Out of scope

- No automatic deletion or moving of photos.
- No video analysis (images only).
- No multi-photo / album-level reasoning — one photo per request.
- No cloud LLMs — Ollama only.
