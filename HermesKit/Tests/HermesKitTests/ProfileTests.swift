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
        "skill_count": 3,
        "has_env": false
      }
      """
    )

    #expect(profile.name == "work")
    #expect(profile.isDefault == false)
    #expect(profile.model == "claude-opus-4-8")
    #expect(profile.provider == "anthropic")
    #expect(profile.skillCount == 3)
    #expect(profile.hasEnv == false)
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
    #expect(profile.skillCount == 0)
    #expect(profile.hasEnv == false)
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

  // MARK: - Bot Mode (`ui_meta['hermes-bots']`) — draft contract, see BotMeta.swift

  @Test func decodesBotManagedProfileWithFullMeta() throws {
    let profile = try decode(
      """
      {
        "name": "researcher",
        "is_default": false,
        "model": "gpt-5",
        "provider": "openai",
        "skill_count": 4,
        "has_env": true,
        "ui_meta": {
          "hermes-bots": {
            "title": "Research Buddy",
            "description": "Digs through papers and summarizes findings",
            "hidden": false,
            "groups": ["research-team"]
          }
        }
      }
      """
    )

    #expect(profile.isBotManaged == true)
    #expect(profile.botMeta?.title == "Research Buddy")
    #expect(profile.botMeta?.description == "Digs through papers and summarizes findings")
    #expect(profile.botMeta?.hidden == false)
    #expect(profile.botMeta?.groups == ["research-team"])
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

  @Test func uiMetaWithoutHermesBotsKeyIsNotBotManaged() throws {
    // Some OTHER plugin might use ui_meta for its own purposes — must not be
    // misread as Bot Mode.
    let profile = try decode(
      """
      {
        "name": "custom",
        "is_default": false,
        "ui_meta": { "some-other-plugin": { "foo": "bar" } }
      }
      """
    )

    #expect(profile.isBotManaged == false)
    #expect(profile.botMeta == nil)
  }

  @Test func malformedHermesBotsBlockDecodesToNilRatherThanCrashing() throws {
    // hermes-bots present but not an object — must never fail the whole Profile decode.
    let profile = try decode(
      """
      {
        "name": "weird",
        "is_default": false,
        "ui_meta": { "hermes-bots": "not-an-object" }
      }
      """
    )

    #expect(profile.name == "weird")
    #expect(profile.botMeta == nil)
  }

  @Test func botMetaWithOnlyPartialFieldsDecodesLeniently() throws {
    let profile = try decode(
      """
      {
        "name": "minimal-bot",
        "is_default": false,
        "ui_meta": { "hermes-bots": { "title": "Just A Title" } }
      }
      """
    )

    #expect(profile.botMeta?.title == "Just A Title")
    #expect(profile.botMeta?.description == nil)
    #expect(profile.botMeta?.hidden == nil)
    #expect(profile.botMeta?.groups == nil)
    #expect(profile.isBotManaged == true)
  }
}
