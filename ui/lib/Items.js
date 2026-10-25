.pragma library

// Small operations on the card lists the views hold.

// The same list with one item's watched/favourite state replaced, so a
// mark shows at once without reloading the page.
function patchUser(list, id, user) {
  if (!list || !id || !user) return list
  var changed = false
  var out = list.map(function(item) {
    if (!item || item.id !== id) return item
    changed = true
    var next = Object.assign({}, item)
    next.user = Object.assign({}, item.user || {}, user)
    return next
  })
  return changed ? out : list
}

function patchRows(rows, id, user) {
  if (!rows) return rows
  return rows.map(function(row) {
    if (!row || !row.items) return row
    var items = patchUser(row.items, id, user)
    if (items === row.items) return row
    var next = Object.assign({}, row)
    next.items = items
    return next
  })
}

// A second page appended to the first, without repeats.
function appendUnique(list, more) {
  var seen = {}
  for (var i = 0; i < list.length; i++) seen[list[i].id] = true
  var out = list.slice()
  for (var j = 0; j < more.length; j++) if (more[j] && !seen[more[j].id]) { seen[more[j].id] = true; out.push(more[j]) }
  return out
}
