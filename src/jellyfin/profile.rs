//! What this computer can play, told to Jellyfin as a device profile, so the
//! server sends files untouched whenever it can and transcodes only what the
//! player cannot show.
//!
//! Both players decode with FFmpeg, so nearly every container and codec plays
//! directly. The difference is subtitles: the window draws text subtitles
//! itself (the server converts them to WebVTT) and cannot draw picture-based
//! ones (PGS, DVD), which the server burns in; mpv draws everything itself.

use serde_json::{Value, json};

pub const VIDEO_CONTAINERS: &str = "mkv,webm,mp4,m4v,mov,avi,ts,m2ts,mpegts,mpg,mpeg,wmv,asf,flv,3gp,ogv";
pub const VIDEO_CODECS: &str = "h264,hevc,h265,av1,vp9,vp8,mpeg2video,mpeg4,msmpeg4v3,vc1,wmv3,theora";
pub const AUDIO_CODECS: &str =
    "aac,mp3,mp2,ac3,eac3,dts,truehd,mlp,flac,alac,opus,vorbis,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,wmav2,wmapro";

const TEXT_SUBTITLES: [&str; 6] = ["srt", "subrip", "vtt", "webvtt", "ass", "ssa"];
const PICTURE_SUBTITLES: [&str; 5] = ["pgssub", "pgs", "dvdsub", "dvbsub", "vobsub"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Player {
    Window,
    Mpv,
}

pub fn device_profile(player: Player, max_bitrate: u64) -> Value {
    let max = if max_bitrate == 0 { 400_000_000 } else { max_bitrate };
    let mut subtitles: Vec<Value> = Vec::new();
    match player {
        Player::Window => {
            for format in TEXT_SUBTITLES {
                subtitles.push(json!({ "Format": format, "Method": "External" }));
            }
            for format in PICTURE_SUBTITLES {
                subtitles.push(json!({ "Format": format, "Method": "Encode" }));
            }
        }
        Player::Mpv => {
            for format in TEXT_SUBTITLES.iter().chain(PICTURE_SUBTITLES.iter()) {
                subtitles.push(json!({ "Format": format, "Method": "Embed" }));
                subtitles.push(json!({ "Format": format, "Method": "External" }));
            }
        }
    }
    json!({
        "Name": match player { Player::Window => "Omafin", Player::Mpv => "Omafin (mpv)" },
        "MaxStreamingBitrate": max,
        "MaxStaticBitrate": max,
        "MusicStreamingTranscodingBitrate": 384000,
        "DirectPlayProfiles": [
            { "Container": VIDEO_CONTAINERS, "Type": "Video", "VideoCodec": VIDEO_CODECS, "AudioCodec": AUDIO_CODECS },
            { "Container": "mp3,aac,m4a,flac,ogg,opus,wav,alac", "Type": "Audio" }
        ],
        "TranscodingProfiles": [
            {
                "Container": "ts", "Type": "Video", "Protocol": "hls", "Context": "Streaming",
                "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3",
                "MaxAudioChannels": "6", "MinSegments": 1, "BreakOnNonKeyFrames": true
            },
            { "Container": "mp3", "Type": "Audio", "AudioCodec": "mp3", "Protocol": "http", "Context": "Streaming" }
        ],
        "ContainerProfiles": [],
        "CodecProfiles": [],
        "SubtitleProfiles": subtitles,
    })
}

pub fn is_picture_subtitle(codec: &str) -> bool {
    PICTURE_SUBTITLES.contains(&codec.to_ascii_lowercase().as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn window_burns_in_picture_subtitles_only() {
        let p = device_profile(Player::Window, 0);
        let subs = p["SubtitleProfiles"].as_array().unwrap();
        let method = |f: &str| subs.iter().find(|s| s["Format"] == f).unwrap()["Method"].clone();
        assert_eq!(method("pgssub"), "Encode");
        assert_eq!(method("srt"), "External");
        let mpv = device_profile(Player::Mpv, 8_000_000);
        assert_eq!(mpv["MaxStreamingBitrate"], 8_000_000);
        assert!(mpv["SubtitleProfiles"].as_array().unwrap().iter().all(|s| s["Method"] != "Encode"));
    }

    #[test]
    fn knows_picture_subtitles() {
        assert!(is_picture_subtitle("PGSSUB"));
        assert!(!is_picture_subtitle("subrip"));
    }
}
