# Third-party components

ReGlass is licensed under the GNU Affero General Public License v3.0 ([LICENSE](LICENSE)). It includes, or builds
from, the components below. Each keeps its own licence.

## Code

| Component | Used for | Licence | Where |
|---|---|---|---|
| [libopus](https://opus-codec.org/) (Xiph.Org Foundation and contributors) | Decoding the glasses' microphone and encoding replies for them | BSD 3-Clause, plus the royalty-free Opus patent licences | Built from source through swift-opus. Licence: [`ReGlassKit/Sources/ReGlassKit/Resources/opus-LICENSE.txt`](ReGlassKit/Sources/ReGlassKit/Resources/opus-LICENSE.txt), which ships inside the app |
| [swift-opus](https://github.com/alta/swift-opus) by Alta Software | Packages libopus for Swift Package Manager. Pinned at exactly 0.0.2 in [`ReGlassKit/Package.swift`](ReGlassKit/Package.swift); only its `Copus` product (the libopus C sources) is used | BSD 3-Clause | Fetched by Xcode at build time; its licence ships in the app as `ReGlassKit/Sources/ReGlassKit/Resources/swift-opus-LICENSE.txt` |

`ReGlassAssistant` has no third-party dependencies. The repository has no `Package.resolved`: the only remote
package is pinned to an exact version in `ReGlassKit/Package.swift`.

## Fonts and icons

| Component | Used for | Licence | Where |
|---|---|---|---|
| [Inter Display](https://github.com/rsms/inter) SemiBold, by The Inter Project Authors | ReGlass's display titles | SIL Open Font License 1.1 | [`ReGlass/Fonts/InterDisplay-SemiBold.ttf`](ReGlass/Fonts/InterDisplay-SemiBold.ttf), licence in [`ReGlass/Fonts/Inter-OFL.txt`](ReGlass/Fonts/Inter-OFL.txt) |
| [Phosphor Icons](https://phosphoricons.com) (Regular weight), by Phosphor Icons | The six category symbols: shopping-cart, check-circle, calendar-blank, lightbulb-filament, briefcase, tag, turned into SF Symbol templates | MIT | `ReGlass/Assets.xcassets/Categories/`, licence in [`Phosphor-MIT.dataset/Phosphor-MIT.txt`](ReGlass/Assets.xcassets/Categories/Phosphor-MIT.dataset/Phosphor-MIT.txt) |
| SF Symbols and Apple's system fonts | Every other icon, and body text | Apple's terms for SF Symbols and Xcode | Supplied by iOS; not in this repository |

## Artwork

The app icon, the Live Activity mark and the glasses picture on the setup and glasses screens were made for ReGlass
with an AI image model, from a written description of generic browline glasses. They show no real product, logo or
brand, and are released with the rest of ReGlass under its licence.

## Data and services

ReGlass uses these services. Each has its own terms, which you accept with your own account or key.

| Service | Used for | Terms |
|---|---|---|
| [Anthropic](https://www.anthropic.com) Claude API | The assistant's answers, web search and web pages, interpreter translations | Your own Anthropic key and Anthropic's terms |
| [ElevenLabs](https://elevenlabs.io) | Optional voice and speech recognition; the interpreter's speech recognition | Your own ElevenLabs key and ElevenLabs' terms |
| [Open-Meteo](https://open-meteo.com) | Weather forecasts | Free for non-commercial use. Data under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); the credit "Weather Data by Open-Meteo.com" is in the Weather connector's options |
| Meta | Sign-in, the signed hand-over of ownership during setup, firmware updates and optional factory wake word downloads | Setup uses client values from your copy of Meta AI for Android. Meta's terms don't permit third-party apps to use these values. Using them may breach those terms, and Meta could restrict your account. [Meta client tokens and risks](docs/META-CREDENTIALS.md) |
| Apple frameworks (Speech, AVFoundation, AlarmKit, EventKit, MusicKit, WidgetKit and others) | Speech recognition, voice, alarms, calendar, music, Live Activities | Apple's developer terms |

The helper in `tools/meta-tokens/` uses only Python's standard library. It can call `apksigner` from Google's Android
SDK build-tools if you have it installed; that tool isn't included.

## Trademarks

Meta, Meta AI and "Hey Meta" are trademarks of Meta Platforms, Inc. Ray-Ban and Clubmaster are trademarks of their
owners in the EssilorLuxottica group. Oakley is a trademark of its owner. Claude and Anthropic are trademarks of
Anthropic, PBC. ElevenLabs is a trademark of ElevenLabs. Apple, iPhone, iOS, Xcode, Apple Music, Siri and SF Symbols
are trademarks of Apple Inc. Google is a trademark of Google LLC. Other names belong to their owners.

**ReGlass is not affiliated with, endorsed by or sponsored by Meta Platforms, EssilorLuxottica, Anthropic,
ElevenLabs or Apple.** The names are used only to say what ReGlass works with.
