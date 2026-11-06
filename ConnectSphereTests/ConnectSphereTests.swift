//
//  ConnectSphereTests.swift
//  ConnectSphereTests
//
//  Created by Trị Minh on 14/5/26.
//

import Foundation
import Testing
@testable import ConnectSphere

struct ConnectSphereTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
        // Swift Testing Documentation
        // https://developer.apple.com/documentation/testing
    }

}

// MARK: - Test fixtures

/// Shared helpers for building minimal, valid model instances for view-model tests.
/// Only pure/computed logic is exercised here, network-backed flows (repository
/// calls) are intentionally left untested, per the project's testing scope.
private enum Fixtures {
    static func user(id: String = "u1", postCount: Int = 3) -> UserProfile {
        UserProfile(
            id: id,
            name: "Test User",
            username: "testuser",
            avatarColor: "#FFAA00",
            bio: "bio",
            skills: [],
            interests: [],
            followerCount: 0,
            followingCount: 0,
            postCount: postCount
        )
    }

    static func post(id: String = "p1", content: String = "hello", author: UserProfile? = nil) -> Post {
        Post(
            id: id,
            author: author ?? user(),
            content: content,
            timestamp: Date(),
            mode: .hobby,
            likeCount: 0,
            commentCount: 0,
            shareCount: 0,
            tags: []
        )
    }
}

// MARK: - ProfileViewModel

@MainActor
struct ProfileViewModelTests {

    @Test func removePostRemovesMatchingPostAndDecrementsPostCount() {
        let vm = ProfileViewModel()
        vm.user = Fixtures.user(postCount: 3)
        vm.posts = [Fixtures.post(id: "p1"), Fixtures.post(id: "p2")]

        vm.removePost(id: "p1")

        #expect(vm.posts.map(\.id) == ["p2"])
        #expect(vm.user?.postCount == 2)
    }

    @Test func removePostClampsPostCountAtZero() {
        let vm = ProfileViewModel()
        vm.user = Fixtures.user(postCount: 0)
        vm.posts = [Fixtures.post(id: "p1")]

        vm.removePost(id: "p1")

        #expect(vm.user?.postCount == 0) // max(0 - 1, 0) must never go negative
    }

    @Test func removePostIsNoOpWhenIdIsNotPresent() {
        let vm = ProfileViewModel()
        vm.user = Fixtures.user(postCount: 5)
        vm.posts = [Fixtures.post(id: "p1")]

        vm.removePost(id: "does-not-exist")

        #expect(vm.posts.map(\.id) == ["p1"])
        #expect(vm.user?.postCount == 5) // unchanged: post was never "present"
    }

    @Test func removePostWithNilUserDoesNotCrash() {
        let vm = ProfileViewModel()
        vm.user = nil
        vm.posts = [Fixtures.post(id: "p1")]

        vm.removePost(id: "p1")

        #expect(vm.posts.isEmpty)
        #expect(vm.user == nil)
    }

    @Test func updatePostReplacesMatchingPostInPlace() {
        let vm = ProfileViewModel()
        vm.posts = [Fixtures.post(id: "p1", content: "old"), Fixtures.post(id: "p2", content: "other")]

        vm.updatePost(Fixtures.post(id: "p1", content: "new"))

        #expect(vm.posts[0].content == "new")
        #expect(vm.posts[1].content == "other") // position preserved, unrelated post untouched
    }

    @Test func updatePostIsNoOpWhenIdIsNotPresent() {
        let vm = ProfileViewModel()
        vm.posts = [Fixtures.post(id: "p1", content: "old")]

        vm.updatePost(Fixtures.post(id: "missing", content: "new"))

        #expect(vm.posts.count == 1)
        #expect(vm.posts[0].content == "old")
    }
}

// MARK: - CreatePostViewModel

@MainActor
struct CreatePostViewModelTests {

    @Test func submitPostBlocksFullyEmptyContentWithNoMediaOrLink() {
        let vm = CreatePostViewModel()
        var succeeded = false

        vm.submitPost(
            content: "",
            mode: .hobby,
            privacy: .publicAll,
            authToken: nil,
            selectedMedia: [],
            onSuccess: { _ in succeeded = true }
        )

        // The empty-content guard returns before any Task is spawned, so this
        // is fully synchronous. No network call is ever attempted.
        #expect(succeeded == false)
        #expect(vm.isPosting == false)
    }

    @Test func submitPostBlocksWhitespaceOnlyContent() {
        let vm = CreatePostViewModel()
        var succeeded = false

        vm.submitPost(
            content: "   \n\t  ",
            mode: .hobby,
            privacy: .publicAll,
            authToken: nil,
            selectedMedia: [],
            onSuccess: { _ in succeeded = true }
        )

        #expect(succeeded == false)
        #expect(vm.isPosting == false)
    }

    @Test func detectAndFetchLinkKeepsPreviewWhenTextHasNoLink() {
        let vm = CreatePostViewModel()
        vm.linkPreview = LinkPreviewDTO(
            url: "https://example.com", title: "Example", description: nil, image: nil, siteName: nil
        )

        // The URL is taken out of the text once the card shows, so a text
        // without a link must not drop the card.
        vm.detectAndFetchLink("just plain text, no url here") { }

        #expect(vm.linkPreview != nil)
    }

    @Test func detectAndFetchLinkKeepsPreviewWhenSameUrlIsDetectedAgain() {
        let vm = CreatePostViewModel()
        // A URL with a path segment so NSDataDetector's normalization (which
        // can append a trailing "/" to a bare host) doesn't change the string,
        // keeping the "same URL as already-fetched" comparison exact.
        let existing = LinkPreviewDTO(
            url: "https://example.com/article", title: "Example", description: nil, image: nil, siteName: nil
        )
        vm.linkPreview = existing

        // Same URL as the already-fetched preview -> should short-circuit
        // without clearing or scheduling a re-fetch.
        var shown = false
        vm.detectAndFetchLink("check this out https://example.com/article") { shown = true }

        #expect(vm.linkPreview?.url == existing.url)
        #expect(shown, "the composer is told to take the URL out of the text")
    }
}
