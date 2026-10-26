.pragma library

// The window's icons by name: Nerd Font glyphs from the Material Design
// range (nf-md-*), the same set the Omarchy shell draws its own icons from,
// so these verbs look like the desktop's. Outline variants where they exist.
// Codepoints checked against Nerd Fonts' glyphnames.json.

var GLYPHS = {
  logo: 0xF0FCF,          // movie-open-outline
  home: 0xF06A1,          // home-outline
  movies: 0xF0DDD,        // movie-outline
  shows: 0xF0502,         // television
  collections: 0xF0D18,   // filmstrip-box-multiple
  folder: 0xF0256,        // folder-outline
  playlists: 0xF0411,     // playlist-play
  music: 0xF0F74,         // music-note-outline
  books: 0xF0B63,         // book-open-outline
  favorite: 0xF02D5,      // heart-outline
  favoriteOn: 0xF02D1,    // heart
  played: 0xF05E1,        // check-circle-outline
  playedOn: 0xF05E0,      // check-circle
  play: 0xF040A,          // play
  playCircle: 0xF040C,    // play-circle
  pause: 0xF03E4,         // pause
  next: 0xF04AD,          // skip-next
  previous: 0xF04AE,      // skip-previous
  skip: 0xF04AC,          // skip-forward
  rewind: 0xF0D2A,        // rewind-10
  forward10: 0xF0D71,     // fast-forward-10
  volume: 0xF057E,        // volume-high
  volumeLow: 0xF0580,     // volume-medium
  mute: 0xF0581,          // volume-off
  subtitles: 0xF0A17,     // subtitles-outline
  audio: 0xF05CA,         // translate
  speed: 0xF04C5,         // speedometer
  quality: 0xF07CF,       // high-definition
  chapters: 0xF0279,      // format-list-bulleted
  video: 0xF0BDC,         // video-outline
  external: 0xF03CC,      // open-in-new
  person: 0xF0013,        // account-outline
  people: 0xF0B58,        // account-group-outline
  star: 0xF04CE,          // star
  clock: 0xF0150,         // clock-outline
  calendar: 0xF0B66,      // calendar-blank-outline
  fullscreen: 0xF0293,    // fullscreen
  fullscreenExit: 0xF0294, // fullscreen-exit
  grid: 0xF11D9,          // view-grid-outline
  sort: 0xF04BF,          // sort-variant
  filter: 0xF0233,        // filter-outline
  shuffle: 0xF049F,       // shuffle-variant
  restart: 0xF0709,       // restart
  info: 0xF02FD,          // information-outline
  chevronLeft: 0xF0141,   // chevron-left
  chevronRight: 0xF0142,  // chevron-right
  chevronDown: 0xF0140,   // chevron-down
  chevronUp: 0xF0143,     // chevron-up
  back: 0xF004D,          // arrow-left
  forward: 0xF0054,       // arrow-right
  close: 0xF0156,         // close
  search: 0xF0349,        // magnify
  settings: 0xF08BB,      // cog-outline
  refresh: 0xF0450,       // refresh
  server: 0xF048B,        // server
  cloudOff: 0xF0164,      // cloud-off-outline
  more: 0xF01D9,          // dots-vertical
  moreHorizontal: 0xF01D8, // dots-horizontal
  sidebar: 0xF10AA,       // dock-left
  warning: 0xF002A,       // alert-outline
  help: 0xF0625,          // help-circle-outline
  link: 0xF0339,          // link-variant
  check: 0xF012C,         // check
  plus: 0xF0415,          // plus
  minus: 0xF0374,         // minus
  trailer: 0xF05C3,       // youtube
  qr: 0xF0432,            // qrcode
  key: 0xF030B,           // key-variant
  signOut: 0xF0343,       // logout
  noImage: 0xF11D1,       // image-off-outline
  stack: 0xF09FE,         // layers-outline
  nextUp: 0xF0662,        // skip-next-circle-outline
  monitor: 0xF0379,       // monitor
  history: 0xF02DA,       // history
  tag: 0xF04FC,           // tag-outline
  eye: 0xF06D0,           // eye-outline
  eyeOff: 0xF06D1,        // eye-off-outline
  circle: 0xF0766,        // circle-outline
  download: 0xF0B8F,      // download-outline
  trash: 0xF0A7A,         // trash-can-outline
  downloaded: 0xF1465,    // download-circle-outline
  error: 0xF05D6,         // alert-circle-outline
  disk: 0xF02CA           // harddisk
}

// Where each icon's drawn shape really is, measured from the font
// (JetBrainsMono Nerd Font, rendered at 80 px): how far its visual centre
// sits right of the text box's centre, and above the baseline, both as a
// fraction of the font size. The font's own metrics do not say this
// reliably, and its icons hang off their advance by different amounts, so
// round buttons centre their icon by this table instead.
var OPTICAL = {
  logo: [0.1286, 0.3311],
  home: [0.1159, 0.2922],
  movies: [0.1206, 0.3681],
  shows: [0.1685, 0.369],
  collections: [0.1321, 0.3765],
  folder: [0.0914, 0.3548],
  playlists: [0.0847, 0.4262],
  music: [0.0772, 0.3492],
  books: [0.199, 0.357],
  favorite: [0.1158, 0.4297],
  favoriteOn: [0.1165, 0.4274],
  played: [0.114, 0.3545],
  playedOn: [0.1159, 0.3606],
  play: [-0.0773, 0.3598],
  playCircle: [0.1157, 0.3601],
  pause: [0.0001, 0.3574],
  next: [-0.0209, 0.3613],
  previous: [0.0211, 0.3612],
  skip: [0.0382, 0.3581],
  rewind: [0.0818, 0.3969],
  forward10: [0.1673, 0.397],
  volume: [0.0874, 0.3596],
  volumeLow: [-0.01, 0.3626],
  mute: [0.0747, 0.3631],
  subtitles: [0.1155, 0.3407],
  audio: [0.1714, 0.3453],
  speed: [0.1198, 0.3799],
  quality: [-0.0037, 0.3578],
  chapters: [0.0926, 0.3584],
  video: [0.0874, 0.3655],
  external: [0.0816, 0.373],
  person: [0.0347, 0.2923],
  people: [0.2003, 0.2946],
  star: [0.116, 0.318],
  clock: [0.1219, 0.3603],
  calendar: [0.0751, 0.3613],
  fullscreen: [0.0001, 0.3574],
  fullscreenExit: [0.0001, 0.3574],
  grid: [0.0751, 0.3678],
  sort: [-0.0047, 0.4352],
  filter: [0.0397, 0.4635],
  shuffle: [0.1438, 0.3626],
  restart: [0.0377, 0.3335],
  info: [0.1154, 0.358],
  chevronLeft: [0.0037, 0.3608],
  chevronRight: [-0.0009, 0.3547],
  chevronDown: [0.0001, 0.3602],
  chevronUp: [0.0001, 0.3587],
  back: [-0.015, 0.3544],
  forward: [0.0777, 0.3544],
  close: [0.0001, 0.3574],
  search: [0.0304, 0.3941],
  settings: [0.1062, 0.359],
  refresh: [0.0524, 0.3839],
  server: [0.0837, 0.3585],
  cloudOff: [0.193, 0.3546],
  more: [0.0001, 0.3589],
  moreHorizontal: [0.0359, 0.3592],
  sidebar: [0.0545, 0.3539],
  warning: [0.1589, 0.2319],
  help: [0.1194, 0.3746],
  link: [0.0849, 0.3606],
  check: [0.0656, 0.333],
  plus: [0.0001, 0.3574],
  minus: [0.0001, 0.3574],
  trailer: [0.1157, 0.3607],
  qr: [0.0714, 0.3641],
  key: [0.0951, 0.3875],
  signOut: [0.0226, 0.3585],
  noImage: [0.1007, 0.3472],
  stack: [0.0751, 0.3516],
  nextUp: [0.117, 0.3606],
  monitor: [0.1681, 0.3849],
  history: [0.1882, 0.3653],
  tag: [0.0657, 0.4105],
  eye: [0.1587, 0.3609],
  eyeOff: [0.1517, 0.3922],
  circle: [0.1149, 0.3609],
  download: [0.0001, 0.3291],
  trash: [0.0323, 0.3669],
  downloaded: [0.1153, 0.3584],
  error: [0.1157, 0.3623],
  disk: [0.0387, 0.3263]
}

function optical(name) {
  return OPTICAL[name] || null
}

function glyph(name) {
  var code = GLYPHS[name]
  if (code === undefined) return ""
  return String.fromCodePoint(code)
}
