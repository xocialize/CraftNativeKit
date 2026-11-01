#!/usr/bin/env python3
"""serde2swift: Swift value types with serde-exact JSON coding, generated from Rust source.

    serde2swift.py OUT.swift --module DCModel --header "..." RUST_FILE...

Every `#[derive(... Serialize ...)]` struct and enum in the given files becomes a Swift type with
`toJSON()` / `init(fromJSON:)` that follow its serde attributes exactly (CNCore's JSON layer):

- structs: field order, `rename_all = "camelCase"`, struct- and field-level `default` (including
  `default = "fn"`), `skip_serializing_if`, `skip`, `deserialize_with`;
- enums: bare-string unit enums, externally, internally (`tag`) and adjacently (`tag` + `content`)
  tagged enums, with struct-variant fields keeping their Rust names (serde's `rename_all` on an
  enum renames variants only; one on a variant renames its fields);
- `id_type!` newtypes (`#[serde(transparent)]`);
- tuple structs (a newtype is its inner value, more fields a sequence), with fields `_0`, `_1`…;
- generic structs (`PropChange<T>`), `BTreeMap<K, V>` (CNCore writes the keys in Rust's order), field and
  variant `rename`, variant `alias`, and `with = "m"` fields (hand-written `mSerialize`/`mDeserialize`);
- a manual `impl Serialize` or `impl Deserialize` in the same file leaves that half to hand-written code.

`--rename Float=FloatingObject` renames a Rust type that would shadow a Swift one. A non-generic
`pub type X = T;` becomes a `typealias`.

`--box Indirect` maps `Box<T>` to `Indirect<T>` (a hand-written wrapper that lets value types recurse);
without it `Box<T>` is `T`.

Behaviour (`impl` blocks) is not generated: it is ported by hand beside the generated file. Types
that need hand-written pieces declare them by name, and the Swift compiler reports any missing:
`static var default` for a manual `impl Default`, the Swift for each custom `skip_serializing_if`
predicate or `default = "fn"` (see the tables below).

Rust → Swift: f64 Double, f32 Float, integers by width (usize Int), Vec<T> [T], Option<T> T?,
Box/Arc<T> T, [T; N] [T] (length checked on read), tuples Pair/Triple, paths by their last segment.
A Rust variant `None` becomes Swift `none_`, so it can't be confused with `Optional.none`, and `Default`
becomes `default_`.
"""
import re
import sys

PRIMS = {
    "f64": "Double", "f32": "Float", "u8": "UInt8", "u16": "UInt16", "u32": "UInt32", "u64": "UInt64",
    "i8": "Int8", "i16": "Int16", "i32": "Int32", "i64": "Int64", "usize": "Int", "isize": "Int",
    "bool": "Bool", "String": "String", "char": "Unicode.Scalar",
}

# `default = "fn"` → Swift expression.
DEFAULT_FNS = {
    "crate::yes": "true", "yes": "true", "med": '"med"', "one": "1.0", "start_one": "1",
    "custom_show_returns": "true", "text_kind": "RunKind.text",
}

# Swift keywords that need backticks as identifiers.
KEYWORDS = {
    "default", "in", "is", "as", "case", "repeat", "where", "self", "Self", "protocol", "extension",
    "func", "import", "init", "inout", "internal", "let", "operator", "private", "public", "static",
    "struct", "subscript", "super", "switch", "throw", "throws", "try", "var", "while", "class",
    "continue", "break", "defer", "do", "else", "fallthrough", "for", "guard", "if", "return",
    "associatedtype", "deinit", "enum", "fileprivate", "typealias", "true", "false", "nil", "Type",
}

# Swift type names the model must not take from the standard library or Foundation by accident.
RENAMED_TYPES = {}


def camel_field(name):
    """serde's camelCase for a snake_case field (tuple fields `_0`, `_1` stay as they are)."""
    if re.fullmatch(r"_\d+", name):
        return name
    out, up = [], False
    for c in name:
        if c == "_":
            up = True
        elif up:
            out.append(c.upper())
            up = False
        else:
            out.append(c)
    return "".join(out)


def camel_variant(name):
    """serde's camelCase for a PascalCase variant: lower the first character."""
    return name[:1].lower() + name[1:]


def ident(name):
    return f"`{name}`" if name in KEYWORDS else name


def swift_case(variant):
    name = camel_variant(variant)
    # `none` and `default` would be confused with `Optional.none` and the type's `static var default`.
    return name + "_" if name in ("none", "default") else ident(name)


# ---------- Rust parsing ----------

def strip_line_comments(src):
    """Drop `//` comments that aren't doc comments, keeping strings intact enough for our items."""
    lines = []
    for line in src.split("\n"):
        s = line.lstrip()
        if s.startswith("//") and not s.startswith("///"):
            continue
        lines.append(line)
    return "\n".join(lines)


DOCS = []


def hide_docs(s):
    """Replace each doc-comment line with a bracket-free placeholder, so `<`, `(` and `,` inside docs
    don't upset the depth-aware split."""
    def repl(m):
        DOCS.append(m.group(2))
        return f"{m.group(1)}///@@{len(DOCS) - 1}@@"
    return re.sub(r"^(\s*)///(.*)$", repl, s, flags=re.M)


def doc_text(s):
    m = re.match(r"^@@(\d+)@@$", s)
    return DOCS[int(m.group(1))].strip() if m else s.strip()


def split_top(s, sep=","):
    parts, depth, cur = [], 0, []
    for c in s:
        if c in "<([{":
            depth += 1
        elif c in ">)]}":
            depth -= 1
        if c == sep and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(c)
    if "".join(cur).strip():
        parts.append("".join(cur))
    return parts


def match_brace(s, i, open_c="{", close_c="}"):
    depth = 0
    for j in range(i, len(s)):
        if s[j] == open_c:
            depth += 1
        elif s[j] == close_c:
            depth -= 1
            if depth == 0:
                return j
    raise ValueError("unbalanced")


def parse_serde_attrs(text):
    """All `#[serde(...)]` key/values in `text` as a dict (flags map to True)."""
    out = {}
    for m in re.finditer(r"#\[serde\((.*?)\)\]", text, re.S):
        for part in split_top(m.group(1)):
            part = part.strip()
            if not part:
                continue
            if "=" in part:
                k, v = part.split("=", 1)
                k, v = k.strip(), v.strip().strip('"')
                if k == "alias":
                    out.setdefault("alias", []).append(v)
                else:
                    out[k] = v
            else:
                out[part] = True
    return out


def leading_meta(seg):
    """Doc lines, attribute text and the remaining declaration of a field/variant segment."""
    docs, attrs, rest = [], [], []
    lines = seg.strip("\n").split("\n")
    i = 0
    while i < len(lines):
        s = lines[i].strip()
        if rest:
            # Past the declaration's first line: everything else (a struct variant's fields with their own
            # docs and attributes) belongs to the declaration.
            rest.append(lines[i])
        elif s.startswith("///"):
            docs.append(doc_text(s[3:]))
        elif s.startswith("#["):
            # attributes can span lines
            buf = s
            while buf.count("[") > buf.count("]") and i + 1 < len(lines):
                i += 1
                buf += " " + lines[i].strip()
            attrs.append(buf)
        elif s:
            rest.append(lines[i])
        i += 1
    return docs, " ".join(attrs), "\n".join(rest).strip()


def parse_type(t):
    t = t.strip()
    t = re.sub(r"\s+", " ", t)
    if t.startswith("(") and t.endswith(")"):
        return ("tuple", [parse_type(x) for x in split_top(t[1:-1])])
    if t.startswith("[") and t.endswith("]"):
        inner, n = t[1:-1].rsplit(";", 1)
        return ("fixed", parse_type(inner), int(n.strip()))
    m = re.match(r"^([A-Za-z_][\w:]*)\s*<(.*)>$", t)
    if m:
        head = m.group(1).split("::")[-1]
        args = [parse_type(x) for x in split_top(m.group(2))]
        if head == "Vec":
            return ("vec", args[0])
        if head == "Option":
            return ("opt", args[0])
        if head == "Box" and BOX_TYPE:
            return ("box", args[0])
        if head in ("Box", "Arc", "Rc"):
            return args[0]
        if head == "BTreeMap":
            return ("map", args[0], args[1])
        if head in ("HashMap", "HashSet", "BTreeSet"):
            raise ValueError(f"unsupported generic {t}")
        return ("generic", head, args)
    name = t.split("::")[-1]
    if name in PRIMS:
        return ("prim", name)
    return ("named", RENAMED_TYPES.get(name, name))


BOX_TYPE = None
# `pub type X = T;` across all the files, so defaults see through them.
ALIASES = {}


def swift_type(ty):
    k = ty[0]
    if k == "map":
        return f"[{swift_type(ty[1])}: {swift_type(ty[2])}]"
    if k == "generic":
        return f"{ty[1]}<{', '.join(swift_type(a) for a in ty[2])}>"
    if k == "box":
        return f"{BOX_TYPE}<{swift_type(ty[1])}>"
    if k == "prim":
        return PRIMS[ty[1]]
    if k == "named":
        return ty[1]
    if k == "vec":
        return f"[{swift_type(ty[1])}]"
    if k == "fixed":
        return f"[{swift_type(ty[1])}]"
    if k == "opt":
        inner = swift_type(ty[1])
        return f"{inner}?"
    if k == "tuple":
        args = ", ".join(swift_type(x) for x in ty[1])
        return {2: f"Pair<{args}>", 3: f"Triple<{args}>"}[len(ty[1])]
    raise ValueError(ty)


# Defaults of types from other modules (no `.default` there).
EXTERNAL_DEFAULTS = {"Xfrm": "Xfrm()", "Size": "Size.zero", "Rect": "Rect.zero", "Point": "Point.zero", "Rgba": "Rgba.black"}


def default_expr(ty):
    k = ty[0]
    if k == "map":
        return "[:]"
    if k == "generic":
        return f"{swift_type(ty)}.default"
    if k == "box":
        return f"{BOX_TYPE}({default_expr(ty[1])})"
    if k == "prim":
        return {"bool": "false", "String": '""'}.get(ty[1], "0")
    if k == "named":
        if ty[1] in ALIASES:
            return default_expr(ALIASES[ty[1]])
        return EXTERNAL_DEFAULTS.get(ty[1], f"{ty[1]}.default")
    if k == "vec":
        return "[]"
    if k == "opt":
        return "nil"
    if k == "fixed":
        return f"Array(repeating: {default_expr(ty[1])}, count: {ty[2]})"
    if k == "tuple":
        return f"{'Pair' if len(ty[1]) == 2 else 'Triple'}({', '.join(default_expr(x) for x in ty[1])})"
    raise ValueError(ty)


def skip_expr(pred, var, ty):
    """Swift condition under which serde skips the field."""
    if pred == "Option::is_none":
        return f"{var} == nil"
    if pred in ("Vec::is_empty", "String::is_empty"):
        return f"{var}.isEmpty"
    if pred == "std::ops::Not::not":
        return f"!{var}"
    if pred == "is_zero":
        return f"{var} == 0"
    if pred == "is_zero4":
        return f"{var}.allSatisfy {{ $0 == 0 }}"
    if pred == "is_true":
        return var
    m = re.match(r"^(?:\w+::)*([A-Z]\w*)::(\w+)$", pred)
    if m:  # `Type::is_empty` and friends (`crate::math::Math::is_empty` too): a property of the value
        return f"{var}.{camel_field(m.group(2))}"
    return f"{camel_field(pred.split('::')[-1])}({var})"


class Field:
    def __init__(self, name, ty, docs, attrs):
        self.rust = name
        self.ty = ty
        self.docs = docs
        self.serde = parse_serde_attrs(attrs)
        self.swift = ident(camel_field(name))
        self.plain = camel_field(name)
        # Labels at a call site take keywords as they are, except these three (declarations keep backticks).
        self.label = self.swift if self.plain in ("inout", "var", "let") else self.plain


def parse_fields(body):
    fields = []
    for seg in split_top(body):
        docs, attrs, decl = leading_meta(seg)
        if not decl:
            continue
        decl = re.sub(r"^pub(\([^)]*\))?\s+", "", decl)
        name, ty = decl.split(":", 1)
        fields.append(Field(name.strip(), parse_type(ty), docs, attrs))
    return fields


class Item:
    pass


def parse_items(path):
    src = hide_docs(strip_line_comments(open(path).read()))
    items = []
    # id_type!(Name) newtypes
    for m in re.finditer(r"^id_type!\((\w+)\);", src, re.M):
        it = Item()
        it.kind, it.name, it.docs, it.derives, it.serde = "id", m.group(1), [], ["Hash", "Default", "Copy"], {}
        it.pos = m.start()
        items.append(it)
    for m in re.finditer(r"#\[derive\(([^)]*)\)\]", src):
        derives = [d.strip() for d in m.group(1).split(",")]
        if "Serialize" not in derives:
            continue
        # docs above the derive
        before = src[: m.start()].rstrip("\n").split("\n")
        docs = []
        for line in reversed(before):
            s = line.strip()
            if s.startswith("///"):
                docs.insert(0, doc_text(s[3:]))
            elif s.startswith("#["):
                continue
            else:
                break
        rest = src[m.end():]
        decl = re.search(r"pub (struct|enum) (\w+)", rest)
        if not decl:
            continue
        head = rest[: decl.start()]
        # The derive must sit directly on the item: only attributes and docs between them (a derive
        # inside `macro_rules!` is followed by `pub struct $name`, which doesn't match).
        if re.sub(r"#\[[^\]]*\]|///@@\d+@@|\s", "", head):
            continue
        it = Item()
        it.docs, it.derives, it.serde = docs, derives, parse_serde_attrs(head)
        it.kind, it.name = decl.group(1), RENAMED_TYPES.get(decl.group(2), decl.group(2))
        it.pos = m.start()
        start = m.end() + decl.end()
        after = rest[decl.end():]
        gm = re.match(r"\s*<([^>]*)>", after)
        it.generics = [g.strip() for g in gm.group(1).split(",")] if gm else []
        if it.kind == "struct" and after.lstrip().startswith("("):
            p0 = start + after.index("(")
            p1 = match_brace(src, p0, "(", ")")
            types = [re.sub(r"^pub(\([^)]*\))?\s+", "", t.strip()) for t in split_top(src[p0 + 1 : p1])]
            it.kind = "tuple"
            it.fields = [Field(f"_{i}", parse_type(t), [], "") for i, t in enumerate(types)]
            items.append(it)
            continue
        b0 = start + after.index("{")
        b1 = match_brace(src, b0)
        body = src[b0 + 1 : b1]
        if it.kind == "struct":
            it.fields = parse_fields(body)
        else:
            it.variants = []
            for seg in split_top(body):
                vdocs, vattrs, vdecl = leading_meta(seg)
                if not vdecl:
                    continue
                v = Item()
                v.docs, v.is_default = vdocs, "#[default]" in vattrs
                v.serde = parse_serde_attrs(vattrs)
                if "{" in vdecl:
                    v.name = vdecl[: vdecl.index("{")].strip()
                    v.shape = "struct"
                    v.fields = parse_fields(vdecl[vdecl.index("{") + 1 : vdecl.rindex("}")])
                elif "(" in vdecl:
                    v.name = vdecl[: vdecl.index("(")].strip()
                    v.shape = "tuple"
                    v.types = [parse_type(x) for x in split_top(vdecl[vdecl.index("(") + 1 : vdecl.rindex(")")])]
                else:
                    v.name = vdecl.strip()
                    v.shape = "unit"
                it.variants.append(v)
        items.append(it)
    # non-generic `pub type X = T;` aliases
    for m in re.finditer(r"^pub type (\w+)\s*=\s*([^;]+);", src, re.M):
        try:
            ty = parse_type(m.group(2))
        except ValueError:
            continue
        it = Item()
        it.kind, it.name, it.ty, it.pos = "alias", RENAMED_TYPES.get(m.group(1), m.group(1)), ty, m.start()
        items.append(it)
    # manual `impl Default for X`, and manual serde halves
    manual = set(re.findall(r"impl Default for (\w+)", src))
    manual_ser = set(re.findall(r"impl(?:<[^>]*>)?\s+(?:serde::)?Serialize\s+for\s+(\w+)", src))
    manual_de = set(re.findall(r"impl<'de>\s+(?:serde::)?Deserialize<'de>\s+for\s+(\w+)", src))
    for it in items:
        it.manual_default = it.name in manual
        it.manual_ser = it.name in manual_ser
        it.manual_de = it.name in manual_de
    items.sort(key=lambda i: i.pos)
    return items


# ---------- Swift emission ----------

def default_fn(name):
    """The Swift for `#[serde(default = "name")]`: a known constant, else the hand-written function."""
    return DEFAULT_FNS.get(name) or f"{camel_field(name.split('::')[-1])}()"


def doc_lines(docs, indent=""):
    return [f"{indent}/// {d}".rstrip() for d in docs]


def type_decl(it):
    """`Name` or `Name<T: …>` for a generic struct."""
    if not getattr(it, "generics", []):
        return it.name
    return f"{it.name}<{', '.join(f'{g}: JSONCodable & Sendable & Equatable' for g in it.generics)}>"


def conformances(it):
    c = ["Sendable", "Equatable"]
    if "Hash" in it.derives:
        c.append("Hashable")
    return c


def field_key(f, rename):
    if "rename" in f.serde:
        return f.serde["rename"]
    return camel_field(f.rust) if rename else f.rust


def decode_field(f, rename, struct_default, var="f"):
    key = field_key(f, rename)
    s = f.serde
    if "deserialize_with" in s:
        fallback = f"d.{f.plain}" if struct_default else default_expr(f.ty)
        return f"try {camel_field(s['deserialize_with'])}({var}.object[\"{key}\"], default: {fallback})"
    if s.get("skip"):
        if isinstance(s.get("default"), str):
            return default_fn(s["default"])
        return f"d.{f.plain}" if struct_default else default_expr(f.ty)
    if "with" in s:
        fn = f"{camel_field(s['with'].split('::')[-1])}Deserialize"
        if s.get("default") is True or struct_default:
            fallback = f"d.{f.plain}" if struct_default and s.get("default") is not True else default_expr(f.ty)
            return f"try {var}.get(\"{key}\", default: {fallback}, with: {fn})"
        return f"try {var}.required(\"{key}\", with: {fn})"
    if f.ty[0] == "vec" and f.ty[1][0] == "fixed":
        # `Vec<[T; N]>`: every element exactly N long.
        rows = f"{{ (j: JSON) throws(JSONDecodeError) -> {swift_type(f.ty)} in try decodeFixedArrays(j, count: {f.ty[1][2]}) }}"
        if s.get("default") is True or struct_default or isinstance(s.get("default"), str):
            if isinstance(s.get("default"), str):
                fallback = default_fn(s["default"])
            else:
                fallback = f"d.{f.plain}" if struct_default and s.get("default") is not True else "[]"
            return f"try {var}.get(\"{key}\", default: {fallback}, with: {rows})"
        return f"try {var}.required(\"{key}\", with: {rows})"
    fixed = f.ty[0] == "fixed"
    if f.ty[0] == "opt" and f.ty[1][0] == "fixed":
        # `Option<[T; N]>`: null or absent is nil, else exactly N elements.
        if s.get("default") is True or struct_default:
            fallback = f"d.{f.plain}" if struct_default and s.get("default") is not True else "nil"
            return f"try {var}.getOptionalFixed(\"{key}\", count: {f.ty[1][2]}, default: {fallback})"
        return f"try {var}.optionalFixed(\"{key}\", count: {f.ty[1][2]})"
    if s.get("default") is True:
        fallback = default_expr(f.ty)
    elif isinstance(s.get("default"), str):
        fallback = default_fn(s["default"])
    elif struct_default:
        fallback = f"d.{f.plain}"
    else:
        fallback = None
    if fixed:
        if fallback is None:
            return f"try {var}.requiredFixed(\"{key}\", count: {f.ty[2]})"
        return f"try {var}.getFixed(\"{key}\", count: {f.ty[2]}, default: {fallback})"
    if fallback is None:
        return f"try {var}.required(\"{key}\")"
    return f"try {var}.get(\"{key}\", default: {fallback})"


def encode_field(f, rename, var, out="o"):
    if f.serde.get("skip"):
        return None
    key = field_key(f, rename)
    pred = f.serde.get("skip_serializing_if")
    if "with" in f.serde:
        value = f"{camel_field(f.serde['with'].split('::')[-1])}Serialize({var})"
        if pred:
            return f"{out}.put(\"{key}\", {value}, skipIf: {skip_expr(pred, var, f.ty)})"
        return f"{out}.put(\"{key}\", {value})"
    if pred == "Option::is_none":
        return f"{out}.putIfPresent(\"{key}\", {var})"
    if pred:
        # A `Box<T>` field's predicate is `T`'s (Rust derefs it).
        target = f"{var}.value" if f.ty[0] == "box" else var
        return f"{out}.put(\"{key}\", {var}, skipIf: {skip_expr(pred, target, f.ty)})"
    return f"{out}.put(\"{key}\", {var})"


def emit_struct(it, out):
    rename = it.serde.get("rename_all") == "camelCase"
    struct_default = it.serde.get("default") is True
    derived_default = "Default" in it.derives and not it.manual_default
    out += doc_lines(it.docs)
    out.append(f"public struct {type_decl(it)}: {', '.join(conformances(it))} {{")
    for f in it.fields:
        out += doc_lines(f.docs, "    ")
        out.append(f"    public var {f.swift}: {swift_type(f.ty)}")
    # memberwise init: defaults when the type derives Default; optionals default to nil
    params = []
    for f in it.fields:
        t = swift_type(f.ty)
        if derived_default:
            params.append(f"{f.swift}: {t} = {default_expr(f.ty)}")
        elif f.ty[0] == "opt":
            params.append(f"{f.swift}: {t} = nil")
        else:
            params.append(f"{f.swift}: {t}")
    out.append("")
    out.append(f"    public init({', '.join(params)}) {{")
    for f in it.fields:
        out.append(f"        self.{f.plain} = {f.swift}")
    out.append("    }")
    if derived_default:
        out.append("")
        out.append(f"    public static var `default`: {it.name} {{ {it.name}() }}")
    out.append("}")
    out.append("")
    out.append(f"extension {it.name}: JSONCodable {{")
    if not it.manual_ser:
        out.append("    public func toJSON() -> JSON {")
        out.append("        var o = JSONObject()")
        for f in it.fields:
            line = encode_field(f, rename, f.swift)
            if line:
                out.append(f"        {line}")
        out.append("        return .object(o)")
        out.append("    }")
    if not it.manual_ser and not it.manual_de:
        out.append("")
    if not it.manual_de:
        out.append("    public init(fromJSON json: JSON) throws(JSONDecodeError) {")
        out.append(f"        let f = try JSONFields(json, \"{it.name}\")")
        if struct_default:
            out.append(f"        let d = {it.name}.default")
        args = ", ".join(f"{f.label}: {decode_field(f, rename, struct_default)}" for f in it.fields)
        out.append(f"        self.init({args})")
        out.append("    }")
    out.append("}")


def emit_tuple(it, out):
    """A tuple struct: serde writes a newtype as its inner value and more fields as a sequence."""
    derived_default = "Default" in it.derives and not it.manual_default
    out += doc_lines(it.docs)
    out.append(f"public struct {type_decl(it)}: {', '.join(conformances(it))} {{")
    for f in it.fields:
        out.append(f"    public var {f.swift}: {swift_type(f.ty)}")
    params = [f"_ {f.swift}: {swift_type(f.ty)}" + (f" = {default_expr(f.ty)}" if derived_default else "") for f in it.fields]
    out.append("")
    out.append(f"    public init({', '.join(params)}) {{")
    for f in it.fields:
        out.append(f"        self.{f.plain} = {f.swift}")
    out.append("    }")
    if derived_default:
        out.append("")
        out.append(f"    public static var `default`: {it.name} {{ {it.name}() }}")
    out.append("}")
    out.append("")
    out.append(f"extension {it.name}: JSONCodable {{")
    newtype = len(it.fields) == 1
    if not it.manual_ser:
        if newtype:
            out.append("    public func toJSON() -> JSON { _0.toJSON() }")
        else:
            out.append(f"    public func toJSON() -> JSON {{ .array([{', '.join(f'{f.swift}.toJSON()' for f in it.fields)}]) }}")
    if not it.manual_de:
        out.append("")
        out.append("    public init(fromJSON json: JSON) throws(JSONDecodeError) {")
        if newtype:
            out.append(f"        self.init(try {swift_type(it.fields[0].ty)}(fromJSON: json))")
        else:
            out.append(f"        let items = try tupleElements(json, count: {len(it.fields)})")
            args = ", ".join(f"try {swift_type(f.ty)}(fromJSON: items[{i}])" for i, f in enumerate(it.fields))
            out.append(f"        self.init({args})")
        out.append("    }")
    out.append("}")


def emit_id(it, out):
    out.append(f"public struct {it.name}: Sendable, Hashable, Comparable, CustomStringConvertible, JSONCodable {{")
    out.append("    public var rawValue: UInt32")
    out.append("")
    out.append("    public init(_ rawValue: UInt32) {")
    out.append("        self.rawValue = rawValue")
    out.append("    }")
    out.append("")
    out.append(f"    public static var `default`: {it.name} {{ {it.name}(0) }}")
    out.append(f"    public static func < (a: {it.name}, b: {it.name}) -> Bool {{ a.rawValue < b.rawValue }}")
    out.append("    public var description: String { String(rawValue) }")
    out.append("    public func toJSON() -> JSON { rawValue.toJSON() }")
    out.append("    public init(fromJSON json: JSON) throws(JSONDecodeError) { rawValue = try UInt32(fromJSON: json) }")
    out.append("}")


def variant_json_name(v, rename):
    """A variant's JSON name under the enum's `rename_all` (None, "camelCase" or "lowercase")."""
    if "rename" in v.serde:
        return v.serde["rename"]
    if rename == "camelCase":
        return camel_variant(v.name)
    if rename == "lowercase":
        return v.name.lower()
    if rename:
        raise ValueError(f"rename_all = {rename!r} on an enum is not supported")
    return v.name


def emit_enum(it, out):
    rename = it.serde.get("rename_all")
    tag, content = it.serde.get("tag"), it.serde.get("content")
    all_unit = all(v.shape == "unit" for v in it.variants)
    default_v = next((v for v in it.variants if v.is_default), None)
    out += doc_lines(it.docs)
    names = [variant_json_name(v, rename) for v in it.variants]
    names_lit = "[" + ", ".join(f'"{n}"' for n in names) + "]"
    if all_unit and not tag:
        conf = ["String", "JSONStringEnum"] + [c for c in conformances(it) if c != "Equatable"]
        out.append(f"public enum {it.name}: {', '.join(conf)} {{")
        for v in it.variants:
            out += doc_lines(v.docs, "    ")
            out.append(f"    case {swift_case(v.name)} = \"{variant_json_name(v, rename)}\"")
        if default_v:
            out.append("")
            out.append(f"    public static var `default`: {it.name} {{ .{swift_case(default_v.name)} }}")
        if any(v.serde.get("alias") for v in it.variants) and not it.manual_de:
            # serde's `alias`: more names read, the variant's own written.
            out.append("")
            out.append("    public init(fromJSON json: JSON) throws(JSONDecodeError) {")
            out.append("        guard case .string(let s) = json else { throw .invalidType(json, expected: \"a variant name\") }")
            out.append("        switch s {")
            for v in it.variants:
                names = [variant_json_name(v, rename)] + v.serde.get("alias", [])
                out.append(f"        case {', '.join(chr(34) + n + chr(34) for n in names)}: self = .{swift_case(v.name)}")
            out.append("        default: throw .unknownVariant(s, expected: Self.allCases.map(\\.rawValue))")
            out.append("        }")
            out.append("    }")
        out.append("}")
        return
    indirect = "indirect " if any(v.shape != "unit" for v in it.variants) else ""
    out.append(f"public {indirect}enum {it.name}: {', '.join(conformances(it))} {{")
    for v in it.variants:
        out += doc_lines(v.docs, "    ")
        if v.shape == "unit":
            out.append(f"    case {swift_case(v.name)}")
        elif v.shape == "tuple":
            out.append(f"    case {swift_case(v.name)}({', '.join(swift_type(t) for t in v.types)})")
        else:
            out.append(f"    case {swift_case(v.name)}({', '.join(f'{f.label}: {swift_type(f.ty)}' for f in v.fields)})")
    if default_v:
        out.append("")
        out.append(f"    public static var `default`: {it.name} {{ .{swift_case(default_v.name)} }}")
    out.append("}")
    out.append("")
    out.append(f"extension {it.name}: JSONCodable {{")
    out.append(f"    private static let variantNames = {names_lit}")
    out.append("")
    body_start = len(out)
    # ---- encode
    out.append("    public func toJSON() -> JSON {")
    out.append("        switch self {")
    for v in it.variants:
        jn = variant_json_name(v, rename)
        case = swift_case(v.name)
        if v.shape == "unit":
            out.append(f"        case .{case}:")
            if tag:
                out.append(f"            return .object(JSONObject([\"{tag}\": .string(\"{jn}\")]))")
            else:
                out.append(f"            return .string(\"{jn}\")")
        elif v.shape == "tuple":
            binds = [f"v{i}" for i in range(len(v.types))]
            out.append(f"        case .{case}({', '.join('let ' + b for b in binds)}):")
            payload = binds[0] + ".toJSON()" if len(binds) == 1 else f".array([{', '.join(b + '.toJSON()' for b in binds)}])"
            if tag and content:
                out.append(f"            return .object(JSONObject([\"{tag}\": .string(\"{jn}\"), \"{content}\": {payload}]))")
            elif tag:
                if len(binds) != 1:
                    raise ValueError(f"{it.name}::{v.name}: internally tagged tuple variant")
                out.append(f"            var o = JSONObject([\"{tag}\": .string(\"{jn}\")])")
                out.append(f"            if case .object(let inner) = {binds[0]}.toJSON() {{ o.merge(inner) }}")
                out.append("            return .object(o)")
            else:
                out.append(f"            return externalVariant(\"{jn}\", {payload})")
        else:
            binds = [f.swift for f in v.fields]
            out.append(f"        case .{case}({', '.join('let ' + b for b in binds)}):")
            if tag and not content:
                out.append(f"            var o = JSONObject([\"{tag}\": .string(\"{jn}\")])")
                target = "o"
            else:
                out.append("            var c = JSONObject()")
                target = "c"
            vrename = v.serde.get("rename_all") == "camelCase"
            for f in v.fields:
                line = encode_field(f, vrename, f.swift, target)
                if line:
                    out.append(f"            {line}")
            if tag and content:
                out.append(f"            return .object(JSONObject([\"{tag}\": .string(\"{jn}\"), \"{content}\": .object(c)]))")
            elif tag:
                out.append("            return .object(o)")
            else:
                out.append(f"            return externalVariant(\"{jn}\", .object(c))")
    out.append("        }")
    out.append("    }")
    out.append("")
    # ---- decode
    out.append("    public init(fromJSON json: JSON) throws(JSONDecodeError) {")
    if tag:
        out.append(f"        let f = try JSONFields(json, \"{it.name}\")")
        out.append(f"        let name = try f.tag(\"{tag}\")")
        if content:
            out.append(f"        let payload = f.object[\"{content}\"]")
        else:
            out.append("        let payload: JSON? = json")
    else:
        out.append("        let (name, payload) = try externalVariant(json)")
    out.append("        switch name {")
    for v in it.variants:
        jn = variant_json_name(v, rename)
        case = swift_case(v.name)
        names = [jn] + v.serde.get("alias", [])
        out.append(f"        case {', '.join(chr(34) + n + chr(34) for n in names)}:")
        if v.shape == "unit":
            out.append(f"            self = .{case}")
            continue
        out.append(f"            guard let payload else {{ throw JSONDecodeError(\"missing content for variant `{jn}`\") }}")
        if v.shape == "tuple":
            if len(v.types) == 1:
                out.append(f"            self = .{case}(try {swift_type(v.types[0])}(fromJSON: payload))")
            else:
                out.append(f"            let items = try tupleElements(payload, count: {len(v.types)})")
                args = ", ".join(f"try {swift_type(t)}(fromJSON: items[{i}])" for i, t in enumerate(v.types))
                out.append(f"            self = .{case}({args})")
        else:
            out.append(f"            let vf = try JSONFields(payload, \"{it.name}::{v.name}\")")
            vrename = v.serde.get("rename_all") == "camelCase"
            args = ", ".join(f"{f.label}: {decode_field(f, vrename, False, 'vf')}" for f in v.fields)
            out.append(f"            self = .{case}({args})")
    out.append("        default:")
    out.append(f"            throw .unknownVariant(name, expected: Self.variantNames)")
    out.append("        }")
    out.append("    }")
    if it.manual_ser or it.manual_de:
        body = out[body_start:]
        del out[body_start:]
        split = body.index("    public init(fromJSON json: JSON) throws(JSONDecodeError) {")
        if not it.manual_ser:
            out += body[:split]
        if not it.manual_de:
            out += body[split:]
    out.append("}")


def main(argv):
    out_path = argv[1]
    module = argv[argv.index("--module") + 1]
    header = argv[argv.index("--header") + 1]
    files = [a for a in argv[2:] if a.endswith(".rs")]
    lines = [
        f"// {module} — GENERATED by Tools/port/serde2swift.py from {', '.join(f.split('crates/')[-1] for f in files)}.",
        "// Do not edit: change the generator or the hand-written files beside this one, then regenerate.",
        "// " + header,
        "import CNCore",
    ]
    global BOX_TYPE
    for i, a in enumerate(argv):
        if a == "--rename":
            old, new = argv[i + 1].split("=", 1)
            RENAMED_TYPES[old] = new
    if "--box" in argv:
        BOX_TYPE = argv[argv.index("--box") + 1]
    imports = [a for i, a in enumerate(argv) if i > 0 and argv[i - 1] == "--import"]
    lines += [f"import {m}" for m in imports]
    parsed = [(path, parse_items(path)) for path in files]
    for _, items in parsed:
        for it in items:
            if it.kind == "alias":
                ALIASES[it.name] = it.ty
    for path, items in parsed:
        for it in items:
            lines.append("")
            lines.append(f"// MARK: {it.name} ({path.split('src/')[-1]})")
            lines.append("")
            if it.kind == "id":
                emit_id(it, lines)
            elif it.kind == "alias":
                lines.append(f"public typealias {it.name} = {swift_type(it.ty)}")
            elif it.kind == "struct":
                emit_struct(it, lines)
            elif it.kind == "tuple":
                emit_tuple(it, lines)
            else:
                emit_enum(it, lines)
    open(out_path, "w").write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main(sys.argv)
