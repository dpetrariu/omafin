// Tests for the UI's JavaScript libraries, run with plain Node.
// Each `.pragma library` file is evaluated in its own context.
"use strict"
const fs = require("fs")
const path = require("path")
const vm = require("vm")
const assert = require("assert")

function load(rel) {
  const file = path.join(__dirname, "..", "ui", rel)
  const source = fs.readFileSync(file, "utf8").replace(/^\.pragma library\s*$/m, "")
  const context = vm.createContext({ String, Number, Math, Date, JSON, Object, Array, isFinite, Infinity })
  vm.runInContext(source, context, { filename: file })
  return context
}

// Objects made in another context have another Object prototype.
function same(actual, expected) {
  assert.deepStrictEqual(JSON.parse(JSON.stringify(actual)), expected)
}

let passed = 0
function test(name, fn) {
  try {
    fn()
    passed++
  } catch (e) {
    console.error("FAIL " + name + ": " + e.message)
    process.exitCode = 1
  }
}

const Format = load("lib/Format.js")
const Items = load("lib/Items.js")
const Keymap = load("keys/Keymap.js")
const Wire = load("backend/Wire.js")

const episode = { type: "Episode", name: "Grace", seriesName: "Homeland", index: 2, parentIndex: 1, runtime: 3000,
  user: { position: 600, played: false, percent: 20 } }

test("runtimes and clocks read naturally", () => {
  assert.strictEqual(Format.runtime(5400), "1h 30m")
  assert.strictEqual(Format.runtime(3600), "1h")
  assert.strictEqual(Format.runtime(2520), "42m")
  assert.strictEqual(Format.runtime(0), "")
  assert.strictEqual(Format.clock(65), "1:05")
  assert.strictEqual(Format.clock(3729), "1:02:09")
})

test("ends at counts from now and the speed", () => {
  const now = new Date(2026, 9, 25, 21, 0, 0).getTime()
  assert.strictEqual(Format.endsAt(3600, now), "Ends at 22:00")
  assert.strictEqual(Format.endsAt(3600, now, 2), "Ends at 21:30")
  assert.strictEqual(Format.endsAt(0, now), "")
})

test("episodes lead with their show and say where they are", () => {
  assert.strictEqual(Format.episodeCode(episode), "S1 · E2")
  assert.strictEqual(Format.episodeCode({ index: 3, indexEnd: 4, parentIndex: 2 }), "S2 · E3–4")
  assert.strictEqual(Format.cardTitle(episode), "Homeland")
  assert.strictEqual(Format.cardSubtitle(episode), "S1 · E2  Grace")
  assert.strictEqual(Format.playLabel(episode), "Resume S1 · E2")
  assert.strictEqual(Format.playLabel({ type: "Movie", user: { position: 0 } }), "Play")
  assert.strictEqual(Format.playLabel({ type: "Movie", user: { position: 30, played: true } }), "Play")
  assert.strictEqual(Format.minutesLeft(episode), "40 min left")
  assert.strictEqual(Format.progress(episode), 0.2)
})

test("shows say when they ran", () => {
  assert.strictEqual(Format.years({ type: "Series", year: 2011, endYear: 2020, status: "Ended" }), "2011–2020")
  assert.strictEqual(Format.years({ type: "Series", year: 2019, status: "Continuing" }), "2019–")
  assert.strictEqual(Format.metaLine({ type: "Movie", year: 2016, officialRating: "PG-13", runtime: 6960, rating: 7.94 }), "2016  ·  PG-13  ·  1h 56m  ·  ★ 7.9")
})

test("WebVTT parses, drops markup and finds the cue on screen", () => {
  const cues = Format.parseVtt("WEBVTT\r\n\r\n1\r\n00:00:01.000 --> 00:00:03.500\r\nHello <i>there</i>\r\n\r\n00:01:02.250 --> 00:01:04.000 align:start\nTwo &amp; lines\nhere\n")
  assert.strictEqual(cues.length, 2)
  same([cues[0].start, cues[0].end, cues[0].text], [1, 3.5, "Hello there"])
  assert.strictEqual(cues[1].start, 62.25)
  assert.strictEqual(Format.cueAt(cues, 2), "Hello there")
  assert.strictEqual(Format.cueAt(cues, 3.6), "")
  assert.strictEqual(Format.cueAt(cues, 63), "Two & lines\nhere")
  assert.strictEqual(Format.cueAt([], 1), "")
  // Overlapping cues both show.
  const both = Format.parseVtt("WEBVTT\n\n00:00:01.000 --> 00:00:05.000\nA\n\n00:00:02.000 --> 00:00:03.000\nB\n")
  assert.strictEqual(Format.cueAt(both, 2.5), "A\nB")
})

test("segments and up next follow the credits", () => {
  const segments = [{ type: "Intro", start: 5, end: 20 }, { type: "Outro", start: 2900, end: 3000 }]
  assert.strictEqual(Format.segmentAt(segments, 10).type, "Intro")
  assert.strictEqual(Format.segmentAt(segments, 19.8), null)
  assert.strictEqual(Format.segmentName("Outro"), "credits")
  // Credits that run to the end: up next starts with them.
  assert.strictEqual(Format.upNextAt(3010, segments), 2900)
  // Credits followed by a long scene: the last 32 seconds instead.
  assert.strictEqual(Format.upNextAt(3600, segments), 3568)
  assert.strictEqual(Format.upNextAt(30, []), -1)
})

test("trickplay frames come from the right tile and spot", () => {
  const info = { width: 320, height: 180, tileWidth: 10, tileHeight: 10, count: 500, interval: 10000 }
  same(Format.trickplayFrame(info, 0), { tile: 0, x: 0, y: 0 })
  same(Format.trickplayFrame(info, 125), { tile: 0, x: 320 * 2, y: 180 })
  same(Format.trickplayFrame(info, 1005), { tile: 1, x: 0, y: 0 })
  assert.strictEqual(Format.trickplayFrame(info, 99999).tile, 4)
  assert.strictEqual(Format.trickplayFrame(null, 1), null)
})

test("streams and transcodes are said in words", () => {
  assert.strictEqual(Format.videoTag({ width: 3840, height: 1600, codec: "hevc", range: "HDR10" }), "4K HEVC HDR10")
  assert.strictEqual(Format.videoTag({ width: 1920, height: 800, codec: "h264", range: "SDR" }), "1080p H264")
  assert.strictEqual(Format.videoTag({ width: 3840, height: 2160, codec: "hevc", range: "DOVIWithEL" }), "4K HEVC Dolby Vision")
  assert.strictEqual(Format.reasonsLabel(["ContainerBitrateExceedsLimit", "VideoBitrateNotSupported", "AudioCodecNotSupported"]), "the quality limit, the audio format")
  assert.strictEqual(Format.streamLabel({ label: "English - SRT", isExternal: true }), "English - SRT · external")
  assert.strictEqual(Format.bitrate(8000000), "8.0 Mbps")
})

test("libraries list what they hold", () => {
  assert.strictEqual(Format.viewTypes("tvshows"), "Series")
  assert.strictEqual(Format.viewTypes("movies"), "Movie")
  assert.strictEqual(Format.viewTypes("homevideos"), "")
  assert.strictEqual(Format.viewIcon("boxsets"), "collections")
  assert.ok(Format.isPlayable({ type: "Episode" }))
  assert.ok(!Format.isPlayable({ type: "Series" }))
  assert.ok(Format.opensGrid({ type: "BoxSet" }))
})

test("marks patch one item and leave the rest alone", () => {
  const list = [{ id: "a", user: { played: false, favorite: true } }, { id: "b", user: {} }]
  const next = Items.patchUser(list, "a", { played: true })
  assert.notStrictEqual(next, list)
  same(next[0].user, { played: true, favorite: true })
  assert.strictEqual(next[1], list[1])
  assert.strictEqual(Items.patchUser(list, "zzz", { played: true }), list)
  const rows = [{ items: list }, { items: [] }]
  assert.strictEqual(Items.patchRows(rows, "b", { favorite: true })[0].items[1].user.favorite, true)
  same(Items.appendUnique([{ id: "a" }], [{ id: "a" }, { id: "c" }]).map(i => i.id), ["a", "c"])
})

test("no key means two things in one context", () => {
  assert.deepStrictEqual(Array.from(Keymap.conflicts()), [])
})

test("typing contexts bind no bare letters", () => {
  for (const context of ["search", "page", "dialog"]) {
    for (const s of Keymap.sequencesFor(context)) assert.ok(Keymap.typingSafe(s.sequence), context + " binds " + s.sequence)
  }
})

test("keys that change the library do not repeat", () => {
  const browse = Keymap.sequencesFor("browse")
  for (const id of ["watched", "favorite"]) {
    assert.ok(browse.filter(s => s.id === id).every(s => s.repeat === false), id + " repeats")
  }
  assert.ok(browse.find(s => s.id === "down").repeat)
})

test("the player answers the keys people expect", () => {
  const player = Keymap.sequencesFor("player")
  const by = seq => (player.find(s => s.sequence === seq) || {}).id
  assert.strictEqual(by("Space"), "playPause")
  assert.strictEqual(by("k"), "playPause")
  assert.strictEqual(by("Left"), "seekBack")
  assert.strictEqual(by("l"), "seekForward")
  assert.strictEqual(by("s"), "skipSegment")
  assert.strictEqual(by("Escape"), "back")
  assert.strictEqual(by("p"), undefined)
})

test("wire frames are checked before use", () => {
  assert.strictEqual(Wire.response({ jsonrpc: "2.0", id: "q1", result: 1 }).result, 1)
  assert.strictEqual(Wire.response({ jsonrpc: "2.0", id: 3, result: 1 }), null)
  assert.ok(Wire.notification({ jsonrpc: "2.0", method: "playback.changed", params: {} }))
  assert.strictEqual(Wire.notification({ jsonrpc: "2.0", method: "sync.changed", params: {} }), null)
})

console.log((process.exitCode ? "some UI logic tests failed" : "ui logic: all passed") + " (" + passed + " passed)")
