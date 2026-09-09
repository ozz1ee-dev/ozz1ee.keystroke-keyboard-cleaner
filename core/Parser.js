.pragma library

// Pure logic for the keyboard cleaner extension: the query shapes it
// answers, how it parses a typed duration, what rows it shows and the
// argv it runs. No processes, no QML here; everything is unit-tested
// in tests/tst_parser.qml.
//
// The plugin blocks every keyboard and pointing device for a chosen
// duration so the user can wipe them down. A query like `wipe 5m`
// parses into a single "start a 5 minute block" row; a typed query
// with no verb still matches via the `pattern` regexes, the same
// way Keystroke's own providers do.

var DEFAULT_KEY = "ozz1ee.keystroke-keyboard-cleaner"
var NAME = "Keyboard Cleaner"
var ICON = "󰌓"            // nf-md-keyboard, the same glyph the Omalaunch extension uses
var COLOR = "#7aa2f7"
var MIN_SECONDS = 1
var MAX_SECONDS = 5 * 60            // 5 minutes, hard cap so an accidental "lock 1h"
// does not strand the user without input for an hour. The Python helper
// keeps its own 60-minute guard, but the UI never offers anything past 5
// minutes — long enough to clean a keyboard, short enough that a slip
// does not lock someone out of their session.

// -------------------------------------------------------------------------
// patterns
//
// What Keystroke tests before calling query(): a match lifts the row above
// the assistant hand-offs (Codex sits at 5, Google at 2). We only declare
// shapes we genuinely answer: a verb followed by a duration. The
// bare-duration shape (no verb) catches `30s` typed at the root.
//
// All regexes are anchored at the start so they don't match inside an
// unrelated query like "settings". Flags limited to "i".

var VERB = "(wipe|wash|clean|block)"

var PATTERNS = [
  { id: "duration-suffix", regex: "^\\s*" + VERB + "\\b\\s*\\d+\\s*s(ec(ond)?s?)?\\b", flags: "i", boost: 18,
    example: "wipe 30s", description: "Block input for N seconds" },
  { id: "duration-minute", regex: "^\\s*" + VERB + "\\b\\s*\\d+\\s*m(in(ute)?s?)?\\b", flags: "i", boost: 18,
    example: "block 5m", description: "Block input for N minutes" },
  { id: "duration-hour", regex: "^\\s*" + VERB + "\\b\\s*\\d+\\s*h(our)?s?\\b", flags: "i", boost: 18,
    example: "block 1h", description: "Block input for N hours" },
  // Bare-duration patterns carry a low boost on purpose. They overlap
  // visually with the bundled Timer extension (which uses the same
  // shapes: `5m`, `1h`), so we let Timer keep the high tier and only
  // surface our row when Timer is disabled or returns nothing for the
  // query. The verb-shaped variants above stay at 18 because they do
  // not overlap with Timer.
  { id: "duration-bare-seconds", regex: "^\\s*\\d+\\s*s(ec(ond)?s?)?\\b", flags: "i", boost: 4,
    example: "30s", description: "N seconds, no verb" },
  { id: "duration-bare-minutes", regex: "^\\s*\\d+\\s*m(in(ute)?s?)?\\b", flags: "i", boost: 4,
    example: "5m", description: "N minutes, no verb" },
  { id: "duration-bare-hours", regex: "^\\s*\\d+\\s*h(our)?s?\\b", flags: "i", boost: 4,
    example: "1h", description: "N hours, no verb" },
  { id: "verb-only", regex: "^\\s*" + VERB + "\\b", flags: "i", boost: 6,
    example: "wipe", description: "A verb without a duration falls back to the default length" }
]

// -------------------------------------------------------------------------
// parsing

// Pull the verb (or "") and the duration in seconds (or null) out of a
// query. The verb is matched first and stripped, so "block keyboard 5m"
// returns { verb: "block", seconds: 300, label: "keyboard" }.
//
// Anything that does not look like a block-this-many-seconds request
// returns null, which `query()` uses to decide to fall back to the
// extension's own navigation row.
//
// Capture-group note: VERB is wrapped in `(...|...)` for alternation, and
// the inner `(wipe|wash|...)` is itself a capture group. So a regex like
// `^...(` + VERB + `)...(\d+)...` has the digits in group 3 (group 1 is
// the outer wrap, group 2 is the inner alternation). Forgetting that
// silently reads the verb as the digit count and clamps to MIN_SECONDS.
function parseQuery(rawQuery) {
  var q = String(rawQuery || "").trim()
  if (!q) return null
  var m

  // Verb + seconds, minutes or hours. Group 3 is the digits.
  m = new RegExp("^\\s*(" + VERB + ")\\b\\s*(\\d+)\\s*s(ec(ond)?s?)?\\b(.*)$", "i").exec(q)
  if (m) return { verb: m[1].toLowerCase(), seconds: clampSeconds(Number(m[3])), label: String(m[6] || "").trim() }

  m = new RegExp("^\\s*(" + VERB + ")\\b\\s*(\\d+)\\s*m(in(ute)?s?)?\\b(.*)$", "i").exec(q)
  if (m) return { verb: m[1].toLowerCase(), seconds: clampSeconds(Number(m[3]) * 60), label: String(m[7] || "").trim() }

  m = new RegExp("^\\s*(" + VERB + ")\\b\\s*(\\d+)\\s*h(our)?s?\\b(.*)$", "i").exec(q)
  if (m) return { verb: m[1].toLowerCase(), seconds: clampSeconds(Number(m[3]) * 3600), label: String(m[5] || "").trim() }

  // Verb only, no duration. Group 1 is the verb (outer wrap), group 2 is
  // the inner alternation, group 3 is the trailing label.
  m = new RegExp("^\\s*(" + VERB + ")\\b(.*)$", "i").exec(q)
  if (m) return { verb: m[1].toLowerCase(), seconds: 0, label: String(m[3] || "").trim() }

  // Bare duration, no verb. Group 1 is the digits.
  m = new RegExp("^\\s*(\\d+)\\s*s(ec(ond)?s?)?\\b(.*)$", "i").exec(q)
  if (m) return { verb: "", seconds: clampSeconds(Number(m[1])), label: String(m[4] || "").trim() }

  m = new RegExp("^\\s*(\\d+)\\s*m(in(ute)?s?)?\\b(.*)$", "i").exec(q)
  if (m) return { verb: "", seconds: clampSeconds(Number(m[1]) * 60), label: String(m[5] || "").trim() }

  m = new RegExp("^\\s*(\\d+)\\s*h(our)?s?\\b(.*)$", "i").exec(q)
  if (m) return { verb: "", seconds: clampSeconds(Number(m[1]) * 3600), label: String(m[3] || "").trim() }

  return null
}

// Clamp to MIN_SECONDS..MAX_SECONDS and round.
function clampSeconds(n) {
  n = Math.round(Number(n) || 0)
  if (n < MIN_SECONDS) return MIN_SECONDS
  if (n > MAX_SECONDS) return MAX_SECONDS
  return n
}

// -------------------------------------------------------------------------
// display

// "5 minutes", "1 minute 30 seconds", "30 seconds", "2 hours", "1 hour 30 minutes".
// Used in row subtitles and in the live view.
function describeDuration(seconds) {
  seconds = Math.max(0, Math.round(Number(seconds) || 0))
  if (seconds === 0) return "0 seconds"
  if (seconds < 60) return seconds + " second" + (seconds === 1 ? "" : "s")
  if (seconds < 3600) {
    var m = Math.floor(seconds / 60), s = seconds % 60
    var parts = []
    if (m > 0) parts.push(m + " minute" + (m === 1 ? "" : "s"))
    if (s > 0) parts.push(s + " second" + (s === 1 ? "" : "s"))
    return parts.join(" ")
  }
  var h = Math.floor(seconds / 3600), rem = seconds % 3600, mm = Math.floor(rem / 60), ss = rem % 60
  var parts = [h + " hour" + (h === 1 ? "" : "s")]
  if (mm > 0) parts.push(mm + " minute" + (mm === 1 ? "" : "s"))
  if (ss > 0) parts.push(ss + " second" + (ss === 1 ? "" : "s"))
  return parts.join(" ")
}

// Short form for the row subtitle: "30s", "5m", "1m 30s", "2h".
function shortDuration(seconds) {
  seconds = Math.max(0, Math.round(Number(seconds) || 0))
  if (seconds === 0) return "0s"
  if (seconds < 60) return seconds + "s"
  if (seconds < 3600) {
    var m = Math.floor(seconds / 60), s = seconds % 60
    return s ? (m + "m " + s + "s") : (m + "m")
  }
  var h = Math.floor(seconds / 3600), rem = seconds % 3600, mm = Math.floor(rem / 60)
  return mm ? (h + "h " + mm + "m") : (h + "h")
}

// -------------------------------------------------------------------------
// argv

// The Python helper takes a single integer seconds argument; we hand it
// the absolute path so a caller who has not put /usr/bin on PATH (rare,
// but possible inside quickshell) still finds it. argv is literal:
// `seconds` is an integer we built ourselves, no quoting risk.
function blockArgv(command, parsed) {
  return [command, String(parsed.seconds)]
}

// -------------------------------------------------------------------------
// rows

// One row per parsed query. Returns [] when the query does not parse:
// the caller then either shows the navigation row (root, no query) or
// nothing (root, no match).
function blockRow(parsed, state) {
  var title = "Block input for " + describeDuration(parsed.seconds)
  var subtitle = parsed.label ? "Label: " + parsed.label : "Wipe the keyboard, then unlock"
  var row = {
    id: "block",
    title: title,
    subtitle: subtitle,
    icon: ICON,
    iconSource: state.iconSource,
    color: COLOR,
    section: NAME,
    verb: "Block",
    tier: "fallback",
    score: 1,
    keywords: "wipe clean wash block lock keyboard input " + (parsed.verb || ""),
    description: "blocks every keyboard and pointing device for " + describeDuration(parsed.seconds)
                  + (parsed.label ? ", labelled \"" + parsed.label + "\"" : ""),
    hint: "ctrl \u21b5 settings",
    action: { type: "block", seconds: parsed.seconds, label: parsed.label, verb: parsed.verb },
    altAction: { type: "navigate", scope: state.key, title: NAME }
  }
  // Anything past a minute is a long block: the user can no longer reach
  // the palette to cancel, so ask first. The host renders the confirm
  // dialog with the row's `confirm` text and the Enter key as the default
  // action ("Block input for 1 minute?" / Enter => confirm => wipe).
  if (parsed.seconds > 60) {
    row.confirm = "Block input for " + describeDuration(parsed.seconds)
      + "? The keyboard will be blocked for that long — you cannot " +
      "cancel from the palette during the window."
  }
  return row
}

// The root navigation row (no query). Lives at the palette root so
// `keyboard` / `wipe` finds the extension even before a duration is
// typed.
function navRow(state) {
  return {
    id: "nav",
    title: NAME,
    subtitle: "Block the keyboard and pointer for a chosen duration",
    icon: ICON,
    iconSource: state.iconSource,
    color: COLOR,
    section: "Extensions",
    verb: "Open",
    score: 30,
    keywords: "wipe clean wash block lock keyboard input keys",
    description: "keyboard cleaner, blocks input so you can wipe safely",
    action: { type: "navigate", scope: state.key, title: NAME }
  }
}

// The extension's own screen rows (scope === key).
function screenRows(state) {
  var rows = []
  var fresh = {
    id: "fresh-15", title: "Block for 15 seconds", subtitle: "Quick wipe", icon: ICON, iconSource: state.iconSource,
    section: NAME, verb: "Block", keywords: "wipe quick short", description: "15 second wipe",
    action: { type: "block", seconds: 15, label: "", verb: "" }
  }
  rows.push(fresh)
  rows.push({
    id: "fresh-30", title: "Block for 30 seconds", subtitle: "Standard wipe", icon: ICON, iconSource: state.iconSource,
    section: NAME, verb: "Block", keywords: "wipe standard", description: "30 second wipe",
    action: { type: "block", seconds: 30, label: "", verb: "" }
  })
  rows.push({
    id: "fresh-60", title: "Block for 1 minute", subtitle: "Deep wipe", icon: ICON, iconSource: state.iconSource,
    section: NAME, verb: "Block", keywords: "wipe deep long", description: "1 minute wipe",
    action: { type: "block", seconds: 60, label: "", verb: "" }
  })
  return rows
}
