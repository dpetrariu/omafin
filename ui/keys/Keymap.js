.pragma library

// Every key the window answers to, in one table. The shortcut sheet and the
// status-bar hints are drawn from this table, so they cannot drift from what
// the keys actually do.
//
// The window is in exactly one context at a time; App.qml derives it from
// what is on screen. A text-entry context binds no bare letters, so typing
// never fires an action.

var CONTEXTS = ["browse", "player", "search", "page", "dialog"]
var BROWSE = ["browse"]
var ANY = ["*"]

var BINDINGS = [
  // Moving
  { id: "left", keys: ["h", "Left"], contexts: BROWSE, group: "Moving", label: "Move left" },
  { id: "right", keys: ["l", "Right"], contexts: BROWSE, group: "Moving", label: "Move right" },
  { id: "up", keys: ["k", "Up"], contexts: BROWSE, group: "Moving", label: "Move up",
    hintKey: "h j k l", hint: { browse: "move" } },
  { id: "down", keys: ["j", "Down"], contexts: BROWSE, group: "Moving", label: "Move down" },
  { id: "pageDown", keys: ["PgDown", "Ctrl+D"], contexts: BROWSE, group: "Moving", label: "Page down" },
  { id: "pageUp", keys: ["PgUp", "Ctrl+U"], contexts: BROWSE, group: "Moving", label: "Page up" },
  { id: "first", keys: ["Home", "g"], contexts: BROWSE, group: "Moving", label: "First" },
  { id: "last", keys: ["End", "Shift+G"], contexts: BROWSE, group: "Moving", label: "Last" },
  { id: "open", keys: ["Return", "Enter", "o"], contexts: BROWSE, group: "Moving", label: "Open",
    hintKey: "enter", hint: { browse: "open" } },
  { id: "back", keys: ["Escape"], contexts: ANY, group: "Moving", label: "Back, or close the player",
    hintKey: "esc", hint: { player: "close", page: "back", search: "cancel", dialog: "cancel" } },
  { id: "backAlt", keys: ["Backspace"], contexts: BROWSE, group: "Moving", label: "Back" },

  // Watching
  { id: "play", keys: ["p"], contexts: BROWSE, group: "Watching", label: "Play or resume",
    hintKey: "p", hint: { browse: "play" } },
  { id: "restart", keys: ["Shift+P"], contexts: BROWSE, group: "Watching", label: "Play from the start" },
  { id: "playMpv", keys: ["m"], contexts: BROWSE, group: "Watching", label: "Play in mpv" },
  { id: "watched", changes: true, keys: ["w"], contexts: BROWSE, group: "Watching", label: "Mark watched or unwatched",
    hintKey: "w", hint: { browse: "watched" } },
  { id: "favorite", changes: true, keys: ["f"], contexts: BROWSE, group: "Watching", label: "Favourite or unfavourite" },
  { id: "menu", keys: ["."], contexts: BROWSE, group: "Watching", label: "More actions..." },

  // The player
  { id: "playPause", keys: ["Space", "k"], contexts: ["player"], group: "Player", label: "Play or pause",
    hintKey: "space", hint: { player: "pause" } },
  { id: "seekBack", keys: ["Left", "j"], contexts: ["player"], group: "Player", label: "Back 10 seconds (presses add up)",
    hintKey: "← →", hint: { player: "-10 / +30 s" } },
  { id: "seekForward", keys: ["Right", "l"], contexts: ["player"], group: "Player", label: "Forward 30 seconds (presses add up)" },
  { id: "seekBackSmall", keys: ["Shift+Left", "Shift+J"], contexts: ["player"], group: "Player", label: "Back 5 seconds" },
  { id: "seekForwardSmall", keys: ["Shift+Right", "Shift+L"], contexts: ["player"], group: "Player", label: "Forward 5 seconds" },
  { id: "volumeUp", keys: ["Up"], contexts: ["player"], group: "Player", label: "Volume up" },
  { id: "volumeDown", keys: ["Down"], contexts: ["player"], group: "Player", label: "Volume down" },
  { id: "mute", keys: ["m"], contexts: ["player"], group: "Player", label: "Mute or unmute" },
  { id: "speedUp", keys: ["Ctrl+Up"], contexts: ["player"], group: "Player", label: "Faster" },
  { id: "speedDown", keys: ["Ctrl+Down"], contexts: ["player"], group: "Player", label: "Slower" },
  { id: "skipSegment", keys: ["s"], contexts: ["player"], group: "Player", label: "Skip the intro, recap or credits",
    hintKey: "s", hint: { player: "skip" } },
  { id: "subtitles", keys: ["t", "c"], contexts: ["player"], group: "Player", label: "Subtitles on or off" },
  { id: "subtitlePicker", keys: ["Shift+T"], contexts: ["player"], group: "Player", label: "Choose subtitles..." },
  { id: "audioPicker", keys: ["a"], contexts: ["player"], group: "Player", label: "Choose the audio track..." },
  { id: "nextChapter", keys: ["PgDown"], contexts: ["player"], group: "Player", label: "Next chapter" },
  { id: "previousChapter", keys: ["PgUp"], contexts: ["player"], group: "Player", label: "Previous chapter" },
  { id: "nextEpisode", keys: ["Shift+N"], contexts: ["player"], group: "Player", label: "Next episode",
    hintKey: "N", hint: { player: "next" } },
  { id: "fullscreenPlayer", keys: ["f"], contexts: ["player"], group: "Player", label: "Full screen" },
  { id: "playbackInfo", keys: ["i"], contexts: ["player"], group: "Player", label: "How it is playing" },
  { id: "continueInMpv", keys: ["Shift+M"], contexts: ["player"], group: "Player", label: "Continue in mpv" },
  { id: "closePlayer", keys: ["q", "Backspace"], contexts: ["player"], group: "Player", label: "Stop and close the player" },

  // Going places
  { id: "search", keys: ["/", "Ctrl+K"], contexts: ["browse", "page"], group: "Going places", label: "Search",
    hintKey: "/", hint: { browse: "search" } },
  { id: "section", keys: ["Alt+1", "Alt+2", "Alt+3", "Alt+4", "Alt+5", "Alt+6", "Alt+7", "Alt+8", "Alt+9", "Alt+0"],
    contexts: ["browse", "page"], group: "Going places", label: "Go to a sidebar section" },
  { id: "historyBack", keys: ["Alt+Left"], contexts: ["browse", "page"], group: "Going places", label: "Back to the previous page" },
  { id: "historyForward", keys: ["Alt+Right"], contexts: ["browse", "page"], group: "Going places", label: "Forward again" },
  { id: "settings", keys: ["Ctrl+,"], contexts: ["browse", "page", "search"], group: "Going places", label: "Settings" },
  { id: "sidebar", keys: ["Ctrl+B"], contexts: ["browse", "page"], group: "Going places", label: "Show or hide the sidebar" },
  { id: "refresh", keys: ["r", "F5"], contexts: BROWSE, group: "Going places", label: "Reload" },
  { id: "fullscreen", keys: ["F11"], contexts: ANY, group: "Going places", label: "Focus mode: hide the bars and sidebar" },
  { id: "help", keys: ["?", "Shift+?"], contexts: ["browse", "player"], group: "Going places", label: "All shortcuts",
    hintKey: "?", hint: { browse: "keys" } }
]

function contextFor(state) {
  if (state.dialog) return "dialog"
  if (state.page) return "page"
  if (state.searchFocused) return "search"
  if (state.player) return "player"
  return "browse"
}

function matches(binding, context) {
  return binding.contexts.indexOf("*") >= 0 || binding.contexts.indexOf(context) >= 0
}

// Text-entry contexts take only modified keys, Escape and function keys.
function typingSafe(sequence) {
  return /^(Ctrl|Alt|Meta)\+/.test(sequence) || sequence === "Escape" || /^F\d+$/.test(sequence)
}

function textContext(context) {
  return context === "search" || context === "page" || context === "dialog"
}

// [{ id, sequence }] live in this context.
function sequencesFor(context) {
  var out = []
  var seen = {}
  for (var i = 0; i < BINDINGS.length; i++) {
    var b = BINDINGS[i]
    if (!matches(b, context)) continue
    for (var k = 0; k < b.keys.length; k++) {
      var seq = b.keys[k]
      if (textContext(context) && !typingSafe(seq)) continue
      if (seen[seq]) continue
      seen[seq] = true
      // Holding a key that changes the library must not repeat it down a row.
      out.push({ id: b.id, sequence: seq, repeat: b.changes !== true })
    }
  }
  return out
}

function hintsFor(context) {
  var out = []
  for (var i = 0; i < BINDINGS.length; i++) {
    var b = BINDINGS[i]
    if (!b.hint || !b.hint[context] || !matches(b, context)) continue
    out.push({ key: b.hintKey || b.keys[0], label: b.hint[context] })
  }
  return out
}

function readable(sequence) {
  return String(sequence)
    .replace("Return", "enter").replace("Escape", "esc").replace("Delete", "del")
    .replace("PgDown", "pgdn").replace("PgUp", "pgup").replace("Shift+?", "?")
}

function unique(list) {
  var out = []
  for (var i = 0; i < list.length; i++) {
    var key = String(list[i]).toLowerCase()
    var seen = false
    for (var j = 0; j < out.length; j++) if (String(out[j]).toLowerCase() === key) seen = true
    if (!seen) out.push(list[i])
  }
  return out
}

function helpGroups() {
  var groups = []
  var index = {}
  for (var i = 0; i < BINDINGS.length; i++) {
    var b = BINDINGS[i]
    if (index[b.group] === undefined) {
      index[b.group] = groups.length
      groups.push({ title: b.group, rows: [] })
    }
    var keys = b.id === "section" ? ["Alt+1 … Alt+0"] : unique(b.keys.map(readable))
    groups[index[b.group]].rows.push({ keys: keys.join("  "), label: b.label })
  }
  return groups
}

// Two bindings in one context on one key would make a key mean two things.
function conflicts() {
  var found = []
  for (var c = 0; c < CONTEXTS.length; c++) {
    var context = CONTEXTS[c]
    var owner = {}
    for (var i = 0; i < BINDINGS.length; i++) {
      var b = BINDINGS[i]
      if (!matches(b, context)) continue
      for (var k = 0; k < b.keys.length; k++) {
        var seq = b.keys[k]
        if (owner[seq] && owner[seq] !== b.id) found.push(context + ": " + seq + " is " + owner[seq] + " and " + b.id)
        owner[seq] = b.id
      }
    }
  }
  return found
}
