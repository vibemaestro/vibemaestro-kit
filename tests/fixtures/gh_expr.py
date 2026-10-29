#!/usr/bin/env python3
"""A small evaluator of GitHub Actions expressions, for the workflow tests: enough to judge a `concurrency` block per event.

    evaluate(text, ctx)   the value of a field as Actions computes it: `${{ … }}` parts interpolated into a string; a field that is
                          exactly one `${{ … }}` keeps the value's type (a boolean `cancel-in-progress` stays a boolean)

Supported: literals ('str' with '' as a quote, numbers, true, false, null), context paths (github.event.pull_request.number,
a.b['c']), ( ), !, ==, !=, <, <=, >, >=, &&, ||, and the functions contains, startsWith, endsWith, format, toJSON, fromJSON. Semantics follow the
Actions documentation: a missing property is null; && and || return an operand, not a boolean; == on two strings ignores case;
null, false, 0 and '' are falsy; a value interpolated into a string is '' for null. Anything else raises ValueError, so a test fails
closed on an expression it cannot judge instead of guessing.

&& and || evaluate their right operand only when the left one does not decide the result, as Actions does; the one effect that matters is
fromJSON of text that is not JSON, which makes the evaluation fail (EvalError: the run fails at once, as Actions reports a bad expression)
and is skipped, not raised, in an operand that is not reached. Any other unsupported function raises ValueError in a skipped operand too.
"""
import re

TOKEN = re.compile(r"\s*(?:(?P<num>-?\d+(?:\.\d+)?)|(?P<str>'(?:[^']|'')*')|(?P<op>==|!=|<=|>=|&&|\|\||[!<>().,\[\]])"
                   r"|(?P<id>[A-Za-z_][A-Za-z0-9_-]*))")


class EvalError(ValueError):
    """The expression is valid but its evaluation fails (fromJSON of text that is not JSON): Actions fails the run."""


def _tokens(src):
    out, i = [], 0
    while i < len(src):
        if src[i:].strip() == "":
            break
        m = TOKEN.match(src, i)
        if not m or m.end() == i:
            raise ValueError("cannot read the expression at %r" % src[i:i + 20])
        kind = m.lastgroup
        out.append((kind, m.group(kind)))
        i = m.end()
    return out


def truthy(v):
    return not (v is None or v is False or v == 0 or v == "")


def _str(v):
    if v is None:
        return ""
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


def _eq(a, b):
    if isinstance(a, str) and isinstance(b, str):
        return a.lower() == b.lower()
    if type(a) is not type(b) and not (isinstance(a, (int, float)) and isinstance(b, (int, float))):
        # the documented coercion: compare as numbers when the types differ (null 0, false 0, true 1, '' 0, a number string)
        return _num(a) == _num(b)
    return a == b


def _num(v):
    if v is None or v is False:
        return 0
    if v is True:
        return 1
    if isinstance(v, (int, float)):
        return v
    if isinstance(v, str):
        try:
            return float(v) if v.strip() else 0
        except ValueError:
            return float("nan")
    return float("nan")


class _P:
    def __init__(self, toks, ctx):
        self.t, self.i, self.ctx = toks, 0, ctx
        self.skip = 0   # >0 while parsing an operand that && or || does not reach

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else (None, None)

    def take(self, val=None):
        tok = self.peek()
        if tok[0] is None or (val is not None and tok[1] != val):
            raise ValueError("expected %r, got %r" % (val, tok[1]))
        self.i += 1
        return tok

    def operand(self, parse, reached):
        """`parse()` the right operand; when `reached` is false it is parsed but its fromJSON failures do not count."""
        if reached:
            return parse()
        self.skip += 1
        try:
            return parse()
        finally:
            self.skip -= 1

    def expr(self):
        v = self.and_()
        while self.peek()[1] == "||":
            self.take()
            r = self.operand(self.and_, not truthy(v))
            v = v if truthy(v) else r
        return v

    def and_(self):
        v = self.cmp()
        while self.peek()[1] == "&&":
            self.take()
            r = self.operand(self.cmp, truthy(v))
            v = r if truthy(v) else v
        return v

    def cmp(self):
        v = self.unary()
        op = self.peek()[1]
        if op in ("==", "!=", "<", "<=", ">", ">="):
            self.take()
            r = self.unary()
            if op == "==":
                return _eq(v, r)
            if op == "!=":
                return not _eq(v, r)
            a, b = _num(v), _num(r)
            return {"<": a < b, "<=": a <= b, ">": a > b, ">=": a >= b}[op]
        return v

    def unary(self):
        """`!` binds tighter than a comparison, as in Actions: `!a == b` is `(!a) == b`."""
        if self.peek()[1] == "!":
            self.take()
            return not truthy(self.unary())
        return self.primary()

    def primary(self):
        kind, val = self.peek()
        if val == "(":
            self.take()
            v = self.expr()
            self.take(")")
            return v
        if kind == "num":
            self.take()
            return float(val) if "." in val else int(val)
        if kind == "str":
            self.take()
            return val[1:-1].replace("''", "'")
        if kind == "id":
            self.take()
            if val in ("true", "false"):
                return val == "true"
            if val == "null":
                return None
            if self.peek()[1] == "(":
                return self.call(val)
            return self.path(self.ctx.get(val))
        raise ValueError("unexpected %r" % (val,))

    def path(self, cur):
        while self.peek()[1] in (".", "["):
            if self.take()[1] == ".":
                key = self.take()[1]
            else:
                key = self.expr()
                self.take("]")
            cur = cur.get(key) if isinstance(cur, dict) else None
        return cur

    def call(self, name):
        self.take("(")
        args = []
        if self.peek()[1] != ")":
            args.append(self.expr())
            while self.peek()[1] == ",":
                self.take()
                args.append(self.expr())
        self.take(")")
        low = name.lower()
        if low == "contains" and len(args) == 2:
            h, n = args
            return any(_eq(x, n) for x in h) if isinstance(h, list) else _str(n).lower() in _str(h).lower()
        if low == "startswith" and len(args) == 2:
            return _str(args[0]).lower().startswith(_str(args[1]).lower())
        if low == "endswith" and len(args) == 2:
            return _str(args[0]).lower().endswith(_str(args[1]).lower())
        if low == "tojson" and len(args) == 1:
            import json
            return json.dumps(args[0], indent=2)
        if low == "fromjson" and len(args) == 1:
            import json
            if self.skip:
                return None
            try:
                return json.loads(_str(args[0]))
            except ValueError:
                raise EvalError("fromJSON: not JSON: %r" % _str(args[0])[:60])
        if low == "format" and args:
            return re.sub(r"\{(\d+)\}", lambda m: _str(args[int(m.group(1)) + 1]), _str(args[0]))
        raise ValueError("unsupported function %s/%d" % (name, len(args)))


def expression(src, ctx):
    p = _P(_tokens(src), ctx)
    v = p.expr()
    if p.i != len(p.t):
        raise ValueError("trailing text in %r" % src)
    return v


PART = re.compile(r"\$\{\{(.*?)\}\}", re.S)


def evaluate(text, ctx):
    """A workflow field's value: a non-string as it is, a string with its `${{ }}` parts evaluated."""
    if not isinstance(text, str):
        return text
    t = text.strip()
    parts = list(PART.finditer(t))
    if len(parts) == 1 and parts[0].span() == (0, len(t)):
        return expression(parts[0].group(1), ctx)
    return PART.sub(lambda m: _str(expression(m.group(1), ctx)), text)
