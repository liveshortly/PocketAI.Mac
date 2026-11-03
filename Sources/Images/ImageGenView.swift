import AppKit
import PocketImageGen
import PocketKit
import PocketUI
import SwiftUI

/// On-device image generation (SDXL Turbo through MLX). Everything stays on
/// this Mac, so the only cost is time and memory — both shown while it runs.
struct ImageGenView: View {
    @Environment(AppModel.self) private var app
    @State private var prompt = ""
    @State private var negativePrompt = ""
    @State private var size = 512
    /// Seeded from the installed model's own preset. A constant is wrong the
    /// moment the model is not SDXL-Turbo: a full-schedule model wants ~50.
    @State private var steps = 2
    @State private var maxSteps = 4
    @State private var stepsHint = "SDXL Turbo is built for 1–4 steps. More is slower, not better."

    @State private var seedText = ""
    @State private var image: NSImage?
    @State private var preview: NSImage?
    @State private var isGenerating = false
    @State private var progress: Double = 0
    @State private var statusText: String?
    @State private var errorText: String?
    @State private var generator: PocketImageGenerator?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Images")
                    .font(.pocket(.headline))
                Spacer()
                if isGenerating {
                    Button("Stop") { stop() }
                        .buttonStyle(.hudDestructive)
                }
            }
            .padding(.horizontal, PocketSpacing.s16)
            .padding(.vertical, PocketSpacing.s8)
            .background(PocketColor.bgSurface)
            HUDRule()

            HSplitView {
                controls
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(PocketColor.bgCanvas)
        .task { adoptInstalledModelDefaults() }
        .onDisappear { task?.cancel() }
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                    HUDLabel("Prompt")
                    TextEditor(text: $prompt)
                        .font(.pocket(.body))
                        .scrollContentBackground(.hidden)
                        .frame(height: 90)
                        .padding(PocketSpacing.s8)
                        .hudPanel(PocketColor.bgCanvas)
                }
                VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                    HUDLabel("Avoid · optional")
                    TextField("blurry, watermark", text: $negativePrompt)
                        .textFieldStyle(.plain)
                        .font(.pocket(.body))
                        .padding(PocketSpacing.s8)
                        .hudPanel(PocketColor.bgCanvas)
                }
                VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                    HUDLabel("Size")
                    Picker("Image size", selection: $size) {
                        ForEach([512, 768, 1024], id: \.self) { value in
                            Text("\(value)²").tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                    HUDLabel("Steps · \(steps)")
                    Slider(
                        value: Binding(
                            get: { Double(steps) }, set: { steps = Int($0) }),
                        in: 1...Double(maxSteps), step: 1)
                    Text(stepsHint)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }
                VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                    HUDLabel("Seed · optional")
                    TextField("random", text: $seedText)
                        .textFieldStyle(.plain)
                        .font(.pocket(.mono))
                        .padding(PocketSpacing.s8)
                        .hudPanel(PocketColor.bgCanvas)
                }
                Button(isGenerating ? "Generating…" : "Generate") { generate() }
                    .buttonStyle(.hudProminent)
                    .disabled(isGenerating || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                if let errorText {
                    Text(errorText)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.statusBad)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(PocketSpacing.s12)
        }
        .background(PocketColor.bgSurface)
    }

    private var canvas: some View {
        VStack(spacing: PocketSpacing.s12) {
            Spacer()
            if let shown = image ?? preview {
                Image(nsImage: shown)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 640, maxHeight: 640)
                    .accessibilityLabel(
                        image == nil
                            ? "Preview of the image being generated"
                            : "Generated image for: \(prompt)")
                    .clipShape(RoundedRectangle(cornerRadius: HUD.radius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: HUD.radius, style: .continuous)
                            .stroke(PocketColor.lineHairline, lineWidth: HUD.hairline))
            } else if isGenerating {
                // Model loading / first step before a preview arrives: the
                // animated PocketAI mark, as on iPhone (UI-28). The step bar
                // below stays — it shows real numbers.
                PocketMarkView(state: .loading, size: 48)
            } else {
                VStack(spacing: PocketSpacing.s8) {
                    Image(systemName: "photo")
                        .font(.system(size: 34))
                        .foregroundStyle(PocketColor.textTertiary)
                        .accessibilityHidden(true)
                    Text("Describe an image and generate it here.")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)
                    Text("Runs fully offline on this Mac.")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }
            }
            if isGenerating {
                VStack(spacing: PocketSpacing.s4) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 240)
                        .accessibilityLabel("Generation progress")
                        .accessibilityValue(statusText ?? "\(Int(progress * 100)) percent")
                    if let statusText { HUDLabel(statusText) }
                }
            }
            if let image, !isGenerating {
                HStack(spacing: PocketSpacing.s8) {
                    Button("Save…") { save(image) }
                        .buttonStyle(.hud)
                        .accessibilityLabel("Save this image")
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                    }
                    .buttonStyle(.hud)
                    .accessibilityLabel("Copy this image")
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PocketColor.bgCanvas)
    }

    /// Reads the installed model's tuned schedule. Silent on failure — the
    /// Turbo defaults stand and the generate path reports a missing model.
    private func adoptInstalledModelDefaults() {
        guard let installed = resolveInstalledImageModel(),
              let preset = try? PocketImageGenerator.defaultSteps(forModelId: installed.modelId),
              let ceiling = try? PocketImageGenerator.maxSteps(forModelId: installed.modelId)
        else { return }
        steps = preset
        maxSteps = ceiling
        stepsHint = ceiling <= 4
            ? "This model is built for 1–\(ceiling) steps. More is slower, not better."
            : "This model is tuned for \(preset) steps. Fewer is faster and rougher."
    }

    /// Directory and id of the installed image model. Mirrors the iPhone's
    /// resolver — both return the id alongside the path so the loader can pick
    /// the matching Stable Diffusion preset.
    private func resolveInstalledImageModel() -> (url: URL, modelId: String)? {
        let catalog = app.core.catalog(
            filter: CatalogFilter(modality: .image, curatedOnly: false, installedOnly: true))
        guard let entry = catalog.first(where: { $0.state == .installed }) else { return nil }
        guard let liveCore = app.core as? LiveCore,
              let plan = try? liveCore.rawCore.planDownload(id: entry.manifest.id)
        else { return nil }
        let candidate = URL(fileURLWithPath: plan.destDir)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return (candidate, entry.manifest.id)
    }

    private func generate() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        errorText = nil
        image = nil
        preview = nil
        progress = 0
        statusText = "Loading the image model…"
        isGenerating = true

        let negative = negativePrompt.trimmingCharacters(in: .whitespaces)
        let seed = Int(seedText.trimmingCharacters(in: .whitespaces))
        let chosenSize = size
        let chosenSteps = steps

        task = Task {
            do {
                if generator == nil {
                    // macOS has the memory headroom; conserveMemory trades
                    // speed for footprint and is for iPhone.
                    generator = PocketImageGenerator(conserveMemory: false)
                }
                guard let generator else { return }

                // This was missing entirely: the generator was built and then
                // asked to generate, so every attempt threw .notLoaded.
                guard let installed = resolveInstalledImageModel() else {
                    throw ImageGenError.modelNotFound("no image model installed")
                }
                try await generator.load(
                    modelDirectory: installed.url, modelId: installed.modelId)
                let cgImage = try await generator.generate(
                    prompt: text,
                    negativePrompt: negative.isEmpty ? nil : negative,
                    size: chosenSize,
                    steps: chosenSteps,
                    seed: seed
                ) { step, total, previewImage in
                    Task { @MainActor in
                        progress = total > 0 ? Double(step) / Double(total) : 0
                        statusText = "Step \(step) of \(total)"
                        if let previewImage {
                            preview = NSImage(
                                cgImage: previewImage,
                                size: NSSize(width: previewImage.width,
                                             height: previewImage.height))
                        }
                    }
                }
                image = NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height))
                statusText = nil
            } catch is CancellationError {
            } catch {
                errorText = "Generation failed: \(error.localizedDescription)"
            }
            isGenerating = false
        }
    }

    private func stop() {
        task?.cancel()
        isGenerating = false
        statusText = nil
    }

    private func save(_ image: NSImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "pocketai.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else {
            errorText = "Couldn't encode the image as PNG."
            return
        }
        do {
            try data.write(to: url)
        } catch {
            errorText = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
