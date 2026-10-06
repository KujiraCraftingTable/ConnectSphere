import Testing
@testable import ConnectSphere

struct RadiusScaleTests {
    private let span = RadiusScale.linearSpan

    @Test func distancesAreLinear() {
        #expect(abs(RadiusScale.fraction(forKm: 5) - span / 6) < 1e-9)
        #expect(abs(RadiusScale.fraction(forKm: 15) - span / 2) < 1e-9)
        #expect(abs(RadiusScale.fraction(forKm: 30) - span) < 1e-9)
    }

    @Test func noLimitIsTheFarEnd() {
        #expect(RadiusScale.fraction(forKm: 0) == 1)
        #expect(RadiusScale.km(forFraction: 1) == 0)
    }

    @Test func leftEdgeFloorsAtOneKilometre() {
        #expect(RadiusScale.km(forFraction: 0) == 1)
        #expect(RadiusScale.km(forFraction: -0.2) == 1)
    }

    @Test func gapMidpointDecidesBetweenThirtyAndNoLimit() {
        let mid = span + (1 - span) / 2
        #expect(RadiusScale.km(forFraction: mid - 0.01) == 30)
        #expect(RadiusScale.km(forFraction: mid + 0.01) == 0)
    }

    @Test func everyWholeKilometreRoundTrips() {
        for km in 1...30 {
            #expect(RadiusScale.km(forFraction: RadiusScale.fraction(forKm: km)) == km, "\(km)")
        }
    }
}
