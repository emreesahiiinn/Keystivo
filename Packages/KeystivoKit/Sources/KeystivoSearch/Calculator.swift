import Foundation

/// Safe arithmetic expression evaluator (no `NSExpression`, no code execution).
///
/// Grammar: + - * / % ^, parentheses, unary minus, implicit multiplication
/// ("2(3+4)", "2pi"), functions (sqrt, cbrt, abs, ln, log, log2, exp, sin, cos,
/// tan, asin, acos, atan, round, floor, ceil), constants (pi, π, e, tau) and
/// percentages ("200 * 15%"). Accepts both "," and "." decimal separators.
nonisolated public enum Calculator {
    public enum Failure: Error, Equatable {
        case invalid
        case divisionByZero
    }

    public static func evaluate(_ input: String) throws(Failure) -> Double {
        var parser = Parser(tokens: try tokenize(input))
        let value = try parser.parseExpression()
        guard parser.isAtEnd else { throw .invalid }
        guard value.isFinite else { throw .divisionByZero }
        return value
    }

    /// Whether the text plausibly is a calculation (so the launcher can show it).
    public static func looksLikeExpression(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return false }
        let hasDigit = trimmed.contains { $0.isNumber }
        let hasOperator = trimmed.contains { "+-*/^%×÷()".contains($0) } || functions.keys.contains { trimmed.lowercased().hasPrefix($0 + "(") }
        return hasDigit && (hasOperator || trimmed.lowercased().contains("pi"))
    }

    /// Formats a result for display using the given locale.
    public static func format(_ value: Double, locale: Locale = .current) -> String {
        if value.rounded() == value, abs(value) < 1e15 {
            return value.formatted(.number.locale(locale).grouping(.automatic).precision(.fractionLength(0)))
        }
        if abs(value) >= 1e15 || abs(value) < 1e-6 {
            return value.formatted(.number.locale(locale).notation(.scientific).precision(.significantDigits(10)))
        }
        return value.formatted(.number.locale(locale).precision(.significantDigits(1...12)))
    }

    // MARK: Tokenizer

    enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case op(Character)
        case leftParen, rightParen
        case percent
    }

    static let functions: [String: @Sendable (Double) -> Double] = [
        "sqrt": { $0.squareRoot() }, "cbrt": { cbrt($0) }, "abs": { abs($0) },
        "ln": { log($0) }, "log": { log10($0) }, "log2": { log2($0) }, "exp": { exp($0) },
        "sin": { sin($0) }, "cos": { cos($0) }, "tan": { tan($0) },
        "asin": { asin($0) }, "acos": { acos($0) }, "atan": { atan($0) },
        "round": { $0.rounded() }, "floor": { floor($0) }, "ceil": { ceil($0) },
    ]

    static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E, "tau": 2 * .pi]

    static func tokenize(_ input: String) throws(Failure) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(input.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "−", with: "-"))
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char.isWhitespace || char == "_" { index += 1; continue }
            if char.isNumber || char == "." || (char == "," && index + 1 < chars.count && chars[index + 1].isNumber && tokens.last.map(isNumber) == true) {
                var text = ""
                while index < chars.count, chars[index].isNumber || chars[index] == "." || chars[index] == "," || chars[index] == "_" {
                    if chars[index] != "_" { text.append(chars[index]) }
                    index += 1
                }
                guard let value = parseNumber(text) else { throw .invalid }
                tokens.append(.number(value))
                continue
            }
            if char.isLetter || char == "π" {
                var text = ""
                while index < chars.count, chars[index].isLetter || chars[index].isNumber || chars[index] == "π" {
                    text.append(chars[index])
                    index += 1
                }
                tokens.append(.identifier(text.lowercased()))
                continue
            }
            switch char {
            case "+", "-", "*", "/", "^": tokens.append(.op(char))
            case "(": tokens.append(.leftParen)
            case ")": tokens.append(.rightParen)
            case "%": tokens.append(.percent)
            default: throw .invalid
            }
            index += 1
        }
        return tokens
    }

    private static func isNumber(_ token: Token) -> Bool {
        if case .number = token { return true }
        return false
    }

    /// Accepts "1,234.5", "1.234,5", "3,5", "3.5".
    static func parseNumber(_ text: String) -> Double? {
        let commas = text.filter { $0 == "," }.count
        let dots = text.filter { $0 == "." }.count
        var normalized = text
        if commas > 0 && dots > 0 {
            if let lastComma = text.lastIndex(of: ","), let lastDot = text.lastIndex(of: "."), lastComma > lastDot {
                normalized = text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                normalized = text.replacingOccurrences(of: ",", with: "")
            }
        } else if commas == 1 {
            normalized = text.replacingOccurrences(of: ",", with: ".")
        } else if commas > 1 {
            normalized = text.replacingOccurrences(of: ",", with: "")
        } else if dots > 1 {
            normalized = text.replacingOccurrences(of: ".", with: "")
        }
        return Double(normalized)
    }

    // MARK: Parser (precedence climbing)

    struct Parser {
        let tokens: [Token]
        var position = 0

        var isAtEnd: Bool { position >= tokens.count }
        func peek() -> Token? { position < tokens.count ? tokens[position] : nil }
        mutating func advance() -> Token? {
            defer { position += 1 }
            return peek()
        }

        mutating func parseExpression() throws(Failure) -> Double {
            var value = try parseTerm()
            while case .op(let op)? = peek(), op == "+" || op == "-" {
                position += 1
                let rhs: Double
                if let percent = additivePercent() {
                    // "200 + 15%" means 200 plus 15% of 200.
                    rhs = value * percent / 100
                } else {
                    rhs = try parseTerm()
                }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func parseTerm() throws(Failure) -> Double {
            var value = try parseFactor()
            while true {
                if case .op(let op)? = peek(), op == "*" || op == "/" {
                    position += 1
                    let rhs = try parseFactor()
                    if op == "/" {
                        guard rhs != 0 else { throw .divisionByZero }
                        value /= rhs
                    } else {
                        value *= rhs
                    }
                } else if startsFactor(peek()) {
                    // Implicit multiplication: 2pi, 3(4+5), (1+2)(3+4)
                    value *= try parseFactor()
                } else {
                    return value
                }
            }
        }

        func startsFactor(_ token: Token?) -> Bool {
            switch token {
            case .number?, .identifier?, .leftParen?: true
            default: false
            }
        }

        mutating func parseFactor() throws(Failure) -> Double {
            let base = try parseUnary()
            if case .op("^")? = peek() {
                position += 1
                let exponent = try parseFactor() // right-associative
                return pow(base, exponent)
            }
            return base
        }

        mutating func parseUnary() throws(Failure) -> Double {
            if case .op(let op)? = peek(), op == "-" || op == "+" {
                position += 1
                let value = try parseUnary()
                return op == "-" ? -value : value
            }
            var value = try parsePrimary()
            if case .percent? = peek() {
                position += 1
                value /= 100
            }
            return value
        }

        /// Matches `NUMBER %` followed by the end, `+`, `-` or `)`, consuming it.
        mutating func additivePercent() -> Double? {
            guard position + 1 < tokens.count, case .number(let value) = tokens[position], tokens[position + 1] == .percent else { return nil }
            let next = position + 2 < tokens.count ? tokens[position + 2] : nil
            switch next {
            case nil, .op("+")?, .op("-")?, .rightParen?:
                position += 2
                return value
            default:
                return nil
            }
        }

        mutating func parsePrimary() throws(Failure) -> Double {
            switch advance() {
            case .number(let value)?:
                return value
            case .leftParen?:
                let value = try parseExpression()
                guard case .rightParen? = advance() else { throw .invalid }
                return value
            case .identifier(let name)?:
                if let constant = Calculator.constants[name] { return constant }
                if let function = Calculator.functions[name] {
                    guard case .leftParen? = advance() else { throw .invalid }
                    let argument = try parseExpression()
                    guard case .rightParen? = advance() else { throw .invalid }
                    return function(argument)
                }
                throw .invalid
            default:
                throw .invalid
            }
        }
    }
}
