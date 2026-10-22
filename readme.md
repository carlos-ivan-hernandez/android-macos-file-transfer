# PhoneFiles

A small native macOS app for copying files between a Mac and an Android phone over USB. It's
built for a Samsung Galaxy S25 but works with any Android phone that supports file transfer.

PhoneFiles uses [libmtp](https://github.com/libmtp/libmtp), the open-source library that
OpenMTP also uses to talk to Android phones. The app itself is SwiftUI.

## Requirements

- macOS 13 Ventura or later
- To build: Xcode or the Xcode command line tools (`xcode-select --install`), and
  [Homebrew](https://brew.sh) for libmtp

## Build

```bash
brew install libmtp pkg-config   # once
./scripts/build.sh               # creates "dist/PhoneFiles.app"
./scripts/build.sh --install     # also copies it into /Applications
swift run PhoneFiles             # run without making an app bundle
swift test                       # run the tests
```

`build.sh` copies libmtp and libusb into the app, so the built app doesn't need Homebrew.

## Connecting the phone

1. Plug the phone into the Mac with a USB cable.
2. Unlock the phone.
3. Swipe down from the top of the screen, tap the **USB** notification, and choose
   **File transfer**.
4. If the phone asks to allow access to phone data, tap **Allow**.

PhoneFiles looks for the phone every two seconds and opens it as soon as it can.

If PhoneFiles says another app is using the phone, quit OpenMTP, Android File Transfer,
Smart Switch, Image Capture, or Photos. macOS's photo import service (`ptpcamerad`) also
tends to claim Android phones as soon as they're plugged in. **Free Phone from macOS**
stops that service and opens the phone right away. macOS restarts the service by itself.

## Using it

- Pick a storage area (such as Internal storage) in the sidebar.
- Double-click a folder to open it. Use the path bar or ⌘↑ to go back.
- Double-click a file to open a copy of it on the Mac.
- **Copy to Mac** (⇧⌘D) copies the selected files and folders to a folder you choose, then shows
  them in Finder.
- **Copy to Phone** (⇧⌘U) copies files and folders into the folder you're viewing. You can also
  drag them from Finder onto the window.
- **New Folder** (⇧⌘N) and **Delete** (⌘⌫) work on the folder you're viewing. Deleting from the
  phone can't be undone.

Copies never overwrite anything. If a name is already in use, the copy gets a number, like
`photo 2.jpg`. A copy can be cancelled at any time. A cancelled file is removed, and files that
finished copying are kept.

## How it's put together

| Folder | Contents |
| --- | --- |
| `Sources/CLibMTP` | Makes libmtp's C functions available to Swift |
| `Sources/PhoneFilesKit/MTPConnection.swift` | The libmtp wrapper: connect, list, copy, create folders and delete |
| `Sources/PhoneFilesKit/Transfers.swift` | Copies and deletes whole folders, picks free names, and reports progress |
| `Sources/PhoneFiles` | The SwiftUI app |

libmtp isn't thread-safe, so every libmtp call runs on one serial queue. The copy and delete
logic works through a small `PhoneDevice` protocol, so the tests use an in-memory fake phone
instead of a real one.

Folder ID `0xFFFFFFFF` means the top of a storage. libmtp treats folder `0` as "choose a
default folder" (for example, DCIM for photos), so PhoneFiles always passes the explicit
value.
