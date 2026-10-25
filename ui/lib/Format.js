.pragma library

// Words and numbers as the window shows them.

var MONTHS = ["January", "February", "March", "April", "May", "June", "July",
  "August", "September", "October", "November", "December"]
var SHORT_MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
var DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

function pad(n) { return n < 10 ? "0" + n : String(n) }

// Jellyfin dates are UTC ("2011-10-01T22:00:00.0000000Z"); a premiere date
// names a calendar day, so read its digits rather than shifting zones.
function dateParts(text) {
  var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(text || ""))
  if (!m) return null
  return { year: Number(m[1]), month: Number(m[2]) - 1, day: Number(m[3]) }
}

function airDate(text) {
  var p = dateParts(text)
  if (!p) return ""
  var weekday = DAYS[new Date(p.year, p.month, p.day).getDay()].slice(0, 3)
  return weekday + ", " + p.day + " " + SHORT_MONTHS[p.month] + " " + p.year
}

// 5400 → "1h 30m", 2520 → "42m".
function runtime(seconds) {
  var s = Math.round(Number(seconds || 0))
  if (s <= 0) return ""
  var minutes = Math.round(s / 60)
  if (minutes < 60) return Math.max(1, minutes) + "m"
  var h = Math.floor(minutes / 60)
  var m = minutes % 60
  return m === 0 ? h + "h" : h + "h " + m + "m"
}

// A playback position: "4:05", "1:02:09".
function clock(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds || 0)))
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  var sec = s % 60
  return h > 0 ? h + ":" + pad(m) + ":" + pad(sec) : m + ":" + pad(sec)
}

// "Ends at 22:41" for something with this much left, from `nowMs`.
function endsAt(remainingSeconds, nowMs, speed) {
  var left = Number(remainingSeconds || 0) / (speed || 1)
  if (!(left > 0)) return ""
  var d = new Date((nowMs || Date.now()) + left * 1000)
  return "Ends at " + pad(d.getHours()) + ":" + pad(d.getMinutes())
}

function minutesLeft(item) {
  if (!item || !item.runtime || !item.user || !item.user.position) return ""
  var left = Math.max(0, item.runtime - item.user.position)
  return Math.max(1, Math.round(left / 60)) + " min left"
}

// "S1 · E3", "S1 · E3–4", or "" when the numbers are unknown.
function episodeCode(item) {
  if (!item || item.index === null || item.index === undefined) return ""
  var e = "E" + item.index + (item.indexEnd ? "–" + item.indexEnd : "")
  return item.parentIndex !== null && item.parentIndex !== undefined ? "S" + item.parentIndex + " · " + e : e
}

// The two lines under a card. Episodes lead with their show, as on every
// Jellyfin client; the episode itself is the second line.
function cardTitle(item) {
  if (!item) return ""
  if (item.type === "Episode" && item.seriesName) return item.seriesName
  return item.name || ""
}

function cardSubtitle(item) {
  if (!item) return ""
  switch (item.type) {
  case "Episode":
    var code = episodeCode(item)
    return (code ? code + "  " : "") + (item.name || "")
  case "Series":
    return years(item)
  case "Season":
    return item.seriesName || ""
  case "Movie":
  case "Video":
    return item.year ? String(item.year) : runtime(item.runtime)
  case "BoxSet":
    return item.childCount ? count(item.childCount, "item", "items") : ""
  case "Person":
    return item.role || ""
  }
  return item.year ? String(item.year) : ""
}

// "2011–2020", "2019–" for a show still running, "2011" for one year.
function years(item) {
  if (!item || !item.year) return ""
  if (item.type !== "Series") return String(item.year)
  if (item.status === "Continuing") return item.year + "–"
  if (item.endYear && item.endYear !== item.year) return item.year + "–" + item.endYear
  return String(item.year)
}

// The detail line: year · rating · runtime · ★ 8.7
function metaLine(item) {
  if (!item) return ""
  var parts = []
  if (item.type === "Episode" && item.premiere) parts.push(airDate(item.premiere))
  else if (years(item)) parts.push(years(item))
  if (item.officialRating) parts.push(item.officialRating)
  if (item.type !== "Series" && runtime(item.runtime)) parts.push(runtime(item.runtime))
  if (item.rating) parts.push("★ " + Number(item.rating).toFixed(1))
  return parts.join("  ·  ")
}

// What Play does, in words: "Resume S1 · E3", "Play", "Resume".
function playLabel(item) {
  if (!item) return "Play"
  var resuming = item.user && item.user.position > 0 && !item.user.played
  var verb = resuming ? "Resume" : "Play"
  if (item.type === "Episode") {
    var code = episodeCode(item)
    return code ? verb + " " + code : verb
  }
  return verb
}

function progress(item) {
  if (!item || !item.user || item.user.played) return 0
  if (item.user.percent) return Math.max(0, Math.min(1, item.user.percent / 100))
  if (item.runtime && item.user.position) return Math.max(0, Math.min(1, item.user.position / item.runtime))
  return 0
}

function bytes(n) {
  n = Number(n || 0)
  if (n < 1024) return n + " B"
  var units = ["KB", "MB", "GB", "TB"]
  var i = -1
  do { n /= 1024; i++ } while (n >= 1024 && i < units.length - 1)
  return (n >= 100 ? Math.round(n) : n.toFixed(1)) + " " + units[i]
}

function bitrate(bps) {
  var n = Number(bps || 0)
  if (n <= 0) return ""
  if (n >= 1000000) return (n >= 10000000 ? Math.round(n / 1000000) : (n / 1000000).toFixed(1)) + " Mbps"
  return Math.round(n / 1000) + " kbps"
}

function count(n, one, many) {
  n = Number(n || 0)
  return thousands(n) + " " + (n === 1 ? one : many)
}

function thousands(n) {
  var s = String(Math.round(Number(n || 0)))
  return s.replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

// A stream's label for a picker: the server's display title, else what we know.
function streamLabel(stream) {
  if (!stream) return "Off"
  var label = stream.label || stream.title || stream.language || stream.codec || ("Track " + stream.index)
  if (stream.isExternal && label.indexOf("External") < 0) label += " · external"
  return label
}

// "1080p HEVC HDR" from the video stream.
function videoTag(video) {
  if (!video) return ""
  var h = Number(video.height || 0)
  var w = Number(video.width || 0)
  var res = w >= 3200 || h >= 2000 ? "4K" : h >= 1000 || w >= 1900 ? "1080p" : h >= 700 || w >= 1260 ? "720p" : h > 0 ? h + "p" : ""
  var parts = [res, String(video.codec || "").toUpperCase()]
  var range = String(video.range || "")
  if (/^DOVI/.test(range)) parts.push("Dolby Vision")
  else if (range === "HDR10Plus") parts.push("HDR10+")
  else if (range && range !== "SDR" && range !== "Unknown") parts.push(range)
  return parts.filter(function(p) { return p !== "" }).join(" ")
}

var METHODS = { DirectPlay: "Direct play", DirectStream: "Direct stream", Transcode: "Transcoding" }
function methodLabel(method) {
  return METHODS[method] || String(method || "")
}

// Transcode reasons in words, for the playback info line.
var REASONS = {
  ContainerBitrateExceedsLimit: "the quality limit",
  VideoBitrateNotSupported: "the quality limit",
  AudioCodecNotSupported: "the audio format",
  VideoCodecNotSupported: "the video format",
  SubtitleCodecNotSupported: "picture subtitles",
  ContainerNotSupported: "the file format",
  DirectPlayError: "a direct play error",
  VideoRangeTypeNotSupported: "HDR"
}
function reasonsLabel(reasons) {
  var out = []
  for (var i = 0; i < (reasons || []).length; i++) {
    var r = REASONS[reasons[i]] || reasons[i]
    if (out.indexOf(r) < 0) out.push(r)
  }
  return out.join(", ")
}

// WebVTT → [{ start, end, text }] in seconds, sorted. Styling tags are
// dropped: the window draws plain text.
function parseVtt(text) {
  var cues = []
  var blocks = String(text || "").replace(/\r/g, "").split(/\n\n+/)
  var stamp = /(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})/
  for (var i = 0; i < blocks.length; i++) {
    var lines = blocks[i].split("\n")
    var at = -1
    for (var j = 0; j < lines.length; j++) if (lines[j].indexOf("-->") >= 0) { at = j; break }
    if (at < 0) continue
    var ends = lines[at].split("-->")
    var a = stamp.exec(ends[0])
    var b = stamp.exec(ends[1] || "")
    if (!a || !b) continue
    var seconds = function(m) { return Number(m[1] || 0) * 3600 + Number(m[2]) * 60 + Number(m[3]) + Number((m[4] + "00").slice(0, 3)) / 1000 }
    var body = lines.slice(at + 1).join("\n")
      .replace(/<[^>]*>/g, "").replace(/\{\\[^}]*\}/g, "")
      .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&nbsp;/g, " ").trim()
    if (body === "") continue
    cues.push({ start: seconds(a), end: seconds(b), text: body })
  }
  cues.sort(function(x, y) { return x.start - y.start })
  return cues
}

// The cues showing at `t`, joined; cues may overlap.
function cueAt(cues, t) {
  if (!cues || cues.length === 0) return ""
  var lo = 0, hi = cues.length - 1, first = cues.length
  // The first cue that starts after t; everything showing starts before it.
  while (lo <= hi) {
    var mid = (lo + hi) >> 1
    if (cues[mid].start > t) { first = mid; hi = mid - 1 } else lo = mid + 1
  }
  var out = []
  for (var i = first - 1; i >= 0 && i >= first - 12; i--) {
    if (cues[i].end > t) out.unshift(cues[i].text)
  }
  return out.join("\n")
}

// The media segment playing at `t`, or null.
function segmentAt(segments, t) {
  for (var i = 0; i < (segments || []).length; i++) {
    var s = segments[i]
    if (t >= s.start && t < s.end - 0.5) return s
  }
  return null
}

var SEGMENT_NAMES = { Intro: "intro", Outro: "credits", Recap: "recap", Preview: "preview", Commercial: "ad" }
function segmentName(type) {
  return SEGMENT_NAMES[type] || "segment"
}

// When Up next shows: as the credits start if they run to (nearly) the end,
// otherwise 32 seconds before the end. Never for clips under 40 seconds.
function upNextAt(runtime, segments) {
  var total = Number(runtime || 0)
  if (total < 40) return -1
  for (var i = 0; i < (segments || []).length; i++) {
    var s = segments[i]
    if (s.type === "Outro" && s.end >= total * 0.9 && total - s.end < 30) return s.start
  }
  return Math.max(0, total - 32)
}

// The trickplay tile and the crop inside it for a position, from the
// backend's trickplay description.
function trickplayFrame(info, seconds) {
  if (!info || !info.interval || !info.tileWidth || !info.tileHeight || !info.count) return null
  var index = Math.min(info.count - 1, Math.max(0, Math.floor(seconds * 1000 / info.interval)))
  var perTile = info.tileWidth * info.tileHeight
  var tile = Math.floor(index / perTile)
  var inTile = index % perTile
  return {
    tile: tile,
    x: (inTile % info.tileWidth) * info.width,
    y: Math.floor(inTile / info.tileWidth) * info.height
  }
}

// The icon for a library by its kind.
function viewIcon(collectionType) {
  switch (collectionType) {
  case "movies": return "movies"
  case "tvshows": return "shows"
  case "boxsets": return "collections"
  case "playlists": return "playlists"
  case "music": return "music"
  case "books": return "books"
  case "homevideos": return "video"
  case "musicvideos": return "video"
  }
  return "folder"
}

// What a library lists in its grid: shows in a TV library, films in a film
// library, everything else as it is.
function viewTypes(collectionType) {
  switch (collectionType) {
  case "movies": return "Movie"
  case "tvshows": return "Series"
  case "boxsets": return "BoxSet"
  case "musicvideos": return "MusicVideo"
  }
  return ""
}

function isPlayable(item) {
  return !!item && (item.mediaType === "Video" || item.type === "Movie" || item.type === "Episode" || item.type === "Video")
}

// Shows, seasons and collections open a page; so do films and episodes.
// People open their filmography.
function opensGrid(item) {
  return !!item && (item.type === "BoxSet" || item.type === "Folder" || item.type === "CollectionFolder" || item.type === "Playlist" || item.type === "UserView")
}
