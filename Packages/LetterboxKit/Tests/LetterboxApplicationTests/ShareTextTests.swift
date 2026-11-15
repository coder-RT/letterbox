import Foundation
import Testing
@testable import LetterboxApplication

@Suite("Share text for people without Letterbox")
struct ShareTextTests {
    @Test func inviteHasTheLinkAndANameOnlyWhenItMeansSomething() {
        let anonymous = ShareText.invite(from: "anon4821")
        #expect(anonymous.contains(ShareText.inviteLink))
        #expect(!anonymous.contains("anon4821"))
        #expect(anonymous.hasPrefix("I'm using Letterbox"))

        let named = ShareText.invite(from: "  Ana\n")
        #expect(named.hasPrefix("Ana here. I'm using Letterbox"))
        #expect(named.contains("no internet or signal"))
        #expect(ShareText.invite(from: "").hasPrefix("I'm using Letterbox"))
    }

    @Test func outsideMessagesAreTrimmedAndEmptyOnesRefused() {
        #expect(ShareText.outside("  at the hut by 6 \n", addInvite: false) == "at the hut by 6")
        #expect(ShareText.outside("   \n ", addInvite: true) == nil)
        #expect(ShareText.outside("", addInvite: false) == nil)
    }

    @Test func theInviteLineIsAddedOnlyWhenAsked() {
        let plain = ShareText.outside("hello", addInvite: false)
        let withInvite = ShareText.outside("hello", addInvite: true)
        #expect(plain == "hello")
        #expect(withInvite?.hasPrefix("hello\n\n— Sent from Letterbox") == true)
        #expect(withInvite?.hasSuffix(ShareText.inviteLink) == true)
    }

    @Test func sharedTextCarriesNoPersonalIdentifiers() {
        // Only the public repository link and the user's chosen nickname ever go out.
        for text in [ShareText.invite(from: "anon1234"), ShareText.outside("x", addInvite: true) ?? ""] {
            #expect(text.range(of: #"@[A-Za-z0-9.-]+\.[a-z]{2,}"#, options: .regularExpression) == nil, "no email addresses")
            #expect(text.contains("github.com/coder-RT/letterbox"))
        }
    }
}
