import PhotosUI
import SwiftData
import SwiftUI
import UIKit
@_spi(Experimental) import Auth

@MainActor
struct AccountSheet: View {
    @Environment(StickerCatalogStore.self) private var catalog
    @Environment(SyncStatusStore.self) private var syncStatus
    @Environment(SupabaseAccountStore.self) private var accountStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \OwnedSticker.updatedAt, order: .reverse) private var ownedStickers: [OwnedSticker]
    @Query(sort: \CollectionMutation.createdAt, order: .forward) private var mutations: [CollectionMutation]
    @State private var email = ""
    @State private var passkeys: [PasskeyListItem] = []
    @State private var profileDisplayName = ""
    @State private var profileHandle = ""
    @State private var didCopyProfileLink = false
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var avatarPreviewImage: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    switch accountStore.state {
                    case .notConfigured:
                        notConfiguredContent
                    case .signedOut:
                        signInContent
                    case .codeSent(let email):
                        codeContent(email: email)
                    case .signedIn(let account):
                        signedInContent(account)
                    }

                    if let error = accountStore.lastError {
                        Text(error)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.red)
                            .padding(.top, 4)
                    }
                }
                .padding(20)
            }
            .background(StickerBackdrop())
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await accountStore.refreshSession()
                if case .signedIn = accountStore.state {
                    passkeys = await accountStore.listPasskeys()
                    populateProfileFields()
                }
            }
            .onChange(of: accountStore.profile) { _, _ in
                populateProfileFields()
            }
            .onChange(of: selectedAvatarItem) { _, item in
                guard let item else { return }
                Task {
                    await uploadAvatar(from: item)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.stickerTeal)

            Text("Back up your album")
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.stickerInk)

            Text("Sign in to sync this phone's collection to Supabase. You can keep using the app offline without an account.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .stickerCard()
    }

    private var notConfiguredContent: some View {
        AccountPanel(title: "Backend not configured", systemImage: "exclamationmark.triangle.fill") {
            Text("Add `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` to the app configuration, then this screen can send email sign-in codes and sync your stickers.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Continue offline") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(.stickerTeal)
        }
    }

    private var signInContent: some View {
        VStack(spacing: 16) {
            AccountPanel(title: "Sign in with passkey", systemImage: "person.badge.key.fill") {
                Text("Use Face ID or Touch ID to sign in instantly if you've already registered a passkey on this device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await accountStore.signInWithPasskey() }
                } label: {
                    Label("Sign in with passkey", systemImage: "faceid")
                }
                .buttonStyle(.borderedProminent)
                .tint(.stickerTeal)
                .disabled(accountStore.isBusy)
            }

            AccountPanel(title: "Sign in with email", systemImage: "envelope.fill") {
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button {
                    Task {
                        await accountStore.sendSignInCode(to: email)
                    }
                } label: {
                    Label("Send code", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.stickerTeal)
                .disabled(accountStore.isBusy)
            }

            Button("Continue offline") {
                dismiss()
            }
            .foregroundStyle(.secondary)
        }
    }

    private func codeContent(email: String) -> some View {
        AccountPanel(title: "Check your email", systemImage: "envelope.badge.fill") {
            Text("We sent a secure sign-in link to \(email). Open it on this iPhone and the app will finish signing in automatically.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Send another link") {
                Task {
                    await accountStore.sendSignInCode(to: email)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private func signedInContent(_ account: SupabaseAccount) -> some View {
        VStack(spacing: 16) {
            profileContent

            AccountPanel(title: "Signed in", systemImage: "checkmark.icloud.fill") {
                LabeledContent("Email", value: account.email ?? "Unknown")
                LabeledContent("User ID", value: account.id.uuidString)
                    .font(.caption)

                if let summary = accountStore.lastSyncSummary {
                    Label(summary, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.stickerTeal)
                }

                if let lastSyncedAt = accountStore.lastSyncedAt {
                    Text(lastSyncedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task {
                        await accountStore.syncNow(
                            ownedStickers: ownedStickers,
                            mutations: mutations,
                            visibility: syncStatus.selectedVisibility,
                            catalog: catalog,
                            context: modelContext
                        )
                    }
                } label: {
                    Label(accountStore.isBusy ? "Syncing..." : "Sync now", systemImage: "arrow.triangle.2.circlepath.icloud")
                }
                .buttonStyle(.borderedProminent)
                .tint(.stickerTeal)
                .disabled(accountStore.isBusy)
            }

            AccountPanel(title: "Passkeys", systemImage: "person.badge.key.fill") {
                if passkeys.isEmpty {
                    Text("No passkeys registered yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(passkeys) { passkey in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(passkey.friendlyName ?? "Unnamed passkey")
                                    .font(.subheadline.weight(.medium))
                                if let lastUsedAt = passkey.lastUsedAt {
                                    Text("Last used \(lastUsedAt, style: .relative)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task {
                                    await accountStore.deletePasskey(id: passkey.id)
                                    passkeys = await accountStore.listPasskeys()
                                }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }
                }

                Button {
                    Task {
                        await accountStore.registerPasskey()
                        passkeys = await accountStore.listPasskeys()
                    }
                } label: {
                    Label("Register passkey on this device", systemImage: "faceid")
                }
                .buttonStyle(.borderedProminent)
                .tint(.stickerTeal)
                .disabled(accountStore.isBusy)
            }

            Button(role: .destructive) {
                Task {
                    await accountStore.signOut()
                }
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .disabled(accountStore.isBusy)
        }
    }

    private var profileContent: some View {
        let isBusy = accountStore.isBusy

        return AccountPanel(title: "Profile", systemImage: "person.text.rectangle.fill") {
            HStack(alignment: .center, spacing: 14) {
                profileAvatar

                PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                    Label(isBusy ? "Uploading..." : "Choose photo", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.bordered)
                .tint(.stickerTeal)
                .disabled(isBusy)
            }

            TextField("Display name", text: $profileDisplayName)
                .textContentType(.name)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            TextField("Username", text: $profileHandle)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("Username is used for your public profile link. Leave it empty to use the private share slug.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let profile = accountStore.profile {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Profile link", value: profile.shareURL.absoluteString)
                        .font(.caption)
                        .textSelection(.enabled)

                    HStack {
                        ShareLink(item: profile.shareURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
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
                }
            }

            Button {
                Task {
                    await accountStore.saveProfile(
                        displayName: profileDisplayName,
                        handle: profileHandle,
                        visibility: syncStatus.selectedVisibility
                    )
                    populateProfileFields()
                }
            } label: {
                Label(accountStore.isBusy ? "Saving..." : "Save profile", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.stickerTeal)
            .disabled(accountStore.isBusy || profileDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private var profileAvatar: some View {
        ZStack {
            Circle()
                .fill(.thinMaterial)

            if let avatarPreviewImage {
                Image(uiImage: avatarPreviewImage)
                    .resizable()
                    .scaledToFill()
            } else if let avatarURL = accountStore.profile?.avatarURL {
                AsyncImage(url: avatarURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        avatarFallback
                    case .empty:
                        ProgressView()
                    @unknown default:
                        avatarFallback
                    }
                }
            } else {
                avatarFallback
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
    }

    private var avatarFallback: some View {
        Image(systemName: "person.crop.circle.fill")
            .font(.system(size: 54, weight: .semibold))
            .foregroundStyle(Color.stickerTeal)
    }

    private func populateProfileFields() {
        guard let profile = accountStore.profile else { return }
        profileDisplayName = profile.displayName
        profileHandle = profile.handle ?? ""
        syncStatus.selectedVisibility = profile.duplicateVisibility
    }

    private func uploadAvatar(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let resized = image.resizedForAvatar(maxDimension: 512),
              let jpegData = resized.jpegData(compressionQuality: 0.82) else {
            return
        }

        avatarPreviewImage = resized
        await accountStore.uploadAvatar(imageData: jpegData)
    }
}

@MainActor
private struct AccountPanel<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.stickerTeal)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .stickerCard()
    }
}

private extension UIImage {
    func resizedForAvatar(maxDimension: CGFloat) -> UIImage? {
        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension else {
            return normalized()
        }

        let scale = maxDimension / longestSide
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1

        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            normalized()?.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    func normalized() -> UIImage? {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
