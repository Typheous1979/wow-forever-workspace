"""Lua 5.1 lexer (stdlib only).

Works on bytes. Produces Token(kind, value, line, col) where kind is one of:
  name, keyword, number, string, op, eof
Comments are skipped but recorded (lexer.comments) so lint can read
`-- wowf-ignore:` directives. Lua 5.2+ operators (`//`, `&`, `|`, `~`, `<<`,
`>>`, `::`) are emitted as op tokens so lint can flag them instead of the
lexer failing. 5.2+ string escapes (\\x, \\z, \\u{) are recorded in
lexer.notes.
"""
import re
from dataclasses import dataclass

KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true",
    "until", "while",
}

# longest first
OPS = [
    b"...", b"..", b"==", b"~=", b"<=", b">=", b"<<", b">>", b"//", b"::",
    b"+", b"-", b"*", b"/", b"%", b"^", b"#", b"<", b">", b"=", b"(", b")",
    b"{", b"}", b"[", b"]", b";", b":", b",", b".", b"&", b"|", b"~",
]

_NAME = re.compile(rb"[A-Za-z_][A-Za-z0-9_]*")
_NUM_HEX = re.compile(rb"0[xX][0-9A-Fa-f]+")
_NUM_DEC = re.compile(rb"(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?")
_LONG_OPEN = re.compile(rb"\[(=*)\[")

_ESC = {
    ord("a"): 7, ord("b"): 8, ord("f"): 12, ord("n"): 10, ord("r"): 13,
    ord("t"): 9, ord("v"): 11, ord("\\"): 92, ord('"'): 34, ord("'"): 39,
}


class LuaSyntaxError(Exception):
    def __init__(self, msg, line, col):
        super().__init__(f"{line}:{col}: {msg}")
        self.msg, self.line, self.col = msg, line, col


@dataclass
class Token:
    kind: str
    value: object
    line: int
    col: int

    def is_op(self, *ops):
        return self.kind == "op" and self.value in ops

    def is_kw(self, *kws):
        return self.kind == "keyword" and self.value in kws


def decode(b):
    return b.decode("utf-8", "surrogateescape")


class Lexer:
    def __init__(self, data, sv_mode=False):
        if isinstance(data, str):
            data = data.encode("utf-8", "surrogateescape")
        self.has_bom = data.startswith(b"\xef\xbb\xbf")
        if self.has_bom:
            data = data[3:]
        self.src = data
        self.pos = 0
        self.line = 1
        self.line_start = 0
        self.sv_mode = sv_mode
        self.comments = []   # (line, text)
        self.notes = []      # (line, col, message)
        if data.startswith(b"#!"):
            nl = data.find(b"\n")
            self.pos = len(data) if nl < 0 else nl

    # -- helpers ---------------------------------------------------------
    def _col(self, pos=None):
        return (self.pos if pos is None else pos) - self.line_start + 1

    def _newlines(self, start, end):
        """Advance line counters over src[start:end]."""
        seg = self.src[start:end]
        i = 0
        while i < len(seg):
            c = seg[i]
            if c == 10 or c == 13:
                # \r\n or \n\r count once
                if i + 1 < len(seg) and seg[i + 1] in (10, 13) and seg[i + 1] != c:
                    i += 1
                self.line += 1
                self.line_start = start + i + 1
            i += 1

    def error(self, msg, line=None, col=None):
        raise LuaSyntaxError(msg, line or self.line, col or self._col())

    # -- long brackets --------------------------------------------------
    def _long_bracket(self, level_eq):
        """At self.pos just after `[==[`. Returns content bytes."""
        start_line, start_col = self.line, self._col()
        close = b"]" + b"=" * level_eq + b"]"
        end = self.src.find(close, self.pos)
        if end < 0:
            self.error("unfinished long string/comment", start_line, start_col)
        content = self.src[self.pos:end]
        self._newlines(self.pos, end + len(close))
        self.pos = end + len(close)
        # first newline right after the opener is dropped
        if content.startswith(b"\r\n") or content.startswith(b"\n\r"):
            content = content[2:]
        elif content[:1] in (b"\n", b"\r"):
            content = content[1:]
        return content.replace(b"\r\n", b"\n").replace(b"\r", b"\n")

    # -- short strings --------------------------------------------------
    def _short_string(self, quote):
        line, col = self.line, self._col()
        self.pos += 1
        out = bytearray()
        src = self.src
        n = len(src)
        while True:
            if self.pos >= n:
                self.error("unfinished string", line, col)
            c = src[self.pos]
            if c == quote:
                self.pos += 1
                return bytes(out)
            if c in (10, 13):
                self.error("unfinished string (newline)", line, col)
            if c == 92:  # backslash
                self.pos += 1
                if self.pos >= n:
                    self.error("unfinished string", line, col)
                e = src[self.pos]
                if e in _ESC:
                    out.append(_ESC[e]); self.pos += 1
                elif e in (10, 13):
                    out.append(10)
                    self.pos += 1
                    if self.pos < n and src[self.pos] in (10, 13) and src[self.pos] != e:
                        self.pos += 1
                    self.line += 1
                    self.line_start = self.pos
                elif 48 <= e <= 57:
                    m = re.match(rb"[0-9]{1,3}", src[self.pos:self.pos + 3])
                    v = int(m.group(0))
                    if v > 255:
                        self.error("escape sequence too large")
                    out.append(v); self.pos += len(m.group(0))
                else:
                    if e in (ord("x"), ord("z"), ord("u")):
                        self.notes.append((self.line, self._col(), f"Lua 5.2+ escape \\{chr(e)} is not supported by Lua 5.1"))
                    # Lua 5.1 keeps the character as-is for unknown escapes
                    out.append(e); self.pos += 1
            else:
                out.append(c); self.pos += 1

    # -- main -----------------------------------------------------------
    def tokens(self):
        out = []
        while True:
            t = self.next()
            out.append(t)
            if t.kind == "eof":
                return out

    def next(self):
        src = self.src
        n = len(src)
        while True:
            # whitespace
            while self.pos < n and src[self.pos] in b" \t\f\v\r\n":
                c = src[self.pos]
                self.pos += 1
                if c in (10, 13):
                    # \r\n and \n\r count as one newline
                    if self.pos < n and src[self.pos] in (10, 13) and src[self.pos] != c:
                        self.pos += 1
                    self.line += 1
                    self.line_start = self.pos
            if self.pos >= n:
                return Token("eof", None, self.line, self._col())
            # comments
            if src.startswith(b"--", self.pos):
                line = self.line
                self.pos += 2
                m = _LONG_OPEN.match(src, self.pos)
                if m:
                    self.pos = m.end()
                    text = self._long_bracket(len(m.group(1)))
                else:
                    end = self.pos
                    while end < n and src[end] not in (10, 13):
                        end += 1
                    text = src[self.pos:end]
                    self.pos = end
                self.comments.append((line, decode(text)))
                continue
            break

        line, col = self.line, self._col()
        c = src[self.pos]

        # names / keywords
        m = _NAME.match(src, self.pos)
        if m:
            word = decode(m.group(0))
            self.pos = m.end()
            if self.sv_mode and word in ("inf", "nan"):
                return Token("number", float(word), line, col)
            return Token("keyword" if word in KEYWORDS else "name", word, line, col)

        # numbers
        if 48 <= c <= 57 or (c == 46 and self.pos + 1 < n and 48 <= src[self.pos + 1] <= 57):
            m = _NUM_HEX.match(src, self.pos)
            if m:
                self.pos = m.end()
                return Token("number", int(m.group(0), 16), line, col)
            m = _NUM_DEC.match(src, self.pos)
            text = m.group(0)
            self.pos = m.end()
            if self.sv_mode and src.startswith(b"#IN", self.pos):  # 1.#INF / 1.#IND
                self.pos += 4
                return Token("number", float("inf") if src[self.pos - 1] == ord("F") else float("nan"), line, col)
            try:
                v = int(text) if re.fullmatch(rb"[0-9]+", text) else float(text)
            except ValueError:
                self.error(f"malformed number {text!r}", line, col)
            return Token("number", v, line, col)

        # strings
        if c in (34, 39):
            return Token("string", decode(self._short_string(c)), line, col)
        if c == 91:
            m = _LONG_OPEN.match(src, self.pos)
            if m:
                self.pos = m.end()
                return Token("string", decode(self._long_bracket(len(m.group(1)))), line, col)

        # operators
        for op in OPS:
            if src.startswith(op, self.pos):
                self.pos += len(op)
                return Token("op", op.decode(), line, col)

        self.error(f"unexpected symbol {chr(c)!r}", line, col)


def tokenize(data, sv_mode=False):
    lx = Lexer(data, sv_mode=sv_mode)
    return lx.tokens(), lx
