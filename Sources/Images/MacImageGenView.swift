import SwiftUI
import AppKit
import PocketKit
import PocketUI
import PocketImageGen

/// MAC-12: Image generation window for Mac with prompt controls and history grid.
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

    public init() {}

    public var body: some View {
        HSplitView {
            // Left: Generation controls & current output
            VStack(alignment: .leading, spacing: PocketSpacing.s16) {
                Text("Generate Image").font(.pocket(.title))

                TextField("Describe an image to generate…", text: $prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)

                HStack(spacing: PocketSpacing.s16) {
                    Picker("Size", selection: $size) {
                        Text("512 × 512").tag(512)
                        Text("768 × 768").tag(768)
                        Text("1024 × 1024").tag(1024)
                    }
                    .frame(width: 160)

                    Picker("Steps", selection: $steps) {
                        Text("1 step").tag(1)
                        Text("2 steps (fast)").tag(2)
                        Text("4 steps").tag(4)
                    }
                    .frame(width: 160)

                    Spacer()

                    Button {
                        generate()
                    } label: {
                        if isGenerating {
                            ProgressView().controlSize(.small)
                            Text("Generating…")
                        } else {
                            Label("Generate", systemImage: "sparkles")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
                }

                if let progressText {
                    Text(progressText)
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.accent)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.statusBad)
                }

                Divider()

                // Display selected or latest generated image
                if let display = selectedImage ?? history.first {
                    VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                        Image(nsImage: display.image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 512, maxHeight: 512)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        HStack {
                            Text(display.prompt)
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.textSecondary)
                                .lineLimit(2)
                            Spacer()
                            Button("Copy") {
                                copyToClipboard(display.image)
                            }
                            Button("Save…") {
                                saveImage(display.image, defaultName: "pocketai-\(display.id.uuidString.prefix(8)).png")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: PocketSpacing.s12) {
                        Spacer()
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 48))
                            .foregroundStyle(PocketColor.textTertiary)
                        Text("On-device SDXL Turbo image generation")
                            .font(.pocket(.headline))
                            .foregroundStyle(PocketColor.textSecondary)
                        Text("Enter a prompt and click Generate to create images completely offline.")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textTertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(PocketSpacing.s16)
            .frame(minWidth: 420)

            // Right: History grid
            VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                Text("History (\(history.count))").font(.pocket(.headline))

                if history.isEmpty {
                    VStack {
                        Spacer()
                        Text("No generated images yet")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textTertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                            ForEach(history) { item in
                                Image(nsImage: item.image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 100, height: 100)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(selectedImage?.id == item.id ? PocketColor.accent : Color.clear, lineWidth: 2)
                                    )
                                    .onTapGesture {
                                        selectedImage = item
                                    }
                            }
                        }
                    }
                }
            }
            .padding(PocketSpacing.s16)
            .frame(minWidth: 160, idealWidth: 200, maxWidth: 260)
        }
        .frame(minWidth: 720, minHeight: 520)
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
