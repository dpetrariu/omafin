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
  circle: 0xF0766         // circle-outline
}

function glyph(name) {
  var code = GLYPHS[name]
  if (code === undefined) return ""
  return String.fromCodePoint(code)
}
