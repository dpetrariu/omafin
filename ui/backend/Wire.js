.pragma library

// The frames that cross stdin/stdout. One JSON object per line.

function request(id, method, params) {
  return JSON.stringify({ jsonrpc: "2.0", id: id, method: method, params: params || {} }) + "\n"
}

// A reply to one of our requests, or null when the line is something else.
function response(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null
  if (value.jsonrpc !== "2.0" || typeof value.id !== "string") return null
  var success = Object.prototype.hasOwnProperty.call(value, "result")
  var failure = Object.prototype.hasOwnProperty.call(value, "error")
  if (success === failure) return null
  if (failure && (!value.error || typeof value.error.message !== "string")) return null
  return value
}

// Only the backend's declared events may arrive without a request.
var EVENTS = ["server.changed", "playback.changed", "downloads.changed"]

function notification(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null
  if (value.jsonrpc !== "2.0" || Object.prototype.hasOwnProperty.call(value, "id")) return null
  if (EVENTS.indexOf(value.method) < 0) return null
  if (!value.params || typeof value.params !== "object") return null
  return value
}

function parse(line) {
  try { return JSON.parse(line) } catch (e) { return null }
}
