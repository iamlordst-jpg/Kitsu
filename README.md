# Kitsu

A minimal, sideloadable iOS browser built for web-only Ren'Py and WebAssembly games.

Kitsu wraps Apple's WKWebView in a single-tab app focused on keeping games running and saves intact.

## Features

- URL bar that adds `https://` automatically
- Desktop mode (on by default, toggle in Settings)
- Persistent storage, so IndexedDB / localStorage saves survive relaunches
- Automatic reload when iOS kills the page for memory, with a crash counter in Settings
- Audio unlock on first touch
- Zoom blocking so taps register as clicks
- Fullscreen mode (tap the faint X in the top right to exit)
- Single tab, so links that open new tabs load in the same view and save memory
- "Clear site data" button in Settings

## Limitations

- iOS can still kill a game that uses too much memory. Kitsu recovers afterward, but unsaved progress is lost.
- The JIT and More RAM toggles are placeholders. Web pages on iOS already get JIT, and the app's memory setting does not raise the page's limit.
- No bookmarks, history, tabs, or downloads yet.
- Very large games (for example multi-GB WebAssembly ports) will not run.

## Build the IPA on GitHub (no Mac needed)

1. Push this repo to GitHub. Make it public so you get free macOS build minutes.
2. Open the **Actions** tab, choose **Build IPA**, and tap **Run workflow**.
3. When the run finishes (about 3 to 5 minutes), open it and download the **Kitsu-ipa** artifact.
4. Unzip it to get `Kitsu.ipa`.

## Install

Sideload `Kitsu.ipa` with one of:

- AltStore or SideStore
- Sideloadly
- TrollStore (if your iOS version supports it)

The IPA is unsigned on purpose. Your sideloader signs it with your Apple ID. Free Apple ID signatures expire after 7 days, so re-sign weekly (AltStore and SideStore can do this automatically).

If you have an older build installed, delete it first so the new name and icon show up.

## Repo layout

```
.github/workflows/build.yml   GitHub Actions build
GameBrowser/GameBrowserApp.swift   The whole app (SwiftUI + WKWebView)
make_icon.py                  Generates the app icon during the build
project.yml                   XcodeGen project definition
```

## Customize

- **Name:** change `CFBundleDisplayName` and `PRODUCT_NAME` in `project.yml`, and the two `Kitsu` mentions in `build.yml`.
- **Icon colors:** edit `C1` and `C2` near the top of `make_icon.py`.
- **Bundle ID:** change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` if your sideloader needs a unique one.

## Troubleshooting

- **"This check has no steps":** the job never got a runner. Make the repo public and rerun the workflow.
- **"Configuration ... is not supported":** the macOS runner image was retired. Set `runs-on: macos-latest` in `build.yml`.
- **Blank page in a game:** usually a memory kill. Check the crash counter in Settings.
- **Game is silent:** tap once on the page to unlock audio.
