import Foundation

enum SavedChatMessageChecks {
    static func run() throws {
        let name = "WearTAK.saved-chat-checks.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let otherName = name + ".other-device"
        let otherDevice = UserDefaults(suiteName: otherName)!
        defer {
            defaults.removePersistentDomain(forName: name)
            otherDevice.removePersistentDomain(forName: otherName)
        }
        let builtIns = TAKChatMessage.quickMessages
        precondition(builtIns == ["Roger", "Negative", "Objective Sighted", "In Position"])
        var saved = try SavedChatMessages(defaults: defaults)
        precondition(saved.messages.isEmpty)
        let text = try saved.add("  Returning to base  ", defaults: defaults)
        precondition(text == "Returning to base" && saved.messages == [text])
        let duplicate = try saved.add("RETURNING TO BASE", defaults: defaults)
        precondition(duplicate == text && saved.messages == [text])
        for preset in builtIns {
            let result = try saved.add(" \(preset.lowercased()) ", defaults: defaults)
            precondition(result == preset && saved.messages == [text])
        }
        let restored = try SavedChatMessages(defaults: defaults)
        precondition(restored.messages == [text])
        let separate = try SavedChatMessages(defaults: otherDevice)
        precondition(separate.messages.isEmpty, "Saved replies must be local to the device")
        for invalid in ["", "  ", "\n", "a\nb", "a\tb", "a\rb", "a\u{2028}b",
                        "\u{0}invalid", String(repeating: "a", count: 129),
                        "a" + String(repeating: "\u{0301}", count: 2_000)] {
            do {
                try saved.add(invalid, defaults: defaults)
                preconditionFailure("Invalid quick message accepted")
            } catch SavedChatMessages.Failure.invalidText {}
        }
        let escaped = try saved.add("A&B <help> \"now\" \u{1F44D}", defaults: defaults)
        let maximum = try saved.add(String(repeating: "x", count: 128), defaults: defaults)
        precondition(saved.messages == [text, escaped, maximum])
        let xml = try TAKChatMessage.outgoing(senderUID: "sender", senderCallSign: "Sender",
            recipientUID: "recipient", recipientCallSign: "Recipient", text: escaped)
        let parsed = TAKChatMessage.parse(xml, ownUID: "recipient")
        precondition(parsed?.text == escaped, "Saved replies must use the existing escaped GeoChat path")
        saved.remove(text, defaults: defaults)
        let afterDelete = try SavedChatMessages(defaults: defaults)
        precondition(afterDelete.messages == [escaped, maximum])
        precondition(TAKChatMessage.quickMessages == builtIns, "Built-ins must not be changed by custom operations")
        defaults.set([" First ", "first", "ROGER", "Second"], forKey: SavedChatMessages.storageKey)
        let deduplicated = try SavedChatMessages(defaults: defaults)
        precondition(deduplicated.messages == ["First", "Second"])
        for corrupted: Any in [42, ["Valid", "\u{0}invalid"]] {
            defaults.set(corrupted, forKey: SavedChatMessages.storageKey)
            let original = defaults.object(forKey: SavedChatMessages.storageKey) as! NSObject
            do {
                _ = try SavedChatMessages(defaults: defaults)
                preconditionFailure("Corrupt saved messages silently accepted")
            } catch SavedChatMessages.Failure.unreadable {}
            precondition(original.isEqual(defaults.object(forKey: SavedChatMessages.storageKey)),
                         "A failed load must not overwrite existing data")
        }
        print("PASS: custom quick message validation, built-in/custom deduplication, per-device persistence, deletion and GeoChat round-trip")
    }
}
