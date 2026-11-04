import Foundation

/// What a word *does*, physically, when it is sung.
enum Archetype: String {
    case velocity   // cars, flight, speed
    case impact     // crashes, thunder, destruction
    case fire       // heat, light, energy
    case heart      // emotion, pulse
    case tears      // sadness, rain (emotion sub-type with falling droplets)
    case cosmic     // sky, stars, elevation
    case vibe       // sound, frequency, shaking
    case none
}

/// The expanded semantic kinetic dictionary (1,000+ words). Inflections are folded onto these base forms
/// with NLTagger lemmatization, so "driving", "drove" and "drives" all find `drive`.
enum SemanticLexicon {
    private static func set(_ text: String) -> Set<String> { Set(text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)) }

    static let velocity = set("""
    car cars drive drove driven driver driving fast faster fastest run runner running ran runs fly flew flown flying flight flights jet jets speed speeding sped speeds race racing raced racer races ride rider riding rode rides
    rush rushing rushed dash dashing dashed sprint sprinting sprinted chase chasing chased hurry hurried hurrying zoom zooming zoomed rocket rockets engine engines motor motors motorcycle motorbike bike bikes bicycle highway highways
    road roads street streets freeway interstate turbo nitro gas gasoline fuel throttle accelerate accelerating acceleration accelerator gear gears wheel wheels tire tires brake brakes braking steer steering cruise cruising cruiser
    truck trucks van bus buses taxi cab train trains tram metro subway plane planes airplane airplanes aircraft airline airport runway fleeing flee fled escape escaping escaped runaway getaway swift swiftly quick quickly rapid rapidly
    velocity vroom skid skidding skidded drift drifting drifted burnout roll rolling rolled rolls leave leaving launch launched launching blast blasting blasted bolt bolting flash flashing flashed gallop galloping horse horses stallion
    mustang ferrari lambo lamborghini porsche corvette cadillac chevy ford jeep convertible coupe sedan limo limousine ambulance siren sirens chauffeur passenger passengers traveling travelling travel traveled journey journeys trip
    trips voyage cruising wander wandering roam roaming roamed rover rovers tour touring torpedo missile missiles bullet bullets arrow arrows dart darting darted streak streaking streaked blur blurry whirl whirling whirlwind spin
    spinning spun twirl twirling rev revving revved ignite ignition starter pedal pedals gearshift clutch piston pistons exhaust tailpipe muffler headlights taillights headlight dashboard windshield backseat passenger steering
    chauffeur cab cabs uber lyft garage pit pitstop grandprix formula racetrack track tracks circuit lap laps lapping finish finishline checkered flag flags marathon sprinter athlete skate skating skated skateboard surf surfing
    ski skiing sled sledding sail sailing sailed sailor ship ships boat boats yacht canoe kayak raft ferry steamer steamship locomotive railroad railway rails rail caboose conductor depart departing departure arrive arriving
    arrival transit commute commuting commuter cruising windshield mph kilometers miles mile hour hours speedometer odometer burn rubber rubberneck overtake overtaking pass passing passed lane lanes merge merging detour shortcut
    gone going went away outrun outrunning outran outracing outpace sweep sweeping swept soar soaring soared glide gliding glided swoop swooping swooped
    """)

    static let impact = set("""
    crash crashes crashed crashing break breaks broke broken breaking breakdown breakthrough hit hits hitting punch punches punched punching fall falls fell fallen falling drop drops dropped dropping boom booms boomed shatter
    shatters shattered shattering slam slams slammed slamming thunder thunders thundered thundering collide collides collided collision wreck wrecked wrecking smash smashes smashed smashing crush crushes crushed crushing explode
    explodes exploded exploding explosion explosions blast blasts bomb bombs bombed grenade bang bangs banged banging knock knocks knocked knocking strike strikes struck striking stab stabbed stabbing shoot shoots shot shooting
    gun guns gunshot trigger triggers fire-arm rifle pistol shell shells riot riots war wars warfare battle battles fight fights fought fighting kill kills killed killing murder murdered die dies died dying dead death deadly
    destroy destroys destroyed destruction demolish demolished ruin ruins ruined ruining wreckage rubble debris collapse collapses collapsed collapsing crumble crumbles crumbled tear tore torn rip rips ripped ripping split splits
    splitting crack cracks cracked cracking fracture fractured burst bursts bursting pop pops popped snap snaps snapped snapping thud thump thumped wham whack whacked bash bashed bashing pound pounds pounded pounding hammer hammers
    hammered anvil quake earthquake tremor avalanche landslide tsunami tornado hurricane storm storms stormy lightning bolt thunderstorm thunderclap clash clashes clashed clap claps clapped fury furious rage raging rage violent
    violence brutal brutality savage attack attacks attacked assault ambush invade invasion conquer conquered bullet impact impacts impacted jolt jolts jolted shock shocks shocked shocking blow blows blew blown knockout nokout
    sledgehammer wrecking ball cannon cannons artillery detonate detonated detonation dynamite tnt fuse blown shrapnel scar scars scarred wound wounds wounded bruise bruised bleed bleeding blood-shed bloodshed slaughter fall-down
    tumble tumbles tumbled tumbling plunge plunges plunged plunging plummet plummeted nosedive topple toppled toppling stumble stumbled trip tripped slip slipped slipping slide slides slid sliding skid crashing sink sinks sank
    sunk sinking drown drowned drowning flood flooded flooding thrown throw throws threw throwing hurl hurled fling flung slap slapped slapping kick kicks kicked kicking stomp stomped stomping trample trampled
    """)

    static let fire = set("""
    fire fires fired burn burns burned burnt burning flame flames flaming flamed sun suns sunny sunshine sunlight sunrise sunset hot hotter hottest heat heated heating warm warmth warmer light lights lit lighting lighted lighter
    spark sparks sparked sparkle sparkles sparkling sparkled gold golden shine shines shone shining shiny glow glows glowed glowing glowy blaze blazes blazed blazing inferno ember embers ash ashes smoke smoking smoked smoky
    candle candles torch torches lantern flare flares flared flaring flash flashes flashing blinding bright brighter brightest brightness radiant radiance beam beams beaming ray rays dawn daylight golden glitter glittering
    glitters glittered shimmer shimmering shimmered gleam gleaming gleamed lava volcano volcanic magma molten melt melts melted melting scorch scorched scorching sizzle sizzling sear seared ignite ignited ignites ignition
    kindle kindled bonfire campfire fireplace fireworks firework firecracker flint match matches lighter wildfire fireball fireman firefighter phoenix dragon dragons energy energetic electric electricity electrify voltage
    current power powerful powered plasma neon laser lasers radiate radiating radiation solar star-fire amber orange scarlet crimson ruby rust copper bronze brass fever feverish passion passionate burning desire desires lust
    inflame inflamed fierce fiercely blistering boil boiling boiled steam steaming scald scalding warm-hearted tropical summer summers desert sahara sweat sweating sweltering torrid thermal heatwave oven stove furnace forge forged
    forging blacksmith anvil sparkler incandescent luminous luminescent lumen brilliance brilliant dazzle dazzling dazzled illuminate illuminated illumination lamp lamps bulb bulbs spotlight spotlights limelight headlight
    sunbeam sunburn sunburnt sunflower sunkissed daydream golden-hour twilight dusk
    """)

    static let heart = set("""
    heart hearts heartbeat heartbeats heartbroken heartbreak heartache heartfelt hearted love loves loved loving lover lovers beloved lovely blood bloody bleeding feel feels felt feeling feelings alive live lives lived living life
    lifetime pain pains painful hurt hurts hurting ache aching aches soul souls spirit spirits cry cries cried crying tears tear weep weeping wept sob sobbing sobbed rain raining rained rainy raindrop raindrops drizzle drizzling
    sorrow sorrows sad sadness sadly grief grieve grieving mourn mourning miss missing missed lonely loneliness alone lonesome longing long longed yearn yearning desire desires crave craving need needs needed want wants wanted
    kiss kisses kissed kissing hug hugs hugged embrace embraced embracing touch touches touched touching hold holds held holding cherish cherished adore adored adoring darling darlin baby babe honey sweetheart sweet sweetest
    dear angel angels devotion devoted faith faithful trust trusted trusting forgive forgiven forgiveness mercy grace gentle gently tender tenderness warmth passion passionate romance romantic romantically affection
    affectionate fond fondness attach attached bond bonded bonds marry married marriage wedding bride groom vow vows promise promises promised forever eternal eternity breathe breathing breath breathless gasp gasping pulse pulses
    pulsing throb throbbing throbbed beat beating beats vein veins artery rib ribs chest bosom emotion emotions emotional feelings tremble trembling trembled shiver shivering shivered quiver quivering goosebumps ecstasy bliss
    blissful joy joyful happy happiness cheer cheerful smile smiles smiled smiling laugh laughs laughed laughing giggle tender sentimental nostalgia nostalgic memory memories remember remembered remembering forget forgotten regret
    regrets regretted guilt guilty shame ashamed sorry apology apologize broken-hearted break-up breakup goodbye farewell tearful teardrop teardrops puddle puddles umbrella storm-cloud weeping willow melancholy blue blues bluesy
    gloom gloomy depress depressed depression despair despairing hopeless hope hopes hoped hopeful dream-love humble humbled vulnerable raw naked bare open opened exposed confess confessed confession whisper whispers whispered
    whispering secret secrets
    """)

    static let tearsWords = set("cry cries cried crying tears tear weep weeping wept sob sobbing sobbed rain raining rained rainy raindrop raindrops drizzle drizzling teardrop teardrops puddle puddles drip dripping dripped drop-by sorrow tearful umbrella")

    static let cosmic = set("""
    star stars starry starlight stardust starlit sky skies moon moons moonlight moonlit moonshine space spaces spaceship astronaut cosmos cosmic universe universal galaxy galaxies milky nebula planet planets orbit orbiting orbited
    comet comets meteor meteors asteroid eclipse constellation constellations horizon heavens heaven heavenly high higher highest float floats floated floating drift drifts drifted drifting dream dreams dreamed dreaming dreamer
    dreamy night nights nightfall midnight tonight evening dusk twilight dawn aurora cloud clouds cloudy fog foggy mist misty haze hazy fly-away wings wing winged feather feathers angel-wings above beyond infinite infinity endless
    eternal ether ethereal celestial divine sacred holy paradise utopia eden zenith summit peak mountain mountains mountaintop alps everest cliff cliffs hill hills ascend ascending ascended rise rises rose risen rising lift lifts
    lifted lifting up upward upwards elevate elevated elevator tower towers skyscraper skyline rooftop rooftops balloon balloons kite kites bird birds eagle eagles hawk falcon dove swallow sparrow butterfly butterflies fairy
    fairies magic magical magician wizard spell enchant enchanted mystic mystical mystery mysterious wonder wonders wonderful wander wandering wanderer lunar solar zodiac horoscope destiny fate fortune cosmos nova supernova
    pulsar quasar void abyss depth depths deep deeper ocean oceans sea seas wave-sky tide tides weightless gravity zero-g stratosphere atmosphere orbit rocket-ship satellite satellites telescope observatory sleep sleeping slept
    sleepy slumber lullaby lullabies pillow pillows blanket blankets bed beds bedroom insomnia insomniac moonbeam moonbeams sunless shadow shadows shade shades silhouette silhouettes darkness dark darker darkest black blackout
    """)

    static let vibe = set("""
    bass bassline beat beats beating loud louder loudest loudly scream screams screamed screaming shout shouts shouted shouting yell yells yelled yelling roar roars roared roaring howl howls howled howling shake shakes shook shaken
    shaking wave waves waved waving echo echoes echoed echoing sound sounds sounded noise noises noisy music melody melodies rhythm rhythms rhythmic tempo drum drums drummer drumming guitar guitars guitarist piano keys violin
    cello trumpet saxophone sax horn horns harmony harmonies chord chords note notes song songs sing sings sang sung singing singer vocal vocals voice voices volume amplify amplified amplifier speaker speakers subwoofer woofer
    tweeter stereo mono radio frequency frequencies hertz vibrate vibrates vibrated vibrating vibration vibrations vibe vibes tremor tremble rattle rattles rattled rattling rumble rumbles rumbled rumbling boomerang resonate
    resonates resonance reverb reverberate static feedback distortion distorted distort glitch glitchy glitches buzz buzzing buzzed hum hums hummed humming whistle whistles whistled whistling ring rings rang ringing bell bells
    chime chimes chiming toll tolls tolled siren alarm alarms alarmed party parties dance dances danced dancing dancer disco club clubs clubbing rave raves raving festival concert concerts stage stages crowd crowds mosh pit
    jump jumps jumped jumping bounce bounces bounced bouncing pump pumps pumped pumping groove grooves grooving funk funky jazz rock roll rocking rocker punk metal rap hiphop techno house trance dubstep synth synthesizer sample
    samples sampling loop loops looping drop-the-bass pulse pulses throb throbbing thump thumping pound pounding hammering clap clapping applause cheer cheers cheering chant chants chanting
    """)

    static let all: [(Archetype, Set<String>)] = [
        (.impact, impact), (.velocity, velocity), (.fire, fire), (.tears, tearsWords), (.heart, heart), (.cosmic, cosmic), (.vibe, vibe),
    ]

    static var wordCount: Int { Set(all.flatMap(\.1)).count }

    /// SF Symbol for specific words (checked first), then the archetype default.
    static let glyphs: [String: String] = [
        "car": "car.side.fill", "cars": "car.side.fill", "drive": "car.fill", "driving": "car.fill", "ride": "car.fill", "taxi": "car.fill",
        "truck": "box.truck.fill", "bus": "bus.fill", "train": "tram.fill", "tram": "tram.fill", "subway": "tram.fill", "bike": "bicycle", "bicycle": "bicycle",
        "plane": "airplane", "airplane": "airplane", "jet": "airplane", "fly": "airplane", "flight": "airplane", "rocket": "paperplane.fill", "ship": "ferry.fill", "boat": "sailboat.fill",
        "fast": "hare.fill", "speed": "gauge.with.dots.needle.67percent", "race": "flag.checkered", "run": "figure.run", "running": "figure.run", "sprint": "figure.run", "horse": "hare.fill",
        "crash": "burst.fill", "boom": "burst.fill", "bomb": "burst.fill", "explode": "burst.fill", "explosion": "burst.fill", "shatter": "burst.fill", "thunder": "cloud.bolt.fill", "lightning": "bolt.fill", "storm": "cloud.bolt.rain.fill",
        "bolt": "bolt.fill", "hit": "hand.raised.fill", "punch": "hand.raised.fill", "break": "bolt.slash.fill", "broken": "bolt.slash.fill", "fall": "arrow.down.circle.fill", "drop": "arrow.down.circle.fill", "slam": "burst.fill",
        "fire": "flame.fill", "flame": "flame.fill", "burn": "flame.fill", "burning": "flame.fill", "hot": "thermometer.sun.fill", "sun": "sun.max.fill", "sunshine": "sun.max.fill", "light": "lightbulb.fill", "spark": "sparkles",
        "sparkle": "sparkles", "gold": "crown.fill", "golden": "crown.fill", "shine": "sparkles", "glow": "sun.max.fill", "candle": "flame.fill", "lava": "flame.fill",
        "heart": "heart.fill", "love": "heart.fill", "blood": "drop.fill", "feel": "heart.text.square.fill", "alive": "waveform.path.ecg", "pulse": "waveform.path.ecg", "heartbeat": "waveform.path.ecg", "pain": "heart.slash.fill", "soul": "sparkle",
        "kiss": "heart.fill", "cry": "drop.fill", "tears": "drop.fill", "tear": "drop.fill", "rain": "cloud.rain.fill", "umbrella": "umbrella.fill",
        "star": "star.fill", "stars": "star.fill", "sky": "cloud.sun.fill", "moon": "moon.stars.fill", "space": "moon.stars.fill", "high": "arrow.up.circle.fill", "float": "balloon.fill", "dream": "moon.zzz.fill", "heaven": "cloud.fill",
        "night": "moon.stars.fill", "cloud": "cloud.fill", "angel": "sparkles", "wings": "bird.fill", "bird": "bird.fill", "mountain": "mountain.2.fill", "ocean": "water.waves", "sea": "water.waves", "wave": "water.waves", "planet": "globe.americas.fill",
        "bass": "waveform", "beat": "waveform", "loud": "speaker.wave.3.fill", "scream": "speaker.wave.3.fill", "shake": "iphone.radiowaves.left.and.right", "echo": "dot.radiowaves.left.and.right", "sound": "speaker.wave.2.fill",
        "music": "music.note", "song": "music.note", "sing": "music.mic", "dance": "figure.dance", "drum": "waveform", "guitar": "guitars.fill", "piano": "pianokeys", "bell": "bell.fill", "party": "party.popper.fill",
    ]

    static let defaultGlyph: [Archetype: String] = [
        .velocity: "car.side.fill", .impact: "burst.fill", .fire: "flame.fill", .heart: "heart.fill", .tears: "drop.fill", .cosmic: "star.fill", .vibe: "waveform",
    ]
}
