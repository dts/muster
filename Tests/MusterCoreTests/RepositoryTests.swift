import Testing
@testable import MusterCore

@Suite("Repository Tests")
struct RepositoryTests {
    @Test("Slug generation from SSH URL")
    func slugFromSSH() {
        let url = "git@github.com:user/repo-name.git"
        let slug = Repository.slug(from: url)
        #expect(slug == "github-com-user-repo-name")
    }

    @Test("Slug generation from HTTPS URL")
    func slugFromHTTPS() {
        let url = "https://github.com/user/repo-name.git"
        let slug = Repository.slug(from: url)
        #expect(slug == "github-com-user-repo-name")
    }

    @Test("Display name extraction")
    func displayName() {
        let url = "git@github.com:user/my-awesome-repo.git"
        let name = Repository.displayName(from: url)
        #expect(name == "my-awesome-repo")
    }
}

@Suite("PathService Tests")
struct PathServiceTests {
    @Test("Slugify removes special characters")
    func slugify() {
        let service = PathService.shared
        #expect(service.slugify("Feature/Auth") == "feature-auth")
        #expect(service.slugify("bug fix 123") == "bug-fix-123")
        #expect(service.slugify("some_thing") == "some-thing")
    }

    @Test("Checkout path structure")
    func checkoutPath() {
        let service = PathService.shared
        let path = service.checkoutPath(repoDisplayName: "myrepo", checkoutName: "feature-x")
        #expect(path.path.hasSuffix("muster/myrepo/feature-x"))
    }
}
