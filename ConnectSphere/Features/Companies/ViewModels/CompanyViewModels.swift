import Foundation
import Observation

// MARK: - Company page
/// One company page: load it, follow / unfollow.
@MainActor
@Observable
final class CompanyPageViewModel {
    private(set) var company: Company?
    private(set) var isLoading = false
    var errorMessage: String?

    let companyId: String
    private let repository = CompanyRepository()

    init(companyId: String, preloaded: Company? = nil) {
        self.companyId = companyId
        self.company = preloaded
    }

    func load(token: String) async {
        isLoading = company == nil
        defer { isLoading = false }
        do { company = try await repository.company(id: companyId, token: token) }
        catch { if company == nil { errorMessage = friendlyError(error) } }
    }

    /// Shown at once; put back if the server refuses.
    func toggleFollow(token: String) async {
        guard let current = company else { return }
        var optimistic = current
        optimistic.isFollowing.toggle()
        optimistic.followerCount = max(0, current.followerCount + (optimistic.isFollowing ? 1 : -1))
        company = optimistic
        do { company = try await repository.setFollowing(optimistic.isFollowing, id: companyId, token: token) }
        catch {
            company = current
            errorMessage = friendlyError(error)
        }
    }

    func replace(with updated: Company) { company = updated }
}

// MARK: - Company editor
/// Creating or editing a page. Photos are uploaded on save.
@MainActor
@Observable
final class CompanyEditorViewModel {
    var name = ""
    var industry = ""
    var size = ""
    var website = ""
    var headquarters = ""
    var foundedYear = ""
    var about = ""
    /// Newly picked photos (JPEG/PNG data), uploaded on save.
    var newLogo: Data?
    var newCover: Data?
    private(set) var logoUrl: String?
    private(set) var coverUrl: String?
    private(set) var isSaving = false
    var errorMessage: String?

    let editing: Company?
    private let repository = CompanyRepository()
    private let uploads = PostRepository()

    /// The form as it opened, to tell whether Cancel would lose anything.
    private var openedSignature: [String] = []
    private var signature: [String] {
        [name, industry, size, website, headquarters, foundedYear, about,
         newLogo == nil ? "" : "logo", newCover == nil ? "" : "cover"]
    }
    var hasChanges: Bool { signature != openedSignature }

    init(editing: Company? = nil) {
        self.editing = editing
        defer { openedSignature = signature }
        guard let c = editing else { return }
        name = c.name
        industry = c.industry ?? ""
        size = c.size ?? ""
        website = c.website ?? ""
        headquarters = c.headquarters ?? ""
        foundedYear = c.foundedYear.map(String.init) ?? ""
        about = c.about ?? ""
        logoUrl = c.logoUrl
        coverUrl = c.coverUrl
    }

    var canSave: Bool {
        (2...100).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count) && !isSaving
            && (foundedYear.isEmpty || Int(foundedYear) != nil)
    }

    /// The saved page, or nil (with `errorMessage`) if it didn't go through.
    func save(token: String) async -> Company? {
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        do {
            if let newLogo { logoUrl = try await uploads.uploadImage(newLogo) }
            if let newCover { coverUrl = try await uploads.uploadImage(newCover) }
            let form = CompanyRepository.Form(
                name: name, logo_url: logoUrl, cover_url: coverUrl, about: about, industry: industry,
                size: size, website: website, headquarters: headquarters, founded_year: Int(foundedYear))
            if let editing {
                return try await repository.update(id: editing.id, form, token: token)
            }
            return try await repository.create(form, token: token)
        } catch {
            errorMessage = friendlyError(error)
            return nil
        }
    }
}

// MARK: - Company search
/// Search's Companies tab: pages matching the text (all pages when empty).
@MainActor
@Observable
final class CompanySearchViewModel {
    private(set) var results: [Company] = []
    private(set) var isLoading = false
    var errorMessage: String?

    private let repository = CompanyRepository()
    private var task: Task<Void, Never>?

    func search(_ query: String, token: String) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            isLoading = true
            defer { isLoading = false }
            do {
                let found = try await repository.search(query.trimmingCharacters(in: .whitespacesAndNewlines), token: token)
                guard !Task.isCancelled else { return }
                results = found
                errorMessage = nil
            } catch {
                if !Task.isCancelled { errorMessage = friendlyError(error) }
            }
        }
    }

    /// A page just created or edited shows up without searching again.
    func upsert(_ company: Company) {
        if let i = results.firstIndex(where: { $0.id == company.id }) { results[i] = company }
        else { results.insert(company, at: 0) }
    }
}
