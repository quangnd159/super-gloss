//! `sgloss` — command-line harness for the Super Gloss core.
//!
//!   sgloss [--cache DIR] index  <roots…>
//!   sgloss [--cache DIR] list   <roots…>
//!   sgloss [--cache DIR] suggest <query> <roots…>
//!   sgloss [--cache DIR] lookup <word> <roots…>        (prints article HTML)
//!   sgloss [--cache DIR] link   <target> <roots…>      (resolves an entry:// target in each dictionary)
//!   sgloss [--cache DIR] bench  <roots…>
//!   sgloss [--cache DIR] verify <roots…>               (renders a sample of every dictionary)
//!   sgloss [--cache DIR] random <roots…>               (N random words, N=40 by default)
//!   sgloss [--cache DIR] sample <roots…>               (N headwords spread through each dictionary, N=3)

use std::time::Instant;
use supergloss::library::{Config, Library};

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mut cache = std::env::temp_dir().join("supergloss-cli-cache");
    if args.first().map(|s| s == "--cache").unwrap_or(false) {
        cache = args[1].clone().into();
        args.drain(0..2);
    }
    let cmd = args.first().cloned().unwrap_or_default();
    let (arg, roots) = match cmd.as_str() {
        "suggest" | "lookup" | "link" | "serve" | "audio" => (args.get(1).cloned().unwrap_or_default(), args[2.min(args.len())..].to_vec()),
        _ => (String::new(), args[1.min(args.len())..].to_vec()),
    };
    let lib = Library::new(cache);
    let t = Instant::now();
    lib.configure(&Config { roots, ..Default::default() });
    lib.wait_idle();
    let ready = t.elapsed();
    match cmd.as_str() {
        "index" | "list" => {
            for d in lib.summaries() {
                println!(
                    "{:9} {:8} {:>8} {}  [{}]{}",
                    d.state,
                    d.format,
                    d.entries,
                    d.name,
                    d.id,
                    d.error.map(|e| format!("  ERROR: {e}")).unwrap_or_default()
                );
            }
            eprintln!("ready in {ready:?}");
        }
        "suggest" => {
            let t = Instant::now();
            let s = lib.suggest(&arg, 30);
            let el = t.elapsed();
            for x in s {
                println!("{:7} {:2} {}", x.kind, x.sources, x.word);
            }
            eprintln!("suggest in {el:?}");
        }
        "lookup" => {
            let t = Instant::now();
            let r = lib.lookup(&arg);
            eprintln!("lookup in {:?}; via={:?}", t.elapsed(), r.via);
            for h in r.hits {
                let t = Instant::now();
                let page = lib.article_page(&h.dict, &h.entries).unwrap();
                println!("===== {} ({} entries: {:?}) rendered in {:?}", h.name, h.entries.len(), h.words, t.elapsed());
                println!("{page}");
            }
        }
        "link" => {
            for d in lib.summaries() {
                println!("{:?}  [{}]", lib.resolve_link(&d.id, &arg), d.name);
            }
        }
        "bench" => {
            let queries = ["a", "ab", "aba", "run", "beauti", "xylo", "serendipity", "qzx", "đi", "ăn", "colour", "recieve", "a*le", "th?nk"];
            let t = Instant::now();
            let mut n = 0;
            for _ in 0..50 {
                for q in queries {
                    n += lib.suggest(q, 50).len();
                }
            }
            eprintln!("suggest: {:?}/query ({n} results)", t.elapsed() / (50 * queries.len() as u32));
            let t = Instant::now();
            for q in ["run", "set", "beautiful", "apple", "go"] {
                let r = lib.lookup(q);
                for h in r.hits {
                    lib.article_page(&h.dict, &h.entries).unwrap();
                }
            }
            eprintln!("lookup+render 5 words across all dictionaries: {:?}", t.elapsed());
        }
        "random" => {
            let n: usize = std::env::var("N").ok().and_then(|v| v.parse().ok()).unwrap_or(40);
            let t = Instant::now();
            lib.random_pick();
            eprintln!("first (calibrates) in {:?}", t.elapsed());
            let t = Instant::now();
            let picks: Vec<(String, u32)> = (0..n).filter_map(|_| lib.random_pick()).collect();
            eprintln!("{} words in {:?}", picks.len(), t.elapsed());
            for (w, k) in picks {
                println!("{k:3}  {w}");
            }
        }
        "sample" => {
            let n: usize = std::env::var("N").ok().and_then(|v| v.parse().ok()).unwrap_or(3);
            let mut seen = std::collections::HashSet::new();
            for d in lib.summaries() {
                let Some(l) = lib.dict(&d.id).and_then(|d| d.loaded()) else { continue };
                let len = l.index.len();
                for k in 0..n.min(len) {
                    if let Some((w, _)) = l.index.entry(k * len / n.min(len) + len / (2 * n.min(len))) {
                        if seen.insert(w.to_string()) {
                            println!("{w}");
                        }
                    }
                }
            }
        }
        "verify" => verify(&lib),
        "audio" => {
            let (id, path) = arg.split_once('/').unwrap_or((&arg, ""));
            let t = Instant::now();
            match lib.audio(id, path) {
                Ok(Some(b)) => {
                    eprintln!("{} bytes in {:?}", b.len(), t.elapsed());
                    use std::io::Write;
                    let _ = std::io::stdout().write_all(&b);
                }
                other => eprintln!("no audio: {other:?}"),
            }
        }
        "serve" => match lib.serve(&arg) {
            Ok((b, mime)) => {
                eprintln!("{mime}, {} bytes", b.len());
                use std::io::Write;
                let _ = std::io::stdout().write_all(&b);
            }
            Err(e) => eprintln!("error: {e:#}"),
        },
        _ => eprintln!("usage: sgloss [--cache DIR] index|list|suggest|lookup|bench|verify …"),
    }
}

/// Renders a spread of entries from each dictionary and checks resources resolve.
fn verify(lib: &Library) {
    let mut failures = 0;
    for d in lib.summaries() {
        if d.state != "ready" {
            println!("SKIP {} ({}): {:?}", d.name, d.state, d.error);
            failures += 1;
            continue;
        }
        let dict = lib.dict(&d.id).unwrap();
        let l = dict.loaded().unwrap();
        let n = l.index.len();
        let step = (n / 400).max(1);
        let t = Instant::now();
        let (mut ok, mut bad, mut bytes) = (0, 0, 0usize);
        let mut i = 0;
        while i < n {
            match lib.article_page(&d.id, &[i]) {
                Ok(p) if !p.contains("sg-error") => {
                    ok += 1;
                    bytes += p.len();
                }
                Ok(p) => {
                    bad += 1;
                    if bad <= 3 {
                        let e = p.find("sg-error").unwrap();
                        println!("  bad entry {i} {:?}: {}", l.index.entry(i).map(|x| x.0), &p[e..(e + 200).min(p.len())]);
                    }
                }
                Err(e) => {
                    bad += 1;
                    if bad <= 3 {
                        println!("  error entry {i}: {e:#}");
                    }
                }
            }
            i += step;
        }
        failures += bad;
        println!(
            "{:4} {:8} {:>7} entries  {ok} rendered ({} KiB) {bad} failed in {:?}  {}",
            if bad == 0 { "OK" } else { "FAIL" },
            d.format,
            n,
            bytes / 1024,
            t.elapsed(),
            d.name
        );
    }
    println!("{}", if failures == 0 { "ALL OK" } else { "FAILURES" });
}
