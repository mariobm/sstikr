import SwiftData
import SwiftUI

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
    @State private var code = ""

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

            Button("Continue offline") {
                dismiss()
            }
            .foregroundStyle(.secondary)
        }
    }

    private func codeContent(email: String) -> some View {
        AccountPanel(title: "Enter code", systemImage: "number.square.fill") {
            Text("We sent a sign-in code to \(email).")
                .foregroundStyle(.secondary)

            TextField("Code", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Button {
                Task {
                    await accountStore.verifyCode(code, email: email)
                }
            } label: {
                Label("Verify and sign in", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.stickerTeal)
            .disabled(accountStore.isBusy)

            Button("Send another code") {
                Task {
                    await accountStore.sendSignInCode(to: email)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private func signedInContent(_ account: SupabaseAccount) -> some View {
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
