import Foundation
import IOKit
import IOKit.usb

/// Calls `onRemoved` on the main queue as soon as a USB device with the given IDs is unplugged.
/// macOS sends this notification right away, so there's no need to poll.
final class USBRemovalWatcher {
    private let onRemoved: () -> Void
    private var port: IONotificationPortRef?
    private var iterator: io_iterator_t = 0

    init?(vendorID: UInt16, productID: UInt16, onRemoved: @escaping () -> Void) {
        self.onRemoved = onRemoved
        guard let port = IONotificationPortCreate(kIOMainPortDefault),
              let cfMatching = IOServiceMatching("IOUSBHostDevice")
        else { return nil }
        self.port = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        let matching = cfMatching as NSMutableDictionary
        matching["idVendor"] = Int(vendorID)
        matching["idProduct"] = Int(productID)

        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, matching as CFDictionary,
            { context, iterator in
                guard let context else { return }
                let watcher = Unmanaged<USBRemovalWatcher>.fromOpaque(context).takeUnretainedValue()
                if USBRemovalWatcher.drain(iterator) { watcher.onRemoved() }
            },
            context, &iterator
        )
        guard result == KERN_SUCCESS else { return nil }
        // The notification only starts once the iterator has been emptied.
        Self.drain(iterator)
    }

    deinit {
        if iterator != 0 { IOObjectRelease(iterator) }
        if let port { IONotificationPortDestroy(port) }
    }

    /// Releases every device in the iterator. Returns whether there were any.
    @discardableResult
    private static func drain(_ iterator: io_iterator_t) -> Bool {
        var found = false
        var service = IOIteratorNext(iterator)
        while service != 0 {
            found = true
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return found
    }
}
