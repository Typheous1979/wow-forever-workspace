import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from lua_lexer import tokenize, LuaSyntaxError  # noqa: E402
from lua_literal import parse_value, parse_doc_chunk, parse_assignments, LuaRef, to_jsonable  # noqa: E402


def kinds(src):
    toks, _ = tokenize(src)
    return [(t.kind, t.value) for t in toks[:-1]]


class LexerTests(unittest.TestCase):
    def test_comments_and_long_strings(self):
        toks, lx = tokenize(b"-- hi\nx = [==[a]]b]==] --[[ multi\nline ]] y")
        vals = [t.value for t in toks[:-1]]
        self.assertEqual(vals, ["x", "=", "a]]b", "y"])
        self.assertEqual(toks[3].line, 3)
        self.assertEqual(len(lx.comments), 2)

    def test_long_string_drops_first_newline_and_crlf(self):
        self.assertEqual(parse_value(b"[[\r\nline1\r\nline2]]"), "line1\nline2")

    def test_escapes(self):
        self.assertEqual(parse_value(rb'"a\tb\65\\\"q"'), 'a\tbA\\"q')
        _, lx = tokenize(rb'x = "\x41"')
        self.assertTrue(lx.notes)

    def test_backslash_newline(self):
        self.assertEqual(parse_value(b'"a\\\nb"'), "a\nb")

    def test_numbers(self):
        self.assertEqual(parse_value(b"0xFF"), 255)
        self.assertEqual(parse_value(b"3.76"), 3.76)
        self.assertEqual(parse_value(b"-1"), -1)
        self.assertEqual(parse_value(b"1e3"), 1000.0)
        self.assertEqual(parse_value(b".5"), 0.5)

    def test_lua52_tokens_emitted(self):
        ops = [v for k, v in kinds(b"a // b & c | d ~ e << f >> g ::lbl:: h ~= i") if k == "op"]
        for op in ("//", "&", "|", "~", "<<", ">>", "::", "~="):
            self.assertIn(op, ops)

    def test_goto_is_a_name_in_51(self):
        self.assertIn(("name", "goto"), kinds(b"goto done"))

    def test_crlf_line_numbers(self):
        toks, _ = tokenize(b"a\r\nb\r\n\r\nc")
        self.assertEqual([t.line for t in toks[:-1]], [1, 2, 4])

    def test_bom_flag(self):
        _, lx = tokenize(b"\xef\xbb\xbfx = 1")
        self.assertTrue(lx.has_bom)

    def test_unfinished_string(self):
        with self.assertRaises(LuaSyntaxError):
            tokenize(b'x = "abc\n"')


class LiteralTests(unittest.TestCase):
    def test_list_and_dict(self):
        self.assertEqual(parse_value(b"{1, 2, 3,}"), [1, 2, 3])
        self.assertEqual(parse_value(b"{a = 1; b = 'x'}"), {"a": 1, "b": "x"})
        self.assertEqual(parse_value(b"{}"), [])

    def test_mixed_and_bracket_keys(self):
        v = parse_value(b'{ "x", [5] = true, ["k k"] = { n = nil } }')
        self.assertEqual(v, {1: "x", 5: True, "k k": []})

    def test_positional_wins(self):
        self.assertEqual(parse_value(b'{ [1] = "a", "b" }'), ["b"])

    def test_refs(self):
        v = parse_value(b"{ SecretReturnsForAspect = { Enum.SecretAspect.Text }, Value = DEFAULT_X }")
        self.assertIsInstance(v["Value"], LuaRef)
        self.assertEqual(v["SecretReturnsForAspect"], ["Enum.SecretAspect.Text"])

    def test_rejects_calls(self):
        with self.assertRaises(LuaSyntaxError):
            parse_value(b"{ x = foo() }")

    def test_nested_deep(self):
        src = b"{" * 300 + b"1" + b"}" * 300
        v = parse_value(src)
        for _ in range(299):
            v = v[0]
        self.assertEqual(v, [1])

    def test_doc_chunk(self):
        src = b"""local Sound =
{
\tName = "Sound",
\tType = "System",
\tNamespace = "C_Sound",
\tFunctions =
\t{
\t\t{
\t\t\tName = "IsPlaying",
\t\t\tType = "Function",
\t\t\tSecretArguments = "AllowedWhenUntainted",
\t\t\tArguments = { { Name = "soundHandle", Type = "number", Nilable = false }, },
\t\t\tReturns = { { Name = "isPlaying", Type = "bool", Nilable = false }, },
\t\t},
\t},
\tEvents = { },
\tTables = { },
};

APIDocumentation:AddDocumentationTable(Sound);
"""
        name, t = parse_doc_chunk(src)
        self.assertEqual(name, "Sound")
        self.assertEqual(t["Namespace"], "C_Sound")
        self.assertEqual(t["Functions"][0]["Returns"][0]["Type"], "bool")

    def test_savedvariables(self):
        src = b"""
MyDB = {
\t["profiles"] = {
\t\t["Default"] = {
\t\t\t["scale"] = 1.25,
\t\t\t["inf"] = 1.#INF,
\t\t\t"first", -- [1]
\t\t},
\t},
\t["version"] = 3,
}
MyCharDB = nil
"""
        sv = parse_assignments(src)
        self.assertEqual(sv["MyDB"]["version"], 3)
        d = sv["MyDB"]["profiles"]["Default"]
        self.assertEqual(d[1], "first")
        self.assertEqual(d["scale"], 1.25)
        self.assertIsNone(sv["MyCharDB"])

    def test_jsonable(self):
        self.assertEqual(to_jsonable({1: "a", "b": [True], 2.5: LuaRef("X")}), {"[1]": "a", "b": [True], "[2.5]": "X"})


if __name__ == "__main__":
    unittest.main()
