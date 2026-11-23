//! Random-access byte sources.
//!
//! * [`ChunkStore`] — our own deflate-chunked blob store, used for data that has to
//!   be converted at index time (Babylon articles, plain-gzip files).
//! * [`Dictzip`] — the dictzip (`.dz`) random-access gzip extension.
//! * [`Source`] — a uniform "read bytes at offset" view over plain files, dictzip
//!   files and chunk stores.

use crate::util::{le16, read_at, BlockCache};
use anyhow::{bail, Context, Result};
use flate2::{Compress, Compression, Decompress, FlushCompress, FlushDecompress, Status};
use std::fs::File;
use std::io::{BufWriter, Read, Write};
use std::path::Path;
use std::sync::Arc;

const CHUNK: usize = 64 * 1024;

pub struct ChunkStoreWriter {
    data: BufWriter<File>,
    table: Vec<u64>,
    buf: Vec<u8>,
    written: u64,
    total: u64,
    comp: Compress,
    out: Vec<u8>,
    tab_path: std::path::PathBuf,
}

impl ChunkStoreWriter {
    pub fn create(dir: &Path, name: &str) -> Result<Self> {
        Ok(ChunkStoreWriter {
            data: BufWriter::new(File::create(dir.join(format!("{name}.dat")))?),
            table: vec![0],
            buf: Vec::with_capacity(CHUNK),
            written: 0,
            total: 0,
            comp: Compress::new(Compression::new(5), false),
            out: Vec::with_capacity(CHUNK + 1024),
            tab_path: dir.join(format!("{name}.tab")),
        })
    }

    /// Appends bytes and returns their (offset, length) in uncompressed space.
    pub fn append(&mut self, mut bytes: &[u8]) -> Result<(u64, u64)> {
        let start = self.total;
        let len = bytes.len() as u64;
        while !bytes.is_empty() {
            let room = CHUNK - self.buf.len();
            let n = room.min(bytes.len());
            self.buf.extend_from_slice(&bytes[..n]);
            bytes = &bytes[n..];
            if self.buf.len() == CHUNK {
                self.flush_chunk()?;
            }
        }
        self.total += len;
        Ok((start, len))
    }

    fn flush_chunk(&mut self) -> Result<()> {
        if self.buf.is_empty() {
            return Ok(());
        }
        self.comp.reset();
        self.out.clear();
        self.out.reserve(self.buf.len() + self.buf.len() / 8 + 64);
        loop {
            let consumed = self.comp.total_in() as usize;
            let st = self.comp.compress_vec(&self.buf[consumed..], &mut self.out, FlushCompress::Finish)?;
            if st == Status::StreamEnd {
                break;
            }
            self.out.reserve(self.out.capacity());
        }
        self.data.write_all(&self.out)?;
        self.written += self.out.len() as u64;
        self.table.push(self.written);
        self.buf.clear();
        Ok(())
    }

    pub fn finish(mut self) -> Result<()> {
        self.flush_chunk()?;
        self.data.flush()?;
        let mut tab = BufWriter::new(File::create(&self.tab_path)?);
        tab.write_all(&self.total.to_le_bytes())?;
        for o in &self.table {
            tab.write_all(&o.to_le_bytes())?;
        }
        tab.flush()?;
        Ok(())
    }
}

pub struct ChunkStore {
    file: File,
    table: Vec<u64>,
    total: u64,
    cache: BlockCache,
}

impl ChunkStore {
    pub fn open(dir: &Path, name: &str) -> Result<Self> {
        let file = File::open(dir.join(format!("{name}.dat")))?;
        let tab = std::fs::read(dir.join(format!("{name}.tab")))?;
        if tab.len() < 16 || tab.len() % 8 != 0 {
            bail!("corrupt chunk table");
        }
        let total = u64::from_le_bytes(tab[0..8].try_into().unwrap());
        let table = tab[8..].chunks_exact(8).map(|c| u64::from_le_bytes(c.try_into().unwrap())).collect();
        Ok(ChunkStore { file, table, total, cache: BlockCache::new(8) })
    }

    fn chunk(&self, i: usize) -> Result<Arc<Vec<u8>>> {
        self.cache.get_or_load(i as u64, || {
            if i + 1 >= self.table.len() {
                bail!("chunk {i} out of range");
            }
            let (s, e) = (self.table[i], self.table[i + 1]);
            let comp = read_at(&self.file, s, e.checked_sub(s).context("corrupt chunk table")? as usize)?;
            inflate_raw(&comp, CHUNK)
        })
    }

    pub fn read(&self, off: u64, len: u64) -> Result<Vec<u8>> {
        read_chunked(off, len, self.total, CHUNK, |i| self.chunk(i))
    }
}

fn read_chunked(
    off: u64,
    len: u64,
    total: u64,
    chunk_len: usize,
    chunk: impl Fn(usize) -> Result<Arc<Vec<u8>>>,
) -> Result<Vec<u8>> {
    if off.checked_add(len).is_none_or(|e| e > total) {
        bail!("read {off}+{len} beyond end {total}");
    }
    let mut out = Vec::with_capacity(len.min(1 << 20) as usize);
    let mut pos = off;
    let end = off + len;
    while pos < end {
        let ci = (pos / chunk_len as u64) as usize;
        let c = chunk(ci)?;
        let within = (pos - ci as u64 * chunk_len as u64) as usize;
        if within >= c.len() {
            bail!("short chunk {ci}");
        }
        let n = (c.len() - within).min((end - pos) as usize);
        out.extend_from_slice(&c[within..within + n]);
        pos += n as u64;
    }
    Ok(out)
}

/// Inflates one chunk of at most `limit` bytes.
pub fn inflate_raw(comp: &[u8], limit: usize) -> Result<Vec<u8>> {
    let mut d = Decompress::new(false);
    // The spare byte tells a chunk that fills `limit` from one that overflows it.
    let mut out = Vec::with_capacity(limit + 1);
    loop {
        let consumed = d.total_in() as usize;
        let st = d.decompress_vec(&comp[consumed..], &mut out, FlushDecompress::Sync)?;
        if out.len() > limit {
            bail!("chunk inflates past {limit} bytes");
        }
        if st != Status::Ok || d.total_in() as usize >= comp.len() {
            break;
        }
    }
    Ok(out)
}

/// Deflate expands data at most 1032-fold and LZO less, so a size claimed beyond this
/// ratio is a lie, however large the buffer it asks for.
const MAX_RATIO: u64 = 1100;

pub fn plausible_size(comp: u64, size: u64) -> bool {
    size <= comp.saturating_mul(MAX_RATIO)
}

/// Inflates a zlib stream that must hold exactly `size` bytes.
pub fn inflate_zlib(comp: &[u8], size: usize) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(size.min(1 << 20));
    flate2::read::ZlibDecoder::new(comp).take(size as u64 + 1).read_to_end(&mut out).context("zlib")?;
    if out.len() != size {
        bail!("zlib block holds {} bytes, not {size}", out.len());
    }
    Ok(out)
}

/// dictzip: gzip with a chunk table in the FEXTRA "RA" subfield.
pub struct Dictzip {
    file: File,
    chunk_len: usize,
    offsets: Vec<u64>,
    total: u64,
    cache: BlockCache,
}

impl Dictzip {
    /// Returns Ok(None) for a gzip file without a usable random-access table.
    pub fn open(path: &Path) -> Result<Option<Dictzip>> {
        let file = File::open(path).with_context(|| format!("open {}", path.display()))?;
        let flen = file.metadata()?.len();
        let head = read_at(&file, 0, (flen.min(1 << 20)) as usize)?;
        if head.len() < 18 || head[0] != 0x1f || head[1] != 0x8b || head[2] != 8 {
            bail!("not a gzip file");
        }
        let flags = head[3];
        if flags & 0x04 == 0 {
            return Ok(None);
        }
        let xlen = le16(&head[10..]) as usize;
        let extra = head.get(12..12 + xlen).context("truncated gzip extra")?;
        let mut pos = 12 + xlen;
        let mut ra: Option<(usize, Vec<u64>)> = None;
        let mut p = 0;
        while p + 4 <= extra.len() {
            let (si1, si2) = (extra[p], extra[p + 1]);
            let len = le16(&extra[p + 2..]) as usize;
            let body = extra.get(p + 4..p + 4 + len).context("truncated subfield")?;
            if si1 == b'R' && si2 == b'A' && body.len() >= 6 {
                let chlen = le16(&body[2..]) as usize;
                let chcnt = le16(&body[4..]) as usize;
                if body.len() < 6 + chcnt * 2 || chlen == 0 {
                    return Ok(None);
                }
                let sizes = (0..chcnt).map(|i| le16(&body[6 + i * 2..]) as u64).collect();
                ra = Some((chlen, sizes));
            }
            p += 4 + len;
        }
        let Some((chunk_len, sizes)) = ra else { return Ok(None) };
        if flags & 0x08 != 0 {
            pos += head.get(pos..).and_then(|s| s.iter().position(|&b| b == 0)).context("bad gzip name")? + 1;
        }
        if flags & 0x10 != 0 {
            pos += head.get(pos..).and_then(|s| s.iter().position(|&b| b == 0)).context("bad gzip comment")? + 1;
        }
        if flags & 0x02 != 0 {
            pos += 2;
        }
        let mut offsets = Vec::with_capacity(sizes.len() + 1);
        let mut o = pos as u64;
        offsets.push(o);
        for s in &sizes {
            o += s;
            offsets.push(o);
        }
        // The table must describe the whole single-member stream (8-byte trailer).
        if o + 8 != flen {
            return Ok(None);
        }
        let isize = u32::from_le_bytes(read_at(&file, flen - 4, 4)?.try_into().unwrap()) as u64;
        let n = sizes.len() as u64;
        // ISIZE is the size mod 2^32; reconstruct the full size from the chunk count.
        let max = n * chunk_len as u64;
        let min = max.saturating_sub(chunk_len as u64) + 1;
        let mut total = (min & !0xFFFF_FFFF) | isize;
        while total < min {
            total += 1 << 32;
        }
        if n == 0 {
            total = 0;
        } else if total > max {
            return Ok(None);
        }
        Ok(Some(Dictzip { file, chunk_len, offsets, total, cache: BlockCache::new(16) }))
    }

    pub fn len(&self) -> u64 {
        self.total
    }

    pub fn is_empty(&self) -> bool {
        self.total == 0
    }

    fn chunk(&self, i: usize) -> Result<Arc<Vec<u8>>> {
        self.cache.get_or_load(i as u64, || {
            if i + 1 >= self.offsets.len() {
                bail!("dictzip chunk {i} out of range");
            }
            let (s, e) = (self.offsets[i], self.offsets[i + 1]);
            let comp = read_at(&self.file, s, (e - s) as usize)?;
            inflate_raw(&comp, self.chunk_len)
        })
    }

    pub fn read(&self, off: u64, len: u64) -> Result<Vec<u8>> {
        read_chunked(off, len, self.total, self.chunk_len, |i| self.chunk(i))
    }
}

/// Reads an entire gzip (or plain) file into memory.
pub fn read_maybe_gzip(path: &Path) -> Result<Vec<u8>> {
    let raw = std::fs::read(path).with_context(|| format!("read {}", path.display()))?;
    if is_gzip(&raw) {
        gunzip(&raw)
    } else {
        Ok(raw)
    }
}

fn is_gzip(b: &[u8]) -> bool {
    b.starts_with(&[0x1f, 0x8b])
}

fn gunzip(raw: &[u8]) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(raw.len() * 4);
    flate2::read::MultiGzDecoder::new(raw).read_to_end(&mut out).context("gunzip")?;
    Ok(out)
}

fn write_store(cache_dir: &Path, name: &str, data: &[u8]) -> Result<()> {
    let mut w = ChunkStoreWriter::create(cache_dir, name)?;
    w.append(data)?;
    w.finish()
}

/// Uniform random-access reader over a dictionary data file.
pub enum Source {
    Plain(File, u64),
    Dz(Dictzip),
    Store(ChunkStore),
}

impl Source {
    /// Opens `path` for random access. Plain gzip files (no dictzip table) are
    /// decompressed once into a chunk store named `store_name` in `cache_dir`.
    pub fn open(path: &Path, cache_dir: &Path, store_name: &str, building: bool) -> Result<Source> {
        let is_gz = {
            let mut f = File::open(path).with_context(|| format!("open {}", path.display()))?;
            let mut m = [0u8; 2];
            f.read(&mut m)? == 2 && m == [0x1f, 0x8b]
        };
        if !is_gz {
            let f = File::open(path)?;
            let len = f.metadata()?.len();
            return Ok(Source::Plain(f, len));
        }
        if let Some(dz) = Dictzip::open(path)? {
            return Ok(Source::Dz(dz));
        }
        if building || !cache_dir.join(format!("{store_name}.tab")).exists() {
            write_store(cache_dir, store_name, &read_maybe_gzip(path)?)?;
        }
        Ok(Source::Store(ChunkStore::open(cache_dir, store_name)?))
    }

    /// Reads the whole text at index time, and from that one decompression prepares what
    /// [`Source::open`] needs later: a plain gzip file's chunk store named `store_name`.
    pub fn prepare(path: &Path, cache_dir: &Path, store_name: &str) -> Result<Vec<u8>> {
        let raw = std::fs::read(path).with_context(|| format!("read {}", path.display()))?;
        if !is_gzip(&raw) {
            return Ok(raw);
        }
        let data = gunzip(&raw)?;
        if Dictzip::open(path)?.is_none() {
            write_store(cache_dir, store_name, &data)?;
        }
        Ok(data)
    }

    pub fn len(&self) -> u64 {
        match self {
            Source::Plain(_, l) => *l,
            Source::Dz(d) => d.len(),
            Source::Store(s) => s.total,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn read(&self, off: u64, len: u64) -> Result<Vec<u8>> {
        match self {
            Source::Plain(f, total) => {
                if off.checked_add(len).is_none_or(|e| e > *total) {
                    bail!("read {off}+{len} beyond end {total}");
                }
                read_at(f, off, len as usize)
            }
            Source::Dz(d) => d.read(off, len),
            Source::Store(s) => s.read(off, len),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunk_store_roundtrip() {
        let d = std::env::temp_dir().join(format!("sg-store-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        let mut w = ChunkStoreWriter::create(&d, "s").unwrap();
        let mut locs = Vec::new();
        let mut expect = Vec::new();
        for i in 0..20000u32 {
            let s = format!("entry number {i} {}", "x".repeat((i % 97) as usize));
            locs.push(w.append(s.as_bytes()).unwrap());
            expect.push(s);
        }
        w.finish().unwrap();
        let s = ChunkStore::open(&d, "s").unwrap();
        for (i, (o, l)) in locs.iter().enumerate().step_by(37) {
            assert_eq!(s.read(*o, *l).unwrap(), expect[i].as_bytes());
        }
        assert!(s.read(s.total, 1).is_err());
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn bombs_stop_at_their_limit() {
        let deflate = |data: &[u8]| {
            let mut e = flate2::write::DeflateEncoder::new(Vec::new(), Compression::best());
            e.write_all(data).unwrap();
            e.finish().unwrap()
        };
        let zeros = vec![0u8; 16 << 20];
        assert!(inflate_raw(&deflate(&zeros), CHUNK).is_err());
        assert_eq!(inflate_raw(&deflate(&zeros[..CHUNK]), CHUNK).unwrap().len(), CHUNK);
        let mut z = flate2::write::ZlibEncoder::new(Vec::new(), Compression::best());
        z.write_all(&zeros).unwrap();
        let z = z.finish().unwrap();
        assert!(inflate_zlib(&z, 1000).is_err());
        assert_eq!(inflate_zlib(&z, zeros.len()).unwrap().len(), zeros.len());
        assert!(!plausible_size(z.len() as u64, 1 << 40));
    }
}
