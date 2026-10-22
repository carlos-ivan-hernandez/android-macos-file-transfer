# AM File Transfer

AM File Transfer (Android–macOS File Transfer) is a small native macOS app for copying files between a Mac and an Android phone over USB. It's
built for a Samsung Galaxy S25 but works with any Android phone that supports file transfer.

AM File Transfer uses [libmtp](https://github.com/libmtp/libmtp), the open-source library that
OpenMTP also uses to talk to Android phones. The app itself is SwiftUI.

## Requirements

- macOS 13 Ventura or later
- To build: Xcode or the Xcode command line tools (`xcode-select --install`), and an internet
  connection the first time

## Build

```bash
./scripts/build.sh               # creates "dist/AM File Transfer.app"
./scripts/build.sh --install     # also copies it into /Applications
./scripts/build-libmtp.sh        # once, before using swift directly:
swift run AMFileTransfer         # run without making an app bundle
swift test                       # run the tests
```

`build-libmtp.sh` downloads libusb and libmtp, checks them against known checksums, and builds
them into `.deps/` for macOS 13. They're linked into the app itself, so it runs on macOS 13 and
later without Homebrew. `build.sh` runs it for you, and it does nothing once `.deps/` is up to
date. To update either library, change its version and checksum at the top of the script. If
you change the app's minimum macOS version, change it in both `Package.swift` and the script.

## Connecting the phone

1. Plug the phone into the Mac with a USB cable.
2. Unlock the phone.
3. Swipe down from the top of the screen, tap the **USB** notification, and choose
   **File transfer**.
4. If the phone asks to allow access to phone data, tap **Allow**.

AM File Transfer looks for the phone every two seconds and opens it as soon as it can. If the
phone is unplugged, AM File Transfer notices right away (macOS tells it), stops any copy, and waits for
the phone to come back.

If AM File Transfer says another app is using the phone, quit OpenMTP, Android File Transfer,
Smart Switch, Image Capture, or Photos. macOS's photo import service (`ptpcamerad`) also
tends to claim Android phones as soon as they're plugged in. **Free Phone from macOS**
stops that service and opens the phone right away. macOS restarts the service by itself.

## Using it

- Pick a storage area (such as Internal storage) in the sidebar.
- Switch between **list** (⌘2) and **column** (⌘3) view with the toolbar's view buttons, as in
  Finder. AM File Transfer remembers your choice.
- In list view, double-click a folder to open it. In column view, click a folder to show its
  contents in the next column, and click a file to see its details. Use the path bar or ⌘↑
  to go back.
- In column view, the arrow keys work as in Finder: ↑ and ↓ move within a column, → goes into
  the highlighted folder, and ← goes back out. ⌘-click and ⇧-click select more than one item.
- Click a file or folder to see its size at the bottom of the window. A folder's size is added
  up from everything inside it, which can take a moment for big folders. Once known, it also
  shows in the list's Size column.
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
| `Sources/AMFileTransferKit/MTPConnection.swift` | The libmtp wrapper: connect, list, copy, create folders and delete |
| `Sources/AMFileTransferKit/Transfers.swift` | Copies and deletes whole folders, picks free names, and reports progress |
| `Sources/AMFileTransfer` | The SwiftUI app |
| `Sources/AMFileTransfer/USBRemovalWatcher.swift` | Gets a notification from macOS (IOKit) the moment the phone is unplugged |

libmtp isn't thread-safe, so every libmtp call runs on one serial queue. The copy and delete
logic works through a small `PhoneDevice` protocol, so the tests use an in-memory fake phone
instead of a real one.

Folder ID `0xFFFFFFFF` means the top of a storage. libmtp treats folder `0` as "choose a
default folder" (for example, DCIM for photos), so AM File Transfer always passes the explicit
value.

## App icon

The app's icon is [Support/AppIcon.png](Support/AppIcon.png). `build.sh` puts it on the macOS
icon grid (a rounded square with a shadow) by running
`AMFileTransfer icon <image> <output.icns>`. To change the icon, replace the image with a
square one, at least 512 px and ideally 1024 px, with no rounded corners of its own.
