//! Lightweight English lemmatization: candidate base forms for an inflected word.
//! Candidates are only suggestions; callers keep those that exist in an index.

const IRREGULAR: &[(&str, &str)] = &[
    ("am", "be"), ("is", "be"), ("are", "be"), ("was", "be"), ("were", "be"), ("been", "be"), ("being", "be"),
    ("has", "have"), ("had", "have"), ("having", "have"), ("does", "do"), ("did", "do"), ("done", "do"),
    ("went", "go"), ("gone", "go"), ("goes", "go"), ("ran", "run"), ("made", "make"), ("said", "say"),
    ("took", "take"), ("taken", "take"), ("came", "come"), ("saw", "see"), ("seen", "see"), ("knew", "know"),
    ("known", "know"), ("got", "get"), ("gotten", "get"), ("gave", "give"), ("given", "give"), ("found", "find"),
    ("thought", "think"), ("told", "tell"), ("became", "become"), ("left", "leave"), ("felt", "feel"),
    ("brought", "bring"), ("began", "begin"), ("begun", "begin"), ("kept", "keep"), ("held", "hold"),
    ("wrote", "write"), ("written", "write"), ("stood", "stand"), ("heard", "hear"), ("meant", "mean"),
    ("met", "meet"), ("paid", "pay"), ("sat", "sit"), ("spoke", "speak"), ("spoken", "speak"), ("led", "lead"),
    ("grew", "grow"), ("grown", "grow"), ("lost", "lose"), ("fell", "fall"), ("fallen", "fall"), ("sent", "send"),
    ("built", "build"), ("understood", "understand"), ("drew", "draw"), ("drawn", "draw"), ("broke", "break"),
    ("broken", "break"), ("spent", "spend"), ("rose", "rise"), ("risen", "rise"), ("drove", "drive"),
    ("driven", "drive"), ("bought", "buy"), ("wore", "wear"), ("worn", "wear"), ("chose", "choose"),
    ("chosen", "choose"), ("sought", "seek"), ("threw", "throw"), ("thrown", "throw"), ("caught", "catch"),
    ("dealt", "deal"), ("won", "win"), ("fought", "fight"), ("taught", "teach"), ("ate", "eat"), ("eaten", "eat"),
    ("sang", "sing"), ("sung", "sing"), ("swam", "swim"), ("swum", "swim"), ("flew", "fly"), ("flown", "fly"),
    ("forgot", "forget"), ("forgotten", "forget"), ("slept", "sleep"), ("sold", "sell"), ("hid", "hide"),
    ("hidden", "hide"), ("rode", "ride"), ("ridden", "ride"), ("shook", "shake"), ("shaken", "shake"),
    ("stole", "steal"), ("stolen", "steal"), ("woke", "wake"), ("woken", "wake"), ("froze", "freeze"),
    ("frozen", "freeze"), ("bitten", "bite"), ("blew", "blow"), ("blown", "blow"), ("dug", "dig"), ("fed", "feed"),
    ("fled", "flee"), ("flung", "fling"), ("forgave", "forgive"), ("forgiven", "forgive"), ("hung", "hang"),
    ("laid", "lay"), ("lain", "lie"), ("lit", "light"), ("rang", "ring"), ("rung", "ring"), ("shot", "shoot"),
    ("shone", "shine"), ("slid", "slide"), ("spun", "spin"), ("sprang", "spring"), ("sprung", "spring"),
    ("stuck", "stick"), ("stung", "sting"), ("struck", "strike"), ("swore", "swear"), ("sworn", "swear"),
    ("swept", "sweep"), ("swung", "swing"), ("tore", "tear"), ("torn", "tear"), ("wept", "weep"),
    ("wound", "wind"), ("bent", "bend"), ("bled", "bleed"), ("bred", "breed"), ("clung", "cling"),
    ("crept", "creep"), ("dove", "dive"), ("drank", "drink"), ("drunk", "drink"), ("fit", "fit"),
    ("ground", "grind"), ("knelt", "kneel"), ("leapt", "leap"), ("lent", "lend"), ("overcame", "overcome"),
    ("sank", "sink"), ("sunk", "sink"), ("slung", "sling"), ("strode", "stride"), ("strove", "strive"),
    ("striven", "strive"), ("thrived", "thrive"), ("trod", "tread"), ("trodden", "tread"), ("wove", "weave"),
    ("woven", "weave"), ("wrung", "wring"), ("sped", "speed"), ("spat", "spit"), ("arose", "arise"),
    ("arisen", "arise"), ("awoke", "awake"), ("awoken", "awake"), ("bore", "bear"), ("borne", "bear"),
    ("forbade", "forbid"), ("forbidden", "forbid"), ("mistook", "mistake"), ("mistaken", "mistake"),
    ("undertook", "undertake"), ("withdrew", "withdraw"), ("withdrawn", "withdraw"),
    ("better", "good"), ("best", "good"), ("worse", "bad"), ("worst", "bad"), ("further", "far"),
    ("farther", "far"), ("less", "little"), ("least", "little"), ("more", "much"), ("most", "much"),
    ("men", "man"), ("women", "woman"), ("children", "child"), ("feet", "foot"), ("teeth", "tooth"),
    ("geese", "goose"), ("mice", "mouse"), ("lice", "louse"), ("people", "person"), ("oxen", "ox"),
    ("lives", "life"), ("knives", "knife"), ("wives", "wife"), ("leaves", "leaf"), ("halves", "half"),
    ("selves", "self"), ("wolves", "wolf"), ("loaves", "loaf"), ("thieves", "thief"), ("shelves", "shelf"),
    ("calves", "calf"), ("data", "datum"), ("criteria", "criterion"), ("phenomena", "phenomenon"),
    ("analyses", "analysis"), ("crises", "crisis"), ("theses", "thesis"), ("hypotheses", "hypothesis"),
    ("indices", "index"), ("matrices", "matrix"), ("vertices", "vertex"), ("cacti", "cactus"),
    ("fungi", "fungus"), ("nuclei", "nucleus"), ("radii", "radius"), ("stimuli", "stimulus"),
    ("alumni", "alumnus"), ("bacteria", "bacterium"), ("media", "medium"), ("curricula", "curriculum"),
    ("dice", "die"), ("them", "they"), ("us", "we"), ("me", "i"), ("him", "he"), ("her", "she"),
];

fn is_vowel(c: u8) -> bool {
    matches!(c, b'a' | b'e' | b'i' | b'o' | b'u')
}

/// Base-form candidates, most likely first. Never includes `word` itself.
pub fn english_lemmas(word: &str) -> Vec<String> {
    let w = word.trim().to_lowercase();
    let mut out: Vec<String> = Vec::new();
    let push = |s: String, out: &mut Vec<String>| {
        if s.len() >= 2 && s != w && !out.contains(&s) {
            out.push(s);
        }
    };
    if w.len() < 3 || !w.bytes().all(|c| c.is_ascii_lowercase() || c == b'\'' || c == b'-') {
        if let Some(base) = w.strip_suffix("'s") {
            push(base.to_string(), &mut out);
        }
        return out;
    }
    for (f, b) in IRREGULAR {
        if *f == w {
            push(b.to_string(), &mut out);
        }
    }
    let b = w.as_bytes();
    let n = b.len();
    let strip = |k: usize| w[..n - k].to_string();
    let doubled = |stem: &str| -> Option<String> {
        let s = stem.as_bytes();
        let m = s.len();
        (m >= 3 && s[m - 1] == s[m - 2] && !is_vowel(s[m - 1]) && !matches!(s[m - 1], b's' | b'l' | b'z' | b'f'))
            .then(|| stem[..m - 1].to_string())
    };
    if let Some(base) = w.strip_suffix("'s") {
        push(base.to_string(), &mut out);
    }
    if w.ends_with("ies") && n > 4 {
        push(format!("{}y", strip(3)), &mut out);
    }
    if w.ends_with("ves") && n > 4 {
        push(format!("{}f", strip(3)), &mut out);
        push(format!("{}fe", strip(3)), &mut out);
    }
    if w.ends_with("es") && n > 3 {
        let stem = strip(2);
        if stem.ends_with("s") || stem.ends_with("x") || stem.ends_with("z") || stem.ends_with("ch") || stem.ends_with("sh") || stem.ends_with('o') {
            push(stem.clone(), &mut out);
        }
        push(strip(1), &mut out);
        push(stem, &mut out);
    } else if w.ends_with('s') && !w.ends_with("ss") && !w.ends_with("us") && !w.ends_with("is") {
        push(strip(1), &mut out);
    }
    if w.ends_with("ied") && n > 4 {
        push(format!("{}y", strip(3)), &mut out);
    }
    if w.ends_with("ed") && n > 3 {
        let stem = strip(2);
        if let Some(d) = doubled(&stem) {
            push(d, &mut out);
        }
        push(strip(1), &mut out); // baked -> bake
        push(stem, &mut out); // walked -> walk
    }
    if w.ends_with("ying") && n >= 5 {
        push(format!("{}ie", strip(4)), &mut out);
    }
    if w.ends_with("ing") && n > 4 {
        let stem = strip(3);
        if let Some(d) = doubled(&stem) {
            push(d, &mut out);
        }
        push(stem.clone(), &mut out);
        push(format!("{stem}e"), &mut out);
    }
    for (suf, k) in [("iest", 4usize), ("ier", 3)] {
        if w.ends_with(suf) && n > k + 1 {
            push(format!("{}y", strip(k)), &mut out);
        }
    }
    for (suf, k) in [("est", 3usize), ("er", 2)] {
        if w.ends_with(suf) && n > k + 2 {
            let stem = strip(k);
            if let Some(d) = doubled(&stem) {
                push(d, &mut out);
            }
            push(stem.clone(), &mut out);
            push(format!("{stem}e"), &mut out);
        }
    }
    if w.ends_with("ily") && n > 4 {
        push(format!("{}y", strip(3)), &mut out);
    }
    if w.ends_with("ly") && n > 4 {
        push(strip(2), &mut out);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn lemmas() {
        assert!(english_lemmas("running").contains(&"run".to_string()));
        assert!(english_lemmas("making").contains(&"make".to_string()));
        assert!(english_lemmas("cats").contains(&"cat".to_string()));
        assert!(english_lemmas("boxes").contains(&"box".to_string()));
        assert!(english_lemmas("studies").contains(&"study".to_string()));
        assert!(english_lemmas("stopped").contains(&"stop".to_string()));
        assert!(english_lemmas("baked").contains(&"bake".to_string()));
        assert!(english_lemmas("bigger").contains(&"big".to_string()));
        assert!(english_lemmas("happily").contains(&"happy".to_string()));
        assert_eq!(english_lemmas("ran")[0], "run");
        assert_eq!(english_lemmas("children")[0], "child");
        assert!(english_lemmas("lying").contains(&"lie".to_string()));
        assert!(english_lemmas("dog's").contains(&"dog".to_string()));
        assert!(!english_lemmas("glass").contains(&"glas".to_string()));
    }
}
