# Kitsu

A sideloadable iOS browser built for web-only Ren'Py and WebAssembly games, with a fast parallel download manager.

Kitsu wraps Apple's WKWebView in a single-tab app focused on keeping games running, saves intact, and big files downloading quickly.

## Features

### Games (Ren'Py and WebAssembly)
- **Real fullscreen on iPhone.** iPhone has no browser fullscreen API for games, so Kitsu fakes it: a game's own fullscreen button (including games embedded in iframes, like itch.io) stretches the game over the whole screen, hides the status bar and home indicator, and letterboxes instead of stretching.
- Optional landscape lock in fullscreen, screen stays awake while fullscreen, back-swipe disabled in fullscreen
- Automatic reload when iOS kills the page for memory
- **Crash-loop guard:** after 3 crashes in 90 seconds Kitsu stops reloading and offers Retry or Close page
- Memory warnings clear WebKit's memory cache
- Persistent storage, so IndexedDB / localStorage saves survive relaunches
- Audio unlock on first touch, touch fixes (no zoom, no long-press callouts, no tap highlight)
- Desktop mode (off by default, applies on the next page load)
- Optional ad and tracker blocking and script-popup blocking, which saves memory and stops ads from hijacking a game page
- Single tab, plus a bookmarks list and a search-or-URL bar

### Downloads
- **Parallel segmented downloads:** files are split into many chunks (4 to 64 MB) and fetched at the same time with HTTP range requests, 16 connections by default (4 to 32 in Settings)
- **Direct disk writes:** every finished chunk is written straight into its place in the final file, so a 20 GB download never sits in memory and needs little extra space beyond the file itself
- **Background downloads:** uses an iOS background session, so downloads keep going when you leave the app
- **Resume:** progress is saved, so a crash, relaunch, or dropped connection continues where it left off. Pause and Resume buttons too.
- **Automatic capture:** attachments, zips, and any file the page can't display are handed to the download manager, using the page's cookies and referer so logged-in downloads work. Downloads from blob: or data: links are saved by WebKit directly.
- **Paste a URL** in the Downloads sheet to download any file
- Live speed, ETA, free-space check before starting, retry on failed parts, and a notification when a download finishes
- **Saved to the Files app:** Files › On My iPhone › Kitsu › Downloads, with a Share button on finished items

## Speed: what to expect

Kitsu can't download faster than your connection or the server allows. It stops wasting the speed you have.

- 20 GB in 10 minutes needs about 270 Mbps sustained (about 33 MB/s). That is realistic on fast Wi-Fi with a fast server or CDN.
- 2 GB in seconds needs 1 to 2 Gbps. An iPhone 11's Wi-Fi tops out far below that in practice, so expect about 40 to 60 seconds at best.
- Servers that cap total speed per user, or that don't support range requests, can't be sped up. Kitsu tells you when a server only allows one connection.
- A 20 GB file needs at least that much free storage.

## Limitations

- iOS can still kill a game that uses too much memory. Kitsu recovers afterward, but unsaved progress is lost.
- Not yet built: save backup/export for IndexedDB, per-site settings, tabs, history.
- The "JIT" and "More RAM" ideas aren't included: web pages on iOS already get JIT, and no app setting raises the page's memory limit.
- Very large games (for example multi-GB WebAssembly ports) will not run.
- The first run of this code hasn't been verified on a device. If a GitHub build fails, the error lines show what to fix.

## Build the IPA on GitHub (no Mac needed)

1. Push this repo to GitHub. Make it public so you get free macOS build minutes.
2. Open the **Actions** tab, choose **Build IPA**, and tap **Run workflow**.
3. When the run finishes (about 3 to 5 minutes), open it and download the **Kitsu-ipa** artifact.
4. Unzip it to get `Kitsu.ipa`.

## Install

Sideload `Kitsu.ipa` with AltStore, SideStore, Sideloadly, or TrollStore. The IPA is unsigned on purpose; your sideloader signs it with your Apple ID. Free Apple ID signatures expire after 7 days, so re-sign weekly (AltStore and SideStore can do this automatically).

If you have an older build installed, delete it first so the new name and icon show up.

## Repo layout

```
.github/workflows/build.yml        GitHub Actions build
GameBrowser/GameBrowserApp.swift   Browser, fullscreen, game fixes, settings, bookmarks
GameBrowser/Downloads.swift        Download manager and Downloads screen
make_icon.py                       Generates the app icon during the build
project.yml                        XcodeGen project definition
```

## Customize

- **Name:** change `CFBundleDisplayName` and `PRODUCT_NAME` in `project.yml`, and the two `Kitsu` mentions in `build.yml`.
- **Icon colors:** edit `C1` and `C2` near the top of `make_icon.py`.
- **Bundle ID:** `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` (currently `com.browser.kitsu`). Sideloaders may rewrite it when signing.
- **Download connections:** Settings › Downloads (restart the app to apply).

## Troubleshooting

- **"This check has no steps":** the job never got a runner. Make the repo public and rerun the workflow.
- **"Configuration ... is not supported":** set `runs-on: macos-latest` in `build.yml`.
- **Blank page in a game:** usually a memory kill. Check the crash counter in Settings.
- **Game is silent:** tap once on the page to unlock audio.
- **Fullscreen looks wrong:** exit with the faint X in the top right and tell us which game.
- **Download is slow:** the server may be limiting speed. Try raising connections in Settings, or check whether the toast said the server allows only one connection.
- **Download says "range requests" error:** the server stopped supporting resume partway. Tap Retry.
