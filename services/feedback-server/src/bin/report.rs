//! Local-only dataset review report. Reads only feedback metadata, never copies examples.
//! Run: cargo run --bin report -- /path/to/private-feedback
use anyhow::Result;
use serde::Deserialize;
use std::{collections::BTreeMap, path::PathBuf};

#[derive(Deserialize)]
struct Entry { model_label: String, rating: String, issue: String, with_example: bool }
fn main() -> Result<()> {
    let root = std::env::args_os().nth(1)
        .map(PathBuf::from).unwrap_or_else(|| PathBuf::from("./private-feedback"));
    let mut tally: BTreeMap<(String,String,String,bool), usize> = BTreeMap::new();
    let mut skipped = 0;
    for e in std::fs::read_dir(&root)? {
        let p = e?.path().join("metadata.json");
        if !p.is_file() { continue; }
        match std::fs::read(&p).ok().and_then(|b| serde_json::from_slice::<Entry>(&b).ok()) {
            Some(f) => *tally.entry((f.model_label, f.rating, f.issue, f.with_example)).or_default() += 1,
            None => skipped += 1,
        }
    }
    println!("PRIVATE BETA FEEDBACK SUMMARY — NO RAW PHOTOS OR UPLOADS READ");
    for ((model,rating,issue,sample),n) in tally {
        println!("{n:>5}  model={model}  rating={rating}  issue={issue}  sample={sample}");
    }
    println!("Ignored unreadable records: {skipped}");
    Ok(())
}
