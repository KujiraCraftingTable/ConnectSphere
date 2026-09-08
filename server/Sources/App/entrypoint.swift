import Vapor
import Logging

@main
struct Entrypoint {
    static func main() async throws {
        // Load `../backend/.env` (overridable via DOTENV_PATH) into the process
        // environment BEFORE anything reads it, so the Swift server shares the
        // exact same config the Node backend uses. Real env vars already set
        // win — they are not overwritten.
        loadDotEnv(ProcessInfo.processInfo.environment["DOTENV_PATH"] ?? "../backend/.env")

        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        let app = try await Application.make(env)
        do {
            try await configure(app)
            try await app.execute()
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    /// Minimal `.env` parser — `KEY=VALUE` lines, `#` comments, optional quotes.
    /// Deliberately tiny; the file it reads is the project's own `backend/.env`.
    static func loadDotEnv(_ path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty, ProcessInfo.processInfo.environment[key] == nil else { continue }
            setenv(key, value, 0)
        }
    }
}
