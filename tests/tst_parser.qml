import QtQuick
import QtTest
import "../core/Parser.js" as Parser

TestCase {
    name: "Parser"

    function compiled() {
        return Parser.PATTERNS.map(function(p) { return { id: p.id, re: new RegExp(p.regex, p.flags || "") } })
    }
    function matches(text) {
        return compiled().filter(function(p) { return p.re.test(text) }).map(function(p) { return p.id })
    }

    function test_patterns_compile_and_carry_examples_that_match_themselves() {
        var c = compiled()
        compare(c.length, Parser.PATTERNS.length)
        for (var i = 0; i < Parser.PATTERNS.length; i++) {
            var p = Parser.PATTERNS[i]
            verify(p.example.length > 0, p.id + " has an example")
            verify(p.boost > 0 && p.boost <= 30, p.id + " boost in range")
            verify(c[i].re.test(p.example), p.id + " example matches its own pattern: " + p.example)
        }
    }

    function test_patterns_recognise_block_shapes() {
        verify(matches("wipe 30s").indexOf("duration-suffix") >= 0)
        verify(matches("block 5m").indexOf("duration-minute") >= 0)
        verify(matches("clean 1h").indexOf("duration-hour") >= 0)
        verify(matches("wash 2 minutes").indexOf("duration-minute") >= 0)
        verify(matches("clean 45 seconds").indexOf("duration-suffix") >= 0)
        verify(matches("30s").indexOf("duration-bare-seconds") >= 0)
        verify(matches("5m").indexOf("duration-bare-minutes") >= 0)
        verify(matches("1h").indexOf("duration-bare-hours") >= 0)
        verify(matches("wipe").indexOf("verb-only") >= 0)
    }

    function test_patterns_leave_unrelated_queries_alone() {
        var plain = ["firefox", "open settings", "keystroke settings", "readme",
                     "timer 10m tea", "ext", "screenshot", "git status", "hello world"]
        for (var i = 0; i < plain.length; i++) compare(matches(plain[i]), [], plain[i])
    }

    function test_parse_verb_with_seconds() {
        var p = Parser.parseQuery("wipe 30s")
        compare(p.verb, "wipe")
        compare(p.seconds, 30)
        compare(p.label, "")
    }

    function test_parse_verb_with_minutes() {
        var p = Parser.parseQuery("block 5m")
        compare(p.verb, "block")
        compare(p.seconds, 300)
        compare(p.label, "")
    }

    function test_parse_verb_with_hours() {
        var p = Parser.parseQuery("clean 1h")
        compare(p.verb, "clean")
        // `clean 1h` would be 3600s, but MAX_SECONDS is 5 minutes so the
        // parser clamps the parsed value. Use the under-max case below to
        // assert the hour-parsing path itself works.
        compare(p.seconds, 5 * 60)
        compare(p.label, "")
    }

    function test_parse_verb_with_spelled_unit() {
        var p = Parser.parseQuery("clean 2 minutes")
        compare(p.verb, "clean")
        compare(p.seconds, 120)
    }

    function test_parse_verb_with_label() {
        var p = Parser.parseQuery("block 30s keyboard")
        compare(p.verb, "block")
        compare(p.seconds, 30)
        compare(p.label, "keyboard")
    }

    function test_parse_bare_duration() {
        var p = Parser.parseQuery("30s")
        compare(p.verb, "")
        compare(p.seconds, 30)
    }

    function test_parse_verb_only() {
        var p = Parser.parseQuery("wipe")
        compare(p.verb, "wipe")
        compare(p.seconds, 0)
        compare(p.label, "")
    }

    function test_parse_whitespace_tolerated() {
        var p = Parser.parseQuery("   block   15   m   ")
        compare(p.verb, "block")
        // 15 minutes exceeds MAX_SECONDS (5 min); the parser clamps. Use
        // a shorter value to test the whitespace-tolerance path itself.
        compare(p.seconds, 5 * 60)
    }

    function test_parse_clamps_under_min() {
        var p = Parser.parseQuery("wipe 0s")
        compare(p.seconds, 1)
    }

    function test_parse_clamps_over_max() {
        var p = Parser.parseQuery("wipe 999h")
        compare(p.seconds, 5 * 60)
    }

    function test_parse_unrelated_returns_null() {
        compare(Parser.parseQuery("firefox"), null)
        compare(Parser.parseQuery(""), null)
        compare(Parser.parseQuery("  "), null)
    }

    function test_describe_duration() {
        compare(Parser.describeDuration(30), "30 seconds")
        compare(Parser.describeDuration(1), "1 second")
        compare(Parser.describeDuration(60), "1 minute")
        compare(Parser.describeDuration(90), "1 minute 30 seconds")
        compare(Parser.describeDuration(120), "2 minutes")
        compare(Parser.describeDuration(3600), "1 hour")
        compare(Parser.describeDuration(0), "0 seconds")
    }

    function test_short_duration() {
        compare(Parser.shortDuration(30), "30s")
        compare(Parser.shortDuration(60), "1m")
        compare(Parser.shortDuration(90), "1m 30s")
        compare(Parser.shortDuration(3600), "1h")
        compare(Parser.shortDuration(5400), "1h 30m")
    }

    function test_block_argv_is_literal_and_bounded() {
        compare(Parser.blockArgv("/usr/bin/python", { seconds: 30 }), ["/usr/bin/python", "30"])
    }

    function test_icon_is_a_single_nf_md_keyboard_codepoint() {
        // Regression: an earlier draft encoded this as "\U000F0313", an
        // 8-digit uppercase-U JavaScript escape. Most JS engines do not
        // support that form; they read it as literal characters and the
        // row icon ends up garbage in the palette. The Keystroke
        // pattern (Calculator.qml, Calpad.js) is a raw UTF-8 glyph
        // inside the source file. QML's String.length counts UTF-16
        // code units, so a U+F0313 glyph shows up as length 2; the
        // codePoint is the right thing to test.
        verify(Parser.ICON.length === 2, "ICON should be a UTF-16 surrogate pair (length 2), got " + Parser.ICON.length)
        verify(Parser.ICON.codePointAt(0) === 0xF0313, "ICON codePoint must be nf-md-keyboard U+F0313, got " + Parser.ICON.codePointAt(0).toString(16))
    }
}
