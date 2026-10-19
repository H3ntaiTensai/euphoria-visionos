"""Readers for compiled YU-RIS 0.474 data (ysbin/*.ybn) as shipped in Euphoria.

Formats, all little-endian:

ysc.ybn  YSCM  command table: per command a name, its argument names and types.
yst_list YSTL  script index -> original source path (.txt / .yst).
ysl.ybn  YSLB  labels: 256-entry hash bucket table, then name, ip, script index.
ysv.ybn  YSVR  variable declarations (scope, type, dimensions). Names are not kept.
ystNNNNN YSTB  one compiled script. Header: instruction count, then the sizes of
               the code, argument, resource and line-number sections. Every section
               is XORed with the 4-byte key below.

YSTB sections:
  code   4 bytes per instruction: command index (into ysc), argument count, pad.
  args   12 bytes per argument: u16 slot (index into the command's argument list),
         u16 type (low byte 1=int 2=float 3=str, high byte assignment operator
         for LET), u32 size, u32 offset into the resource section. A type of 0
         means the argument is control-flow metadata: size holds the target
         instruction index for IF/ELSE/LOOP.
  res    Expressions in reverse Polish notation. Each token is one opcode byte,
         a u16 payload length, then the payload. See EXPR_* below.
  lines  u32 source line number per instruction.
"""
import struct

KEY = bytes.fromhex("781b7330")

BINARY_OPS = {
    "+": "+", "-": "-", "*": "*", "/": "/", "%": "%",
    "=": "==", "!": "!=", "<": "<", ">": ">", "S": "<=", "Z": ">=",
    "&": "&&", "|": "||", "A": "&", "O": "|", "^": "^",
}
UNARY_OPS = {"R": "-", "s": "str", "i": "int"}
LET_OPS = {0: "=", 1: "+=", 2: "-=", 3: "*=", 4: "/=", 5: "%=", 6: "&=", 7: "|=", 8: "^="}


def xor(data):
    k = KEY
    return bytes(b ^ k[i & 3] for i, b in enumerate(data))


def _cstr(data, p):
    end = data.index(b"\0", p)
    return data[p:end].decode("cp932"), end + 1


def read_commands(path):
    data = open(path, "rb").read()
    count = struct.unpack_from("<I", data, 8)[0]
    p = 0x10
    commands = []
    for _ in range(count):
        name, p = _cstr(data, p)
        argc = data[p]
        p += 1
        args = []
        for _ in range(argc):
            arg, p = _cstr(data, p)
            args.append(arg)
            p += 2
        commands.append((name, args))
    return commands


def read_script_list(path):
    data = open(path, "rb").read()
    count = struct.unpack_from("<I", data, 8)[0]
    p = 0x0C
    scripts = {}
    for _ in range(count):
        index, length = struct.unpack_from("<II", data, p)
        p += 8
        scripts[index] = data[p : p + length].decode("cp932")
        p += length + 20
    return scripts


def read_labels(path):
    data = open(path, "rb").read()
    count = struct.unpack_from("<I", data, 8)[0]
    p = 0x0C + 256 * 4
    labels = []
    for _ in range(count):
        length = data[p]
        name = data[p + 1 : p + 1 + length].decode("cp932", "replace")
        p += 1 + length
        _hash, ip, script, flag = struct.unpack_from("<IIHH", data, p)
        p += 12
        labels.append(dict(name=name, ip=ip, script=script, flag=flag))
    return labels


def tokens(raw):
    """Yield (opcode, value) pairs for an RPN expression."""
    p = 0
    while p < len(raw):
        op = chr(raw[p])
        length = struct.unpack_from("<H", raw, p + 1)[0]
        payload = raw[p + 3 : p + 3 + length]
        p += 3 + length
        if op in "HVv":
            value = (chr(payload[0]), struct.unpack_from("<H", payload, 1)[0])
        elif op == "B":
            value = struct.unpack("<b", payload)[0]
        elif op == "W":
            value = struct.unpack("<h", payload)[0]
        elif op == "I":
            value = struct.unpack("<i", payload)[0]
        elif op == "L":
            value = struct.unpack("<q", payload)[0]
        elif op == "F":
            value = struct.unpack("<d", payload)[0]
        elif op == "M":
            value = payload.decode("cp932", "replace")
        else:
            value = payload
        yield op, value


def var_name(kind, index):
    return f"{kind}{index}"


def expression(raw):
    """Convert an RPN expression to infix source text."""
    stack = []
    marker = object()
    for op, value in tokens(raw):
        if op in "BWIL":
            stack.append(str(value))
        elif op == "F":
            stack.append(repr(value))
        elif op == "M":
            stack.append(value)  # already quoted in the bytecode
        elif op == "H":
            stack.append(var_name(*value))
        elif op == "v":
            stack.append("&" + var_name(*value))
        elif op == "V":
            stack.append(marker)
            stack.append(var_name(*value))
        elif op == ",":
            pass
        elif op == ")":
            items = []
            while stack and stack[-1] is not marker:
                items.append(stack.pop())
            stack.pop()
            items.reverse()
            stack.append(f"{items[0]}({', '.join(items[1:])})")
        elif op in UNARY_OPS:
            a = stack.pop() if stack else "?"
            sym = UNARY_OPS[op]
            stack.append(f"-{a}" if sym == "-" else f"{sym}({a})")
        elif op in BINARY_OPS:
            b = stack.pop() if stack else "?"
            a = stack.pop() if stack else "?"
            stack.append(f"({a} {BINARY_OPS[op]} {b})")
        else:
            stack.append(f"<{op}:{value!r}>")
    parts = [s for s in stack if s is not marker]
    text = " ".join(parts)
    if text.startswith("(") and text.endswith(")") and len(parts) == 1 and _balanced(text[1:-1]):
        text = text[1:-1]
    return text


def _balanced(s):
    depth = 0
    for ch in s:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth < 0:
                return False
    return depth == 0


def literal(raw):
    """Return the Python value of a single-literal expression, or None."""
    toks = list(tokens(raw))
    if len(toks) == 1 and toks[0][0] in "BWILF":
        return toks[0][1]
    if len(toks) == 1 and toks[0][0] == "M":
        s = toks[0][1]
        return s[1:-1] if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'" else s
    if len(toks) == 2 and toks[0][0] in "BWILF" and toks[1][0] == "R":
        return -toks[0][1]
    return None


class Script:
    def __init__(self, path, commands):
        data = open(path, "rb").read()
        magic, version, count, cs, as_, rs, ls, _ = struct.unpack_from("<4sIIIIIII", data)
        if magic != b"YSTB":
            raise ValueError(f"{path}: not a YSTB script")
        p = 0x20
        code = xor(data[p : p + cs]); p += cs
        args = xor(data[p : p + as_]); p += as_
        res = xor(data[p : p + rs]); p += rs
        lines = xor(data[p : p + ls])
        self.instructions = []
        a = 0
        for i in range(count):
            op, argc, _pad = struct.unpack_from("<BBH", code, i * 4)
            name, arg_names = commands[op]
            items = []
            for j in range(argc):
                slot, typ, size, off = struct.unpack_from("<HHII", args, (a + j) * 12)
                if typ == 0:
                    items.append(dict(slot=slot, type=0, target=size, aux=off))
                else:
                    items.append(dict(
                        slot=slot,
                        name=arg_names[slot] if slot < len(arg_names) else str(slot),
                        type=typ & 0xFF, op=typ >> 8, raw=res[off : off + size]))
            a += argc
            line = struct.unpack_from("<I", lines, i * 4)[0] if ls else 0
            self.instructions.append(dict(cmd=name, args=items, line=line))
