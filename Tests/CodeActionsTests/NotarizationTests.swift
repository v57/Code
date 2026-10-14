import Foundation
import Testing
@testable import CodeActions

struct NotarizationTests {
  @Test func parsesOnlyDeveloperIDApplicationIdentities() {
    let output = """
      1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: Jane Doe (N97KT34BX7)"
      2) 1123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Jane Doe (AUCR797TMH)"
      3) 2123456789ABCDEF0123456789ABCDEF01234567 "Apple Distribution: Example Ltd. (T8BYC53S7N)"
      4) 3123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Дмитрий (Personal) (ZZZZ99ZZZZ)"
         4 valid identities found
    """
    #expect(Notarization.parseDeveloperIDIdentities(output) == [
      DeveloperIDIdentity(name: "Developer ID Application: Jane Doe (AUCR797TMH)", teamID: "AUCR797TMH"),
      DeveloperIDIdentity(name: "Developer ID Application: Дмитрий (Personal) (ZZZZ99ZZZZ)", teamID: "ZZZZ99ZZZZ"),
    ])
  }

  @Test func parsesNoIdentities() {
    #expect(Notarization.parseDeveloperIDIdentities("     0 valid identities found\n").isEmpty)
  }

  @Test func profileStatusReadsHistoryResult() {
    #expect(Notarization.profileStatus(exitCode: 0, output: "{\"history\":[]}") == .valid)
    #expect(Notarization.profileStatus(
      exitCode: 69,
      output: "Error: No Keychain password item found for profile: notary\n"
    ) == .missing)
    #expect(Notarization.profileStatus(exitCode: 1, output: "Error: HTTP status code: 401. Invalid credentials.\n")
      == .failed("Error: HTTP status code: 401. Invalid credentials."))
    #expect(Notarization.profileStatus(exitCode: 3, output: "") == .failed("notarytool exited with status 3."))
  }

  @Test func storeArgumentsPerMethod() {
    #expect(Notarization.storeArguments(
      profile: "notary",
      credentials: .apiKey(path: "/k/AuthKey_ABC.p8", keyID: "ABC", issuerID: "1-2-3")
    ) == ["notarytool", "store-credentials", "notary", "--key", "/k/AuthKey_ABC.p8", "--key-id", "ABC", "--issuer", "1-2-3"])
    #expect(Notarization.storeArguments(
      profile: "notary",
      credentials: .apiKey(path: "/k/AuthKey_ABC.p8", keyID: "ABC", issuerID: "")
    ) == ["notarytool", "store-credentials", "notary", "--key", "/k/AuthKey_ABC.p8", "--key-id", "ABC"])
    #expect(Notarization.storeArguments(
      profile: "work",
      credentials: .appleID(appleID: "jane@example.com", teamID: "AUCR797TMH")
    ) == ["notarytool", "store-credentials", "work", "--apple-id", "jane@example.com", "--team-id", "AUCR797TMH"])
  }

  #if os(macOS)
    /// The answer goes to the terminal the tool reads its prompt from, with
    /// echo off, as notarytool reads the app-specific password.
    @Test func answersAPromptOnTheTerminal() {
      let script = "stty -echo; printf 'Password: '; read secret < /dev/tty; stty echo; echo; echo \"got ${#secret}\"; exit 3"
      let result = Notarization.runOnTerminal("/bin/sh", ["sh", "-c", script], answering: "password", with: "hunter2\n", timeout: 10)
      #expect(result.exitCode == 3)
      #expect(result.output.contains("got 7"))
      #expect(!result.output.contains("hunter2"))
    }

    @Test func givesUpOnAToolThatNeverFinishes() {
      let result = Notarization.runOnTerminal("/bin/sleep", ["sleep", "30"], answering: "password", with: "\n", timeout: 1)
      #expect(result.exitCode == -1)
      #expect(result.output.contains("Timed out"))
    }
  #endif
}
