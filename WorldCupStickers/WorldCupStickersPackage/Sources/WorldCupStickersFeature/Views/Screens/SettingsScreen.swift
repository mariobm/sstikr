import SwiftData
import SwiftUI

@MainActor
struct SettingsScreen: View {
    @Environment(SyncStatusStore.self) private var syncStatus
    @Environment(SupabaseAccountStore.self) private var accountStore
    @Environment(StickerCatalogStore.self) private var catalog
    @Environment(GoalAlertsStore.self) private var goalAlertsStore
    @Environment(\.modelContext) private var modelContext
    @Query private var ownedStickers: [OwnedSticker]
    @State private var didClearImageCache = false
    @State private var isAccountSheetPresented = false
    @State private var isExportSheetPresented = false
    @State private var isImportSheetPresented = false
    @State private var isWantedSheetPresented = false
    @State private var isMissingExportSheetPresented = false
    @State private var didCopyProfileLink = false
    @State private var visibilitySaveTask: Task<Void, Never>?
    @State private var isDeleteAccountConfirmPresented = false
    @State private var isDeleteAllDataConfirmPresented = false
    @State private var isDeletingData = false
    @State private var dataActionMessage: String?

    var body: some View {
        @Bindable var syncStatus = syncStatus

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SettingsCard(title: "Account sync", systemImage: "icloud.and.arrow.up") {
                        accountStatus

                        Button {
                            isAccountSheetPresented = true
                        } label: {
                            Label(accountButtonTitle, systemImage: "person.crop.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.stickerTeal)
                    }

                    SettingsCard(title: "Duplicate visibility", systemImage: "person.2.badge.gearshape") {
                        Picker("Visibility", selection: $syncStatus.selectedVisibility) {
                            ForEach(ProfileVisibility.allCases) { visibility in
                                Text(visibility.title).tag(visibility)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(syncStatus.selectedVisibility.summary)
                            .foregroundStyle(.secondary)

                        if case .signedIn = accountStore.state {
                            Label("Saved to your profile automatically.", systemImage: "checkmark.icloud.fill")
                                .font(.caption)
                                .foregroundStyle(Color.stickerTeal)
                        } else {
                            Text("Sign in to persist this setting to profile sharing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    SettingsCard(title: "Goal alerts", systemImage: "bell.badge.fill") {
                        goalAlertsContent
                    }

                    SettingsCard(title: "Fast mode", systemImage: "bolt.fill") {
                        Toggle("Skip confirmation for new stickers", isOn: $syncStatus.fastMode)
                        Text("When enabled, new stickers are added instantly without the confirm dialog. Duplicates still ask for confirmation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if syncStatus.fastMode {
                            Stepper("Skip recent: \(syncStatus.recentScanBufferSize)", value: $syncStatus.recentScanBufferSize, in: 0...20)
                            Text("Ignores the last \(syncStatus.recentScanBufferSize) scanned stickers so you don't re-add the same one. Set to 0 to disable.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    SettingsCard(title: "Look for", systemImage: "checklist") {
                        Toggle("Filter scanner to wanted stickers", isOn: $syncStatus.isWantedFilterEnabled)

                        if syncStatus.isWantedFilterEnabled {
                            HStack {
                                Text("\(syncStatus.wantedStickerIDs.count) stickers")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Edit list") {
                                    isWantedSheetPresented = true
                                }
                                .buttonStyle(.bordered)
                                .tint(.stickerTeal)
                            }
                        }

                        Button {
                            isMissingExportSheetPresented = true
                        } label: {
                            Label("Export missing stickers", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .tint(.stickerTeal)

                        Text("Paste a list of stickers you're looking for. The scanner will only react to stickers on this list. Export missing stickers to share or paste into the list.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SettingsCard(title: "Display", systemImage: "eye") {
                        Toggle("Clean tiles", isOn: $syncStatus.cleanMode)
                        Text("Hides country code and player name on owned stickers -- the image already has them. Missing stickers keep the full label.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SettingsCard(title: "Images", systemImage: "photo.on.rectangle") {
                        Button("Clear image cache", systemImage: "trash") {
                            ImageCache.clearAll()
                            didClearImageCache = true
                        }
                        .buttonStyle(.bordered)
                        .tint(.stickerTeal)

                        Text("Reloads sticker images from R2 without touching your collection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SettingsCard(title: "Transfer collection", systemImage: "arrow.up.arrow.down.square") {
                        Button {
                            isExportSheetPresented = true
                        } label: {
                            Label("Export collection", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .tint(.stickerTeal)

                        Button {
                            isImportSheetPresented = true
                        } label: {
                            Label("Import collection", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .tint(.stickerTeal)

                        Text("Export your stickers as text to transfer between devices. Import replaces your current collection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SettingsCard(title: "Share profile", systemImage: "link.circle") {
                        shareProfileContent
                    }

                    SettingsCard(title: "Data", systemImage: "trash") {
                        if isDeletingData {
                            ProgressView("Deleting data...")
                                .tint(.stickerTeal)
                        }

                        Button(role: .destructive) {
                            isDeleteAccountConfirmPresented = true
                        } label: {
                            Label("Delete account", systemImage: "person.crop.circle.badge.xmark")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!isSignedIn || isDeletingData)

                        Text("Deletes your Supabase account, cloud collection, profile, avatar, friends, and exchange data. Your local album stays on this phone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button(role: .destructive) {
                            isDeleteAllDataConfirmPresented = true
                        } label: {
                            Label("Delete all data", systemImage: "trash.slash")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(isDeletingData)

                        Text("Deletes cloud data if signed in, then clears all local stickers and pending sync mutations. This cannot be undone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let dataActionMessage {
                            Text(dataActionMessage)
                                .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.stickerTeal)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(StickerBackdrop())
            .navigationTitle("Settings")
            .alert("Image cache cleared", isPresented: $didClearImageCache) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Sticker artwork will reload as it appears.")
            }
            .confirmationDialog(
                "Delete cloud account?",
                isPresented: $isDeleteAccountConfirmPresented,
                titleVisibility: .visible
            ) {
                Button("Delete account", role: .destructive) {
                    deleteAccountOnly()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes your Supabase user, cloud collection, profile, avatar, friends, and exchange data. Your local album remains on this phone.")
            }
            .confirmationDialog(
                "Delete all sticker data?",
                isPresented: $isDeleteAllDataConfirmPresented,
                titleVisibility: .visible
            ) {
                Button("Delete all data", role: .destructive) {
                    deleteAllData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes your cloud account if signed in, then clears every local sticker and pending sync mutation on this phone.")
            }
            .sheet(isPresented: $isAccountSheetPresented) {
                AccountSheet()
            }
            .sheet(isPresented: $isExportSheetPresented) {
                ExportSheet(
                    exportText: CollectionTransfer.export(
                        ownedStickers: ownedStickers,
                        catalog: catalog
                    )
                )
            }
            .sheet(isPresented: $isImportSheetPresented) {
                ImportSheet { text in
                    importCollection(text)
                }
            }
            .sheet(isPresented: $isWantedSheetPresented) {
                WantedStickersSheet(
                    existingIDs: syncStatus.wantedStickerIDs
                ) { newIDs in
                    syncStatus.wantedStickerIDs = newIDs
                }
            }
            .sheet(isPresented: $isMissingExportSheetPresented) {
                ExportSheet(
                    exportText: CollectionTransfer.exportMissing(
                        ownedStickers: ownedStickers,
                        catalog: catalog
                    )
                )
            }
            .task {
                applyProfileVisibility()
            }
            .onChange(of: accountStore.profile) { _, profile in
                guard let profile else { return }
                applyProfileVisibility(profile)
            }
            .onChange(of: syncStatus.selectedVisibility) { _, visibility in
                guard case .signedIn = accountStore.state else { return }
                visibilitySaveTask?.cancel()
                visibilitySaveTask = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    await accountStore.saveDuplicateVisibility(visibility)
                }
            }
        }
    }

    private func applyProfileVisibility(_ profile: UserProfile? = nil) {
        guard let profile = profile ?? accountStore.profile else { return }
        syncStatus.selectedVisibility = profile.duplicateVisibility
    }

    @ViewBuilder
    private var accountStatus: some View {
        switch accountStore.state {
        case .notConfigured:
            Label("Account sync unavailable", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        case .signedOut:
            Label("Not signed in", systemImage: "person.crop.circle")
                .foregroundStyle(.secondary)
        case .codeSent(let email):
            Label("Code sent to \(email)", systemImage: "envelope.badge")
                .foregroundStyle(Color.stickerTeal)
        case .signedIn(let account):
            Label(account.email ?? "Signed in", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.stickerTeal)
        }
    }

    private var accountButtonTitle: String {
        switch accountStore.state {
        case .signedIn:
            "Manage account"
        case .codeSent:
            "Enter code"
        case .notConfigured, .signedOut:
            "Sign in"
        }
    }

    private var isSignedIn: Bool {
        if case .signedIn = accountStore.state {
            return true
        }
        return false
    }

    @ViewBuilder
    private var goalAlertsContent: some View {
        if goalAlertsStore.authorization == .denied {
            Label("Goal alerts are unavailable on this iPhone.", systemImage: "bell.slash.fill")
                .foregroundStyle(.secondary)

            Button("Open iPhone Settings", systemImage: "gearshape") {
                goalAlertsStore.openSystemSettings()
            }
            .buttonStyle(.bordered)
            .tint(.stickerTeal)

            Text("Allow notifications for Sstikr in iPhone Settings, then return here to register this device.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Toggle("Goal alerts", isOn: goalAlertsBinding)

            if goalAlertsStore.authorization == .notDetermined {
                Button("Enable notifications on this iPhone", systemImage: "bell.fill") {
                    Task {
                        await goalAlertsStore.requestAuthorization(
                            accessToken: await accountStore.currentAccessToken()
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.stickerTeal)

                Text("Sstikr asks only after you choose to enable match alerts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            goalAlertRegistrationStatus
        }
    }

    private var goalAlertsBinding: Binding<Bool> {
        Binding(
            get: { goalAlertsStore.goalAlertsEnabled },
            set: { isEnabled in
                Task {
                    await goalAlertsStore.setGoalAlertsEnabled(
                        isEnabled,
                        accessToken: await accountStore.currentAccessToken()
                    )
                }
            }
        )
    }

    @ViewBuilder
    private var goalAlertRegistrationStatus: some View {
        switch goalAlertsStore.registrationState {
        case .notConfigured:
            Label("Goal-alert relay is not configured yet.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .waitingForPermission:
            Text("Allow iOS notifications to receive goal alerts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .waitingForDeviceToken:
            Text("Registering this iPhone with Apple…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .registering:
            ProgressView("Registering goal alerts…")
                .font(.caption)
                .tint(.stickerTeal)
        case .registered:
            Label("This iPhone is ready for World Cup goal alerts.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.stickerTeal)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var shareProfileContent: some View {
        if case .signedIn = accountStore.state, let profile = accountStore.profile {
            LabeledContent("Web preview", value: profile.shareURL.absoluteString)
                .font(.caption)
                .textSelection(.enabled)

            Text("Your duplicate visibility controls what the web preview can show.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                ShareLink(item: profile.shareURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(.stickerTeal)

                Button {
                    UIPasteboard.general.string = profile.shareURL.absoluteString
                    withAnimation { didCopyProfileLink = true }
                } label: {
                    Label(didCopyProfileLink ? "Copied" : "Copy", systemImage: didCopyProfileLink ? "checkmark.circle.fill" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .tint(.stickerTeal)
            }
        } else if case .signedIn = accountStore.state {
            Label("Profile is loading", systemImage: "clock")
                .foregroundStyle(.secondary)

            Button {
                Task { await accountStore.refreshProfile() }
            } label: {
                Label("Refresh profile", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .tint(.stickerTeal)
        } else {
            Text("Sign in and set a username to create your sstikr.com profile link.")
                .foregroundStyle(.secondary)

            Button {
                isAccountSheetPresented = true
            } label: {
                Label("Open account", systemImage: "person.crop.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.stickerTeal)
        }
    }

    private func importCollection(_ text: String) {
        guard let data = CollectionTransfer.parse(text) else { return }
        do {
            _ = try CollectionWriter.importCollection(
                data,
                catalog: catalog,
                context: modelContext
            )
        } catch {
            // Silent failure -- the sheet handles its own error display
        }
    }

    private func deleteAccountOnly() {
        Task {
            isDeletingData = true
            dataActionMessage = nil
            defer { isDeletingData = false }

            guard await accountStore.deleteCloudAccount() else {
                dataActionMessage = accountStore.lastError ?? "Could not delete cloud account."
                return
            }

            do {
                let keptCount = try CollectionWriter.resetCloudSyncMetadata(context: modelContext)
                try modelContext.save()
                dataActionMessage = "Cloud account deleted. Kept \(keptCount) local stickers offline."
            } catch {
                dataActionMessage = "Cloud account deleted, but local sync metadata could not be reset."
            }
        }
    }

    private func deleteAllData() {
        Task {
            isDeletingData = true
            dataActionMessage = nil
            defer { isDeletingData = false }

            if isSignedIn {
                guard await accountStore.deleteCloudAccount() else {
                    dataActionMessage = accountStore.lastError ?? "Could not delete cloud account."
                    return
                }
            }

            do {
                let result = try CollectionWriter.clearLocalData(context: modelContext)
                try modelContext.save()
                ImageCache.clearAll()
                dataActionMessage = "Deleted \(result.ownedStickerCount) local stickers and cleared sync history."
            } catch {
                dataActionMessage = "Could not delete local sticker data."
            }
        }
    }
}

@MainActor
private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.stickerTeal)
                .labelStyle(.titleAndIcon)

            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .stickerCard()
    }
}

@MainActor
private struct ExportSheet: View {
    let exportText: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Copy the text below or share it to your new device.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(exportText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.stickerInk)
                        .padding(12)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .textSelection(.enabled)

                    Button {
                        UIPasteboard.general.string = exportText
                        withAnimation { copied = true }
                    } label: {
                        Label(copied ? "Copied!" : "Copy to clipboard", systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.stickerTeal)

                    ShareLink(item: exportText) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .tint(.stickerTeal)
                }
                .padding(20)
            }
            .background(StickerBackdrop())
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

@MainActor
private struct ImportSheet: View {
    let onImport: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var showingConfirm = false
    @State private var parseError = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Paste your exported collection text. This will replace your current collection.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 160)
                        .padding(8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    if parseError {
                        Label("Invalid format. Expected SA26|1|...|...", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button {
                        if CollectionTransfer.parse(text) != nil {
                            showingConfirm = true
                        } else {
                            withAnimation { parseError = true }
                        }
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.stickerTeal)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(20)
            }
            .background(StickerBackdrop())
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .confirmationDialog(
                "Replace your collection?",
                isPresented: $showingConfirm,
                titleVisibility: .visible
            ) {
                Button("Replace and import", role: .destructive) {
                    onImport(text)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete all your current stickers and import the ones from the text. This cannot be undone.")
            }
        }
    }
}

@MainActor
private struct WantedStickersSheet: View {
    let existingIDs: Set<String>
    let onSave: (Set<String>) -> Void

    @Environment(StickerCatalogStore.self) private var catalog
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var parsedCount = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Paste your wanted stickers in the format `TEAM: number, number` (one team per line).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 240)
                        .padding(8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: text) { _, newValue in
                            let ids = WantedStickerParser.parse(newValue, catalog: catalog)
                            parsedCount = ids.count
                        }

                    if parsedCount > 0 {
                        Label("\(parsedCount) stickers found in catalog", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Color.stickerTeal)
                    }

                    Button {
                        let ids = WantedStickerParser.parse(text, catalog: catalog)
                        onSave(ids)
                        dismiss()
                    } label: {
                        Label("Save wanted list", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.stickerTeal)
                    .disabled(parsedCount == 0)

                    if !existingIDs.isEmpty {
                        Button("Clear list", role: .destructive) {
                            onSave([])
                            dismiss()
                        }
                        .font(.subheadline)
                    }
                }
                .padding(20)
            }
            .background(StickerBackdrop())
            .navigationTitle("Look For")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
