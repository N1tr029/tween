//
//  TweenAppTests.swift
//  TweenAppTests
//
//  Created by Kavi Gandham on 6/6/26.
//

import CoreLocation
import Foundation
import Testing
@testable import TweenApp

struct TweenStateTests {

    @Test func roundTripsThroughURL() throws {
        let original = TweenState(text: "Lunch at Caffè Macs?", latitude: 37.3349, longitude: -122.0090)
        let url = original.encodedURL()
        let decoded = try #require(TweenState(url: url))
        #expect(decoded == original)
    }

    @Test func encodesAsHTTPSUnderLimit() {
        let url = TweenState.placeholder.encodedURL()
        #expect(url.scheme == "https")
        #expect(url.absoluteString.count < 5000)
    }

    @Test func roundTripsTextNeedingPercentEncoding() throws {
        let original = TweenState(text: "Meet @ 5? cost $10 & up #plans", latitude: -33.8688, longitude: 151.2093)
        let decoded = try #require(TweenState(url: original.encodedURL()))
        #expect(decoded == original)
    }

    @Test func returnsNilForUnrelatedURL() {
        #expect(TweenState(url: URL(string: "https://example.com/nope")!) == nil)
    }
}

@Suite(.serialized)
struct LocationCacheTests {

    init() {
        UserDefaults().removePersistentDomain(forName: LocationCache.suiteName)
    }

    @Test func roundTripsCoordinate() {
        LocationCache.save(CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090))
        let loaded = LocationCache.load()
        #expect(loaded?.latitude == 37.3349)
        #expect(loaded?.longitude == -122.0090)
    }

    @Test func roundTripsPeerCoordinateSeparately() {
        LocationCache.savePeer(CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060))
        #expect(LocationCache.load() == nil)
        let loaded = LocationCache.loadPeer()
        #expect(loaded?.latitude == 40.7128)
        #expect(loaded?.longitude == -74.0060)
    }

    @Test func loadReturnsNilWhenEmpty() {
        #expect(LocationCache.load() == nil)
        #expect(LocationCache.loadPeer() == nil)
    }
}
