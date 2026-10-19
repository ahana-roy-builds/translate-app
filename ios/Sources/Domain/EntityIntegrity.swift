import Foundation

struct EntityIntegrityReport: Equatable, Sendable {
    let source: [CriticalEntity]
    let translation: [CriticalEntity]
    let missingKinds: Set<CriticalEntityKind>
    let mismatchedValues: [CriticalEntity]
    let inventedValues: [CriticalEntity]
    let extractionLimitExceeded: Bool
    var requiresConfirmation: Bool { !source.isEmpty || hasMismatch }
    var hasMismatch: Bool {
        extractionLimitExceeded || !missingKinds.isEmpty || !mismatchedValues.isEmpty || !inventedValues.isEmpty
    }
}

private struct CriticalEntityExtraction {
    let entities: [CriticalEntity]
    let limitExceeded: Bool
}

/// A deliberately conservative, deterministic guardrail. It does not repair a
/// translation; it only decides whether the app may speak it without review.
struct CriticalEntityExtractor: Sendable {
    private struct Rule: Sendable {
        let kind: CriticalEntityKind
        let pattern: String
        let options: NSRegularExpression.Options
    }

    private struct LanguageProfile: Sendable {
        let languageCode: String
        let rules: [Rule]
    }

    private struct ConceptAliases: Sendable {
        let concept: String
        let fragments: [String]
    }

    // These rules preserve the original English, Spanish, and Japanese behavior.
    // Additional language vocabularies are isolated in `languageProfiles`.
    private let baseRules: [Rule] = [
        Rule(kind: .currency, pattern: #"(?:R\$\s?\d+(?:[.,]\d{1,2})?|[$€£¥₩]\s?\d+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?\s?(?:USD|EUR|GBP|JPY|BRL|KRW|dollars?|dólares?|euros?|pounds?|libras?|yen(?:es)?|reais?|won|円|원)|(?:₹|INR|रु\.?|रुप(?:या|ये|ए|यों))\s?[0-9०-९]+(?:[.,][0-9०-९]{1,3})?|[0-9०-९]+(?:[.,][0-9०-९]{1,3})?\s?(?:INR|रु\.?|रुप(?:या|ये|ए|यों)))"#, options: [.caseInsensitive]),
        Rule(kind: .unit, pattern: #"(?<![\p{L}\d])(?:\d+(?:[.,]\d+)?\s?(?:kg|kilograms?|kilogrammes?|kilogramm|chilogrammi?|quilogramas?|kilos?|chili|quilos?|킬로그램|g|grams?|grammes?|gramm|grammi?|gramas?|그램|km|kilometers?|kilómetros?|kilomètres?|kilometer|chilometri?|quilômetros?|킬로미터|m|meters?|metros?|mètres?|meter|metri?|미터|cm|mm|mi|miles?|millas?|meilen?|miglia|milhas?|마일|lb|lbs|pounds?|libbr[ae]s?|libras?|pfund|파운드|°\s?[CF]|degrees?\s?(?:Celsius|Fahrenheit)|degrés?\s?(?:Celsius|Fahrenheit)|Grad\s?(?:Celsius|Fahrenheit)|gradi?\s?(?:Celsius|Fahrenheit)|graus?\s?(?:Celsius|Fahrenheit)|(?:섭씨|화씨)\s?\d*\s?도|キロ(?:グラム|メートル)?|グラム|メートル|センチ|マイル)|[0-9०-९]+(?:[.,][0-9०-९]+)?\s?(?:किलोमीटर|कि\.?\s?मी\.?|किलोग्राम|किलो|कि\.?\s?ग्रा\.?|ग्राम|सेंटीमीटर|सेमी|मिलीमीटर|मिमी|मीटर|मील|पाउंड|°\s?[CF]|डिग्री\s?(?:सेल्सियस|फारेनहाइट|फ़ारेनहाइट)))(?!\p{L})"#, options: [.caseInsensitive]),
        Rule(kind: .time, pattern: #"\b(?:[01]?\d|2[0-3])(?::[0-5]\d)(?:\s?[ap]\.??m\.?)?\b|\b(?:1[0-2]|0?[1-9])\s?[ap]\.??m\.?\b|\b(?:[01]?\d|2[0-3])\s?(?:h|Uhr)\s?(?:[0-5]\d)?\b|(?:午前|午後|오전|오후)\s?\d{1,2}(?::\d{2}|時(?:\d{1,2}分)?|시(?:\s?\d{1,2}분)?)|(?:सुबह|दोपहर|शाम|रात)?\s?[0-9०-९]{1,2}(?::[0-9०-९]{2})?\s?बजे"#, options: [.caseInsensitive]),
        Rule(kind: .date, pattern: #"(?<!\d)(?:\d{1,2}[./-]){2}\d{2,4}(?!\d)|(?<!\d)\d{4}[./-]\d{1,2}[./-]\d{1,2}(?!\d)|\b(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|today|tomorrow|yesterday|lunes|martes|miércoles|jueves|viernes|sábado|domingo|hoy|mañana|ayer)\b|(?:月曜日|火曜日|水曜日|木曜日|金曜日|土曜日|日曜日|今日|明日|昨日|सोमवार|मंगलवार|बुधवार|गुरुवार|बृहस्पतिवार|शुक्रवार|शनिवार|रविवार|आज|बीता\s+हुआ\s+कल|बीता\s+कल|आने\s+वाला\s+कल)"#, options: [.caseInsensitive]),
        Rule(kind: .phone, pattern: #"(?<!\w)(?:\+?\d[\d\s().-]{6,}\d)(?!\w)"#, options: []),
        Rule(kind: .address, pattern: #"(?:\b\d{1,6}\s+[\p{L}0-9.'’-]+(?:\s+[\p{L}0-9.'’-]+){0,5}\s+(?:Street|St|Road|Rd|Avenue|Ave|Lane|Ln|Drive|Dr|Boulevard|Blvd|Calle|Avenida|Carretera|Paseo|Straße|Strasse|Weg)\b|\b\d{1,6}\s+(?:rue|route|avenue|boulevard|straße|strasse|weg|via|viale|corso|rua|avenida|estrada)\s+[\p{L}0-9.'’-]+(?:\s+[\p{L}0-9.'’-]+){0,5}\b|(?:〒?\d{3}-\d{4}\s*)?(?:東京都|北海道|(?:大阪|京都)府|.{2,3}県).{1,30}\d+(?:-\d+)*|(?:서울특별시|부산광역시|대구광역시|인천광역시|광주광역시|대전광역시|울산광역시|세종특별자치시|[\p{Hangul}]{2,12}(?:도|시|구))\s*[\p{Hangul}\d\s-]{2,40}\d+(?:-\d+)*)"#, options: [.caseInsensitive]),
        Rule(kind: .properName, pattern: #"(?:\b(?i:my name is|i am|ask for|named|me llamo|mi nombre es|pregunte por)\s+[\p{Lu}][\p{L}'-]+(?:\s+[\p{Lu}][\p{L}'-]+){0,3}\b|(?:私の名前は|名前は|さんは)\s*[\p{Han}\p{Hiragana}\p{Katakana}ー]{2,12})"#, options: []),
        Rule(kind: .negation, pattern: #"\b(?:no|not|never|without|don't|doesn't|cannot|can't|won't|neither|nor|sin|nunca|jamás|tampoco|ni)\b|(?:ない|ません|できない|無し|なし)"#, options: [.caseInsensitive]),
        Rule(kind: .allergy, pattern: #"\b(?:allerg(?:y|ic|ies)|anaphylaxis|gluten|peanuts?|nuts?|shellfish|dairy|lactose|celiac|al[eé]rg(?:ia|ias|ico|ica|icos|icas)|anafilaxia|cacahuetes?|cacahuates?|maní|mariscos?|lácteos?|lactosa|celíac[oa])\b|(?:アレルギー|アナフィラキシー|グルテン|ピーナッツ|ナッツ|乳製品|乳糖|甲殻類)"#, options: [.caseInsensitive]),
        Rule(kind: .medication, pattern: #"\b(?:(?i:(?:medication|medicine|prescription\s+drug|drug|medicamento|medicina|f[aá]rmaco)\s+(?:called|named|llamad[oa])\s+)(?:["“'][\p{L}\p{M}\d][\p{L}\p{M}\d-]{0,31}(?:\s+[\p{L}\p{M}\d][\p{L}\p{M}\d-]{0,31}){0,2}["”']|[\p{L}\p{M}\d][\p{L}\p{M}\d-]{0,31}\s+(?i:(?:extended|immediate|sustained|controlled|delayed)\s+release|liberaci[oó]n\s+(?:prolongada|inmediata|retardada))|\p{Lu}[\p{L}\p{M}\d-]{0,31}(?:\s+(?:\p{Lu}[\p{L}\p{M}\d-]{0,31}|(?i:XR|XL|ER|SR|CR|DR|IR))){0,2}|[\p{L}\p{M}\d][\p{L}\p{M}\d-]{0,31}(?:\s+[\p{L}\p{M}\d][\p{L}\p{M}\d-]{0,31}){0,1}\s+(?i:XR|XL|ER|SR|CR|DR|IR)|[\p{L}\p{M}\d][\p{L}\p{M}\d-]{0,31})(?=\s+(?i:is|was|for|in|with|and|or|from|on|to|est[aá]|es|era|para|en|con|y|o|de|del|por)\b|\s+\p{Ll}|[.,!?;:]|$)|[\p{L}\p{M}\dー-]{1,32}(?:\s+[\p{L}\p{M}\dー-]{1,32}){0,2}(?:という薬|と呼ばれる薬))"#, options: []),
        Rule(kind: .medication, pattern: #"\b(?:medication|medicine|prescription(?:\s+drug)?|drug|dos(?:e|age)|insulin|epinephrine|adrenaline|epipen|inhaler|nitroglycerin|anticoagulants?|blood\s+thinners?|antibiotics?|aspirin|acetaminophen|paracetamol|ibuprofen|penicillin|antihistamines?|metformin|warfarin|amoxicillin|apixaban|rivaroxaban|medicamento|medicina|f[aá]rmaco|receta|dosis|insulina|epinefrina|adrenalina|autoinyector|inhalador|nitroglicerina|anticoagulantes?|antibióticos?|aspirina|acetaminof[eé]n|ibuprofeno|penicilina|antihistam[ií]nicos?|metformina|warfarina|amoxicilina|apixab[aá]n|rivaroxab[aá]n)\b|(?:薬|医薬品|処方箋?|服用量|投薬|インスリン|エピネフリン|アドレナリン|エピペン|吸入器|ニトログリセリン|抗凝固薬|抗生物質|アスピリン|アセトアミノフェン|パラセタモール|イブプロフェン|ペニシリン|抗ヒスタミン薬|メトホルミン|ワルファリン|アモキシシリン|アピキサバン|リバーロキサバン)"#, options: [.caseInsensitive]),
        Rule(kind: .emergency, pattern: #"\b(?:ambulance|police|hospital|fire|overdose|cannot\s+breathe|can't\s+breathe|difficulty\s+breathing|breathing\s+difficulty|chest\s+pain|heart\s+attack|stroke|unconscious|severe\s+bleeding|seizure|help|danger|ambulancia|policía|hospital|incendio|sobredosis|no\s+puedo\s+respirar|dificultad\s+para\s+respirar|dolor\s+de\s+pecho|ataque\s+cardíaco|infarto|derrame\s+cerebral|inconsciente|sangrado\s+grave|convulsión|ayuda|peligro)\b|(?:救急車|警察|病院|火事|過剰摂取|息ができない|呼吸困難|胸の痛み|心臓発作|脳卒中|意識不明|大量出血|けいれん|痙攣|助けて|危険)"#, options: [.caseInsensitive]),
        Rule(kind: .number, pattern: #"(?<![\p{L}\d])\d+(?:[.,]\d+)?(?![\p{L}\d])|\b(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|cero|uno|una|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|once|doce)\b|[一二三四五六七八九十百千万〇零]+"#, options: [.caseInsensitive])
    ]

    private static let languageProfiles: [LanguageProfile] = [
        LanguageProfile(languageCode: "fr", rules: [
            Rule(kind: .date, pattern: #"\b(?:lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche|aujourd['’]hui|demain|hier)\b"#, options: [.caseInsensitive]),
            Rule(kind: .properName, pattern: #"\b(?i:je m['’]appelle|mon nom est|demandez à voir|demandez après|demandez)\s+[\p{Lu}][\p{L}\p{M}'’-]+(?:\s+[\p{Lu}][\p{L}\p{M}'’-]+){0,3}\b"#, options: []),
            Rule(kind: .negation, pattern: #"\b(?:ne\s+[\p{L}'’-]{1,24}\s+pas|jamais|sans|aucuns?|aucunes?|ni)\b|\bn['’]\s*[\p{L}'’-]{1,24}\s+pas\b"#, options: [.caseInsensitive]),
            Rule(kind: .allergy, pattern: #"\b(?:allerg(?:ie|ies|ique|iques)|anaphylaxie|gluten|cacahu[eè]tes?|arachides?|noix|fruits?\s+de\s+mer|crustac[eé]s?|produits?\s+laitiers?|lactose|c[oœ]liaque)\b"#, options: [.caseInsensitive]),
            Rule(kind: .medication, pattern: #"\b(?i:(?:médicament|médecine)\s+(?:appelé|nommé)\s+)(?:["“']?[\p{L}\p{M}\d-]{1,32}(?:\s+(?:[\p{Lu}][\p{L}\p{M}\d-]{0,31}|XR|XL|LP|ER|SR|CR|DR|IR)){0,2}["”']?)(?=\s+(?i:est|était|pour|dans|avec|et|ou|de|du|à)\b|[.,!?;:]|$)"#, options: []),
            Rule(kind: .medication, pattern: #"\b(?:médicaments?|médecine|ordonnance|dose|insuline|épinéphrine|adrénaline|epipen|inhalateur|nitroglycérine|anticoagulants?|fluidifiants?\s+du\s+sang|antibiotiques?|aspirine|paracétamol|ibuprofène|pénicilline|antihistaminiques?|metformine|warfarine|amoxicilline|apixaban|rivaroxaban)\b"#, options: [.caseInsensitive]),
            Rule(kind: .emergency, pattern: #"\b(?:ambulance|police|hôpital|incendie|feu|surdose|ne\s+peux\s+pas\s+respirer|difficulté\s+à\s+respirer|douleur\s+thoracique|crise\s+cardiaque|infarctus|accident\s+vasculaire\s+cérébral|avc|inconscient|saignement\s+grave|convulsion|à\s+l'aide|aidez-moi|danger)\b"#, options: [.caseInsensitive]),
            Rule(kind: .number, pattern: #"\b(?:zéro|deux|trois|quatre|cinq|six|sept|huit|neuf|dix|onze|douze)\b"#, options: [.caseInsensitive])
        ]),
        LanguageProfile(languageCode: "de", rules: [
            Rule(kind: .date, pattern: #"\b(?:Montag|Dienstag|Mittwoch|Donnerstag|Freitag|Samstag|Sonntag|heute|morgen|gestern)\b"#, options: [.caseInsensitive]),
            Rule(kind: .properName, pattern: #"\b(?i:ich heiße|ich heisse|mein name ist|fragen sie nach)\s+[\p{Lu}][\p{L}\p{M}'’-]+(?:\s+[\p{Lu}][\p{L}\p{M}'’-]+){0,3}\b"#, options: []),
            Rule(kind: .negation, pattern: #"\b(?:nicht|nie|niemals|ohne|kein|keine|keinen|keinem|keiner|keines|weder|noch)\b"#, options: [.caseInsensitive]),
            Rule(kind: .allergy, pattern: #"\b(?:allergie|allergisch|anaphylaxie|gluten|erdn[uü]sse?|n[uü]sse?|schalentiere?|meeresfr[uü]chte|milchprodukte?|laktose|z[oö]liakie|z[oö]liakisch)\b"#, options: [.caseInsensitive]),
            Rule(kind: .medication, pattern: #"\b(?i:(?:medikament|arzneimittel)\s+(?:namens|genannt)\s+)(?:["“']?[\p{L}\p{M}\d-]{1,32}(?:\s+(?:[\p{Lu}][\p{L}\p{M}\d-]{0,31}|XR|XL|ER|SR|CR|DR|IR)){0,2}["”']?)(?=\s+(?i:ist|war|für|im|in|mit|und|oder|von)\b|[.,!?;:]|$)"#, options: []),
            Rule(kind: .medication, pattern: #"\b(?:medikamente?|arzneimittel|rezept|dosis|insulin|epinephrin|adrenalin|epipen|inhalator|nitroglycerin|antikoagulanzien|blutverdünner|antibiotika|aspirin|paracetamol|ibuprofen|penicillin|antihistaminika|metformin|warfarin|amoxicillin|apixaban|rivaroxaban)\b"#, options: [.caseInsensitive]),
            Rule(kind: .emergency, pattern: #"\b(?:krankenwagen|rettungswagen|polizei|krankenhaus|feuer|brand|überdosis|kann\s+nicht\s+atmen|atemnot|brustschmerzen|herzinfarkt|schlaganfall|bewusstlos|starke\s+blutung|krampfanfall|hilfe|gefahr)\b"#, options: [.caseInsensitive]),
            Rule(kind: .number, pattern: #"\b(?:null|eins|zwei|drei|vier|fünf|sechs|sieben|acht|neun|zehn|elf|zwölf)\b"#, options: [.caseInsensitive])
        ]),
        LanguageProfile(languageCode: "it", rules: [
            Rule(kind: .date, pattern: #"\b(?:lunedì|martedì|mercoledì|giovedì|venerdì|sabato|domenica|oggi|domani|ieri)\b"#, options: [.caseInsensitive]),
            Rule(kind: .properName, pattern: #"\b(?i:mi chiamo|il mio nome è|chieda di)\s+[\p{Lu}][\p{L}\p{M}'’-]+(?:\s+[\p{Lu}][\p{L}\p{M}'’-]+){0,3}\b"#, options: []),
            Rule(kind: .negation, pattern: #"\b(?:non|mai|senza|nessun|nessuna|nessuno|né)\b"#, options: [.caseInsensitive]),
            Rule(kind: .allergy, pattern: #"\b(?:allergia|allergico|allergica|allergici|allergiche|anafilassi|glutine|arachidi|noci|frutta\s+a\s+guscio|crostacei|frutti\s+di\s+mare|latticini|lattosio|celiachia|celiaco|celiaca)\b"#, options: [.caseInsensitive]),
            Rule(kind: .medication, pattern: #"\b(?i:(?:farmaco|medicinale)\s+(?:chiamato|denominato)\s+)(?:["“']?[\p{L}\p{M}\d-]{1,32}(?:\s+(?:[\p{Lu}][\p{L}\p{M}\d-]{0,31}|XR|XL|ER|SR|CR|DR|IR)){0,2}["”']?)(?=\s+(?i:è|era|per|nel|in|con|e|o|di)\b|[.,!?;:]|$)"#, options: []),
            Rule(kind: .medication, pattern: #"\b(?:farmaci?|medicinali?|ricetta|dose|insulina|epinefrina|adrenalina|epipen|inalatore|nitroglicerina|anticoagulanti?|fluidificanti?\s+del\s+sangue|antibiotici?|aspirina|paracetamolo|ibuprofene|penicillina|antistaminici?|metformina|warfarin|amoxicillina|apixaban|rivaroxaban)\b"#, options: [.caseInsensitive]),
            Rule(kind: .emergency, pattern: #"\b(?:ambulanza|polizia|ospedale|incendio|fuoco|overdose|non\s+riesco\s+a\s+respirare|difficoltà\s+respiratoria|dolore\s+al\s+petto|attacco\s+cardiaco|infarto|ictus|incosciente|emorragia\s+grave|convulsione|aiuto|pericolo)\b"#, options: [.caseInsensitive]),
            Rule(kind: .number, pattern: #"\b(?:zero|due|tre|quattro|cinque|sei|sette|otto|nove|dieci|undici|dodici)\b"#, options: [.caseInsensitive])
        ]),
        LanguageProfile(languageCode: "pt", rules: [
            Rule(kind: .date, pattern: #"\b(?:segunda-feira|terça-feira|quarta-feira|quinta-feira|sexta-feira|sábado|domingo|hoje|amanhã|ontem)\b"#, options: [.caseInsensitive]),
            Rule(kind: .properName, pattern: #"\b(?i:me chamo|meu nome é|pergunte por)\s+[\p{Lu}][\p{L}\p{M}'’-]+(?:\s+[\p{Lu}][\p{L}\p{M}'’-]+){0,3}\b"#, options: []),
            Rule(kind: .negation, pattern: #"\b(?:não|nunca|jamais|sem|nenhum|nenhuma|nem)\b"#, options: [.caseInsensitive]),
            Rule(kind: .allergy, pattern: #"\b(?:alergia|alérgico|alérgica|alérgicos|alérgicas|anafilaxia|glúten|amendo(?:im|ins)|castanhas?|nozes|mariscos?|frutos\s+do\s+mar|laticínios?|lactose|celíaco|celíaca)\b"#, options: [.caseInsensitive]),
            Rule(kind: .medication, pattern: #"\b(?i:(?:medicamento|remédio|fármaco)\s+(?:chamado|denominado)\s+)(?:["“']?[\p{L}\p{M}\d-]{1,32}(?:\s+(?:[\p{Lu}][\p{L}\p{M}\d-]{0,31}|XR|XL|LP|ER|SR|CR|DR|IR)){0,2}["”']?)(?=\s+(?i:é|era|para|no|na|em|com|e|ou|de|do|da)\b|[.,!?;:]|$)"#, options: []),
            Rule(kind: .medication, pattern: #"\b(?:medicamentos?|remédios?|fármacos?|receita|dose|insulina|epinefrina|adrenalina|epipen|inalador|nitroglicerina|anticoagulantes?|afinadores?\s+do\s+sangue|antibióticos?|aspirina|paracetamol|ibuprofeno|penicilina|anti-histamínicos?|antihistamínicos?|metformina|varfarina|amoxicilina|apixabana?|rivaroxabana?)\b"#, options: [.caseInsensitive]),
            Rule(kind: .emergency, pattern: #"\b(?:ambulância|polícia|hospital|incêndio|fogo|sobredose|não\s+consigo\s+respirar|dificuldade\s+para\s+respirar|falta\s+de\s+ar|dor\s+no\s+peito|ataque\s+cardíaco|infarto|avc|derrame\s+cerebral|inconsciente|sangramento\s+grave|convulsão|ajuda|perigo)\b"#, options: [.caseInsensitive]),
            Rule(kind: .number, pattern: #"\b(?:zero|dois|duas|três|quatro|cinco|seis|sete|oito|nove|dez|onze|doze)\b"#, options: [.caseInsensitive])
        ]),
        LanguageProfile(languageCode: "hi", rules: [
            Rule(kind: .negation, pattern: #"(?<![\p{L}\p{M}])(?:कभी\s+नहीं|नहीं|नही|मत|बिना|न|ना|kabhi\s+nah(?:i|in)|nah(?:i|in)|mat|bina)(?![\p{L}\p{M}])"#, options: [.caseInsensitive]),
            Rule(kind: .allergy, pattern: #"(?:एलर्जी|अलर्जी|एनाफिलैक्सिस|एनाफिलेक्सिस|ग्लूटेन|मूंगफली|मूँगफली|मेवे|सूखे\s+मेवे|शेलफिश|झींगा|डेयरी|दूध|दुग्ध(?:\s+उत्पाद)?|लैक्टोज|सीलिएक)"#, options: []),
            Rule(kind: .medication, pattern: #"(?:दवा|दवाई|दवाइयाँ|दवाएँ|औषधि|पर्चा|खुराक|इंसुलिन|एपिनेफ्रिन|एड्रेनालिन|एपिपेन|इनहेलर|नाइट्रोग्लिसरीन|एंटीकोआगुलेंट|खून\s+पतला\s+करने\s+वाली\s+दवा|एंटीबायोटिक|एस्पिरिन|पैरासिटामोल|इबुप्रोफेन|पेनिसिलिन|एंटीहिस्टामिन|मेटफॉर्मिन|वारफारिन|अमोक्सिसिलिन|एपिक्साबैन|रिवरोक्साबैन)"#, options: []),
            Rule(kind: .emergency, pattern: #"(?:एम्बुलेंस|पुलिस|अस्पताल|आग|ओवरडोज|(?:साँस|सांस)\s+लेने\s+में\s+(?:कठिनाई|दिक्कत|परेशानी|तकलीफ)|(?:साँस|सांस)\s+नहीं(?:\s+आ\s+रह[ाी])?|saans\s+lene\s+mein\s+(?:dikkat|pareshani|takleef)|saans\s+nahi\s+aa\s+rah(?:a|i)|सीने\s+में\s+दर्द|दिल\s+का\s+दौरा|हृदयाघात|स्ट्रोक|बेहोश|भारी\s+रक्तस्राव|(?:बहुत\s+)?खून\s+(?:बह|निकल)\s+रह[ाी](?:\s+है)?|(?:bahut\s+)?(?:khun|khoon)\s+bah\s+rah(?:a|i)|दौरा|मदद|खतरा)"#, options: [.caseInsensitive]),
            Rule(kind: .number, pattern: #"(?<![\p{L}\p{M}])(?:बारह|ग्यारह|शून्य|ज़ीरो|जीरो|एक|दो|तीन|चार|पाँच|पांच|छह|छः|सात|आठ|नौ|दस)(?![\p{L}\p{M}])"#, options: [])
        ]),
        LanguageProfile(languageCode: "ko", rules: [
            Rule(kind: .date, pattern: #"(?:월요일|화요일|수요일|목요일|금요일|토요일|일요일|오늘|내일|어제)"#, options: []),
            Rule(kind: .properName, pattern: #"(?:제\s*이름은|이름은)\s*(?:[\p{Lu}][\p{Latin}\p{M}'-]*(?:\s+[\p{Lu}][\p{Latin}\p{M}'-]*){0,3}|[\p{Hangul}]{2,8})(?=입니다|이에요|예요|라고|[.,!?]|$)"#, options: []),
            Rule(kind: .negation, pattern: #"(?<!\p{L})(?:안|못)(?!\p{L})|(?:없(?:다|어요|습니다|고)?|아니(?:다|에요|예요|요|습니다)?|않(?:다|아요|습니다)?|말(?:다|아요|습니다)?|불가|금지)"#, options: []),
            Rule(kind: .allergy, pattern: #"(?:알레르기|아나필락시스|글루텐|땅콩|견과류|갑각류|조개류|해산물|유제품|유당|셀리악병?)"#, options: []),
            Rule(kind: .medication, pattern: #"[\p{L}\p{M}\d-]{1,32}(?:\s+[\p{L}\p{M}\d-]{1,32}){0,2}(?:(?:이)?라는|이라고\s+하는|라고\s+하는)\s*약"#, options: []),
            Rule(kind: .medication, pattern: #"(?:약|의약품|처방전?|복용량|투약|인슐린|에피네프린|아드레날린|에피펜|흡입기|니트로글리세린|항응고제|혈액희석제|항생제|아스피린|아세트아미노펜|파라세타몰|이부프로펜|페니실린|항히스타민제|메트포르민|와파린|아목시실린|아픽사반|리바록사반)"#, options: []),
            Rule(kind: .emergency, pattern: #"(?:구급차|경찰|병원|화재|불이\s*났|과다\s*복용|숨을\s*쉴\s*수\s*없|호흡\s*곤란|가슴\s*통증|심장\s*마비|심근\s*경색|뇌졸중|의식\s*불명|심한\s*출혈|대량\s*출혈|발작|경련|도와\s*주세요|도움|위험)"#, options: []),
            Rule(kind: .number, pattern: #"(?<![\p{L}\d])(?:열두|열한|열|아홉|여덟|일곱|여섯|다섯|넷|네|셋|세|둘|두|하나|한|십|구|팔|칠|육|오|사|삼|이|일|영|공)(?![\p{L}\d])"#, options: [])
        ])
    ]

    private static let allergyConceptAliases: [ConceptAliases] = [
        ConceptAliases(concept: "PEANUT", fragments: [
            "peanut", "cacahu", "mani", "ピーナッツ", "arachid", "erdnuss", "amendoim", "땅콩",
            "मूंगफली", "मूँगफली"
        ]),
        ConceptAliases(concept: "SHELLFISH", fragments: [
            "shellfish", "marisco", "甲殻類", "crustace", "fruits de mer", "schalentier",
            "meeresfrucht", "crostace", "frutti di mare", "frutos do mar", "갑각류", "조개류", "해산물",
            "शेलफिश", "झींगा"
        ]),
        ConceptAliases(concept: "DAIRY", fragments: [
            "dairy", "lacte", "乳製品", "produit laitier", "milchprodukt", "latticin", "laticin", "유제품",
            "डेयरी", "दूध", "दुग्ध"
        ]),
        ConceptAliases(concept: "LACTOSE", fragments: [
            "lactose", "laktose", "lattosio", "乳糖", "유당", "लैक्टोज"
        ]),
        ConceptAliases(concept: "GLUTEN", fragments: [
            "gluten", "グルテン", "celiac", "cœlia", "coelia", "zoliak", "celiach", "셀리악", "글루텐",
            "ग्लूटेन", "सीलिएक"
        ]),
        ConceptAliases(concept: "NUT", fragments: [
            "nut", "ナッツ", "noix", "nuss", "frutta a guscio", "castanha", "noz", "견과류",
            "मेवे", "सूखे मेवे"
        ]),
        ConceptAliases(concept: "ANAPHYLAXIS", fragments: [
            "anaphyl", "anafil", "アナフィ", "아나필", "एनाफिलैक्सिस", "एनाफिलेक्सिस"
        ])
    ]

    private static let medicationConceptAliases: [ConceptAliases] = [
        ConceptAliases(concept: "INSULIN", fragments: [
            "insulin", "insulina", "insuline", "インスリン", "인슐린", "इंसुलिन"
        ]),
        ConceptAliases(concept: "EPINEPHRINE", fragments: [
            "epinephrine", "epinefrina", "epinephrin", "epinephrine", "epipen", "adrenaline",
            "adrenalina", "adrenalin", "エピネフリン", "エピペン", "アドレナリン",
            "에피네프린", "에피펜", "아드레날린", "एपिनेफ्रिन", "एड्रेनालिन", "एपिपेन"
        ]),
        ConceptAliases(concept: "ASPIRIN", fragments: [
            "aspirin", "aspirina", "aspirine", "アスピリン", "아스피린", "एस्पिरिन"
        ]),
        ConceptAliases(concept: "ACETAMINOPHEN", fragments: [
            "acetaminophen", "acetaminofen", "paracetamol", "paracetamolo",
            "アセトアミノフェン", "パラセタモール", "아세트아미노펜", "파라세타몰", "पैरासिटामोल"
        ]),
        ConceptAliases(concept: "IBUPROFEN", fragments: [
            "ibuprofen", "ibuprofeno", "ibuprofene", "イブプロフェン", "이부프로펜", "इबुप्रोफेन"
        ]),
        ConceptAliases(concept: "PENICILLIN", fragments: [
            "penicillin", "penicilina", "penicillina", "ペニシリン", "페니실린", "पेनिसिलिन"
        ]),
        ConceptAliases(concept: "ANTIHISTAMINE", fragments: [
            "antihistamin", "anti-histamin", "antistamin", "antihistamine", "antihistamines",
            "antihistaminico", "antihistaminicos", "anti-histaminico", "anti-histaminicos",
            "antihistaminique", "antihistaminiques", "antihistaminika", "antistaminico",
            "antistaminici", "抗ヒスタミン", "항히스타민", "항히스타민제", "एंटीहिस्टामिन"
        ]),
        ConceptAliases(concept: "METFORMIN", fragments: [
            "metformin", "metformina", "metformine", "メトホルミン", "메트포르민", "मेटफॉर्मिन"
        ]),
        ConceptAliases(concept: "WARFARIN", fragments: [
            "warfarin", "warfarina", "warfarine", "varfarina", "ワルファリン", "와파린", "वारफारिन"
        ]),
        ConceptAliases(concept: "AMOXICILLIN", fragments: [
            "amoxicillin", "amoxicilina", "amoxicillina", "amoxicilline", "アモキシシリン", "아목시실린", "अमोक्सिसिलिन"
        ]),
        ConceptAliases(concept: "APIXABAN", fragments: [
            "apixaban", "apixabana", "アピキサバン", "아픽사반", "एपिक्साबैन"
        ]),
        ConceptAliases(concept: "RIVAROXABAN", fragments: [
            "rivaroxaban", "rivaroxabana", "リバーロキサバン", "리바록사반", "रिवरोक्साबैन"
        ]),
        ConceptAliases(concept: "INHALER", fragments: [
            "inhaler", "inhalador", "inhalateur", "inhalator", "inalatore", "吸入器", "흡입기", "इनहेलर"
        ]),
        ConceptAliases(concept: "NITROGLYCERIN", fragments: [
            "nitroglycerin", "nitroglicerina", "nitroglycerine", "ニトログリセリン", "니트로글리세린", "नाइट्रोग्लिसरीन"
        ]),
        ConceptAliases(concept: "ANTICOAGULANT", fragments: [
            "anticoag", "blood thinner", "fluidifiant du sang", "blutverdunn", "fluidificante del sangue",
            "afinador do sangue", "抗凝固", "항응고", "혈액희석", "एंटीकोआगुलेंट", "खून पतला"
        ]),
        ConceptAliases(concept: "ANTIBIOTIC", fragments: [
            "antibi", "抗生物質", "항생제", "एंटीबायोटिक"
        ]),
        ConceptAliases(concept: "PRESCRIPTION", fragments: [
            "prescription", "receta", "ordonnance", "rezept", "ricetta", "receita", "処方", "처방", "पर्चा"
        ]),
        ConceptAliases(concept: "DOSE", fragments: [
            "dose", "dosage", "dosis", "服用量", "복용량", "खुराक"
        ])
    ]

    private static let emergencyConceptAliases: [ConceptAliases] = [
        ConceptAliases(concept: "AMBULANCE", fragments: [
            "ambul", "krankenwagen", "rettungswagen", "救急車", "구급차", "एम्बुलेंस"
        ]),
        ConceptAliases(concept: "POLICE", fragments: [
            "polic", "polizei", "polizia", "警察", "경찰", "पुलिस"
        ]),
        ConceptAliases(concept: "HOSPITAL", fragments: [
            "hospital", "hopital", "krankenhaus", "ospedale", "病院", "병원", "अस्पताल"
        ]),
        ConceptAliases(concept: "FIRE", fragments: [
            "fire", "incend", "feuer", "brand", "fuoco", "火事", "화재", "불이", "आग"
        ]),
        ConceptAliases(concept: "OVERDOSE", fragments: [
            "overdose", "sobredosis", "surdose", "uberdosis", "sobredose", "過剰摂取", "과다", "ओवरडोज"
        ]),
        ConceptAliases(concept: "BREATHING_DIFFICULTY", fragments: [
            "breathe", "breathing", "respirar", "respiratoire", "atemnot", "atmen",
            "respiratoria", "falta de ar", "呼吸困難", "息ができない", "숨을", "호흡",
            "साँस", "सांस", "saans"
        ]),
        ConceptAliases(concept: "CHEST_PAIN", fragments: [
            "chest", "pecho", "thoracique", "brustschmerz", "petto", "胸の痛み", "가슴", "सीने में दर्द"
        ]),
        ConceptAliases(concept: "HEART_ATTACK", fragments: [
            "heart attack", "cardiaco", "crise cardiaque", "infarct", "herzinfarkt",
            "attacco cardiaco", "ataque cardiaco", "心臓発作", "심장", "심근", "दिल का दौरा", "हृदयाघात"
        ]),
        ConceptAliases(concept: "STROKE", fragments: [
            "stroke", "derrame", "accident vasculaire", "schlaganfall", "ictus", "avc", "脳卒中", "뇌졸중", "स्ट्रोक"
        ]),
        ConceptAliases(concept: "UNCONSCIOUS", fragments: [
            "unconscious", "inconsciente", "inconscient", "bewusstlos", "incosciente", "意識不明", "의식", "बेहोश"
        ]),
        ConceptAliases(concept: "SEVERE_BLEEDING", fragments: [
            "bleeding", "sangrado", "saignement", "blutung", "emorragia", "sangramento", "大量出血", "출혈", "रक्तस्राव",
            "खून बह", "खून निकल", "khoon bah", "khun bah"
        ]),
        ConceptAliases(concept: "SEIZURE", fragments: [
            "seizure", "convulsion", "krampfanfall", "けいれん", "痙攣", "발작", "경련", "दौरा"
        ]),
        ConceptAliases(concept: "DANGER", fragments: [
            "danger", "peligro", "gefahr", "pericolo", "perigo", "危険", "위험", "खतरा"
        ])
    ]

    func extract(
        from text: String,
        locale: Locale? = nil,
        referenceDate: Date = Date(),
        timeZone: TimeZone = .current
    ) -> [CriticalEntity] {
        extractLimited(from: text, locale: locale, referenceDate: referenceDate, timeZone: timeZone).entities
    }

    private func extractLimited(
        from text: String,
        locale: Locale?,
        referenceDate: Date,
        timeZone: TimeZone
    ) -> CriticalEntityExtraction {
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        var occupied = Set<NSRangeKey>()
        var result: [CriticalEntity] = []
        var limitExceeded = false

        for rule in rules(for: locale) {
            guard !limitExceeded else { break }
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else { continue }
            regex.enumerateMatches(in: text, range: full) { match, _, stop in
                guard let match else { return }
                guard let range = Range(match.range, in: text) else { return }
                let key = NSRangeKey(match.range)
                if occupied.contains(where: { $0.contains(key) }) { return }
                guard result.count < ConversationContentPolicy.maximumSafetyEntities else {
                    limitExceeded = true
                    stop.pointee = true
                    return
                }
                let value = String(text[range])
                let normalized = normalize(value, kind: rule.kind, locale: locale, referenceDate: referenceDate, timeZone: timeZone)
                result.append(CriticalEntity(kind: rule.kind, value: value, normalizedValue: normalized))
                if rule.kind != .number { occupied.insert(key) }
            }
        }
        let sorted = result.sorted {
            if $0.kind.rawValue == $1.kind.rawValue { return $0.normalizedValue < $1.normalizedValue }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        return CriticalEntityExtraction(entities: sorted, limitExceeded: limitExceeded)
    }

    private func rules(for locale: Locale?) -> [Rule] {
        guard let languageCode = locale?.language.languageCode?.identifier else {
            return baseRules + Self.languageProfiles.flatMap(\.rules)
        }
        return baseRules + Self.languageProfiles
            .filter { $0.languageCode == languageCode }
            .flatMap(\.rules)
    }

    func compare(
        source: String,
        translation: String,
        sourceLocale: Locale? = nil,
        targetLocale: Locale? = nil,
        referenceDate: Date = Date(),
        timeZone: TimeZone = .current
    ) -> EntityIntegrityReport {
        let sourceExtraction = extractLimited(from: source, locale: sourceLocale, referenceDate: referenceDate, timeZone: timeZone)
        let translationExtraction = extractLimited(from: translation, locale: targetLocale, referenceDate: referenceDate, timeZone: timeZone)
        let sourceEntities = sourceExtraction.entities
        let translatedEntities = translationExtraction.entities
        var remaining = Dictionary(grouping: translatedEntities, by: \CriticalEntity.kind)
        var missing = Set<CriticalEntityKind>()
        var mismatches: [CriticalEntity] = []

        for entity in sourceEntities {
            guard var candidates = remaining[entity.kind], !candidates.isEmpty else {
                missing.insert(entity.kind)
                continue
            }
            if let index = candidates.firstIndex(where: { equivalent(entity.normalizedValue, $0.normalizedValue, kind: entity.kind) }) {
                candidates.remove(at: index)
                remaining[entity.kind] = candidates
            } else {
                mismatches.append(entity)
                // Consume one same-kind candidate so duplicate counts are compared as a multiset.
                candidates.removeFirst()
                remaining[entity.kind] = candidates
            }
        }

        let invented = remaining.values.flatMap { $0 }.sorted {
            if $0.kind.rawValue == $1.kind.rawValue { return $0.normalizedValue < $1.normalizedValue }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        return EntityIntegrityReport(
            source: sourceEntities,
            translation: translatedEntities,
            missingKinds: missing,
            mismatchedValues: mismatches,
            inventedValues: invented,
            extractionLimitExceeded: sourceExtraction.limitExceeded || translationExtraction.limitExceeded
        )
    }

    private func equivalent(_ lhs: String, _ rhs: String, kind: CriticalEntityKind) -> Bool {
        if lhs == rhs { return true }
        // Names and address street labels can be transliterated, but their numeric
        // components may never change. Anything else remains review-required.
        if kind == .address {
            let leftDigits = lhs.filter(\.isNumber)
            let rightDigits = rhs.filter(\.isNumber)
            return !leftDigits.isEmpty && leftDigits == rightDigits && tokenSimilarity(lhs, rhs) >= 0.45
        }
        if kind == .properName { return tokenSimilarity(lhs, rhs) >= 0.78 }
        return false
    }

    private func normalize(_ value: String, kind: CriticalEntityKind, locale: Locale?, referenceDate: Date, timeZone: TimeZone) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        switch kind {
        case .phone:
            return canonicalDecimalDigits(folded)
        case .number:
            return canonicalNumber(folded)
        case .currency:
            let code: String
            if folded.contains("€") || folded.contains("eur") || folded.contains("euro") { code = "EUR" }
            else if folded.contains("£") || folded.contains("gbp") || folded.contains("pound") || folded.contains("libra") { code = "GBP" }
            else if folded.contains("¥") || folded.contains("jpy") || folded.contains("yen") || folded.contains("円") { code = "JPY" }
            else if folded.contains("r$") || folded.contains("brl") || folded.contains("real") || folded.contains("reais") { code = "BRL" }
            else if folded.contains("₩") || folded.contains("krw") || folded.contains("won") || folded.contains("원") { code = "KRW" }
            else if folded.contains("₹") || folded.contains("inr") || folded.contains("रु") { code = "INR" }
            else { code = "USD" }
            return "\(code):\(canonicalDigits(folded))"
        case .unit:
            return canonicalUnit(folded)
        case .time:
            return canonicalTime(folded)
        case .date:
            return canonicalDate(folded, locale: locale, referenceDate: referenceDate, timeZone: timeZone)
        case .allergy:
            return allergyConcept(folded)
        case .medication:
            return medicationConcept(folded)
        case .emergency:
            return emergencyConcept(folded)
        case .negation:
            return "NEGATION"
        case .address:
            return canonicalAddress(folded)
        case .properName:
            return folded
                .replacingOccurrences(
                    of: #"^(my name is|i am|ask for|named|me llamo|mi nombre es|pregunte por|je m['’]appelle|mon nom est|demandez a voir|demandez apres|demandez|ich heiße|ich heisse|mein name ist|fragen sie nach|mi chiamo|il mio nome e|chieda di|me chamo|meu nome e|pergunte por|私の名前は|名前は|さんは|제\s*이름은|이름은)\s*"#,
                    with: "",
                    options: .regularExpression
                )
                .filter { $0.isLetter || $0.isNumber }
        }
    }

    private func canonicalNumber(_ value: String) -> String {
        let words: [String: String] = [
            "zero": "0", "cero": "0", "null": "0", "영": "0", "공": "0",
            "one": "1", "uno": "1", "una": "1", "un": "1", "une": "1", "eins": "1",
            "ein": "1", "eine": "1", "um": "1", "uma": "1", "하나": "1", "한": "1", "일": "1",
            "two": "2", "dos": "2", "deux": "2", "zwei": "2", "due": "2", "dois": "2",
            "duas": "2", "둘": "2", "두": "2", "이": "2",
            "three": "3", "tres": "3", "trois": "3", "drei": "3", "tre": "3", "셋": "3",
            "세": "3", "삼": "3",
            "four": "4", "cuatro": "4", "quatre": "4", "vier": "4", "quattro": "4",
            "quatro": "4", "넷": "4", "네": "4", "사": "4",
            "five": "5", "cinco": "5", "cinq": "5", "funf": "5", "cinque": "5", "다섯": "5", "오": "5",
            "six": "6", "seis": "6", "sechs": "6", "sei": "6", "여섯": "6", "육": "6",
            "seven": "7", "siete": "7", "sept": "7", "sieben": "7", "sette": "7",
            "sete": "7", "일곱": "7", "칠": "7",
            "eight": "8", "ocho": "8", "huit": "8", "acht": "8", "otto": "8",
            "oito": "8", "여덟": "8", "팔": "8",
            "nine": "9", "nueve": "9", "neuf": "9", "neun": "9", "nove": "9", "아홉": "9", "구": "9",
            "ten": "10", "diez": "10", "dix": "10", "zehn": "10", "dieci": "10",
            "dez": "10", "열": "10", "십": "10",
            "eleven": "11", "once": "11", "onze": "11", "elf": "11", "undici": "11", "열한": "11",
            "twelve": "12", "doce": "12", "douze": "12", "zwolf": "12", "dodici": "12",
            "doze": "12", "열두": "12",
            "शून्य": "0", "ज़ीरो": "0", "जीरो": "0",
            "एक": "1", "दो": "2", "तीन": "3", "चार": "4", "पाँच": "5", "पांच": "5",
            "छह": "6", "छः": "6", "सात": "7", "आठ": "8", "नौ": "9", "दस": "10",
            "ग्यारह": "11", "बारह": "12"
        ]
        if let mapped = words[value.trimmingCharacters(in: .whitespacesAndNewlines)] { return mapped }
        if value.range(of: #"^[一二三四五六七八九十百千万〇零]+$"#, options: .regularExpression) != nil,
           let number = parseJapaneseNumber(value) { return String(number) }
        return canonicalDigits(value)
    }

    private func asciiDigit(_ character: Character) -> Character {
        switch character {
        case "०": "0"
        case "१": "1"
        case "२": "2"
        case "३": "3"
        case "४": "4"
        case "५": "5"
        case "६": "6"
        case "७": "7"
        case "८": "8"
        case "९": "9"
        default: character
        }
    }

    private func replacingDevanagariDigits(in value: String) -> String {
        String(value.map(asciiDigit))
    }

    private func canonicalDecimalDigits(_ value: String) -> String {
        replacingDevanagariDigits(in: value).filter(\.isNumber)
    }

    private func canonicalDigits(_ value: String) -> String {
        var result = replacingDevanagariDigits(in: value)
            .filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }
        if result.contains(","), !result.contains(".") {
            let commaCount = result.filter { $0 == "," }.count
            let finalGroupCount = result.split(separator: ",", omittingEmptySubsequences: false).last?.count ?? 0
            if commaCount > 1 || finalGroupCount == 3 {
                result = result.replacingOccurrences(of: ",", with: "")
            } else {
                result = result.replacingOccurrences(of: ",", with: ".")
            }
        } else {
            result = result.replacingOccurrences(of: ",", with: "")
        }
        return result
    }

    private func canonicalUnit(_ value: String) -> String {
        let amount = canonicalDigits(value)
        let compact = value.replacingOccurrences(
            of: #"[.\s]"#,
            with: "",
            options: .regularExpression
        )
        let unit: String
        if compact.contains("किलोमीटर") || compact.contains("किमी") { unit = "km" }
        else if value.contains("kg") || value.contains("kilogram") || value.contains("chilogram") || value.contains("quilogram") || value.contains("kilo") || value.contains("キロクラム") || value.contains("キログラム") || value.contains("킬로그램") || compact.contains("किलोग्राम") || compact.hasSuffix("किलो") || compact.contains("किग्रा") { unit = "kg" }
        else if value.contains("km") || value.contains("kilomet") || value.contains("chilometr") || value.contains("quilometr") || value.contains("キロメートル") || value.contains("킬로미터") { unit = "km" }
        else if value.contains("lb") || value.contains("pound") || value.contains("libra") || value.contains("libbr") || value.contains("pfund") || value.contains("パウンド") || value.contains("파운드") { unit = "lb" }
        else if value.contains("mile") || value.contains("milla") || value.contains("meile") || value.contains("migli") || value.contains("milha") || value.contains("マイル") || value.contains("마일") || value.contains("मील") { unit = "mi" }
        else if value.contains("cm") || value.contains("centim") || value.contains("zentimet") || value.contains("センチ") || value.contains("센티미터") || compact.contains("सेंटीमीटर") || compact.contains("सेमी") { unit = "cm" }
        else if value.contains("mm") || value.contains("millim") || value.contains("ミリメートル") || value.contains("밀리미터") || compact.contains("मिलीमीटर") || compact.contains("मिमी") { unit = "mm" }
        else if value.contains("°f") || value.contains("fahrenheit") || value.contains("화씨") || value.contains("फारेनहाइट") || value.contains("फ़ारेनहाइट") { unit = "F" }
        else if value.contains("°c") || value.contains("celsius") || value.contains("섭씨") || value.contains("सेल्सियस") { unit = "C" }
        else if value.contains("gram") || value.contains("gramm") || value.contains("グラム") || value.contains("그램") || value.contains("ग्राम") { unit = "g" }
        else { unit = "m" }
        return "\(unit):\(amount)"
    }

    private func canonicalTime(_ value: String) -> String {
        let isPM = value.contains("pm") || value.contains("p.m") || value.contains("午後") || value.contains("오후") || value.contains("दोपहर") || value.contains("शाम")
        let isAM = value.contains("am") || value.contains("a.m") || value.contains("午前") || value.contains("오전") || value.contains("सुबह")
        let isNight = value.contains("रात")
        let asciiValue = replacingDevanagariDigits(in: value)
        let parts = asciiValue.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard var hour = parts.first else { return value }
        let minute = parts.dropFirst().first ?? 0
        if isPM && hour < 12 { hour += 12 }
        if isAM && hour == 12 { hour = 0 }
        if isNight { hour = hour == 12 ? 0 : hour < 12 ? hour + 12 : hour }
        return String(format: "%02d:%02d", hour, minute)
    }

    private func canonicalDate(_ value: String, locale: Locale?, referenceDate: Date, timeZone: TimeZone) -> String {
        let relative: [String: Int] = [
            "today": 0, "hoy": 0, "今日": 0, "aujourd'hui": 0, "aujourd’hui": 0,
            "heute": 0, "oggi": 0, "hoje": 0, "오늘": 0, "आज": 0,
            "tomorrow": 1, "manana": 1, "明日": 1, "demain": 1, "morgen": 1,
            "domani": 1, "amanha": 1, "내일": 1, "आने वाला कल": 1,
            "yesterday": -1, "ayer": -1, "昨日": -1, "hier": -1, "gestern": -1,
            "ieri": -1, "ontem": -1, "어제": -1, "बीता कल": -1, "बीता हुआ कल": -1
        ]
        if let offset = relative[value] {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
            let date = calendar.date(byAdding: .day, value: offset, to: referenceDate) ?? referenceDate
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            formatter.timeZone = timeZone
            return formatter.string(from: date)
        }
        let weekdays: [String: String] = [
            "monday": "MON", "lunes": "MON", "月曜日": "MON", "lundi": "MON", "montag": "MON",
            "lunedi": "MON", "segunda-feira": "MON", "월요일": "MON", "सोमवार": "MON",
            "tuesday": "TUE", "martes": "TUE", "火曜日": "TUE", "mardi": "TUE", "dienstag": "TUE",
            "martedi": "TUE", "terca-feira": "TUE", "화요일": "TUE", "मंगलवार": "TUE",
            "wednesday": "WED", "miercoles": "WED", "水曜日": "WED", "mercredi": "WED", "mittwoch": "WED",
            "mercoledi": "WED", "quarta-feira": "WED", "수요일": "WED", "बुधवार": "WED",
            "thursday": "THU", "jueves": "THU", "木曜日": "THU", "jeudi": "THU", "donnerstag": "THU",
            "giovedi": "THU", "quinta-feira": "THU", "목요일": "THU", "गुरुवार": "THU", "बृहस्पतिवार": "THU",
            "friday": "FRI", "viernes": "FRI", "金曜日": "FRI", "vendredi": "FRI", "freitag": "FRI",
            "venerdi": "FRI", "sexta-feira": "FRI", "금요일": "FRI", "शुक्रवार": "FRI",
            "saturday": "SAT", "sabado": "SAT", "土曜日": "SAT", "samedi": "SAT", "samstag": "SAT",
            "토요일": "SAT", "शनिवार": "SAT",
            "sunday": "SUN", "domingo": "SUN", "日曜日": "SUN", "dimanche": "SUN", "sonntag": "SUN",
            "domenica": "SUN", "일요일": "SUN", "रविवार": "SUN"
        ]
        if let weekday = weekdays[value] { return weekday }
        let numericValue = replacingDevanagariDigits(in: value)
        let components = numericValue.split(whereSeparator: { !$0.isNumber })
        let digits = components.compactMap { Int($0) }
        if digits.count == 3, components.count == 3 {
            let yearFirst = components[0].count == 4
            let rawYear = yearFirst ? digits[0] : digits[2]
            let year = rawYear < 100 ? 2000 + rawYear : rawYear
            let language = locale?.language.languageCode?.identifier ?? "en"
            let month = yearFirst ? digits[1] : language == "en" ? digits[0] : digits[1]
            let day = yearFirst ? digits[2] : language == "en" ? digits[1] : digits[0]
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        return value
    }

    private func allergyConcept(_ value: String) -> String {
        concept(for: value, aliases: Self.allergyConceptAliases) ?? "ALLERGY"
    }

    private func medicationConcept(_ value: String) -> String {
        if let name = explicitMedicationName(value) {
            return knownExplicitMedicationConcept(name) ?? "NAMED_MEDICATION:\(name)"
        }
        return concept(for: value, aliases: Self.medicationConceptAliases) ?? "MEDICATION"
    }

    private func explicitMedicationName(_ value: String) -> String? {
        var name = value
        if value.hasSuffix("という薬") || value.hasSuffix("と呼ばれる薬") {
            name = value.replacingOccurrences(of: #"(?:という薬|と呼ばれる薬)$"#, with: "", options: .regularExpression)
        } else if value.range(of: #"(?:이라는|라는|이라고\s+하는|라고\s+하는)\s*약$"#, options: .regularExpression) != nil {
            name = value.replacingOccurrences(
                of: #"(?:이라는|라는|이라고\s+하는|라고\s+하는)\s*약$"#,
                with: "",
                options: .regularExpression
            )
        } else {
            let stripped = value.replacingOccurrences(
                of: #"^(?:(?:medication|medicine|prescription\s+drug|drug|medicamento|medicina|farmaco)\s+(?:called|named|llamad[oa])|(?:medicament|medecine)\s+(?:appele|nomme)|(?:medikament|arzneimittel)\s+(?:namens|genannt)|(?:farmaco|medicinale)\s+(?:chiamato|denominato)|(?:medicamento|remedio|farmaco)\s+(?:chamado|denominado))\s+"#,
                with: "",
                options: .regularExpression
            )
            guard stripped != value else { return nil }
            name = stripped
        }

        name = name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: #""'“”"#)))
        let tokens = name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard (1...3).contains(tokens.count),
              tokens.allSatisfy({ token in
                  (1...32).contains(token.count) && token.unicodeScalars.allSatisfy {
                      CharacterSet.letters.contains($0)
                          || CharacterSet.nonBaseCharacters.contains($0)
                          || CharacterSet.decimalDigits.contains($0)
                          || $0.value == 0x2D
                          || $0.value == 0x30FC
                  }
              }) else { return nil }
        let canonical = tokens.joined(separator: " ").uppercased()
        // The regex admits at most three 32-character tokens. Four-byte Unicode
        // scalars plus separators therefore remain below this defensive ceiling.
        guard canonical.utf8.count <= 512 else { return nil }
        return canonical
    }

    private func knownExplicitMedicationConcept(_ name: String) -> String? {
        let folded = name
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        for mapping in Self.medicationConceptAliases where mapping.fragments.contains(folded) {
            return mapping.concept
        }
        return nil
    }

    private func emergencyConcept(_ value: String) -> String {
        concept(for: value, aliases: Self.emergencyConceptAliases) ?? "HELP"
    }

    private func concept(for value: String, aliases: [ConceptAliases]) -> String? {
        aliases.first { mapping in
            mapping.fragments.contains { value.contains($0) }
        }?.concept
    }

    private func canonicalAddress(_ value: String) -> String {
        replacingDevanagariDigits(in: value)
            .replacingOccurrences(of: #"\b(street|st|calle|rue|straße|strasse|via|rua)\b"#, with: "street", options: .regularExpression)
            .replacingOccurrences(of: #"\b(avenue|ave|avenida|viale)\b"#, with: "avenue", options: .regularExpression)
            .replacingOccurrences(of: #"\b(road|rd|carretera|route|weg|estrada)\b"#, with: "road", options: .regularExpression)
            .replacingOccurrences(of: #"\b(boulevard|blvd|corso)\b"#, with: "boulevard", options: .regularExpression)
            .filter { $0.isLetter || $0.isNumber }
    }

    private func tokenSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Set(lhs.filter { $0.isLetter || $0.isNumber })
        let b = Set(rhs.filter { $0.isLetter || $0.isNumber })
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    private func parseJapaneseNumber(_ value: String) -> Int? {
        let digits: [Character: Int] = ["〇": 0, "零": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1_000, "万": 10_000]
        var total = 0, section = 0, pending = 0
        for character in value {
            if let digit = digits[character] { pending = digit }
            else if let unit = units[character] {
                if unit == 10_000 { section += pending; total += max(1, section) * unit; section = 0 }
                else { section += max(1, pending) * unit }
                pending = 0
            } else { return nil }
        }
        return total + section + pending
    }
}

private struct NSRangeKey: Hashable {
    let location: Int
    let length: Int
    init(_ range: NSRange) { location = range.location; length = range.length }
    func contains(_ other: NSRangeKey) -> Bool { other.location >= location && other.location + other.length <= location + length }
}
