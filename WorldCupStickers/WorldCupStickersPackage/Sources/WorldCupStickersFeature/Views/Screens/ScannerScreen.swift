import SwiftData
import SwiftUI

@MainActor
struct ScannerScreen: View {
    @Environment(StickerCatalogStore.self) private var catalog
    @Environment(\.modelContext) private var modelContext
    @State private var scanner = CameraScanner()
    @State private var pendingScan: StickerScanResult?
    @State private var addMessage: String?
    @State private var focusLocation: CGPoint?

    var body: some View {
        NavigationStack {
            ZStack {
                scannerContent
                scannerOverlay
            }
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await scanner.configure()
                scanner.start()
            }
            .onDisappear {
                scanner.stop()
            }
            .onChange(of: scanner.stableResult) { _, result in
                guard let result else { return }
                guard catalog.sticker(teamCode: result.teamCode, number: result.number) != nil else {
                    scanner.discardStableResult(
                        message: "\(result.displayCode) is not in the catalog. Scanning again."
                    )
                    return
                }

                pendingScan = StickerScanResult(
                    teamCode: result.teamCode,
                    number: result.number,
                    rawText: result.rawText,
                    confidence: 1
                )
                scanner.pauseDetections()
            }
            .sheet(item: $pendingScan, onDismiss: {
                scanner.resumeDetections()
            }) { result in
                ScanConfirmationSheet(result: result) { teamCode, number, confidence in
                    addSticker(teamCode: teamCode, number: number, confidence: confidence)
                }
                .presentationDetents([.medium])
            }
        }
    }

    @ViewBuilder
    private var scannerContent: some View {
        switch scanner.authorizationState {
        case .authorized:
            CameraPreview(session: scanner.session) { devicePoint, viewPoint in
                focusLocation = viewPoint
                scanner.focus(at: devicePoint)
            }
                .ignoresSafeArea()
                .accessibilityIdentifier("cameraPreview")
        case .notDetermined:
            ProgressView("Requesting camera access")
        case .denied, .restricted:
            ContentUnavailableView(
                "Camera Access Needed",
                systemImage: "camera.badge.ellipsis",
                description: Text("Enable camera access in Settings to scan sticker backs.")
            )
        case .unavailable:
            ContentUnavailableView(
                "Camera Unavailable",
                systemImage: "camera.slash",
                description: Text("Use manual entry from the confirmation sheet after camera support is available.")
            )
        }
    }

    private var scannerOverlay: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    scanner.switchToNextLens()
                } label: {
                    Label(scanner.currentLens.buttonTitle, systemImage: "camera.aperture")
                        .font(.headline.weight(.bold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
                .disabled(scanner.availableLenses.count < 2)
                .stickerGlass(cornerRadius: 16)
                .accessibilityLabel("Switch camera lens")
                .accessibilityIdentifier("switchLensButton")
                .accessibilityHint("Toggles between the 0.5x close-up camera and the 1x camera when available.")
            }
            .padding(.horizontal)
            .padding(.top, 10)

            Spacer()
            VStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.94), style: StrokeStyle(lineWidth: 3, dash: [14, 8]))
                    .overlay(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.stickerOrange, lineWidth: 4)
                            .frame(width: 130, height: 58)
                            .padding(.top, 22)
                            .padding(.trailing, 18)
                    }
                    .frame(maxWidth: 330, maxHeight: 470)
                    .aspectRatio(0.68, contentMode: .fit)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text(scanner.statusMessage)
                        .font(.headline)
                    if let candidate = scanner.lastCandidate {
                        Text("\(candidate.displayCode) - \(candidate.confidence.formatted(.percent.precision(.fractionLength(0)))) confidence")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Only the upper-right badge is read.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let addMessage {
                        Text(addMessage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.stickerTeal)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(16)
                .stickerGlass(cornerRadius: 20)
            }
            .padding()
        }
        .overlay(alignment: .topLeading) {
            if let focusLocation {
                FocusReticle()
                    .position(focusLocation)
                    .allowsHitTesting(false)
            }
        }
    }

    private func addSticker(teamCode: String, number: Int, confidence: Double?) {
        do {
            if let owned = try CollectionWriter.addSticker(
                teamCode: teamCode,
                number: number,
                confidence: confidence,
                catalog: catalog,
                context: modelContext
            ) {
                addMessage = "\(owned.teamCode) \(owned.number) saved. Quantity: \(owned.quantity)."
            } else {
                addMessage = "\(teamCode) \(number) is not in the catalog."
            }
        } catch {
            addMessage = "Could not save sticker."
        }
    }
}

@MainActor
private struct FocusReticle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.stickerOrange, lineWidth: 2)
            .frame(width: 72, height: 72)
            .shadow(color: .black.opacity(0.24), radius: 8, y: 3)
            .accessibilityHidden(true)
    }
}

@MainActor
private struct ScanConfirmationSheet: View {
    @Environment(StickerCatalogStore.self) private var catalog
    let result: StickerScanResult
    let onAdd: (String, Int, Double?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var teamCode: String
    @State private var numberText: String

    init(result: StickerScanResult, onAdd: @escaping (String, Int, Double?) -> Void) {
        self.result = result
        self.onAdd = onAdd
        _teamCode = State(initialValue: result.teamCode)
        _numberText = State(initialValue: "\(result.number)")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Detected") {
                    if let definition = catalog.sticker(teamCode: result.teamCode, number: result.number),
                       let team = catalog.team(for: definition.teamCode) {
                        HStack(spacing: 12) {
                            CountryBadge(team: team, fallbackCode: definition.teamCode)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(team.name)
                                    .font(.headline)
                                Text(team.groupTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack {
                        Text("Code")
                        Spacer()
                        Text(result.displayCode)
                            .font(.title3.weight(.black))
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Match")
                        Spacer()
                        Text("100% catalog match")
                            .foregroundStyle(Color.stickerTeal)
                    }
                }

                Section("Confirm or edit") {
                    TextField("Country code", text: $teamCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Number", text: $numberText)
                        .keyboardType(.numberPad)
                }

                if let definition = editedDefinition,
                   let team = catalog.team(for: definition.teamCode) {
                    Section("Match") {
                        Label("\(team.name) - \(definition.displayCode)", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Color.stickerTeal)
                    }
                } else {
                    Section("Match") {
                        Label("No catalog match", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.stickerOrange)
                    }
                }
            }
            .navigationTitle("Confirm Sticker")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Retry") {
                        dismiss()
                    }
                    .accessibilityIdentifier("retryScanButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let number = Int(numberText) else { return }
                        onAdd(teamCode.uppercased(), number, result.confidence)
                        dismiss()
                    }
                    .disabled(editedDefinition == nil)
                    .accessibilityIdentifier("addScannedStickerButton")
                }
            }
        }
    }

    private var editedDefinition: StickerDefinition? {
        guard let number = Int(numberText) else { return nil }
        return catalog.sticker(teamCode: teamCode, number: number)
    }
}
