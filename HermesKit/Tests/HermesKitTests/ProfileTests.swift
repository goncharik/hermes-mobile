import Foundation
import Testing

@testable import HermesKit

struct ProfileTests {
  private func decode(_ json: String) throws -> Profile {
    try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
  }

  @Test func decodesFullDefaultPayload() throws {
    let profile = try decode(
      """
      {
        "name": "default",
        "is_default": true,
        "model": "gpt-5",
        "provider": "openai",
        "skill_count": 12,
        "has_env": true
      }
      """
    )

    #expect(profile.name == "default")
    #expect(profile.isDefault == true)
    #expect(profile.model == "gpt-5")
    #expect(profile.provider == "openai")
    #expect(profile.skillCount == 12)
    #expect(profile.hasEnv == true)
    #expect(profile.hasAvatar == false)
    #expect(profile.id == "default")
  }

  @Test func decodesCustomProfilePayload() throws {
    let profile = try decode(
      """
      {
        "name": "work",
        "is_default": false,
        "model": "claude-opus-4-8",
        "provider": "anthropic",
        "display_name": "Work",
        "description": "Writing and editing",
        "skill_count": 3,
        "has_env": false,
        "has_avatar": true
      }
      """
    )

    #expect(profile.name == "work")
    #expect(profile.isDefault == false)
    #expect(profile.model == "claude-opus-4-8")
    #expect(profile.provider == "anthropic")
    #expect(profile.displayName == "Work")
    #expect(profile.description == "Writing and editing")
    #expect(profile.skillCount == 3)
    #expect(profile.hasEnv == false)
    #expect(profile.hasAvatar == true)
  }

  @Test func decodesWithMissingOptionalsSucceeds() throws {
    let profile = try decode(
      """
      {
        "name": "minimal",
        "is_default": false
      }
      """
    )

    #expect(profile.name == "minimal")
    #expect(profile.isDefault == false)
    #expect(profile.model == nil)
    #expect(profile.provider == nil)
    #expect(profile.description == nil)
    #expect(profile.skillCount == 0)
    #expect(profile.hasEnv == false)
    #expect(profile.hasAvatar == false)
  }

  @Test func decodesProfilesArrayWrapper() throws {
    struct Wrapper: Decodable { let profiles: [Profile] }
    let wrapper = try JSONDecoder().decode(
      Wrapper.self,
      from: Data(
        """
        { "profiles": [
          { "name": "default", "is_default": true },
          { "name": "work", "model": "gpt-5" }
        ] }
        """.utf8
      )
    )

    #expect(wrapper.profiles.map(\.id) == ["default", "work"])
    #expect(wrapper.profiles[0].isDefault == true)
    #expect(wrapper.profiles[1].model == "gpt-5")
    #expect(wrapper.profiles[1].isDefault == false)
  }

  @Test func decodesActualBotModeMetadataAndTopLevelDescription() throws {
    let profile = try decode(
      """
      {
        "name": "researcher",
        "is_default": false,
        "description": "Digs through papers and summarizes findings",
        "has_avatar": true,
        "ui_meta": {
          "hermes-bots": {
            "title": "Research Buddy",
            "shape": "blob",
            "color": "blue",
            "imageKind": "shape",
            "custom": true,
            "created": 1755710000000,
            "pinned": false,
            "hidden": false,
            "groups": ["research-team"],
            "group": "legacy-team"
          }
        }
      }
      """
    )

    #expect(profile.isBotManaged == true)
    #expect(profile.description == "Digs through papers and summarizes findings")
    #expect(profile.hasAvatar == true)
    #expect(profile.botMeta?.title == "Research Buddy")
    #expect(profile.botMeta?.shape == "blob")
    #expect(profile.botMeta?.color == "blue")
    #expect(profile.botMeta?.imageKind == "shape")
    #expect(profile.botMeta?.custom == true)
    #expect(profile.botMeta?.pinned == false)
    #expect(profile.botMeta?.groups == ["research-team"])
    #expect(profile.botMeta?.group == "legacy-team")
  }

  @Test func plainProfileWithoutUIMetaIsNotBotManaged() throws {
    let profile = try decode(
      """
      { "name": "default", "is_default": true }
      """
    )

    #expect(profile.isBotManaged == false)
    #expect(profile.botMeta == nil)
  }

  @Test func emptyHermesBotsBlockIsNotBotManaged() throws {
    let profile = try decode(
      """
      {
        "name": "empty",
        "ui_meta": { "hermes-bots": {} }
      }
      """
    )

    #expect(profile.isBotManaged == false)
    #expect(profile.botMeta != nil)
  }

  @Test func uiMetaWithoutHermesBotsKeyIsNotBotManaged() throws {
    let profile = try decode(
      """
      {
        "name": "custom",
        "ui_meta": { "some-other-plugin": { "foo": "bar" } }
      }
      """
    )

    #expect(profile.isBotManaged == false)
    #expect(profile.botMeta == nil)
  }

  @Test func malformedHermesBotsBlockDecodesToNilRatherThanCrashing() throws {
    let profile = try decode(
      """
      {
        "name": "weird",
        "ui_meta": { "hermes-bots": "not-an-object" }
      }
      """
    )

    #expect(profile.name == "weird")
    #expect(profile.botMeta == nil)
  }

  @Test func unknownBotMetadataStillMarksProfileAsManaged() throws {
    let profile = try decode(
      """
      {
        "name": "future-bot",
        "ui_meta": { "hermes-bots": { "new_desktop_field": true } }
      }
      """
    )

    #expect(profile.isBotManaged == true)
    #expect(profile.botMeta?.title == nil)
  }
}
