import Vapor
import SQLKit

/// A seller's listing auto-reply (migration 072). When a buyer sends one of
/// the seller's listings into their 1-on-1 chat ("Message seller"), the
/// seller's canned answer follows straight away. Once per buyer per listing.
///
/// It's stored as the seller's message but skips the message-request gate:
/// only the seller writing back themselves accepts a stranger's request.
/// It isn't pushed to the seller either; it's their own words.
enum ListingAutoReply {
    static func afterMessage(_ msg: MessageObject, conversationID: String, participants: [String],
                             hub: SocketHub, on db: any SQLDatabase) async throws {
        guard msg.message_type == "post", let postID = msg.shared_post_id, participants.count == 2,
              let reply = try await ListingStore.autoReply(forPost: postID, on: db),
              reply.seller_id.caseInsensitiveCompare(msg.sender_id) != .orderedSame,
              participants.contains(where: { $0.caseInsensitiveCompare(reply.seller_id) == .orderedSame }),
              try await ListingStore.claimAutoReply(listingID: reply.listing_id, buyerID: msg.sender_id, on: db)
        else { return }
        let id = try await ChatStore.insertMessage(conversationID, senderID: reply.seller_id, content: reply.text,
            messageType: "text", mediaUrl: nil, replyToMessageID: nil, voiceDuration: nil, voiceWaveform: nil,
            isAutoReply: true, on: db)
        guard let autoMessage = try await ChatStore.messageByID(id, on: db) else { return }
        hub.emitConversation(conversationID, participants: participants, event: "new_message", autoMessage)
    }
}
