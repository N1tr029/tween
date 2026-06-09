//
//  FriendRosterTests.swift
//  TweenAppTests
//

import Foundation
import Testing
@testable import TweenApp

@Suite(.serialized)
struct FriendRosterTests {

    init() {
        // Only clear our own key — LocationCacheTests shares this App Group suite, and
        // wiping the whole persistent domain would race with its tests.
        FriendRoster.clear()
    }

    @Test func loadReturnsEmptyWhenUnset() {
        #expect(FriendRoster.load() == [])
    }

    @Test func roundTripsMultipleFriendsPreservingOrder() {
        let friends = [
            TweenFriend(name: "Maya"),
            TweenFriend(name: "Jordan"),
            TweenFriend(name: "Sam"),
        ]
        FriendRoster.save(friends)
        #expect(FriendRoster.load() == friends)
    }

    @Test func renameInPlaceKeepsIdentity() {
        let original = TweenFriend(name: "Maya")
        FriendRoster.save([original])

        var renamed = original
        renamed.name = "Maya P."
        FriendRoster.save([renamed])

        let loaded = FriendRoster.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == original.id)
        #expect(loaded.first?.name == "Maya P.")
    }

    @Test func deleteReducesCount() {
        let friends = [TweenFriend(name: "A"), TweenFriend(name: "B"), TweenFriend(name: "C")]
        FriendRoster.save(friends)
        FriendRoster.save(friends.filter { $0.name != "B" })

        let loaded = FriendRoster.load()
        #expect(loaded.count == 2)
        #expect(loaded.map(\.name) == ["A", "C"])
    }

    @Test func clearEmptiesRoster() {
        FriendRoster.save([TweenFriend(name: "Maya")])
        FriendRoster.clear()
        #expect(FriendRoster.load() == [])
    }
}
