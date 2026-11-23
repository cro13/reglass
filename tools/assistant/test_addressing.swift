import Foundation

@main
struct AddressingTests {
    static func main() {
        var checks = 0
        func expect(_ text: String, _ expected: [String]) {
            let result = Addressing.parse(text).parts
            precondition(result == expected, "\(text) → \(result), expected \(expected)")
            checks += 1
        }
        for name in ["ReGlass", "reglass", "REGLASS", "Re glass", "Re-glass", "Ree glass", "Reeglass", "Ree-glass"] {
            expect("Hey \(name), set a timer for ten minutes.", ["Set a timer for ten minutes."])
            expect("Take a note: buy oat milk and eggs. \(name), set a timer for ten minutes.",
                   ["Take a note: buy oat milk and eggs.", "Set a timer for ten minutes."])
            expect("Type: hey \(name), I'm late.", ["Type: hey \(name), I'm late."])
        }
        expect("Take a note: see you at eight and then hey re glass, set a reminder.",
               ["Take a note: see you at eight", "Set a reminder."])
        expect("Re glass, please set a timer.", ["Please set a timer."])
        expect("Hey ReGlass, re glass, set a timer.", ["Set a timer."])
        expect("Write hey re glass, I'm late.", ["Write hey re glass, I'm late."])
        expect("Take a note: re glass is useful.", ["Take a note: re glass is useful."])
        expect("The ReGlass app is useful.", ["The ReGlass app is useful."])
        expect("I use re glass.", ["I use re glass."])
        expect("Please re-glass the kitchen window.", ["Please re-glass the kitchen window."])
        expect("Take a note. Re. Glass ornaments.", ["Take a note. Re. Glass ornaments."])
        expect("Thanks, ReGlass.", ["Thanks, ReGlass."])
        expect("I saw a werewolf film.", ["I saw a werewolf film."])
        expect("Take a note. Werewolf, set a timer.", ["Take a note. Werewolf, set a timer."])
        expect("", [])
        expect("   ", [])
        let multiple = Addressing.parse("Take a note: oat milk. Re glass, set a timer.").text
        precondition(multiple.contains("1. Take a note: oat milk.\n2. Set a timer."))
        checks += 1
        print("ReGlass spoken addressing: \(checks) checks passed.")
    }
}
