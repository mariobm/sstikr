import Foundation
import Testing
@testable import WorldCupStickersFeature

@Suite("Community RPC payloads")
struct CommunityModelsTests {
    @Test("Profile discovery payload preserves relationship and visibility state")
    func profilePayloadDecodes() throws {
        let data = Data(
            """
            {
              "profile_id": "8f1a3f5d-2f6a-4e8f-8a33-885bce11f999",
              "display_name": "Alex",
              "handle": "alex-collects",
              "avatar_url": null,
              "duplicate_visibility": "friends",
              "is_discoverable": true,
              "friendship_id": "d2ea5d9b-6077-47fb-ae3a-ecb91f68e56f",
              "friendship_status": "pending",
              "requested_by_me": false,
              "can_view_duplicates": false
            }
            """.utf8
        )

        let profile = try JSONDecoder().decode(CommunityProfile.self, from: data)

        #expect(profile.displayHandle == "@alex-collects")
        #expect(profile.friendshipLabel == "Wants to connect")
        #expect(profile.isDiscoverable)
        #expect(!profile.canViewDuplicates)
    }

    @Test("Trade inbox payload decodes both sets of line items")
    func exchangePayloadDecodes() throws {
        let data = Data(
            """
            {
              "exchange_id": "f0d8c6f0-a3a4-49f5-ae2b-d3d4b14e5a01",
              "counterpart_id": "8f1a3f5d-2f6a-4e8f-8a33-885bce11f999",
              "counterpart_display_name": "Alex",
              "counterpart_handle": "alex-collects",
              "counterpart_avatar_url": null,
              "direction": "incoming",
              "status": "accepted",
              "message": "Want to swap?",
              "created_at": "2026-07-11T09:00:00+00:00",
              "updated_at": "2026-07-11T09:01:00+00:00",
              "offered_items": [{
                "sticker_id": "ARG-1",
                "quantity": 1,
                "display_code": "ARG 1",
                "name": "Argentina",
                "image_url": null
              }],
              "requested_items": [{
                "sticker_id": "BRA-2",
                "quantity": 1,
                "display_code": "BRA 2",
                "name": "Brazil",
                "image_url": null
              }],
              "current_user_confirmed": false,
              "counterpart_confirmed": true
            }
            """.utf8
        )

        let exchange = try JSONDecoder().decode(CommunityExchange.self, from: data)

        #expect(exchange.direction == .incoming)
        #expect(exchange.status == .accepted)
        #expect(exchange.offeredItems.map(\.stickerID) == ["ARG-1"])
        #expect(exchange.requestedItems.map(\.stickerID) == ["BRA-2"])
        #expect(!exchange.currentUserConfirmed)
        #expect(exchange.counterpartConfirmed)
    }
}
