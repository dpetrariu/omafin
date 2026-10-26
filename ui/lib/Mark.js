.pragma library

// Omafin's mark: the film glyph with Jellyfin's logo in its bottom-right corner
// (Material Design Icons, Apache-2.0; the logo from the project's own SVG,
// Jellyfin's under CC BY-SA 4.0, as this adaptation is; see README).
// One colour, written into the SVG itself, so it draws the same with or
// without a GPU;
// ui/assets/icon.svg is the launcher icon: the same drawing in Tokyo Night's
// accent (a launcher icon is a file, so it cannot follow the theme).

var SVG = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\" width=\"256\" height=\"256\"><defs><mask id=\"cut\" maskUnits=\"userSpaceOnUse\" x=\"-2\" y=\"-2\" width=\"28\" height=\"28\"><rect x=\"-2\" y=\"-2\" width=\"28\" height=\"28\" fill=\"white\"/><g transform=\"translate(19.4 19.2) scale(0.01822) translate(-256 -247)\"><path d=\"M256,201.6c-20.4,0-86.2,119.3-76.2,139.4s142.5,19.9,152.4,0S276.5,201.6,256,201.6z\" fill=\"black\" stroke=\"black\" stroke-width=\"142.7\" stroke-linejoin=\"round\"/><path d=\"M256,23.3c-61.6,0-259.8,359.4-229.6,420.1s429.3,60,459.2,0S317.6,23.3,256,23.3zM406.5,390.8c-19.6,39.3-281.1,39.8-300.9,0s110.1-275.3,150.4-275.3S426.1,351.4,406.5,390.8z\" fill=\"black\" stroke=\"black\" stroke-width=\"142.7\" stroke-linejoin=\"round\"/></g></mask></defs><path d=\"M20.84 2.18L16.91 2.96L19.65 6.5L21.62 6.1L20.84 2.18M13.97 3.54L12 3.93L14.75 7.46L16.71 7.07L13.97 3.54M9.07 4.5L7.1 4.91L9.85 8.44L11.81 8.05L9.07 4.5M4.16 5.5L3.18 5.69C2.1 5.9 1.39 6.96 1.61 8.04L2 10L6.9 9.03L4.16 5.5M20 12V20H4V12H20M22 10H2V20C2 21.11 2.9 22 4 22H20C21.11 22 22 21.11 22 20V10Z\" fill=\"%COLOR%\" mask=\"url(#cut)\"/><g transform=\"translate(19.4 19.2) scale(0.01822) translate(-256 -247)\"><path d=\"M256,201.6c-20.4,0-86.2,119.3-76.2,139.4s142.5,19.9,152.4,0S276.5,201.6,256,201.6z\" fill=\"%COLOR%\" fill-rule=\"evenodd\"/><path d=\"M256,23.3c-61.6,0-259.8,359.4-229.6,420.1s429.3,60,459.2,0S317.6,23.3,256,23.3zM406.5,390.8c-19.6,39.3-281.1,39.8-300.9,0s110.1-275.3,150.4-275.3S426.1,351.4,406.5,390.8z\" fill=\"%COLOR%\" fill-rule=\"evenodd\"/></g></svg>"

function hex(v) {
  var s = Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16)
  return s.length < 2 ? "0" + s : s
}

// The mark in colour (r, g, b from 0 to 1), as an image URL.
function url(r, g, b) {
  return "data:image/svg+xml;base64," + Qt.btoa(SVG.replace(/%COLOR%/g, "#" + hex(r) + hex(g) + hex(b)))
}
