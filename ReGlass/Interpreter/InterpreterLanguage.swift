import Foundation

/// A language the other person can speak. The interpreter hears it and tells the wearer in English.
///
/// Every language here is in ElevenLabs Scribe v2 (speech to text, 90+ languages; tiers from its capability page) and
/// in Eleven v4 Turbo (the voice's model, 87 languages). Not offered: Albanian, Irish, Basque, Swiss German as such
/// (Scribe hears it as German at best). Korean, Arabic, Hebrew and Thai are in Scribe's "good" tier (10–20 % word
/// errors): offered, less accurate.
struct InterpreterLanguage: Identifiable, Hashable, Sendable {
    /// In English: "French".
    let name: String
    /// ISO 639-1: "fr".
    let code: String
    /// ISO 639-3 spellings Scribe may report: "fra".
    let scribeCodes: [String]
    /// Other ways to say it, lowercased: "francais", "français".
    let aliases: [String]

    var id: String { code }

    static let english = InterpreterLanguage(name: "English", code: "en", scribeCodes: ["eng"],
                                             aliases: ["english"])

    /// The ones the screen shows first.
    static let common: [InterpreterLanguage] = [french, german, italian, spanish, portuguese, romanian, dutch, polish]

    static let french = InterpreterLanguage(name: "French", code: "fr", scribeCodes: ["fra", "fre"],
                                            aliases: ["francais", "français"])
    static let german = InterpreterLanguage(name: "German", code: "de", scribeCodes: ["deu", "ger"],
                                            aliases: ["deutsch", "high german"])
    static let italian = InterpreterLanguage(name: "Italian", code: "it", scribeCodes: ["ita"],
                                             aliases: ["italiano"])
    static let spanish = InterpreterLanguage(name: "Spanish", code: "es", scribeCodes: ["spa"],
                                             aliases: ["espanol", "español", "castilian"])
    static let portuguese = InterpreterLanguage(name: "Portuguese", code: "pt", scribeCodes: ["por"],
                                                aliases: ["portugues", "português", "brazilian", "brazilian portuguese"])
    static let romanian = InterpreterLanguage(name: "Romanian", code: "ro", scribeCodes: ["ron", "rum"],
                                              aliases: ["romana", "română", "moldovan"])
    static let dutch = InterpreterLanguage(name: "Dutch", code: "nl", scribeCodes: ["nld", "dut"],
                                           aliases: ["nederlands", "flemish"])
    static let polish = InterpreterLanguage(name: "Polish", code: "pl", scribeCodes: ["pol"],
                                            aliases: ["polski"])

    /// Everything offered, common ones first, then alphabetical.
    static let all: [InterpreterLanguage] = common + [
        InterpreterLanguage(name: "Bulgarian", code: "bg", scribeCodes: ["bul"], aliases: []),
        InterpreterLanguage(name: "Catalan", code: "ca", scribeCodes: ["cat"], aliases: ["catala", "català"]),
        InterpreterLanguage(name: "Chinese", code: "zh", scribeCodes: ["zho", "cmn", "chi"],
                            aliases: ["mandarin", "mandarin chinese", "chinese mandarin"]),
        InterpreterLanguage(name: "Croatian", code: "hr", scribeCodes: ["hrv"], aliases: ["hrvatski"]),
        InterpreterLanguage(name: "Czech", code: "cs", scribeCodes: ["ces", "cze"], aliases: ["cesky", "čeština"]),
        InterpreterLanguage(name: "Danish", code: "da", scribeCodes: ["dan"], aliases: ["dansk"]),
        InterpreterLanguage(name: "Finnish", code: "fi", scribeCodes: ["fin"], aliases: ["suomi"]),
        InterpreterLanguage(name: "Greek", code: "el", scribeCodes: ["ell", "gre"], aliases: []),
        InterpreterLanguage(name: "Hindi", code: "hi", scribeCodes: ["hin"], aliases: []),
        InterpreterLanguage(name: "Hungarian", code: "hu", scribeCodes: ["hun"], aliases: ["magyar"]),
        InterpreterLanguage(name: "Indonesian", code: "id", scribeCodes: ["ind"], aliases: ["bahasa"]),
        InterpreterLanguage(name: "Japanese", code: "ja", scribeCodes: ["jpn"], aliases: []),
        InterpreterLanguage(name: "Korean", code: "ko", scribeCodes: ["kor"], aliases: []),
        InterpreterLanguage(name: "Arabic", code: "ar", scribeCodes: ["ara"], aliases: []),
        InterpreterLanguage(name: "Hebrew", code: "he", scribeCodes: ["heb"], aliases: ["ivrit"]),
        InterpreterLanguage(name: "Norwegian", code: "no", scribeCodes: ["nor", "nob", "nb"],
                            aliases: ["norsk", "bokmal", "bokmål", "norwegian bokmal"]),
        InterpreterLanguage(name: "Russian", code: "ru", scribeCodes: ["rus"], aliases: []),
        InterpreterLanguage(name: "Serbian", code: "sr", scribeCodes: ["srp"], aliases: ["srpski"]),
        InterpreterLanguage(name: "Slovak", code: "sk", scribeCodes: ["slk", "slo"], aliases: []),
        InterpreterLanguage(name: "Slovenian", code: "sl", scribeCodes: ["slv"], aliases: ["slovene"]),
        InterpreterLanguage(name: "Swedish", code: "sv", scribeCodes: ["swe"], aliases: ["svenska"]),
        InterpreterLanguage(name: "Thai", code: "th", scribeCodes: ["tha"], aliases: []),
        InterpreterLanguage(name: "Turkish", code: "tr", scribeCodes: ["tur"], aliases: ["turkce", "türkçe"]),
        InterpreterLanguage(name: "Ukrainian", code: "uk", scribeCodes: ["ukr"], aliases: []),
        InterpreterLanguage(name: "Vietnamese", code: "vi", scribeCodes: ["vie"], aliases: []),
    ].sorted { $0.name < $1.name }

    /// The language a name means: "French", "french", "Français", "fr". Nil when it isn't offered.
    static func named(_ text: String) -> InterpreterLanguage? {
        let wanted = text.lowercased()
            .replacingOccurrences(of: "the ", with: "")
            .replacingOccurrences(of: " language", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !wanted.isEmpty else { return nil }
        return ([english] + all).first { language in
            language.name.lowercased() == wanted || language.code == wanted || language.aliases.contains(wanted)
                || language.scribeCodes.contains(wanted)
        }
    }
}
