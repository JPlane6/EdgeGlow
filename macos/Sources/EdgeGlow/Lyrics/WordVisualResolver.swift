import Foundation
import AppKit
import NaturalLanguage

/// Resolves a lyric word to an SF Symbol or emoji.
///  Layer 0: direct overrides · Layer 1: curated dictionary · Layer 2: Apple's CoreGlyphs search index
///  (`symbol_search.plist`) · Layer 3: `NLTagger` lemma, then `NLEmbedding` nearest neighbours re-resolved
///  through layers 0–2. Resolved words persist in `~/Library/Caches/EdgeGlow/WordVisuals.json`.
final class WordVisualResolver: @unchecked Sendable {
    static let shared = WordVisualResolver()

    private let lock = NSLock()
    private var cache: [String: WordVisual?] = [:]
    private var inflight = Set<String>()
    private var glyphIndex: [String: String] = [:]
    private var glyphIndexReady = false
    private var embedding: NLEmbedding?
    private var embeddingReady = false
    private var cacheDirty = false
    private let queue = DispatchQueue(label: "com.jplane6.EdgeLyrics.visuals", qos: .utility)

    private init() {
        queue.async { [self] in loadDiskCache() }
        queue.async { [self] in loadGlyphIndex() }
    }

    // MARK: Public

    /// Cheap and thread-safe; safe to call every frame. Deeper layers fill in asynchronously.
    func visual(for rawWord: String) -> WordVisual? {
        let token = Self.normalize(rawWord)
        guard token.count >= 2 else { return nil }
        if let v = Self.overrideLookup(token), Self.exists(v) { return v }
        if let v = Self.curatedLookup(token), Self.exists(v) { return v }
        guard token.count >= 4, !Self.stopwords.contains(token) else { return nil }
        lock.lock()
        if let hit = cache[token] { lock.unlock(); return hit ?? nil }
        let ready = glyphIndexReady
        let alreadyQueued = inflight.contains(token)
        if ready, !alreadyQueued { inflight.insert(token) }
        lock.unlock()
        if ready, !alreadyQueued {
            queue.async { [self] in
                let v = deepResolve(token)
                lock.lock(); cache[token] = .some(v); inflight.remove(token); lock.unlock()
            }
        }
        return nil
    }

    /// Warm the deep layers for every word in a song so frames only hit the cache. Loads the English word
    /// embedding on first use (only the icon styles call this).
    func prepare(_ lyrics: TimedLyrics) {
        queue.async { [self] in
            loadEmbedding()
            // The indexes load on this same serial queue, so they are ready by now.
            for w in Set(lyrics.words.map { Self.normalize($0.text) }) where w.count >= 4 && !Self.stopwords.contains(w) {
                if Self.overrideLookup(w) != nil || Self.curatedLookup(w) != nil { continue }
                lock.lock(); let known = cache[w] != nil; lock.unlock()
                if known { continue }
                let v = deepResolve(w)
                lock.lock(); cache[w] = .some(v); cacheDirty = true; lock.unlock()
            }
            saveDiskCache()
        }
    }

    /// Drops the ~40 MB embedding when no icon style is selected. Resolved words stay cached.
    func releaseDeepLayers() {
        queue.async { [self] in
            lock.lock(); embedding = nil; embeddingReady = false; lock.unlock()
        }
    }

    var diagnostics: String {
        lock.lock(); defer { lock.unlock() }
        return "glyphIndex ready=\(glyphIndexReady) terms=\(glyphIndex.count) · embedding ready=\(embeddingReady) loaded=\(embedding != nil) · cached=\(cache.count)"
    }

    /// Describes how the deep layers see a word (used by `--self-test`).
    func debugDeep(_ word: String) -> String {
        let token = Self.normalize(word)
        lock.lock(); let l2 = glyphIndex[token]; lock.unlock()
        var l3 = "n/a"
        if let e = embedding, e.contains(token) {
            l3 = e.neighbors(for: token, maximumCount: 3).map { "\($0.0)=\(String(format: "%.2f", $0.1))" }.joined(separator: ",")
        }
        return "\(token): lemma=\(Self.lemma(token)) L2=\(l2 ?? "–") L3=\(l3)"
    }

    // MARK: Normalisation

    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
        // contractions: you're → youre, i've → ive, she's → shes …
        t = t.replacingOccurrences(of: "'", with: "")
        return String(t.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) })
    }

    // MARK: Layer 1 — curated

    private static let existsLock = NSLock()
    nonisolated(unsafe) private static var existsCache: [String: Bool] = [:]

    /// Curated SF Symbols are verified against this OS once; emoji always pass.
    private static func exists(_ v: WordVisual) -> Bool {
        guard case .symbol(let name) = v else { return true }
        existsLock.lock(); defer { existsLock.unlock() }
        if let c = existsCache[name] { return c }
        let ok = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        existsCache[name] = ok
        return ok
    }

    private static func curatedLookup(_ token: String) -> WordVisual? { stemLookup(token, in: curated) }
    private static func overrideLookup(_ token: String) -> WordVisual? { stemLookup(token, in: overrides) }

    /// Exact match, then simple English suffix stripping ("driving" → "drive", "running" → "run").
    private static func stemLookup(_ token: String, in table: [String: WordVisual]) -> WordVisual? {
        if let v = table[token] { return v }
        for suffix in ["ing", "ed", "es", "s", "ly", "er"] where token.hasSuffix(suffix) && token.count > suffix.count + 2 {
            let stem = String(token.dropLast(suffix.count))
            if let v = table[stem] { return v }
            if let v = table[stem + "e"] { return v }
            if stem.count > 2, stem.last == stem.dropLast().last, let v = table[String(stem.dropLast())] { return v }
        }
        return nil
    }

    /// Direct overrides; checked before everything else.
    static let overrides: [String: WordVisual] = {
        var d: [String: WordVisual] = [:]
        func sym(_ words: String, _ s: String) { for w in words.split(separator: " ") { d[String(w)] = .symbol(s) } }
        sym("heart hearts", "heart.circle.fill")
        sym("broken", "heart.slash.fill")
        sym("world", "globe.americas.fill")
        sym("rain storm storms", "cloud.bolt.rain.fill")
        sym("sun hot", "thermometer.sun.fill")
        sym("swim swimming", "figure.pool.swim")
        sym("money cash", "dollarsign.circle.fill")
        sym("party", "party.popper.fill")
        sym("star", "star.circle.fill")
        sym("music song", "music.quarternote.3")
        sym("walk run", "figure.walk.motion")
        sym("light", "flashlight.on.fill")
        sym("car drive", "engine.combustion.fill")
        sym("fly plane", "airplane.departure")
        sym("time clock", "clock.arrow.circlepath")
        sym("smile", "face.smiling.fill")
        sym("talk say", "bubble.left.fill")
        sym("fire", "flame.fill")
        sym("moon", "moon.stars.fill")
        return d
    }()

    private static let curated: [String: WordVisual] = {
        var d: [String: WordVisual] = [:]
        func add(_ words: String, _ v: WordVisual) { for w in words.split(separator: " ") { d[String(w)] = v } }
        func sym(_ words: String, _ s: String) { add(words, .symbol(s)) }
        func emo(_ words: String, _ e: String) { add(words, .emoji(e)) }

        for (word, symbol) in HinglishLexicon.table { d[word] = .symbol(symbol) }
        // — SF Symbols —
        sym("love loves loved lover lovers heart hearts darling baby babe sweetheart romance valentine", "heart.fill")
        sym("broken break breaks pain hurt hurts hurting ache wound wounds scar scars heartbreak heartache", "bolt.heart.fill")
        sym("fire burn burns burning flame flames blaze inferno ignite lit hot heat", "flame.fill")
        sym("shine shining glow glowing universe galaxy cosmos magic magical sparkle sparkling glitter glittering stardust", "sparkles")
        sym("night midnight space dark darkness moonlight tonight evening", "moon.stars.fill")
        sym("dream dreams dreaming sleep sleeping sleepy slumber lullaby rest", "moon.zzz.fill")
        sym("thunder lightning storm storms electric electricity shock", "cloud.bolt.fill")
        sym("rain raining rainy drizzle tears cry crying", "cloud.rain.fill")
        sym("sun sunshine sunny summer daylight morning sunrise sunset", "sun.max.fill")
        sym("star stars superstar", "star.fill")
        sym("moon lunar", "moon.fill")
        sym("music song songs melody melodies tune sing singing sang rhythm", "music.note")
        sym("eye eyes see seen look looking watch watching vision stare gaze blind", "eye.fill")
        sym("ear listen listening hear hearing whisper whispers sound sounds", "ear.fill")
        sym("hand hands touch touching hold holding grab reach reaching", "hand.raised.fill")
        sym("run running runs walk walking walks dance dancing danced dancer", "figure.walk")
        sym("car cars drive driving drove ride riding highway road roads street streets", "car.fill")
        sym("plane airplane fly flying flew flight wings wing sky skies heaven", "airplane")
        sym("home house homes door doors inside", "house.fill")
        sym("key keys lock locked unlock secret secrets", "key.fill")
        sym("phone call calling telephone text message messages", "phone.fill")
        sym("time clock hour hours minute minutes forever late early wait waiting", "clock.fill")
        sym("water drop drops ocean sea tide wave waves river lake swim drown drowning blue", "drop.fill")
        sym("tree trees leaf leaves forest garden grow growing green nature spring", "leaf.fill")
        sym("snow winter cold ice frozen freeze freezing chill", "snowflake")
        sym("wind breeze breath breathe breathing blow blowing air", "wind")
        sym("world earth globe planet planets global", "globe")
        sym("light lights bright lamp lighthouse spotlight flash", "lightbulb.fill")
        sym("bolt power energy strong strength fast speed quick", "bolt.fill")
        sym("flag flags war battle fight fighting fights victory win winning winner champion", "flag.fill")
        sym("gift gifts present presents surprise", "gift.fill")
        sym("bell bells ring ringing alarm", "bell.fill")
        sym("camera photo photos picture pictures photograph snapshot memory memories", "camera.fill")
        sym("book books story stories page pages write writing wrote words letter letters poem", "book.fill")
        sym("mic microphone voice voices scream screaming shout shouting yell", "mic.fill")
        sym("headphones headphone", "headphones")
        sym("bed pillow", "bed.double.fill")
        sym("map lost found find finding where somewhere place places direction compass", "location.fill")
        sym("crown king queen royal throne princess prince", "crown")
        sym("warning danger dangerous careful risk alert trouble", "exclamationmark.triangle.fill")
        sym("smile smiling laugh laughing happy joy joyful fun glad", "face.smiling.fill")
        sym("lonely alone sad sadness sorrow misery blue cry lonesome empty", "cloud.fill")
        sym("gold golden money cash rich dollar dollars diamond diamonds jewel jewels", "dollarsign.circle.fill")
        sym("trophy medal prize glory fame famous", "trophy.fill")
        sym("anchor ship boat sail sailing captain", "sailboat.fill")
        sym("mountain mountains hill hills climb climbing top peak", "mountain.2.fill")
        sym("tornado hurricane cyclone chaos wild crazy insane madness", "tornado")
        sym("rainbow colors colours color colour", "rainbow")
        sym("paint painting art artist draw drawing canvas brush", "paintbrush.fill")
        sym("hammer build building construct work working", "hammer.fill")
        sym("scissors cut cutting cuts", "scissors")
        sym("pencil sign signed write wrote", "pencil")
        sym("link chain chains bound bind tied tie connect connection together", "link")
        sym("wifi signal network online connected", "wifi")
        sym("battery charge charged charging", "battery.100percent")
        sym("shield protect protection safe safety guard guardian armor", "shield.fill")
        sym("target aim aimed bullseye goal goals focus", "target")
        sym("infinity infinite endless eternity eternal", "infinity")
        sym("hourglass past yesterday history old ancient", "hourglass")
        sym("trash garbage waste throw thrown away", "trash.fill")
        sym("pin stuck stay stays staying", "pin.fill")
        sym("paperplane send sent sending", "paperplane.fill")
        sym("bag shopping buy bought store shop", "bag.fill")
        sym("tv television screen screens movie movies film cinema", "tv.fill")
        sym("gamecontroller game games play playing player", "gamecontroller.fill")
        sym("pawprint paw paws animal animals", "pawprint.fill")
        sym("hare rabbit bunny", "hare.fill")
        sym("tortoise turtle slow slowly", "tortoise.fill")
        sym("bird birds sparrow dove swallow", "bird.fill")
        sym("fish fishing", "fish.fill")
        sym("ant bug bugs insect", "ant.fill")
        sym("cloud clouds cloudy fog mist haze", "cloud.fill")
        sym("umbrella shelter cover", "umbrella.fill")
        sym("thermometer fever temperature", "thermometer.medium")
        sym("pills medicine pill drug drugs high medication", "pills.fill")
        sym("cross faith pray prayer prayers god lord angel angels church", "cross.fill")
        sym("lock secure tight", "lock.fill")
        sym("bolt.horizontal flash flashing blink", "bolt.horizontal.fill")
        sym("person someone somebody body man woman boy girl people everybody", "person.fill")
        sym("family mother father mama papa mom dad brother sister kids children", "figure.2.and.child.holdinghands")
        sym("couple lovers kiss kisses kissing", "heart.circle.fill")
        sym("face mask masks mirror", "theatermasks.fill")
        sym("drum drums beat beats bass boom", "speaker.wave.3.fill")
        sym("radio station frequency", "radio.fill")
        sym("guitar string strings strum", "guitars.fill")
        sym("piano keys keyboard", "pianokeys")
        sym("tag name names label", "tag.fill")
        sym("bookmark mark marked remember remembered", "bookmark.fill")
        sym("checkmark yes right correct truth true", "checkmark.circle.fill")
        sym("xmark no never wrong false lie lies liar lying", "xmark.circle.fill")
        sym("questionmark why question questions wonder wondering", "questionmark.circle.fill")
        sym("arrow up rise rising higher", "arrow.up.circle.fill")
        sym("down fall falling fell drop dropping lower", "arrow.down.circle.fill")
        sym("repeat again loop over circle circles round spin spinning", "arrow.triangle.2.circlepath")
        sym("back return returning rewind", "arrow.uturn.backward.circle.fill")
        sym("forward ahead onward future tomorrow", "forward.fill")
        sym("pause stop stopped halt freeze", "pause.circle.fill")
        sym("eyeglasses glasses sunglasses shades", "eyeglasses")
        sym("hat cap", "graduationcap.fill")
        sym("flashlight torch beam", "flashlight.on.fill")

        // — Emoji —
        emo("tequila shot shots margarita cocktail cocktails", "🍹")
        emo("whiskey whisky bourbon liquor vodka rum gin", "🥃")
        emo("beer beers pint pints brew", "🍺")
        emo("wine champagne cheers toast bubbly", "🍷")
        emo("coffee espresso latte caffeine", "☕️")
        emo("pizza slice", "🍕")
        emo("burger burgers hamburger fries", "🍔")
        emo("cake birthday cupcake dessert sweet sugar candy", "🍰")
        emo("apple apples", "🍎")
        emo("cherry cherries strawberry berry berries", "🍒")
        emo("peach peaches", "🍑")
        emo("banana bananas", "🍌")
        emo("lemon lemons lime lemonade", "🍋")
        emo("watermelon melon", "🍉")
        emo("cookie cookies", "🍪")
        emo("honey bee bees", "🍯")
        emo("disco discoball glitterball", "🪩")
        emo("party parties celebrate celebration confetti", "🎉")
        emo("rocket launch launching liftoff blast", "🚀")
        emo("skull skulls death dead die dying died deadly bones grave", "💀")
        emo("ghost ghosts haunted haunt haunting spirit spirits phantom", "👻")
        emo("dragon dragons", "🐉")
        emo("rose roses flower flowers petal petals bloom blooming bouquet", "🌹")
        emo("tulip daisy sunflower", "🌻")
        emo("butterfly butterflies", "🦋")
        emo("wolf wolves howl howling", "🐺")
        emo("lion lions roar roaring", "🦁")
        emo("tiger tigers", "🐯")
        emo("cat cats kitty kitten", "🐱")
        emo("dog dogs puppy", "🐶")
        emo("horse horses ride cowboy", "🐴")
        emo("snake snakes serpent venom poison", "🐍")
        emo("spider spiders web", "🕷️")
        emo("monkey monkeys", "🐒")
        emo("unicorn unicorns", "🦄")
        emo("eagle hawk falcon", "🦅")
        emo("shark sharks", "🦈")
        emo("whale whales", "🐋")
        emo("octopus", "🐙")
        emo("devil demon demons hell evil satan", "😈")
        emo("clown joker jester", "🤡")
        emo("alien aliens ufo", "👽")
        emo("robot robots machine machines", "🤖")
        emo("ring rings wedding marry married marriage engaged", "💍")
        emo("gun guns bullet bullets shoot shooting shot trigger", "🔫")
        emo("bomb bombs explode explosion explosive dynamite", "💣")
        emo("knife blade blades sword swords", "🗡️")
        emo("lipstick makeup", "💄")
        emo("heels shoes shoe sneakers boots", "👠")
        emo("dress gown", "👗")
        emo("jeans pants", "👖")
        emo("sunglasses cool", "😎")
        emo("beach palm island paradise tropical vacation holiday", "🏝️")
        emo("tent camp camping campfire bonfire", "🏕️")
        emo("city skyline downtown lights", "🌃")
        emo("bridge bridges", "🌉")
        emo("train trains railroad station subway", "🚆")
        emo("bike bicycle motorcycle motorbike", "🏍️")
        emo("police cop cops sirens siren", "🚨")
        emo("balloon balloons", "🎈")
        emo("guitarist", "🎸")
        emo("trumpet horn horns saxophone sax", "🎺")
        emo("microphone karaoke", "🎤")
        emo("popcorn", "🍿")
        emo("ice cream icecream", "🍦")
        emo("chocolate", "🍫")
        emo("pumpkin halloween", "🎃")
        emo("christmas xmas santa", "🎄")
        emo("fireworks firework", "🎆")
        emo("tears teardrop", "😢")
        emo("angry anger rage mad furious", "😡")
        emo("kiss kisses xoxo", "😘")
        emo("hug hugs embrace", "🤗")
        emo("shh quiet silence silent hush", "🤫")
        emo("brain mind think thinking thought thoughts mental", "🧠")
        emo("muscle muscles gym", "💪")
        emo("lucky luck clover fortune", "🍀")
        emo("dice gamble gambling casino bet", "🎲")
        emo("prayer hands please", "🙏")
        emo("hundred perfect", "💯")
        emo("vibe vibes vibin groove groovy", "✨")
        emo("swag drip bling", "💎")
        emo("handcuffs prison jail locked arrest", "⛓️")
        emo("mermaid siren", "🧜‍♀️")
        emo("witch spell spells curse cursed potion", "🧙")
        emo("vampire vampires blood bleed bleeding bite", "🧛")
        emo("zombie zombies", "🧟")
        emo("ninja samurai", "🥷")
        emo("pirate pirates treasure", "🏴‍☠️")
        emo("cowboy western", "🤠")
        emo("tokyo japan japanese", "🗼")
        emo("paris france eiffel", "🗼")
        emo("london england", "🎡")
        emo("newyork brooklyn manhattan", "🗽")
        emo("hollywood la california", "🌴")
        emo("vegas", "🎰")
        return d
    }()

    static let stopwords: Set<String> = [
        "the", "and", "but", "for", "nor", "yet", "with", "from", "that", "this", "these", "those", "then", "than",
        "when", "what", "where", "which", "while", "who", "whom", "whose", "why", "how", "are", "was", "were", "been",
        "being", "have", "has", "had", "having", "does", "did", "doing", "done", "will", "would", "could", "should",
        "shall", "might", "must", "can", "cant", "wont", "dont", "didnt", "isnt", "arent", "wasnt", "werent", "youre",
        "ive", "ill", "youll", "were", "theyre", "shes", "hes", "its", "thats", "theres", "heres", "whats", "lets",
        "your", "yours", "mine", "ours", "their", "theirs", "them", "they", "you", "she", "her", "him", "his", "its",
        "our", "out", "into", "onto", "upon", "over", "under", "about", "above", "below", "after", "before", "again",
        "just", "like", "even", "ever", "every", "some", "any", "all", "each", "both", "such", "only", "own", "same",
        "very", "much", "more", "most", "many", "too", "also", "here", "there", "now", "got", "get", "gets", "gonna",
        "wanna", "gotta", "cause", "till", "though", "through", "still", "aint", "ooh", "yeah", "hey", "uh", "oh",
        "baby",
    ]

    // MARK: Layers 2 & 3

    private func deepResolve(_ token: String) -> WordVisual? {
        if let v = shallowResolve(token) { return v }
        // Layer 3a — NLTagger lemma ("ran" → "run", "hearts" → "heart").
        let lemma = Self.lemma(token)
        if lemma != token, let v = shallowResolve(lemma) { return v }
        // Layer 3b — nearest neighbours in Apple's English word embedding, re-resolved through layers 0–2.
        lock.lock(); let e = embedding; lock.unlock()
        guard let e else { return nil }
        for candidate in [token, lemma] where e.contains(candidate) {
            // Apple's English embedding reports cosine distances of ~0.75–1.15; good matches sit below ~0.98.
            for (neighbor, distance) in e.neighbors(for: candidate, maximumCount: 10) where distance < 0.98 {
                let n = Self.normalize(neighbor)
                guard n.count >= 3, !Self.stopwords.contains(n) else { continue }
                if let v = shallowResolve(n) { return v }
            }
        }
        return nil
    }

    /// Layers 0–2 for one token.
    private func shallowResolve(_ token: String) -> WordVisual? {
        if let v = Self.overrideLookup(token), Self.exists(v) { return v }
        if let v = Self.curatedLookup(token), Self.exists(v) { return v }
        lock.lock(); let sym = glyphIndex[token] ?? glyphIndex[Self.singular(token)]; lock.unlock()
        if let sym, Self.exists(.symbol(sym)) { return .symbol(sym) }
        return nil
    }

    static func lemma(_ token: String) -> String {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = token
        let (tag, _) = tagger.tag(at: token.startIndex, unit: .word, scheme: .lemma)
        return tag.map { normalize($0.rawValue) }.flatMap { $0.isEmpty ? nil : $0 } ?? token
    }

    private static func singular(_ t: String) -> String {
        if t.hasSuffix("ies"), t.count > 4 { return String(t.dropLast(3)) + "y" }
        if t.hasSuffix("s"), !t.hasSuffix("ss"), t.count > 3 { return String(t.dropLast()) }
        return t
    }

    private func loadGlyphIndex() {
        let path = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/symbol_search.plist"
        var index: [String: (name: String, score: Int)] = [:]
        if let d = NSDictionary(contentsOfFile: path) as? [String: Any] {
            for (name, value) in d {
                guard let terms = value as? [String] else { continue }
                // Score: prefer filled, short, simple symbols.
                let dots = name.filter { $0 == "." }.count
                var score = dots * 10 + name.count
                if name.hasSuffix(".fill") { score -= 25 }
                if name.contains("circle") || name.contains("square") || name.contains("badge") || name.contains("slash") { score += 15 }
                for term in terms {
                    let t = term.lowercased()
                    guard !t.contains(" "), t.count >= 3 else { continue }
                    if let existing = index[t], existing.score <= score { continue }
                    index[t] = (name, score)
                }
            }
        }
        // Existence is checked lazily when a glyph is rasterized (the atlas skips unknown symbols); verifying
        // every term up front would instantiate thousands of SVG symbols and cost tens of megabytes.
        var verified: [String: String] = [:]
        for (term, v) in index { verified[term] = v.name }
        lock.lock(); glyphIndex = verified; glyphIndexReady = true; lock.unlock()
    }

    /// Queue only. The embedding costs ~40 MB, so it is loaded on demand and released with the icon styles.
    private func loadEmbedding() {
        lock.lock(); let ready = embeddingReady; lock.unlock()
        guard !ready else { return }
        let e = NLEmbedding.wordEmbedding(for: .english)
        lock.lock(); embedding = e; embeddingReady = true; lock.unlock()
    }

    // MARK: Disk cache

    private struct DiskCache: Codable {
        var version = 2
        var hits: [String: WordVisual] = [:]
        var misses: [String] = []
    }

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("EdgeGlow", isDirectory: true)
            .appendingPathComponent("WordVisuals.json")
    }

    private func loadDiskCache() {
        guard let url = Self.cacheURL, let data = try? Data(contentsOf: url),
              let disk = try? JSONDecoder().decode(DiskCache.self, from: data), disk.version == DiskCache().version else { return }
        lock.lock()
        for (k, v) in disk.hits where cache[k] == nil { cache[k] = .some(v) }
        for k in disk.misses where cache[k] == nil { cache[k] = .some(nil) }
        lock.unlock()
    }

    private func saveDiskCache() {
        lock.lock()
        guard cacheDirty else { lock.unlock(); return }
        cacheDirty = false
        var disk = DiskCache()
        for (k, v) in cache {
            if let v = v { disk.hits[k] = v } else { disk.misses.append(k) }
        }
        lock.unlock()
        guard let url = Self.cacheURL, let data = try? JSONEncoder().encode(disk) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
