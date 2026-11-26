import CoreMedia
import Foundation
import NaturalLanguage

/// Evidence from a single transcript of one utterance. The two recognizers hear
/// the same audio, so their word counts must never be added together.
enum MixedLanguageTurn {
    static func reading(_ candidates: [RecognitionCandidate], pair: LanguagePair) -> RecognitionCandidate? {
        if pair.isEnglishHindi,
           let english = candidates.first(where: { $0.language == .englishUS }),
           let hindi = candidates.first(where: { $0.language == .hindiIndia }),
           let reading = englishFrameAroundHindi(english, hindi: hindi.text) {
            return reading
        }
        var best: (candidate: RecognitionCandidate, wordCount: Int)?
        for candidate in candidates {
            let other = candidates.first { $0.language != candidate.language }
            guard let result = analyze(candidate, other: other, pair: pair) else { continue }
            if let best {
                guard best.candidate.language == result.candidate.language else { return nil }
                if best.wordCount > result.wordCount { continue }
                if best.wordCount == result.wordCount && candidate.language != result.candidate.language { continue }
            }
            best = result
        }
        return best?.candidate
    }

    /// English ASR may join a Hindi phrase into a single Latin word. The Hindi
    /// model often writes the surrounding English words in Devanagari as well.
    private static func englishFrameAroundHindi(_ english: RecognitionCandidate, hindi: String) -> RecognitionCandidate? {
        let text = english.text
        guard text.range(of: #"\p{Devanagari}"#, options: .regularExpression) == nil,
              hindi.range(of: #"\p{Devanagari}"#, options: .regularExpression) != nil else { return nil }
        let tokens = text.split(whereSeparator: { !$0.isLetter })
        let words = tokens.map { $0.lowercased() }
        guard words.count >= 4, englishFrameWords.intersection(words).count >= 3 else { return nil }
        let detector = NLLanguageRecognizer()
        detector.processString(text)
        guard (detector.languageHypotheses(withMaximum: 1)[.english] ?? 0) >= 0.65 else { return nil }
        let unknown = words.filter { romanHindi.contains($0) || !confidentlyEnglish($0, detector: detector) }
        guard !unknown.isEmpty, unknown.count * 2 < words.count else { return nil }
        let native = hindi.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let forms = native.map { $0.applyingTransform(.toLatin, reverse: false) ?? $0 }
        let possible = Set(unknown.filter { $0.count >= 3 }.map(phoneticForm))
        var corroborated = false
        var spellings: [String: Set<String>] = [:]
        for start in forms.indices {
            var phrase = ""
            for index in start..<min(start + 3, forms.count) {
                phrase += forms[index]
                let joined = phoneticForm(phrase)
                for word in possible where word == joined || (joined.count >= 5 && abs(word.count - joined.count) <= 1
                    && consonants(word) == consonants(joined) && word.difference(from: joined).count <= 1) {
                    corroborated = true
                    let spelling = native[start...index].joined(separator: " ")
                    if spelling.range(of: hindiGrammar, options: .regularExpression) != nil {
                        spellings[word, default: []].insert(spelling)
                    }
                }
            }
        }
        guard corroborated else { return nil }
        if spellings.isEmpty { return english }
        var reading = text
        for token in tokens.reversed() {
            if let options = spellings[phoneticForm(String(token))], options.count == 1, let spelling = options.first {
                reading.replaceSubrange(token.startIndex..<token.endIndex, with: spelling)
            }
        }
        return ContinuousLanguageDecisionPolicy.makeCandidate(
            language: english.language,
            transcript: Transcript(text: reading, isFinal: english.isFinal, confidence: english.confidence,
                                   lowConfidenceFraction: english.lowConfidenceFraction),
            constrainedLanguageProbability: english.constrainedLanguageProbability)
    }

    private static func analyze(_ candidate: RecognitionCandidate, other: RecognitionCandidate?,
                                pair: LanguagePair) -> (candidate: RecognitionCandidate, wordCount: Int)? {
        let englishPair = pair.traveler == .englishUS || pair.local == .englishUS
        let tokenizer = NLTokenizer(unit: .word)
        let detector = NLLanguageRecognizer()
        let partner = englishPair ? (pair.traveler == .englishUS ? pair.local : pair.traveler) : candidate.language
        guard let code = partner.locale.language.languageCode?.identifier else { return nil }
        let partnerCode = NLLanguage(rawValue: code)
        let script = nativeScript(of: partner)
        tokenizer.setLanguage(partnerCode)
        let original = candidate.text
        let hasNativeScript = script.map { original.range(of: $0, options: .regularExpression) != nil } ?? false
        let romanized = partner == .hindiIndia && !hasNativeScript
        if script != nil && !hasNativeScript && !romanized { return nil }
        // Prefer a recognizer that captured Hindi in its native script.
        if romanized && other?.text.range(of: #"\p{Devanagari}"#, options: .regularExpression) != nil { return nil }
        tokenizer.string = original
        // For languages sharing the Latin alphabet, corroborate a minority
        // word in the other recognizer before overriding ordinary ASR scoring.
        let otherTokens = (other?.text ?? "").lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let otherWords = Set(otherTokens)
        let ownWords = original.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        if script == nil && otherWords.isDisjoint(with: ownWords) { return nil }
        if romanized && romanHindi.intersection(ownWords).count < 2 { return nil }
        let aligned = partner == .hindiIndia && other?.language == .englishUS
            ? other.map { alignedEnglishSpellings(native: candidate, english: $0) } ?? [:] : [:]
        var native = 0, english = 0, total = 0
        var sharedNative = false, sharedEnglish = false
        var edits: [(Range<String.Index>, String)] = []
        tokenizer.enumerateTokens(in: original.startIndex..<original.endIndex) { range, _ in
            let token = String(original[range])
            guard token.contains(where: \.isLetter) else { return true }
            total += 1
            if let script {
                let known = englishSpelling[token].flatMap { otherWords.contains($0) ? $0 : nil }
                if partner == .hindiIndia, let spelling = aligned[token] ?? known {
                    edits.append((range, spelling))
                    english += 1
                } else if token.range(of: script, options: .regularExpression) != nil
                            || (partner == .hindiIndia && romanHindi.contains(token.lowercased())) {
                    native += 1
                } else if token.range(of: #"\p{Latin}"#, options: .regularExpression) != nil {
                    // A Latin fragment in Japanese or Korean dictation can also be a
                    // phonetic rendering of the other participant's language.
                    let needsEnglishCheck = romanized || !englishPair
                    if (englishPair || otherWords.contains(token.lowercased()))
                        && (!needsEnglishCheck || confidentlyEnglish(token, detector: detector)) {
                        english += 1
                    }
                }
            } else {
                let word = token.lowercased()
                detector.reset()
                detector.languageConstraints = [.english, partnerCode]
                detector.processString(word)
                let probability = detector.languageHypotheses(withMaximum: 2)[.english] ?? 0.5
                if probability >= 0.8 {
                    english += 1
                    sharedEnglish = sharedEnglish || otherWords.contains(word)
                } else if probability <= 0.2 {
                    native += 1
                    sharedNative = sharedNative || otherWords.contains(word)
                }
            }
            return true
        }
        guard english > 0, native > 0, max(english, native) * 2 > total else { return nil }
        let dominant: AppLanguage = english > native ? .englishUS : partner
        guard englishPair || dominant == partner else { return nil }
        if script == nil {
            guard dominant == .englishUS ? sharedNative : sharedEnglish else { return nil }
            if let other, other.language != dominant, other.score >= ContinuousLanguageDecisionPolicy.minimumScore,
               candidate.score < ContinuousLanguageDecisionPolicy.minimumScore, otherTokens.count * 3 >= total * 2 {
                return nil
            }
            detector.reset()
            detector.processString(original)
            guard detector.dominantLanguage == (dominant == .englishUS ? .english : partnerCode) else { return nil }
        }
        // Hindi dictation sometimes renders a fully English sentence phonetically.
        // A borrowed word in that rendering alone cannot overturn a fluent,
        // full-length English alternative without evidence of Hindi grammar.
        if partner == .hindiIndia, dominant == partner, let other, other.language == .englishUS,
           other.text.split(whereSeparator: \.isWhitespace).count >= total - 1,
           PairLanguageEvidencePolicy.isConfidentEnglish(other),
           !romanized, original.range(of: hindiGrammar, options: .regularExpression) == nil { return nil }

        var text = original
        for (range, spelling) in edits.reversed() { text.replaceSubrange(range, with: spelling) }
        guard let mixed = ContinuousLanguageDecisionPolicy.makeCandidate(
            language: dominant,
            transcript: Transcript(text: text, isFinal: candidate.isFinal, confidence: candidate.confidence,
                                   lowConfidenceFraction: candidate.lowConfidenceFraction),
            constrainedLanguageProbability: dominant == candidate.language ? candidate.constrainedLanguageProbability : nil
        ) else { return nil }
        return (mixed, total)
    }

    /// Recover an English spelling beyond the common loanwords when both models
    /// put a phonetically matching word at the same point in the same audio.
    private static func alignedEnglishSpellings(native candidate: RecognitionCandidate,
                                               english alternate: RecognitionCandidate) -> [String: String] {
        // Some result runs omit timings or contain several words. Keep their
        // position in the complete sentence even when their clock is unavailable.
        func words(_ candidate: RecognitionCandidate) -> [TimedSpeechWord] {
            let times = Dictionary(grouping: candidate.timedWords, by: { $0.text.lowercased() })
            return candidate.text.split(whereSeparator: { !$0.isLetter }).map {
                let token = String($0)
                let occurrences = times[token.lowercased()]
                let time = occurrences?.count == 1 ? occurrences?.first?.range : nil
                return TimedSpeechWord(text: token, range: time ?? .invalid)
            }
        }
        let native = words(candidate), english = words(alternate)
        guard !english.isEmpty, !native.isEmpty else { return [:] }
        let detector = NLLanguageRecognizer()
        var spellings: [String: String] = [:]
        let nativeForms = native.map { phoneticForm($0.text.applyingTransform(.toLatin, reverse: false) ?? $0.text) }
        let englishForms = english.map { phoneticForm($0.text) }
        let englishByConsonants = Dictionary(grouping: english.indices, by: { consonants(englishForms[$0]) })
        let occurrences = Dictionary(grouping: native, by: \.text)
        for (i, nativeWord) in native.enumerated() {
            let token = nativeWord.text
            guard occurrences[token]?.count == 1 else { continue }
            guard token.range(of: #"\p{Devanagari}"#, options: .regularExpression) != nil,
                  token.range(of: hindiGrammar, options: .regularExpression) == nil,
                  token.count <= 40 else { continue }
            let nativeForm = nativeForms[i]
            let key = consonants(nativeForm)
            guard key.count >= 3, let indices = englishByConsonants[key] else { continue }
            let time = nativeWord.range
            let matches = indices.filter { j in
                let word = english[j]
                let overlap = time.isValid && word.range.isValid
                    ? CMTimeRangeGetIntersection(time, otherRange: word.range).duration.seconds : 0
                let timeMatches = overlap > 0 && overlap >= 0.55 * max(time.duration.seconds, word.range.duration.seconds)
                // The dictation and speech models sometimes report different word clocks.
                // Matching both adjacent words also identifies the same position.
                let leftMatches = i > 0 && j > 0 && nativeForms[i - 1] == englishForms[j - 1]
                let rightMatches = i + 1 < native.count && j + 1 < english.count && nativeForms[i + 1] == englishForms[j + 1]
                let positionMatches = i == j && native.count == english.count && (leftMatches || rightMatches)
                guard timeMatches || (leftMatches && rightMatches) || positionMatches,
                      word.text.count <= 40, word.text.range(of: #"^[A-Za-z]+$"#, options: .regularExpression) != nil
                else { return false }
                let form = englishForms[j]
                return form.difference(from: nativeForm).count <= max(2, form.count / 3)
            }
            guard matches.count == 1, let index = matches.first else { continue }
            let word = english[index].text
            guard !romanHindi.contains(word.lowercased()), confidentlyEnglish(word, detector: detector) else { continue }
            spellings[token] = word
        }
        return spellings
    }

    private static func confidentlyEnglish(_ word: String, detector: NLLanguageRecognizer) -> Bool {
        let lowercase = word.lowercased()
        if NLEmbedding.wordEmbedding(for: .english)?.contains(lowercase) == true { return true }
        detector.reset()
        detector.processString(lowercase)
        return (detector.languageHypotheses(withMaximum: 1)[.english] ?? 0) >= 0.35
    }

    private static func phoneticForm(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "ph", with: "f")
            .replacingOccurrences(of: "ck", with: "k")
            .replacingOccurrences(of: "c(?=[eiy])", with: "s", options: .regularExpression)
            .replacingOccurrences(of: "c", with: "k")
            .replacingOccurrences(of: "ee", with: "i")
            .replacingOccurrences(of: "[ae]$", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(.)\1+"#, with: "$1", options: .regularExpression)
    }

    private static func consonants(_ form: String) -> String {
        form.replacingOccurrences(of: "[aeiouy]", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(.)\1+"#, with: "$1", options: .regularExpression)
    }

    private static func nativeScript(of language: AppLanguage) -> String? {
        switch language {
        case .hindiIndia: #"\p{Devanagari}"#
        case .japaneseJapan: #"[\p{Han}\p{Hiragana}\p{Katakana}]"#
        case .koreanSouthKorea: #"\p{Hangul}"#
        default: nil
        }
    }

    private static let romanHindi: Set<String> = [
        "mujhe", "tumhe", "hamara", "hamari", "mera", "meri", "mere", "aap", "aapko", "apna", "apni",
        "karna", "karni", "karne", "karo", "kya", "kyun", "kahan", "kidhar", "yahan", "yahaan",
        "chahiye", "nahi", "nahin", "hain", "hai", "hoon", "kal", "mein", "sakte", "sakti"
    ]

    private static let englishFrameWords: Set<String> = [
        "the", "a", "an", "i", "we", "you", "it", "they", "me", "my", "your", "our", "their",
        "can", "could", "would", "should", "will", "was", "were", "have", "has", "please",
        "to", "for", "with", "before", "after", "what", "when", "where", "how", "and", "but"
    ]

    private static let hindiGrammar = #"(?<![\p{L}\p{M}])(?:मैं|मुझे|तुम|आप|हम|यह|वह|में|पर|को|से|का|की|के|है|हैं|हूँ|था|थी|थे|करना|करनी|करने|क्या|कहाँ|क्यों|मेरी|मेरा|नहीं)(?![\p{L}\p{M}])"#

    // Unambiguous English loanword spellings emitted by Hindi dictation. Apply
    // only in a mixed reading; keep arbitrary Latin words and punctuation verbatim.
    private static let englishSpelling = [
        "ऑफिस": "office", "ऑफ़िस": "office", "मीटिंग": "meeting", "मीटिंग्स": "meetings",
        "लैपटॉप": "laptop", "क्लाइंट": "client", "प्रोजेक्ट": "project",
        "डेडलाइन": "deadline", "ईमेल": "email", "वीकेंड": "weekend",
        "डाउनलोड": "download", "अपलोड": "upload", "अपडेट": "update", "ऑनलाइन": "online"
    ]
}
