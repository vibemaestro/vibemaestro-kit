#!/usr/bin/env python3
"""The lint of tests/test-baton-output.sh: every line baton.py prints goes through its print layer, and no call site formats a
value into output by hand.

  baton_output_lint.py <baton.py>        one finding per line (`<line>: <what>`), rc 1 when there is any, rc 0 when none

The layer is `shown(fmt, *args)`, `say(fmt, *args, out=None)`, `shown_join(sep, parts)` and `Stop(rc, fmt, *args)`: the format is
a constant baton writes itself and every arg is escaped at run time (unless the layer built it), so the lint looks only at
the format and the number of args, never at the args:
- the format (the separator of shown_join) is a string constant, or one of ALLOWED (baton's usage text), which takes no arg;
- with args, the number of %-conversions of the format is the number of args (a stale positional `out` counts as an arg);
  no *args, no %(name)s, no * width, no stray %, no %r or %a (repr would run on the escaped text: pass repr(x) to a %s),
  no %c (an int is not escaped); without args the format holds no % at all (it is printed as it is);
- `Safe(` is called only inside the layer;
- `print(` is not called, nor `sys.exit(` or `SystemExit(` with a text message; a `.write(` or `.writelines(` call is a flush of a Held
  (`x.write(<a HELD name>.text())`), a write to a file (`f.write`, `os.write`) in a function of FILE_WRITERS, or one of the
  layer's own writes (WRITERS).
A lint reads names, not values: an alias of say, a Safe made through str.__new__, or a subprocess that inherits stdout would
pass it; the forge run of the suite is the check of what reaches the output."""
import ast
import re
import sys

LAYER = {"shown", "say", "shown_join"}              # functions whose first argument is the format (the separator)
SAFE_MAKERS = {"shown", "shown_join"}                # the only functions that may call Safe(
INSIDE = {"say", "Stop.__init__"}                  # the layer's own calls: format and args passed on as they came
ALLOWED = {"__doc__.strip()"}                      # formats that are not a literal: constants baton writes itself
WRITERS = {"say", "SafeOut.write", "Held.write", "help_topic"}       # the layer, the closed-pipe wrapper, the buffer, help <topic>
FILE_WRITERS = {"make_copy", "run_phase", "cmd_new", "write_private", "log_event", "mark_started", "stdin_script",
                "write_record", "pack_put_file"}                    # functions that write files (not stdout/stderr) with f/os
HELD = {"held", "rheld", "sheld", "preamble"}        # the names a Held goes by where it is flushed
CONV = re.compile(r"%(?:\((?P<name>[^)]*)\))?[-#0 +]*(?P<width>\*|\d+)?(?:\.(?P<prec>\*|\d+))?(?P<type>[diouxXeEfFgGcrsa%])")


def conversions(fmt):
    """(count, problem) of the %-conversions a format holds; %% is not one."""
    n = 0
    if "%" in CONV.sub("", fmt):
        return n, "a % that is no conversion (Python refuses it when the line is printed)"
    for m in CONV.finditer(fmt):
        if m.group("type") == "%":
            if m.group(0) != "%%":
                return n, "a malformed %% in the format"
            continue
        if m.group("name") is not None or m.group("width") == "*" or m.group("prec") == "*":
            return n, "a %(name)s or * conversion (the args are counted by position)"
        if m.group("type") in "ra":
            return n, "a %%%s conversion (repr of the escaped text): pass repr(x) to a %%s" % m.group("type")
        if m.group("type") == "c":
            return n, "a %c conversion: an int arg is not escaped, so it could print any character"
        n += 1
    return n, None


def is_text(node):
    """A message that is text for sure: a str constant, an f-string, or `+`/`%` with a str constant on its left."""
    if isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Add, ast.Mod)):
        return is_text(node.left)
    return (isinstance(node, ast.Constant) and isinstance(node.value, str)) or isinstance(node, ast.JoinedStr)


def is_format(node):
    return (isinstance(node, ast.Constant) and isinstance(node.value, str)) or ast.unparse(node) in ALLOWED


def lint(path):
    src = open(path, encoding="utf-8").read()
    tree = ast.parse(src)
    findings = []
    scope = {}                                     # id(node) -> the dotted name of the function it is in

    def walk(node, name):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                walk(child, child.name if not name or isinstance(node, ast.Module) else "%s.%s" % (name, child.name))
            else:
                scope[id(child)] = name
                walk(child, name)
    walk(tree, "")

    def where(node):
        return scope.get(id(node), "")

    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        f = node.func
        fname = f.id if isinstance(f, ast.Name) else None
        line = node.lineno
        if (fname in LAYER or fname == "Stop") and where(node) in INSIDE:
            continue                               # the layer passing its own format and args on
        if fname in LAYER or fname == "Stop":
            pos = 1 if fname == "Stop" else 0
            if len(node.args) <= pos:
                findings.append((line, "%s() without a format" % fname))
                continue
            if any(isinstance(a, ast.Starred) for a in node.args):
                findings.append((line, "%s() with *args: the args cannot be counted" % fname))
                continue
            fmt, args = node.args[pos], node.args[pos + 1:]
            if not is_format(fmt):
                findings.append((line, "%s() formats by hand: its format is %s, not a constant"
                                 % (fname, type(fmt).__name__ if not isinstance(fmt, ast.BinOp) else "a " + type(fmt.op).__name__)))
                continue
            if args and not isinstance(fmt, ast.Constant):
                findings.append((line, "%s(): %s takes no arg (it is printed as it is)" % (fname, ast.unparse(fmt))))
                continue
            if fname == "shown_join":
                if len(args) != 1:
                    findings.append((line, "shown_join() takes a separator and one list of parts"))
                continue
            if not args and isinstance(fmt, ast.Constant) and "%" in fmt.value:
                findings.append((line, "%s(): a %% in a format without args is printed as it is" % fname))
            if args and isinstance(fmt, ast.Constant):
                n, why = conversions(fmt.value)
                if why:
                    findings.append((line, "%s(): %s" % (fname, why)))
                elif n != len(args):
                    findings.append((line, "%s(): %d conversion%s in the format, %d arg%s" % (
                        fname, n, "" if n == 1 else "s", len(args), "" if len(args) == 1 else "s")))
        elif fname == "Safe" and where(node) not in SAFE_MAKERS:
            findings.append((line, "Safe() outside the layer (in %s)" % (where(node) or "the module")))
        elif fname == "print":
            findings.append((line, "print(): output goes through say()"))
        elif ((ast.unparse(f) in ("sys.exit", "SystemExit")) and node.args and is_text(node.args[0])):
            findings.append((line, "%s() with a text message: it writes to stderr past say()" % ast.unparse(f)))
        elif isinstance(f, ast.Attribute) and f.attr in ("write", "writelines"):
            w = where(node)
            recv = ast.unparse(f.value)
            arg = node.args[0] if node.args else None
            if w in WRITERS:
                continue
            if (f.attr == "write" and isinstance(arg, ast.Call) and isinstance(arg.func, ast.Attribute) and arg.func.attr == "text"
                    and not arg.args and ast.unparse(arg.func.value) in HELD):
                continue                           # a Held flushed: it holds only what the layer wrote into it
            if recv in ("f", "os") and w in FILE_WRITERS:
                continue
            findings.append((line, "%s.%s() in %s: output goes through say()" % (recv, f.attr, w or "the module")))
    return sorted(findings)


def main(argv):
    if len(argv) != 1:
        sys.stderr.write("usage: baton_output_lint.py <baton.py>\n")
        return 64
    found = lint(argv[0])
    for line, what in found:
        sys.stdout.write("%d: %s\n" % (line, what))
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
