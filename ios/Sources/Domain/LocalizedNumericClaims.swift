import Foundation

/// Character ranges refer to the original string, so the UI can quote exactly what was said.
struct LocalizedNumericClaims {
    struct Match {
        let range: NSRange
        let entity: CriticalEntity
    }

    private let locale: Locale
    private let words: [String: Int]
    private let currency: NSRegularExpression
    private let counter: NSRegularExpression
    private let hour: NSRegularExpression
    private let language: String

    private static let lexicons: [String: Self] = Dictionary(
        uniqueKeysWithValues:
            AppLanguage.allCases.compactMap { language in
                guard let code = language.locale.language.languageCode?.identifier else { return nil }
                return (code, Self(locale: language.locale, language: code))
            })

    static func matches(in text: String, locale: Locale?) -> [Match] {
        guard let code = locale?.language.languageCode?.identifier else { return [] }
        return lexicons[code]?.matches(in: text) ?? []
    }

    private init(locale: Locale, language: String) {
        self.language = language
        self.locale = locale
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = locale
        var forms: [String: Int] = [:]
        for value in 0...99 {
            if let word = formatter.string(from: NSNumber(value: value)) {
                forms[word.lowercased().replacingOccurrences(of: "\u{00ad}", with: "")] = value
            }
        }
        if language == "ko" {
            for (i, word) in ["영", "한", "두", "세", "네", "다섯", "여섯", "일곱", "여덟", "아홉", "열", "열한", "열두"].enumerated() {
                forms[word] = i
            }
        }
        for scale in [100, 1_000, 1_000_000] {
            if let spelled = formatter.string(from: NSNumber(value: scale)) {
                forms[spelled.lowercased()] = scale
            }
        }
        self.words = forms
        let left = ["ja", "ko"].contains(language) ? "" : #"(?<![\p{L}\p{M}\d])"#
        let right = ["ja", "ko"].contains(language) ? "" : #"(?![\p{L}\p{M}\d])"#
        func alternatives(_ max: Int) -> String {
            forms.filter { $0.value <= max }.keys.sorted { $0.count > $1.count }
                .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        }
        let number = #"(?:\d+(?:[.,\u00a0\u202f]\d+)*|"# + alternatives(99) + ")"
        let symbols = #"R\$|[$€£¥₩₹]|(?<![A-Za-z])(?:USD|EUR|GBP|JPY|BRL|KRW|INR)(?![A-Za-z])"#
        let units =
            #"euros?\b|EUR\b|ユーロ|유로|यूरो|रुप(?:या|ये|ए|यों)|rupees?\b|USD\b|GBP\b|JPY\b|BRL\b|KRW\b|INR\b|dollars?\b|pounds?\b|reais\b|円|원"#
        // A language can end a compound amount with a scale word ("one hundred euros").
        let scales = [
            "hundred", "thousand", "million", "cien", "ciento", "cientos", "mil", "millón", "cent", "cents", "mille",
            "million", "cento", "mila", "mille", "milhão", "cem", "hundert", "tausend", "百", "千", "万", "백", "천", "만",
            "सौ", "हज़ार", "हजार", "लाख",
        ]
        let ending = "(?:" + number + "|" + scales.joined(separator: "|") + ")"
        currency = try! NSRegularExpression(
            pattern: "(?:(" + symbols + #")\s*("# + number + ")|" + left + "(" + ending + #")\s*("# + symbols + "|"
                + units + "))", options: .caseInsensitive)
        counter = try! NSRegularExpression(pattern: "(" + number + #")\s*(?:枚|장|매)"#, options: .caseInsensitive)
        hour = try! NSRegularExpression(
            pattern: left + #"(?:(?:午前|午後|오전|오후)\s*)?((?:[01]?\d|2[0-3])|"# + alternatives(23)
                + #")(?!\d)(?:[:h]([0-5]\d))?\s*(o['’]clock|hours?|heures?|h\b|Uhr\b|時|시|बजे|[ap]\.?m\.?|de la mañana|de la tarde|de la noche)?"#
                + right,
            options: .caseInsensitive)
    }

    /// ICU reports how much input it consumed. Requiring full consumption prevents
    /// unrelated preceding words from being attached to the amount.
    private func spelledAmount(in text: NSString, range: NSRange, currencyFirst: Bool) -> (
        amount: NSNumber, range: NSRange
    )? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = locale
        let bounds =
            currencyFirst
            ? NSRange(location: range.location, length: min(100, text.length - range.location))
            : NSRange(location: max(0, NSMaxRange(range) - 100), length: min(100, NSMaxRange(range)))
        let sample = text.substring(with: bounds)
        let tokens = Self.amountToken.matches(in: sample, range: NSRange(sample.startIndex..., in: sample)).map(\.range)
        let starts =
            currencyFirst
            ? [range.location] : tokens.map { $0.location + bounds.location }.filter { $0 <= range.location }
        let ends =
            currencyFirst
            ? tokens.map { NSMaxRange($0) + bounds.location }.filter { $0 >= NSMaxRange(range) }.reversed()
            : [NSMaxRange(range)].reversed()
        for start in starts {
            for end in ends {
                let candidate = NSRange(location: start, length: end - start)
                let string = text.substring(with: candidate)
                var consumed = NSRange(location: 0, length: candidate.length)
                var object: AnyObject?
                if (try? formatter.getObjectValue(&object, for: string, range: &consumed)) != nil,
                    consumed.location == 0, consumed.length == candidate.length, let amount = object as? NSNumber
                {
                    return (amount, candidate)
                }
            }
        }
        return nil
    }

    private static let amountToken = try! NSRegularExpression(pattern: #"[\p{L}\p{M}]+(?:[-’'][\p{L}\p{M}]+)*"#)

    private func decimalAmount(_ token: String) -> String {
        var digits = token.filter { !$0.isWhitespace }
        if let group = locale.groupingSeparator, group != locale.decimalSeparator {
            digits = digits.replacingOccurrences(of: group, with: "")
        }
        if let decimal = locale.decimalSeparator, decimal != "." {
            digits = digits.replacingOccurrences(of: decimal, with: ".")
        }
        guard let amount = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")) else { return token }
        return NSDecimalNumber(decimal: amount).stringValue
    }

    private func currencyCode(_ symbol: String) -> String {
        switch symbol {
        case "€", "eur", "euro", "euros", "ユーロ", "유로", "यूरो": return "EUR"
        case "£", "gbp", "pound", "pounds": return "GBP"
        case "¥", "jpy", "円": return "JPY"
        case "₩", "krw", "원": return "KRW"
        case "r$", "brl", "reais": return "BRL"
        case "$", "usd", "dollar", "dollars": return "USD"
        default: return "INR"
        }
    }

    private static let unpricedCurrency = try! NSRegularExpression(pattern: #"R\$|[$€£¥₩₹]"#, options: .caseInsensitive)

    private func matches(in text: String) -> [Match] {
        let original = text as NSString
        let full = NSRange(location: 0, length: original.length)
        var matches: [Match] = []
        func add(_ span: NSRange, _ kind: CriticalEntityKind, _ normalized: String) {
            matches.append(
                Match(
                    range: span,
                    entity: CriticalEntity(
                        kind: kind, value: original.substring(with: span), normalizedValue: normalized)))
        }
        func value(_ token: String) -> String {
            if let number = words[token.lowercased()] { return String(number) }
            return token.map { $0.wholeNumberValue.map(String.init) ?? String($0) }.joined()
        }
        for match in currency.matches(in: text, range: full) {
            let prefix = match.range(at: 1).location != NSNotFound
            let symbol = original.substring(with: match.range(at: prefix ? 1 : 4)).lowercased()
            let numericRange = match.range(at: prefix ? 2 : 3)
            var span = match.range
            var amount = value(original.substring(with: numericRange))
            if original.substring(with: numericRange).first?.isNumber == true {
                amount = decimalAmount(amount)
            }
            if original.substring(with: numericRange).first?.wholeNumberValue == nil,
                let parsed = spelledAmount(in: original, range: numericRange, currencyFirst: prefix)
            {
                amount = parsed.amount.stringValue
                span = NSUnionRange(span, parsed.range)
            }
            guard amount.first?.isNumber == true else { continue }
            add(span, .currency, currencyCode(symbol) + ":" + amount)
        }
        // Dictation can retain a currency symbol while dropping the amount. Keep
        // it reviewable even when both sides contain the same incomplete price.
        for token in Self.unpricedCurrency.matches(in: text, range: full) {
            guard !matches.contains(where: { NSIntersectionRange($0.range, token.range).length > 0 }) else { continue }
            add(token.range, .currency, currencyCode(original.substring(with: token.range).lowercased()))
        }
        if language == "ko" || language == "ja" {
            for match in counter.matches(in: text, range: full) {
                add(match.range, .number, value(original.substring(with: match.range(at: 1))))
            }
        }
        // Compare the two roles only within a single departure statement. Keep ordinary
        // number/time extraction for unrelated clauses or an ambiguous construction.
        let departure = #"(?i)\b(?:leaves?|departs?|sale|parte|part|fährt|sai)\b|出発|출발|चलती|चलता|निकलती|निकलता"#
        guard text.range(of: departure, options: .regularExpression) != nil else { return matches }
        let hours = hour.matches(in: text, range: full).filter { match in
            // In these scripts a bare number can be part of an unrelated word, e.g.
            // 열 in 열차 (train). Require a clock marker or an explicit minute.
            !["ja", "ko"].contains(language)
                || match.range(at: 2).location != NSNotFound || match.range(at: 3).location != NSNotFound
        }
        guard hours.count == 2 else { return matches }
        let first = hours[0].range
        let second = hours[1].range
        let between = original.substring(
            with: NSRange(location: NSMaxRange(first), length: second.location - NSMaxRange(first)))
        guard between.range(of: #"[.!?。;]"#, options: .regularExpression) == nil else { return matches }
        let before = original.substring(to: first.location)
        let after = original.substring(from: NSMaxRange(second))
        let prefixNegative = #"(?i)\b(?:not|no|pas|nicht|non|não)\s*(?:at|a las|à|um|alle|às)?\s*$"#
        let suffixNegative = #"^\s*(?:ではありません|ではなく|でなく|ではない|(?:가|이)?\s*(?:아니라|아닙니다|아니에요|아니다)|(?:에는|에|는)?\s*출발하지\s*않(?:습니다|아요|는다)|नहीं|नही)"#
        let regions = [
            (before, prefixNegative, 0, 0), (between, suffixNegative, NSMaxRange(first), 0),
            (between, prefixNegative, NSMaxRange(first), 1), (after, suffixNegative, NSMaxRange(second), 1),
        ]
        var exclusion: (NSRange, Int)?
        for (fragment, pattern, offset, index) in regions {
            guard let match = fragment.range(of: pattern, options: .regularExpression) else { continue }
            let range = NSRange(match, in: fragment)
            exclusion = (NSRange(location: offset + range.location, length: range.length), index)
            break
        }
        guard let (negation, excludedIndex) = exclusion else { return matches }
        add(negation, .negation, "NEGATION")
        for (index, match) in hours.enumerated() {
            guard var clockHour = Int(value(original.substring(with: match.range(at: 1)))) else { continue }
            let minutes = match.range(at: 2)
            let minute = minutes.location == NSNotFound ? "00" : original.substring(with: minutes)
            let qualifier = match.range(at: 3)
            let suffix =
                qualifier.location == NSNotFound
                ? "" : original.substring(with: qualifier).lowercased().replacingOccurrences(of: ".", with: "")
            let fullTime = original.substring(with: match.range)
            let morning =
                ["am", "de la mañana"].contains(suffix) || fullTime.hasPrefix("午前") || fullTime.hasPrefix("오전")
            let evening =
                ["pm", "de la tarde", "de la noche"].contains(suffix) || fullTime.hasPrefix("午後")
                || fullTime.hasPrefix("오후")
            var precision = ""
            if morning || evening {
                guard (1...12).contains(clockHour) else { continue }
                clockHour = clockHour % 12 + (evening ? 12 : 0)
                precision = "@period"
            } else if clockHour > 12 || clockHour == 0
                || (language == "fr" && fullTime.range(of: #"\d\s*h(?=\d|\b)"#, options: .regularExpression) != nil)
            {
                precision = "@24h"
            }
            add(
                match.range, .time,
                "departure:" + (index == excludedIndex ? "excluded:" : "affirmed:") + String(clockHour) + ":" + minute
                    + precision)
        }
        return matches
    }
}
