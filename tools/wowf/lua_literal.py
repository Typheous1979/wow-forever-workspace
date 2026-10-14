"""Safe Lua literal parser (never executes Lua).

Grammar accepted:
  value := nil | true | false | NUMBER | '-' NUMBER | STRING | table | ref
  ref   := NAME ('.' NAME)*          -> LuaRef("Enum.X.Y") (a str subclass)
  table := '{' [field (sep field)*] [sep] '}'   sep := ',' | ';'
  field := '[' value ']' '=' value | NAME '=' value | value

Tables convert to a Python list when they only hold positional/1..n keys,
otherwise to a dict (positional values keyed 1..n as ints).

Entry points:
  parse_value(data)        a single value
  parse_doc_chunk(data)    Blizzard *Documentation.lua: `local X = {...}; APIDocumentation:...(X);`
  parse_assignments(data)  SavedVariables file: repeated `NAME = value`
"""
import math
import sys

from lua_lexer import Lexer, LuaSyntaxError  # noqa: E402  (tools/wowf on sys.path)

MAX_DEPTH = 400
MAX_BYTES = 64 * 1024 * 1024


class LuaRef(str):
    """A bare/dotted identifier used as a value (e.g. Enum.SecretAspect.Text)."""
    def __repr__(self):
        return f"LuaRef({str.__repr__(self)})"


class _Parser:
    def __init__(self, data, sv_mode=False):
        if isinstance(data, (bytes, bytearray)) and len(data) > MAX_BYTES:
            raise LuaSyntaxError(f"file larger than {MAX_BYTES} bytes", 1, 1)
        self.lexer = Lexer(data, sv_mode=sv_mode)
        self.toks = self.lexer.tokens()
        self.i = 0
        self.warnings = []
        self.allow_expr = False  # docs only: simple arithmetic in constant values

    # token helpers
    @property
    def tok(self):
        return self.toks[self.i]

    def advance(self):
        t = self.toks[self.i]
        if t.kind != "eof":
            self.i += 1
        return t

    def expect_op(self, op):
        t = self.tok
        if not t.is_op(op):
            raise LuaSyntaxError(f"expected '{op}' near {t.value!r}", t.line, t.col)
        return self.advance()

    # values
    def value(self, depth=0):
        v = self._primary(depth)
        if self.allow_expr and self.tok.is_op("+", "-", "*", "/", "%", "^", ".."):
            parts = [str(v)]
            while self.tok.is_op("+", "-", "*", "/", "%", "^", ".."):
                parts.append(self.advance().value)
                parts.append(str(self._primary(depth)))
            return LuaRef(" ".join(parts))
        return v

    def _primary(self, depth=0):
        if depth > MAX_DEPTH:
            t = self.tok
            raise LuaSyntaxError("table nesting too deep", t.line, t.col)
        t = self.tok
        if t.kind == "keyword":
            if t.value == "nil":
                self.advance(); return None
            if t.value == "true":
                self.advance(); return True
            if t.value == "false":
                self.advance(); return False
            raise LuaSyntaxError(f"unexpected keyword {t.value!r}", t.line, t.col)
        if t.kind == "number" or t.kind == "string":
            self.advance(); return t.value
        if t.is_op("-"):
            self.advance()
            n = self.tok
            if n.kind != "number":
                raise LuaSyntaxError("expected number after '-'", n.line, n.col)
            self.advance()
            return -n.value
        if t.is_op("{"):
            return self.table(depth + 1)
        if t.kind == "name":
            parts = [self.advance().value]
            while self.tok.is_op(".") and self.toks[self.i + 1].kind == "name":
                self.advance()
                parts.append(self.advance().value)
            if self.tok.is_op("(", ":", "["):
                raise LuaSyntaxError("function calls/indexing are not allowed in literals", self.tok.line, self.tok.col)
            return LuaRef(".".join(parts))
        raise LuaSyntaxError(f"unexpected {t.value!r}", t.line, t.col)

    def table(self, depth):
        self.expect_op("{")
        arr = []
        hsh = {}
        while not self.tok.is_op("}"):
            t = self.tok
            if t.is_op("["):
                self.advance()
                k = self.value(depth)
                self.expect_op("]")
                self.expect_op("=")
                v = self.value(depth)
                self._set(hsh, k, v, t)
            elif t.kind == "name" and self.toks[self.i + 1].is_op("="):
                k = self.advance().value
                self.advance()
                v = self.value(depth)
                self._set(hsh, k, v, t)
            else:
                arr.append(self.value(depth))
            if self.tok.is_op(",", ";"):
                self.advance()
            elif not self.tok.is_op("}"):
                b = self.tok
                raise LuaSyntaxError(f"expected ',' or '}}' near {b.value!r}", b.line, b.col)
        self.expect_op("}")
        # positional entries win over explicit [n] (Lua SETLIST semantics)
        for n, v in enumerate(arr, 1):
            if n in hsh:
                self.warnings.append(f"positional value overrides explicit [{n}]")
            hsh[n] = v
        return _shape(hsh)

    def _set(self, hsh, k, v, t):
        if isinstance(k, float) and k.is_integer():
            k = int(k)
        if k is None or (isinstance(k, float) and math.isnan(k)):
            raise LuaSyntaxError("table index is nil/NaN", t.line, t.col)
        if k in hsh:
            self.warnings.append(f"{t.line}: duplicate key {k!r} (last wins)")
        if v is None:
            hsh.pop(k, None)
        else:
            hsh[k] = v


def _shape(hsh):
    n = len(hsh)
    if n and all(isinstance(k, int) and not isinstance(k, bool) for k in hsh):
        if set(hsh) == set(range(1, n + 1)):
            return [hsh[i] for i in range(1, n + 1)]
    if n == 0:
        return []
    return dict(hsh)


def parse_value(data, sv_mode=False):
    p = _Parser(data, sv_mode=sv_mode)
    v = p.value()
    if p.tok.kind != "eof":
        t = p.tok
        raise LuaSyntaxError(f"unexpected trailing {t.value!r}", t.line, t.col)
    return v


def parse_doc_chunk(data):
    """Parse a Blizzard *Documentation.lua file. Returns (name, table).

    Expected shape: `local NAME = { ... };` followed by
    `APIDocumentation:AddDocumentationTable(NAME);` (ignored).
    """
    p = _Parser(data)
    while p.tok.kind != "eof":
        t = p.tok
        if t.is_kw("local") and p.toks[p.i + 1].kind == "name" and p.toks[p.i + 2].is_op("="):
            p.advance()
            name = p.advance().value
            p.advance()
            p.allow_expr = True
            return name, p.value()
        p.advance()
    raise LuaSyntaxError("no `local NAME = {...}` found", 1, 1)


def parse_assignments(data):
    """Parse a SavedVariables file: repeated `NAME = value` (comments ignored)."""
    p = _Parser(data, sv_mode=True)
    out = {}
    while p.tok.kind != "eof":
        t = p.tok
        if t.kind != "name" or not p.toks[p.i + 1].is_op("="):
            raise LuaSyntaxError(f"expected `NAME = value` near {t.value!r}", t.line, t.col)
        name = p.advance().value
        p.advance()
        out[name] = p.value()
        if p.tok.is_op(";"):
            p.advance()
    return out


def to_jsonable(v):
    """Convert parsed values to JSON-safe structures (non-str keys -> "[k]")."""
    if isinstance(v, dict):
        return {(k if isinstance(k, str) else f"[{_keystr(k)}]"): to_jsonable(x) for k, x in v.items()}
    if isinstance(v, list):
        return [to_jsonable(x) for x in v]
    if isinstance(v, float) and (math.isinf(v) or math.isnan(v)):
        return str(v)
    return str(v) if isinstance(v, LuaRef) else v


def _keystr(k):
    if isinstance(k, bool):
        return "true" if k else "false"
    return repr(k) if isinstance(k, float) else str(k)


sys.setrecursionlimit(max(sys.getrecursionlimit(), 4000))
