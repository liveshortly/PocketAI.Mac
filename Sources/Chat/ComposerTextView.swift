import AppKit
import PocketUI
import SwiftUI

/// A real multi-line text editor for the composer.
///
/// SwiftUI's `TextField(axis: .vertical)` is a field, not a text area: on
/// macOS it fights over the Return key, loses the newline/submit distinction,
/// and gives no control over growth. This wraps `NSTextView` so the composer
/// behaves the way every chat app's does — Return sends, Shift-Return inserts
/// a newline, the box grows with the text and then scrolls, and the usual
/// editing (undo, select all, paste, spell check) just works.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Message…"
    var minHeight: CGFloat = 20
    var maxHeight: CGFloat = 180
    /// A counter, not a flag: every increment is one request to take the
    /// caret. A `Bool` latched true, so after the first grab (or after the
    /// user clicked away) ⌘L and the empty-state suggestions had nothing left
    /// to change and silently did nothing.
    var focusRequest: Int = 0
    var onSubmit: () -> Void
    var onEdit: () -> Void = {}
    /// Esc. Return true when it was used (stopped a reply, ended dictation);
    /// false leaves AppKit's own Esc (word completion) alone.
    var onEscape: () -> Bool = { false }
    /// Up-arrow in an empty box: the text to recall (the last message sent),
    /// the way a terminal or Slack does. Nil leaves the caret move alone.
    var onRecall: () -> String? = { nil }
    /// UI-67: focus in/out, so the composer can draw its focus ring.
    var onFocusChange: (Bool) -> Void = { _ in }
    /// UI-67: image files from the pasteboard. Return true when taken; false
    /// lets the normal paste run.
    var onPasteImages: ([URL]) -> Bool = { _ in false }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = ComposerNSTextView()
        textView.onFocusChange = { context.coordinator.parent.onFocusChange($0) }
        textView.onPasteImages = { context.coordinator.parent.onPasteImages($0) }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = NSColor(PocketColor.textPrimary)
        textView.insertionPointColor = NSColor(PocketColor.accent)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.placeholder = placeholder
        textView.placeholderColor = NSColor(PocketColor.textTertiary)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
        }
        textView.placeholder = placeholder
        // Claim focus only on a fresh request. Re-asserting it on every
        // update stole the caret back from wherever the user had clicked —
        // once per streamed token.
        if focusRequest != context.coordinator.servedFocusRequest {
            context.coordinator.servedFocusRequest = focusRequest
            if focusRequest > 0, textView.window?.firstResponder !== textView {
                DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
            }
        }
        context.coordinator.resize()
    }

    /// Height the editor wants for its current text, clamped to the range the
    /// composer allows. SwiftUI reads it through the coordinator.
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?
        weak var scrollView: NSScrollView?
        /// The last focus request acted on, so an update that carries no new
        /// request never re-steals first responder.
        var servedFocusRequest = 0

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            parent.onEdit()
            resize()
        }

        /// Return sends; Shift-Return (and Option-Return) insert a newline.
        func textView(
            _ textView: NSTextView, doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                return parent.onEscape()
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)), textView.string.isEmpty {
                guard let recalled = parent.onRecall(), !recalled.isEmpty else { return false }
                textView.string = recalled
                textView.setSelectedRange(NSRange(location: (recalled as NSString).length, length: 0))
                parent.text = recalled
                resize()
                return true
            }
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            if modifiers.contains(.shift) || modifiers.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            parent.onSubmit()
            return true
        }

        func resize() {
            guard let textView, let scrollView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer
            else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let height = min(
                max(used + textView.textContainerInset.height * 2, parent.minHeight),
                parent.maxHeight)
            if abs(scrollView.frame.height - height) > 0.5 {
                scrollView.setFrameSize(NSSize(width: scrollView.frame.width, height: height))
            }
            // Past the cap the box stops growing and starts scrolling.
            scrollView.hasVerticalScroller = used > parent.maxHeight
            if let heightConstraint = scrollView.constraints.first(where: {
                $0.firstAttribute == .height
            }) {
                heightConstraint.constant = height
            } else {
                scrollView.heightAnchor.constraint(equalToConstant: height).isActive = true
            }
        }
    }
}

/// `NSTextView` with a placeholder, which AppKit does not provide.
final class ComposerNSTextView: NSTextView {
    var placeholder: String = ""
    var placeholderColor: NSColor = .placeholderTextColor
    var onFocusChange: (Bool) -> Void = { _ in }
    var onPasteImages: ([URL]) -> Bool = { _ in false }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange(false) }
        return ok
    }

    /// `isRichText = false` makes AppKit ignore image data on paste. Take
    /// images (files copied in Finder, or raw image data) as attachments;
    /// anything with plain text still pastes as text.
    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if board.string(forType: .string) == nil {
            let files = (board.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingContentsConformToTypes: ["public.image"]]) as? [URL]) ?? []
            if !files.isEmpty, onPasteImages(files) { return }
            if let image = NSImage(pasteboard: board), let url = Self.writeTemp(image),
               onPasteImages([url]) { return }
        }
        super.paste(sender)
    }

    private static func writeTemp(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pasted image \(UUID().uuidString.prefix(8)).png")
        return (try? png.write(to: url)) == nil ? nil : url
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: placeholderColor,
        ]
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: attributes)
    }
}
