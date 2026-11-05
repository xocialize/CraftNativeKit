#!/usr/bin/env python3
"""Tests for serde2swift.py: each serde attribute's Swift, on a small Rust source.

    python3 -I Tools/port/test_serde2swift.py

They check the emitted lines, not the Swift compiler's view of them; a consumer's build and round-trip tests
(GridCraftNative's GCModel uses every feature here) are the end-to-end check. Consumers' outputs must stay
byte-identical across a generator change: regenerate each one with the old and the new script and diff.
"""
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
GEN = os.path.join(HERE, "serde2swift.py")

RUST = r'''
use std::sync::Arc;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Book {
    pub title: String,
    /// Read, never written.
    #[serde(rename = "macros", default, skip_serializing, deserialize_with = "crate::macros::entries")]
    pub macros_read: Vec<serde_json::Value>,
    /// Written, never read.
    #[serde(default, skip_serializing_if = "crate::macros::Macros::is_empty", skip_deserializing)]
    pub macros: Macros,
    #[serde(deserialize_with = "lenient_size")]
    pub size: u32,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Step {
    #[serde(flatten)]
    pub kind: StepKind,
    #[serde(default = "yes", skip_serializing_if = "is_true")]
    pub enabled: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum StepKind {
    Command { id: String },
    Stop,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Cell {
    pub value: f64,
    pub formula: Option<Arc<Formula>>,
    /// Shared, never absent.
    pub code: Arc<Formula>,
    pub other: Option<Arc<Other>>,
    pub name: Arc<str>,
}
'''


def generate(source, *flags):
    with tempfile.TemporaryDirectory() as d:
        src, out = os.path.join(d, "lib.rs"), os.path.join(d, "Out.swift")
        with open(src, "w") as f:
            f.write(source)
        r = subprocess.run([sys.executable, "-I", GEN, out, "--module", "M", "--header", "test", *flags, src],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(r.stderr.strip().splitlines()[-1])
        with open(out) as f:
            return f.read()


class Attributes(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.out = generate(RUST, "--arc", "Shared=Formula")

    def section(self, name):
        start = self.out.index(f"// MARK: {name} ")
        end = self.out.find("// MARK: ", start + 1)
        return self.out[start:end if end >= 0 else None]

    def test_skip_serializing_alone_reads_but_never_writes(self):
        book = self.section("Book")
        enc = book[book.index("func toJSON"):book.index("init(fromJSON")]
        self.assertNotIn("macrosRead", enc)
        self.assertIn('macrosRead: try entries(f.object["macros"], default: [])', book)

    def test_skip_deserializing_alone_writes_but_never_reads(self):
        book = self.section("Book")
        self.assertIn('o.put("macros", macros, skipIf: macros.isEmpty)', book)
        self.assertIn("macros: Macros.default", book)
        self.assertNotIn('f.get("macros"', book)

    def test_deserialize_with_names_the_paths_last_segment(self):
        book = self.section("Book")
        self.assertIn("try entries(", book)
        self.assertIn('size: try lenientSize(f.object["size"], default: 0)', book)
        self.assertNotIn("crate::", book.split("extension Book")[1])

    def test_flatten_writes_in_place_and_reads_the_whole_object(self):
        step = self.section("Step")
        self.assertIn("if case .object(let inner) = kind.toJSON() { o.merge(inner) }", step)
        enc = step[step.index("func toJSON"):step.index("init(fromJSON")]
        self.assertLess(enc.index("kind.toJSON()"), enc.index('"enabled"'))
        self.assertIn("kind: try StepKind(fromJSON: .object(f.object))", step)

    def test_arc_fields_are_shared_boxes_behind_value_properties(self):
        cell = self.section("Cell")
        self.assertIn("@usableFromInline var formulaBox: Shared<Formula>?", cell)
        self.assertIn("@usableFromInline var codeBox: Shared<Formula>\n", cell)
        # stored after every plain field, in field order
        self.assertLess(cell.index("public var name: String"), cell.index("var formulaBox"))
        self.assertLess(cell.index("var formulaBox"), cell.index("var codeBox"))
        self.assertIn("public var formula: Formula? {", cell)
        self.assertIn("@inlinable get { formulaBox?.value }", cell)
        self.assertIn("set { formulaBox = newValue.map { Shared($0) } }", cell)
        self.assertIn("set { codeBox = Shared(newValue) }", cell)
        self.assertIn("self.formulaBox = formula.map { Shared($0) }", cell)
        self.assertIn("self.codeBox = Shared(code)", cell)
        self.assertIn("    /// Shared, never absent.\n    public var code: Formula {", cell)
        # memberwise init and JSON keep the value types
        self.assertIn("formula: Formula? = nil, code: Formula = Formula.default", cell)
        self.assertIn('o.put("formula", formula)', cell)

    def test_arc_of_an_unlisted_type_and_arc_str_stay_inline(self):
        cell = self.section("Cell")
        self.assertIn("public var other: Other?", cell)
        self.assertIn("public var name: String", cell)

    def test_without_arc_every_arc_is_inline(self):
        cell = generate(RUST).split("// MARK: Cell ")[1]
        self.assertIn("public var formula: Formula?", cell)
        self.assertNotIn("Box", cell)


class Refusals(unittest.TestCase):
    def test_arc_inside_a_collection_is_refused(self):
        src = "#[derive(Serialize)]\npub struct S {\n    pub list: Vec<Arc<Formula>>,\n}\n"
        with self.assertRaisesRegex(RuntimeError, "--arc"):
            generate(src, "--arc", "Shared=Formula")

    def test_arc_in_an_enum_payload_is_refused(self):
        src = "#[derive(Serialize)]\npub enum E {\n    A(Arc<Formula>),\n}\n"
        with self.assertRaisesRegex(RuntimeError, "--arc"):
            generate(src, "--arc", "Shared=Formula")

    def test_flatten_with_other_attributes_or_an_option_is_refused(self):
        for field in ["#[serde(flatten)]\n    pub k: Option<K>,", "#[serde(flatten, default)]\n    pub k: K,"]:
            src = f"#[derive(Serialize)]\npub struct S {{\n    {field}\n}}\n"
            with self.assertRaisesRegex(RuntimeError, "flatten"):
                generate(src)


if __name__ == "__main__":
    unittest.main()
