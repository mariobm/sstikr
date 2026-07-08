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

                if syncStatus.isWantedFilterEnabled && !syncStatus.wantedStickerIDs.contains(definition.id) {
                    scanner.discardStableResult(
                        message: "Not looking for \(definition.displayCode)."
                    )
                    return
                }

                if syncStatus.fastMode && recentScans.contains(definition.id) {
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
                ScanConfirmationSheet(
                    result: result,
                    initialOwnedQuantity: ownedQuantity(for: result),
                    onAdd: { teamCode, number, confidence in
                        addSticker(teamCode: teamCode, number: number, confidence: confidence)
                    },
                    onRemove: { definition in
                        removeStickerDirectly(definition)
                    },
                    onRemoveFromWanted: { stickerID in
                        syncStatus.wantedStickerIDs.remove(stickerID)
                    }
                )
                .presentationDetents([.medium])
                .presentationBackground(.ultraThinMaterial)
                .presentationDragIndicator(.visible)
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
                    } else if syncStatus.isWantedFilterEnabled {
                        Label("Looking for \(syncStatus.wantedStickerIDs.count) stickers", systemImage: "checklist")
                            .font(.subheadline)
                            .foregroundStyle(Color.stickerTeal)
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

    private func ownedQuantity(for result: StickerScanResult) -> Int {
        guard let definition = catalog.sticker(teamCode: result.teamCode, number: result.number) else {
            return 0
        }
        return ownedByID[definition.id]?.quantity ?? 0
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

    private func removeStickerDirectly(_ definition: StickerDefinition) {
        do {
            _ = try CollectionWriter.removeSticker(
                teamCode: definition.teamCode,
                number: definition.number,
                catalog: catalog,
                context: modelContext
            )
            let label = definition.name.isEmpty ? definition.displayCode : definition.name
            withAnimation {
                addMessage = "Removed \(label)"
            }
            scanner.discardStableResult(message: "Ready for the next scan.")
        } catch {
            addMessage = "Could not remove sticker."
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
    @Environment(SyncStatusStore.self) private var syncStatus
    @Query private var ownedStickers: [OwnedSticker]
    let result: StickerScanResult
    let initialOwnedQuantity: Int
    let onAdd: (String, Int, Double?) -> Void
    let onRemove: (StickerDefinition) -> Void
    let onRemoveFromWanted: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var teamCode: String
    @State private var numberText: String

    init(
        result: StickerScanResult,
        initialOwnedQuantity: Int,
        onAdd: @escaping (String, Int, Double?) -> Void,
        onRemove: @escaping (StickerDefinition) -> Void,
        onRemoveFromWanted: @escaping (String) -> Void
    ) {
        self.result = result
        self.initialOwnedQuantity = initialOwnedQuantity
        self.onAdd = onAdd
        self.onRemove = onRemove
        self.onRemoveFromWanted = onRemoveFromWanted
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

    private var activeDefinition: StickerDefinition? {
        editedDefinition ?? detectedDefinition
    }

    private var activeTeam: TeamDefinition? {
        guard let activeDefinition else { return nil }
        return catalog.team(for: activeDefinition.teamCode)
    }

    private var duplicateQuantity: Int {
        guard let definition = activeDefinition else { return 0 }
        let liveQuantity = ownedByID[definition.id]?.quantity ?? 0
        if definition.id == detectedDefinition?.id {
            return max(initialOwnedQuantity, liveQuantity)
        }
        return liveQuantity
    }

    private var duplicateStatus: DuplicateStatus {
        DuplicateStatus(quantity: duplicateQuantity)
    }

    private var ownedByID: [String: OwnedSticker] {
        Dictionary(uniqueKeysWithValues: ownedStickers.map { ($0.stickerID, $0) })
    }

    var body: some View {
        ZStack {
            Color.clear

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    topActionBar

                    if let definition = activeDefinition,
                       let team = activeTeam {
                        detectedHeader(definition: definition, team: team)
                    }

                    if let definition = activeDefinition {
                        stickerImage(definition)
                    }

                    correctionPanel

                    if let definition = activeDefinition,
                       let team = activeTeam {
                        Label("\(team.name) - \(definition.displayCode)", systemImage: "checkmark.seal.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.stickerTeal)
                    } else {
                        Label("No catalog match", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.stickerOrange)
                    }

                    removeArea
                }
                .padding(18)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
        }
    }

    private var topActionBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
            .accessibilityIdentifier("retryScanButton")

            Spacer()

            Button {
                guard let number = Int(numberText) else { return }
                onAdd(teamCode.uppercased(), number, result.confidence)
                dismiss()
            } label: {
                Label("Add", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(.stickerTeal)
            .controlSize(.regular)
            .disabled(editedDefinition == nil)
            .accessibilityIdentifier("addScannedStickerButton")
        }
    }

    private func detectedHeader(definition: StickerDefinition, team: TeamDefinition) -> some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 12) {
                Text(team.flag)
                    .font(.system(size: 25))
                    .frame(width: 46, height: 46)
                    .background(.regularMaterial, in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(definition.displayCode)
                        .font(.title2.weight(.black))
                        .monospacedDigit()
                    Text(team.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            duplicateStatusPill
        }
        .padding(16)
        .stickerGlass(cornerRadius: 22)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(team.name), \(definition.displayCode), \(duplicateStatus.text)")
    }

    @ViewBuilder
    private func stickerImage(_ definition: StickerDefinition) -> some View {
        AsyncImage(url: definition.imageURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            case .failure:
                EmptyView()
            case .empty:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            @unknown default:
                EmptyView()
            }
        }
        .padding(10)
        .background(Color.cardSurface.opacity(0.64), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var correctionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Code")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("Country code", text: $teamCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.title3.weight(.bold).monospaced())
                        .padding(.horizontal, 12)
                        .frame(height: 48)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Number")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("Number", text: $numberText)
                        .keyboardType(.numberPad)
                        .font(.title3.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 12)
                        .frame(height: 48)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            Text("Catalog match is confirmed before adding.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .stickerGlass(cornerRadius: 22)
    }

    @ViewBuilder
    private var removeArea: some View {
        if let definition = activeDefinition {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                    .opacity(0.45)

                Button(role: .destructive) {
                    onRemove(definition)
                    if syncStatus.isWantedFilterEnabled && syncStatus.wantedStickerIDs.contains(definition.id) {
                        onRemoveFromWanted(definition.id)
                    }
                    dismiss()
                } label: {
                    Label("Remove from collection", systemImage: "minus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .tint(.stickerOrange)
                .accessibilityIdentifier("removeScannedStickerButton")

                Text(syncStatus.isWantedFilterEnabled && syncStatus.wantedStickerIDs.contains(definition.id)
                     ? "Also removes this sticker from the wanted list."
                     : "Use this when the physical duplicate leaves your pile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.top, 2)
        }
    }

    private var duplicateStatusPill: some View {
        Label(duplicateStatus.text, systemImage: duplicateStatus.symbol)
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .foregroundStyle(duplicateStatus.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(duplicateStatus.color.opacity(0.14), in: Capsule())
    }
}

private struct DuplicateStatus {
    let quantity: Int

    var text: String {
        quantity > 0 ? "Duplicate x\(quantity)" : "New sticker"
    }

    var symbol: String {
        quantity > 0 ? "square.stack.3d.up.fill" : "sparkles"
    }

    var color: Color {
        quantity > 0 ? .stickerOrange : .stickerTeal
    }
}
