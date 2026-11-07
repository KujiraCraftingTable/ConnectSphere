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

    @Test func leftEdgeFloorsAtFiveKilometres() {
        #expect(RadiusScale.km(forFraction: 0) == 5)
        #expect(RadiusScale.km(forFraction: -0.2) == 5)
    }

    @Test func touchesSnapToTheNearestStep() {
        #expect(RadiusScale.km(forFraction: RadiusScale.fraction(forKm: 7)) == 5)
        #expect(RadiusScale.km(forFraction: RadiusScale.fraction(forKm: 8)) == 10)
        #expect(RadiusScale.km(forFraction: RadiusScale.fraction(forKm: 28)) == 30)
    }

    @Test func oldStoredValuesMoveOntoAStep() {
        #expect(RadiusScale.snapped(0) == 0)
        #expect(RadiusScale.snapped(1) == 5)
        #expect(RadiusScale.snapped(12) == 10)
        #expect(RadiusScale.snapped(13) == 15)
        #expect(RadiusScale.snapped(30) == 30)
        #expect(RadiusScale.snapped(45) == 30)
    }

    @Test func gapMidpointDecidesBetweenThirtyAndNoLimit() {
        let mid = span + (1 - span) / 2
        #expect(RadiusScale.km(forFraction: mid - 0.01) == 30)
        #expect(RadiusScale.km(forFraction: mid + 0.01) == 0)
    }

    @Test func everyStepRoundTrips() {
        for km in RadiusScale.ticks {
            #expect(RadiusScale.km(forFraction: RadiusScale.fraction(forKm: km)) == km, "\(km)")
        }
    }
}
