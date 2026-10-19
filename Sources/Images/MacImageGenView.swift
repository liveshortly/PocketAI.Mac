import SwiftUI
import AppKit
import PocketKit
import PocketUI
import PocketImageGen

/// MAC-12: Image generation window for Mac with prompt controls and history grid.
/// Offline on-device SDXL Turbo generator with rich macOS UI.
public struct MacImageGenView: View {
    @Environment(AppModel.self) private var model

    public struct GeneratedImageItem: Identifiable {
        public let id = UUID()
        public let prompt: String
        public let image: NSImage
        public let timestamp: Date
    }

    @State private var prompt = ""
    @State private var size = 512
    @State private var steps = 2
    @State private var isGenerating = false
    @State private var progressText: String?
    @State private var errorMessage: String?
    @State private var history: [GeneratedImageItem] = []
    @State private var selectedImage: GeneratedImageItem?
    @State private var generator: PocketImageGenerator?
    @State private var copiedFeedback = false

    public init() {}

    public var body: some View {
        HSplitView {
            // Left: Prompt Controls & Current Output
            VStack(alignment: .leading, spacing: PocketSpacing.s16) {
                // Header
                VStack(alignment: .leading, spacing: 2) {
                    Text("Image Generation")
                        .font(.pocket(.title))
                        .fontWeight(.bold)
                        .foregroundStyle(PocketColor.textPrimary)

                    Text("On-device SDXL Turbo generation running entirely offline.")
                        .font(.pocket(.callout))
                        .foregroundStyle(PocketColor.textSecondary)
                }

                // Prompt Input Box
                VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                    TextField("Describe an image in detail (e.g. A serene mountain lake at sunrise)…", text: $prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.pocket(.body))
                        .lineLimit(2...4)
                        .padding(PocketSpacing.s8)
                        .background(PocketColor.bgSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(PocketColor.lineHairline, lineWidth: 0.8)
                        )

                    HStack(spacing: PocketSpacing.s16) {
                        Picker("Size", selection: $size) {
                            Text("512 × 512").tag(512)
                            Text("768 × 768").tag(768)
                            Text("1024 × 1024").tag(1024)
                        }
                        .frame(width: 150)

                        Picker("Steps", selection: $steps) {
                            Text("1 step").tag(1)
                            Text("2 steps (fast)").tag(2)
                            Text("4 steps").tag(4)
                        }
                        .frame(width: 150)

                        Spacer()

                        Button {
                            generate()
                        } label: {
                            if isGenerating {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Generating…")
                                }
                            } else {
                                Label("Generate", systemImage: "sparkles")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(PocketColor.accent)
                        .controlSize(.large)
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
                    }
                }
                .padding(PocketSpacing.s16)
                .background(PocketColor.bgRaised)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(PocketColor.lineHairline, lineWidth: 0.8)
                )

                if let progressText {
                    HStack(spacing: PocketSpacing.s8) {
                        ProgressView().controlSize(.small)
                        Text(progressText)
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.accent)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.statusBad)
                }

                Divider()

                // Display Selected or Latest Output
                if let display = selectedImage ?? history.first {
                    VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                        Image(nsImage: display.image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 512, maxHeight: 512)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(PocketColor.lineHairline, lineWidth: 0.8)
                            )
                            .shadow(color: Color.black.opacity(0.06), radius: 8, y: 3)

                        HStack {
                            Text(display.prompt)
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.textSecondary)
                                .lineLimit(2)

                            Spacer()

                            Button {
                                copyToClipboard(display.image)
                                copiedFeedback = true
                                Task {
                                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                                    copiedFeedback = false
                                }
                            } label: {
                                Label(copiedFeedback ? "Copied" : "Copy", systemImage: copiedFeedback ? "checkmark" : "doc.on.doc")
                                    .font(.pocket(.caption))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Save…") {
                                saveImage(display.image, defaultName: "pocketai-\(display.id.uuidString.prefix(8)).png")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: PocketSpacing.s12) {
                        Spacer()
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 44))
                            .foregroundStyle(PocketColor.accent)
                        Text("On-device SDXL Turbo generator")
                            .font(.pocket(.headline))
                            .foregroundStyle(PocketColor.textPrimary)
                        Text("Describe any scene above and click Generate to synthesize images completely offline.")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(PocketSpacing.gutterMac)
            .frame(minWidth: 440)
            .background(PocketColor.bgCanvas)

            // Right: History Grid
            VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                HStack {
                    Text("HISTORY")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PocketColor.textTertiary)
                    Spacer()
                    Text("(\(history.count))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PocketColor.accent)
                }

                Divider()

                if history.isEmpty {
                    VStack {
                        Spacer()
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 28))
                            .foregroundStyle(PocketColor.textTertiary)
                        Text("No generated images yet")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textTertiary)
                            .padding(.top, 4)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
                            ForEach(history) { item in
                                Image(nsImage: item.image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 90, height: 90)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(selectedImage?.id == item.id ? PocketColor.accent : PocketColor.lineHairline, lineWidth: selectedImage?.id == item.id ? 2 : 0.5)
                                    )
                                    .onTapGesture {
                                        selectedImage = item
                                    }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(PocketSpacing.s16)
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
            .background(PocketColor.bgSurface)
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    private func generate() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isGenerating = true
        errorMessage = nil
        progressText = "Preparing image generator…"

        Task {
            do {
                if generator == nil {
                    generator = PocketImageGenerator(conserveMemory: false)
                }
                guard let gen = generator else { return }

                progressText = "Generating \(steps) step\(steps == 1 ? "" : "s")…"
                let cgImage = try await gen.generate(prompt: trimmed, size: size, steps: steps) { step, total, _ in
                    Task { @MainActor in
                        self.progressText = "Step \(step) of \(total)…"
                    }
                }

                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
                let item = GeneratedImageItem(prompt: trimmed, image: nsImage, timestamp: Date())
                history.insert(item, at: 0)
                selectedImage = item
                isGenerating = false
                progressText = nil
            } catch {
                isGenerating = false
                progressText = nil
                errorMessage = "Generation error: \(error.localizedDescription)"
            }
        }
    }

    private func copyToClipboard(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    private func saveImage(_ image: NSImage, defaultName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [.png, .jpeg]

        if panel.runModal() == .OK, let url = panel.url {
            if let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let pngData = rep.representation(using: .png, properties: [:]) {
                try? pngData.write(to: url)
            }
        }
    }
}
