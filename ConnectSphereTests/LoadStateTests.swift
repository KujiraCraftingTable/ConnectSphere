import Testing
@testable import ConnectSphere

struct LoadStateTests {
    @Test func errorMessageOnlyForFailed() {
        #expect(LoadState.idle.errorMessage == nil)
        #expect(LoadState.loading.errorMessage == nil)
        #expect(LoadState.loaded.errorMessage == nil)
        #expect(LoadState.failed("offline").errorMessage == "offline")
    }

    @Test func isLoadingOnlyForLoading() {
        #expect(LoadState.loading.isLoading)
        #expect(!LoadState.idle.isLoading)
        #expect(!LoadState.failed("x").isLoading)
    }
}
