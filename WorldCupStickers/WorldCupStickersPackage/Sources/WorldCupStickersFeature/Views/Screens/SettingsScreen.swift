import SwiftUI

@MainActor
struct SettingsScreen: View {
    @Environment(SyncStatusStore.self) private var syncStatus

    var body: some View {
        @Bindable var syncStatus = syncStatus

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SettingsCard(title: "Account sync", systemImage: "icloud.and.arrow.up") {
                        switch syncStatus.phaseStatus {
                        case .localOnly:
                            Label("Local-only mode", systemImage: "iphone")
                                .font(.headline)
                            Text("Supabase URL and publishable key are not configured yet. Scans are saved locally with sync-ready mutation records.")
                                .foregroundStyle(.secondary)
                        case .configured(let configuration):
                            Label("Supabase configured", systemImage: "checkmark.icloud.fill")
                                .foregroundStyle(Color.stickerTeal)
                                .font(.headline)
                            Text(configuration.projectURL.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                    }

                    SettingsCard(title: "Share profile", systemImage: "link.circle") {
                        LabeledContent("Web preview", value: "https://stickers.example.com/u/your-handle")
                        Label("Universal Links are scaffolded for the web app", systemImage: "link")
                            .foregroundStyle(.secondary)
                    }

                    SettingsCard(title: "Roadmap", systemImage: "point.3.connected.trianglepath.dotted") {
                        RoadmapRow(title: "Email magic link sign-in", systemImage: "envelope.badge")
                        RoadmapRow(title: "Friends and mutuals", systemImage: "person.2.fill")
                        RoadmapRow(title: "Duplicate comparison", systemImage: "arrow.left.arrow.right")
                        RoadmapRow(title: "Exchange requests", systemImage: "shippingbox.fill")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(StickerBackdrop())
            .navigationTitle("Settings")
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
private struct RoadmapRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.stickerInk)
            .labelStyle(.titleAndIcon)
    }
}
