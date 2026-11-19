//! Makes dictionary audio playable by AVFoundation: Ogg Vorbis is transcoded to
//! 16-bit PCM WAV, MP3-in-WAV is unwrapped to a plain MP3 stream; everything else
//! passes through unchanged.

use anyhow::Result;
use lewton::inside_ogg::OggStreamReader;
use std::io::Cursor;

pub fn is_ogg_vorbis(b: &[u8]) -> bool {
    b.starts_with(b"OggS") && b[..b.len().min(128)].windows(6).any(|w| w == b"vorbis")
}

pub fn vorbis_to_wav(b: &[u8]) -> Result<Vec<u8>> {
    let mut r = OggStreamReader::new(Cursor::new(b))?;
    let channels = r.ident_hdr.audio_channels as u16;
    let rate = r.ident_hdr.audio_sample_rate;
    let mut pcm: Vec<i16> = Vec::new();
    while let Some(p) = r.read_dec_packet_itl()? {
        pcm.extend_from_slice(&p);
    }
    Ok(wav(&pcm, channels, rate))
}

fn wav(pcm: &[i16], channels: u16, rate: u32) -> Vec<u8> {
    let data_len = (pcm.len() * 2) as u32;
    let mut out = Vec::with_capacity(44 + data_len as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_len).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&channels.to_le_bytes());
    out.extend_from_slice(&rate.to_le_bytes());
    out.extend_from_slice(&(rate * channels as u32 * 2).to_le_bytes());
    out.extend_from_slice(&(channels * 2).to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_len.to_le_bytes());
    for s in pcm {
        out.extend_from_slice(&s.to_le_bytes());
    }
    out
}

/// The `data` chunk of a RIFF/WAVE file whose format tag is 0x0055 (MPEG Layer 3).
/// Lingvo-style DSL sound packs (Cambridge, Macmillan) ship these; CoreAudio rejects
/// the container but plays the MP3 frames inside.
fn mp3_in_wav(b: &[u8]) -> Option<&[u8]> {
    if b.len() < 12 || &b[..4] != b"RIFF" || &b[8..12] != b"WAVE" {
        return None;
    }
    let mut pos = 12usize;
    let mut is_mp3 = false;
    while pos + 8 <= b.len() {
        let id = &b[pos..pos + 4];
        let size = u32::from_le_bytes(b[pos + 4..pos + 8].try_into().unwrap()) as usize;
        let body = &b[pos + 8..(pos + 8).saturating_add(size).min(b.len())];
        match id {
            b"fmt " => is_mp3 = body.len() >= 2 && u16::from_le_bytes([body[0], body[1]]) == 0x0055,
            b"data" => return (is_mp3 && !body.is_empty()).then_some(body),
            _ => {}
        }
        pos = pos + 8 + size + (size & 1);
    }
    None
}

/// Returns bytes AVAudioPlayer can decode.
pub fn playable(bytes: Vec<u8>) -> Result<Vec<u8>> {
    if is_ogg_vorbis(&bytes) {
        vorbis_to_wav(&bytes)
    } else if let Some(mp3) = mp3_in_wav(&bytes) {
        Ok(mp3.to_vec())
    } else {
        Ok(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unwraps_mp3_in_wav() {
        let mut w = b"RIFF\0\0\0\0WAVEfmt \x1e\0\0\0\x55\0\x01\0".to_vec();
        w.extend_from_slice(&[0; 26]);
        w.extend_from_slice(b"fact\x04\0\0\0\x10\0\0\0data\x04\0\0\0\xff\xfb\x90\x00");
        assert_eq!(mp3_in_wav(&w), Some(&[0xff, 0xfb, 0x90, 0x00][..]));
        let pcm = wav(&[0, 1, 2], 1, 8000);
        assert_eq!(mp3_in_wav(&pcm), None);
        assert_eq!(playable(pcm.clone()).unwrap(), pcm);
    }
}
