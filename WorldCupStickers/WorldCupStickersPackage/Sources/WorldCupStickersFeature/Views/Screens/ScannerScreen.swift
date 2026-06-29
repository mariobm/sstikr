import SwiftData
import SwiftUI

@MainActor
struct ScannerScreen: View {
    @Environment(StickerCatalogStore.self) private var catalog
    @Environment(SyncStatusStore.self) private var syncStatus
    @Environment(\.modelContext) private var modelContext
    @Query private var ownedStickers: [OwnedSticker]
    @State private var scanner = CameraScanner()
    @State private var pendingScan: StickerScanResult?
    @State private var addMessage: String?
    @State private var recentScans: [String] = []
    @State private var fastAddTrigger = 0

    var body: some View {
        NavigationStack {
            ZStack {
                scannerContent
                scannerOverlay
            }
            .sensoryFeedback(.success, trigger: fastAddTrigger)
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                scanner.updateCatalog(stickers: catalog.stickers)
                await scanner.configure()
                scanner.start()
            }
            .onAppear {
                scanner.resetForScreenEntry()
                scanner.start()
            }
            .onDisappear {
                scanner.stop()
            }
            .onChange(of: catalog.stickers.count, initial: true) { _, _ in
                scanner.updateCatalog(stickers: catalog.stickers)
            }
            .onChange(of: scanner.stableResult) { _, result in
                guard let result else { return }
                guard let definition = catalog.sticker(teamCode: result.teamCode, number: result.number) else {
                    scanner.discardStableResult(
                        message: "\(result.displayCode) is not in the catalog. Scanning again."
                    )
                    return
                }

                if recentScans.contains(definition.id) {
                    scanner.discardStableResult(
                        message: "Already scanned \(definition.displayCode). Looking for the next sticker."
                    )
                    return
                }

                let isDuplicate = ownedByID[definition.id]?.quantity ?? 0 > 0

                if syncStatus.fastMode && !isDuplicate {
                    addStickerDirectly(definition, result: result)
                } else {
                    pendingScan = StickerScanResult(
                        teamCode: result.teamCode,
                        number: result.number,
                        rawText: result.rawText,
                        confidence: 1,
                        scanMode: result.scanMode
                    )
                    scanner.pauseDetections()
                }
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
            CameraPreview(session: scanner.session)
                .ignoresSafeArea()
                .accessibilityIdentifier("cameraPreview")
        case .notDetermined:
            ProgressView("Requesting camera access")
        case .denied, .restricted:
            ContentUnavailableView(
                "Camera Access Needed",
                systemImage: "camera.badge.ellipsis",
                description: Text("Enable camera access in Settings to scan stickers.")
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
                scanGuide

                VStack(spacing: 6) {
                    Text(scanner.statusMessage)
                        .font(.headline)
                    if let candidate = scanner.lastCandidate {
                        Text("\(candidate.displayCode) - \(candidate.confidence.formatted(.percent.precision(.fractionLength(0)))) confidence")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Align the sticker inside the guide.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let addMessage {
                        Label(addMessage, systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.stickerTeal)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .multilineTextAlignment(.center)
                .padding(16)
                .stickerGlass(cornerRadius: 20)
            }
            .padding()
        }
        .task(id: addMessage) {
            guard addMessage != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.4)) {
                addMessage = nil
            }
        }
    }

    private var ownedByID: [String: OwnedSticker] {
        Dictionary(uniqueKeysWithValues: ownedStickers.map { ($0.stickerID, $0) })
    }

    private var scanGuide: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(.white.opacity(0.94), style: StrokeStyle(lineWidth: 3, dash: [14, 8]))
            .overlay {
                scanTargetOverlay
            }
            .frame(maxWidth: 330, maxHeight: 470)
            .aspectRatio(0.68, contentMode: .fit)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var scanTargetOverlay: some View {
        switch scanner.activeScanMode {
        case .auto, .back:
            VStack {
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.stickerOrange, lineWidth: 4)
                        .frame(width: 130, height: 58)
                        .padding(.top, 22)
                        .padding(.trailing, 18)
                }
                Spacer()
            }
        case .front:
            VStack {
                Spacer()
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.stickerOrange, lineWidth: 4)
                    .frame(width: 242, height: 82)
                    .padding(.bottom, 42)
            }
        }
    }

    private func addSticker(teamCode: String, number: Int, confidence: Double?) {
        do {
            if try CollectionWriter.addSticker(
                teamCode: teamCode,
                number: number,
                confidence: confidence,
                catalog: catalog,
                context: modelContext
            ) != nil {
                let definition = catalog.sticker(teamCode: teamCode, number: number)
                let label = definition?.name ?? "\(teamCode.uppercased())-\(number)"
                addMessage = "Added \(label)"
                if let id = definition?.id { recordRecentScan(id) }
            } else {
                addMessage = "\(teamCode) \(number) is not in the catalog."
            }
        } catch {
            addMessage = "Could not save sticker."
        }
    }

    private func addStickerDirectly(_ definition: StickerDefinition, result: StickerScanResult) {
        do {
            _ = try CollectionWriter.addSticker(
                teamCode: definition.teamCode,
                number: definition.number,
                confidence: result.confidence,
                catalog: catalog,
                context: modelContext
            )
            let label = definition.name.isEmpty ? definition.displayCode : definition.name
            withAnimation {
                addMessage = "Added \(label)"
            }
            fastAddTrigger += 1
            recordRecentScan(definition.id)
            scanner.discardStableResult(message: "Ready for the next scan.")
        } catch {
            addMessage = "Could not save sticker."
        }
    }

    private func recordRecentScan(_ stickerID: String) {
        recentScans.append(stickerID)
        let maxSize = max(syncStatus.recentScanBufferSize, 1)
        if recentScans.count > maxSize {
            recentScans.removeFirst(recentScans.count - maxSize)
        }
    }
}

@MainActor
private struct ScanConfirmationSheet: View {
    @Environment(StickerCatalogStore.self) private var catalog
    @Query private var ownedStickers: [OwnedSticker]
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

    private var detectedDefinition: StickerDefinition? {
        catalog.sticker(teamCode: result.teamCode, number: result.number)
    }

    private var detectedTeam: TeamDefinition? {
        guard let definition = detectedDefinition else { return nil }
        return catalog.team(for: definition.teamCode)
    }

    private var editedDefinition: StickerDefinition? {
        guard let number = Int(numberText) else { return nil }
        return catalog.sticker(teamCode: teamCode, number: number)
    }

    private var duplicateQuantity: Int {
        guard let definition = editedDefinition ?? detectedDefinition else { return 0 }
        return ownedByID[definition.id]?.quantity ?? 0
    }

    private var ownedByID: [String: OwnedSticker] {
        Dictionary(uniqueKeysWithValues: ownedStickers.map { ($0.stickerID, $0) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Detected") {
                    if let definition = detectedDefinition,
                       let team = detectedTeam {
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

                        stickerImage(definition)
                    }

                    HStack {
                        Text("Code")
                        Spacer()
                        Text(result.displayCode)
                            .font(.title3.weight(.bold))
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

                    duplicateBadge
                }

                if let definition = editedDefinition,
                   let team = catalog.team(for: definition.teamCode) {
                    Section("Match") {
                        Label("\(team.name) - \(definition.displayCode)", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Color.stickerTeal)
                    }
                } else if editedDefinition == nil && !teamCode.isEmpty {
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

    @ViewBuilder
    private func stickerImage(_ definition: StickerDefinition) -> some View {
        AsyncImage(url: definition.imageURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            case .failure:
                EmptyView()
            case .empty:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            @unknown default:
                EmptyView()
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var duplicateBadge: some View {
        if editedDefinition != nil {
            if duplicateQuantity > 0 {
                Label("Duplicate — you have \(duplicateQuantity)", systemImage: "square.stack.3d.up.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.stickerOrange)
            } else {
                Label("New sticker", systemImage: "sparkles")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.stickerTeal)
            }
        }
    }
}
