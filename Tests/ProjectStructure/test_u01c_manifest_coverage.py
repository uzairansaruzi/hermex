import json
import re
import subprocess
import tempfile
import unittest
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = Path(__file__).with_name("u01c-shared-boundary-manifest.json")
WITNESS_CONTRACT = Path(__file__).with_name("u01c-semantic-witnesses.json")
DECLARATION_TEMPLATE = r"\b(?:struct|enum|protocol|actor|class|typealias)\s+{name}\b"
SWIFT_SCAN_EXCLUDED_PARTS = {".build", "DerivedData", ".git", "Tests"}
CANONICAL_SHARED_SOURCES = Path("Packages/WatchShared/Sources/WatchShared")

# Existing multi-field domain/transport aggregates reviewed as legitimate consumers.
AGGREGATE_CONSUMER_ALLOWLIST = {
    ("HermesMobile/Models/Approval.swift", "ApprovalRespondResponse", "choice", "ApprovalChoice"),
    ("HermesMobile/Networking/APIClient+Chat.swift", "ApprovalRespondRequest", "choice", "ApprovalChoice"),
}


def mask_swift_noncode(text):
    """Blank comments and literals while preserving offsets and newlines."""
    chars = list(text)
    index = 0
    state = "code"
    block_depth = 0
    while index < len(chars):
        pair = text[index:index + 2]
        if state == "code":
            if pair == "//":
                chars[index:index + 2] = "  "
                index += 2
                state = "line_comment"
                continue
            if pair == "/*":
                chars[index:index + 2] = "  "
                index += 2
                block_depth = 1
                state = "block_comment"
                continue
            if text.startswith('"""', index):
                chars[index:index + 3] = "   "
                index += 3
                state = "multiline_string"
                continue
            if chars[index] == '"':
                chars[index] = " "
                index += 1
                state = "string"
                continue
            if chars[index] == "'":
                chars[index] = " "
                index += 1
                state = "character"
                continue
        elif state == "line_comment":
            if chars[index] == "\n":
                state = "code"
            else:
                chars[index] = " "
        elif state == "block_comment":
            if pair == "/*":
                chars[index:index + 2] = "  "
                index += 2
                block_depth += 1
                continue
            if pair == "*/":
                chars[index:index + 2] = "  "
                index += 2
                block_depth -= 1
                if block_depth == 0:
                    state = "code"
                continue
            if chars[index] != "\n":
                chars[index] = " "
        elif state in {"string", "character"}:
            delimiter = '"' if state == "string" else "'"
            if chars[index] == "\\":
                chars[index] = " "
                if index + 1 < len(chars) and chars[index + 1] != "\n":
                    chars[index + 1] = " "
                    index += 1
            elif chars[index] == delimiter:
                chars[index] = " "
                state = "code"
            elif chars[index] != "\n":
                chars[index] = " "
        elif state == "multiline_string":
            if text.startswith('"""', index):
                chars[index:index + 3] = "   "
                index += 3
                state = "code"
                continue
            if chars[index] != "\n":
                chars[index] = " "
        index += 1
    return "".join(chars)


def _ast_nodes(text):
    """Return Swift AST nodes with enough structure to relate sibling attrs."""
    nodes = []
    stack = []
    quoted = False
    escaped = False
    for index, char in enumerate(text):
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
            continue
        if char == '"':
            quoted = True
        elif char == "(":
            kind_match = re.match(r"\(([a-z_]+)\b", text[index:])
            node = {
                "kind": kind_match.group(1) if kind_match else None,
                "start": index,
                "end": None,
                "parent": stack[-1] if stack else None,
                "children": [],
            }
            if stack:
                stack[-1]["children"].append(node)
            nodes.append(node)
            stack.append(node)
        elif char == ")":
            if not stack:
                raise ValueError("unbalanced swift AST output")
            stack.pop()["end"] = index + 1
    if stack:
        raise ValueError("unbalanced swift AST output")
    return nodes


def _node_text(ast, node):
    return ast[node["start"]:node["end"]]


def _is_test_attr(ast, node):
    return node["kind"] == "custom_attr" and bool(
        re.search(r'\(type_unqualified_ident id="Test"', _node_text(ast, node))
    )


def _source_slice(source, start_line, start_column, end_line, end_column):
    lines = source.splitlines(keepends=True)
    if start_line == end_line:
        return lines[start_line - 1][start_column - 1:end_column]
    selected = [lines[start_line - 1][start_column - 1:]]
    selected.extend(lines[start_line:end_line - 1])
    selected.append(lines[end_line - 1][:end_column])
    return "".join(selected)


def swift_test_functions(source):
    """Use Swift's parser AST, not source regex, to locate actual @Test funcs."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".swift", encoding="utf-8") as handle:
        handle.write(source)
        handle.flush()
        process = subprocess.run(
            ["xcrun", "swiftc", "-frontend", "-dump-parse", handle.name],
            capture_output=True,
            text=True,
            check=False,
        )
    if process.returncode:
        raise AssertionError(f"Swift parser rejected witness source: {process.stderr.strip()}")
    ast = process.stdout
    ast_nodes = _ast_nodes(ast)
    functions = []
    for function_node in (node for node in ast_nodes if node["kind"] == "func_decl"):
        node = _node_text(ast, function_node)
        name_match = re.search(r'\s"([A-Za-z_][A-Za-z0-9_]*)\([^\"]*\)"', node[:1000])
        range_match = re.search(r"range=\[[^\]]*?:(\d+):(\d+) - line:(\d+):(\d+)\]", node[:1000])
        if not name_match or not range_match:
            continue
        direct_attrs = [child for child in function_node["children"] if child["kind"] == "custom_attr"]
        sibling_attrs = []
        parent = function_node["parent"]
        if parent is not None:
            siblings = parent["children"]
            sibling_index = siblings.index(function_node)
            scan = sibling_index - 1
            while scan >= 0 and siblings[scan]["kind"] == "custom_attr":
                sibling_attrs.append(siblings[scan])
                scan -= 1
        is_test = any(_is_test_attr(ast, attr) for attr in direct_attrs + sibling_attrs)
        start_line, start_column, end_line, end_column = map(int, range_match.groups())
        functions.append({
            "name": name_match.group(1),
            "is_test": is_test,
            "source": _source_slice(source, start_line, start_column, end_line, end_column),
        })
    return functions


def _type_pattern(swift_type):
    pieces = re.split(r"([<>,\[\]\?:])", swift_type)
    return r"\s*".join(re.escape(piece) for piece in pieces if piece)


def _has_value_reference(code, swift_type):
    # A bare metatype comparison is bookkeeping, not executable typed evidence.
    manifested = swift_type.split("<", 1)[0].strip().split(".")[-1]
    references = list(re.finditer(rf"\b{re.escape(manifested)}\b", code))
    if any(not re.match(r"\s*\.\s*self\b", code[match.end():]) for match in references):
        return True
    type_pattern = _type_pattern(swift_type)
    return bool(re.search(
        rf"JSONDecoder\s*\(\s*\)\s*\.\s*decode\s*\(\s*{type_pattern}\s*\.\s*self\s*,\s*from\s*:",
        code,
    ))


def _balanced_end(code, opening, opener="(", closer=")"):
    """Return the end of a balanced Swift delimiter range."""
    depth = 0
    for index in range(opening, len(code)):
        if code[index] == opener:
            depth += 1
        elif code[index] == closer:
            depth -= 1
            if depth == 0:
                return index + 1
    return None


def _assertion_bodies(code):
    """Yield balanced #expect/#require argument text."""
    for assertion in re.finditer(r"#(?:expect|require)\s*\(", code):
        opening = code.find("(", assertion.start())
        end = _balanced_end(code, opening)
        if end is not None:
            yield code[opening + 1:end - 1]


def _roundtrip_bindings(code, swift_type):
    """Find value/encoded/decoded names connected by explicit data flow."""
    type_pattern = _type_pattern(swift_type)
    bindings = []
    decode_pattern = re.compile(
        rf"\blet\s+(\w+)\s*(?::\s*{type_pattern})?\s*=\s*try\s+"
        rf"JSONDecoder\s*\(\s*\)\s*\.\s*decode\s*\(\s*{type_pattern}\s*\.\s*self\s*,\s*from\s*:\s*(\w+)\s*\)"
    )
    encode_pattern = re.compile(
        r"\blet\s+(\w+)\s*=\s*try\s+JSONEncoder\s*\(\s*\)\s*\.\s*encode\s*\(\s*(\w+)\s*\)"
    )
    encoded_values = {match.group(1): match.group(2) for match in encode_pattern.finditer(code)}
    for decoded in decode_pattern.finditer(code):
        decoded_name, encoded_name = decoded.groups()
        if encoded_name in encoded_values:
            bindings.append((decoded_name, encoded_values[encoded_name]))
    return bindings


def _normalized_member_path(path):
    return re.sub(r"\s+|\?", "", path)


def _has_source_linked_equality(assertions, decoded_name, value_name):
    member_path = r"((?:\s*\??\.\s*[A-Za-z_]\w*)+)"
    decoded = re.escape(decoded_name)
    value = re.escape(value_name)
    whole_value = re.compile(
        rf"(?:\b{decoded}\b(?!\s*\??\.)\s*==\s*\b{value}\b(?!\s*\??\.)"
        rf"|\b{value}\b(?!\s*\??\.)\s*==\s*\b{decoded}\b(?!\s*\??\.))"
    )
    forward_fields = re.compile(rf"\b{decoded}\b{member_path}\s*==\s*\b{value}\b{member_path}")
    reverse_fields = re.compile(rf"\b{value}\b{member_path}\s*==\s*\b{decoded}\b{member_path}")
    for body in assertions:
        if whole_value.search(body):
            return True
        for pattern in (forward_fields, reverse_fields):
            if any(
                _normalized_member_path(match.group(1)) == _normalized_member_path(match.group(2))
                for match in pattern.finditer(body)
            ):
                return True
    return False


def _has_roundtrip_equality(code, swift_type, helper_call, has_pinned_type):
    assertions = list(_assertion_bodies(code))
    bindings = _roundtrip_bindings(code, swift_type)
    for decoded_name, value_name in bindings:
        if _has_source_linked_equality(assertions, decoded_name, value_name):
            return True

    # Also accept an inline decode only when its input is the output binding of
    # an encoder and the equality's other operand is that encoder's value.
    type_pattern = _type_pattern(swift_type)
    encoded_values = {
        match.group(1): match.group(2)
        for match in re.finditer(
            r"\blet\s+(\w+)\s*=\s*try\s+JSONEncoder\s*\(\s*\)\s*\.\s*encode\s*\(\s*(\w+)\s*\)",
            code,
        )
    }
    inline_decode = re.compile(
        rf"JSONDecoder\s*\(\s*\)\s*\.\s*decode\s*\(\s*{type_pattern}\s*\.\s*self\s*,\s*from\s*:\s*(\w+)\s*\)\s*==\s*(\w+)"
    )
    for body in assertions:
        for match in inline_decode.finditer(body):
            encoded_name, compared_name = match.groups()
            encoded_value = encoded_values.get(encoded_name)
            if encoded_value == compared_name:
                return True
            if re.search(
                rf"JSONEncoder\s*\(\s*\)\s*\.\s*encode\s*\(\s*{re.escape(compared_name)}\s*\)",
                code,
            ):
                return True

    # A typed roundTrip helper returns its input's value. Require that call to
    # participate in an asserted equality or feed asserted decoded fields.
    if helper_call and has_pinned_type:
        for body in assertions:
            if re.search(r"\broundTrip\s*\([^)]*\).*==|==.*\broundTrip\s*\(", body, re.DOTALL):
                return True
        helper_binding = re.compile(r"\blet\s+(\w+)\s*(?::[^=]+)?=\s*try\s+roundTrip\s*\(")
        for binding in helper_binding.finditer(code):
            result_name = binding.group(1)
            if any(re.search(rf"\b{re.escape(result_name)}\b", body) for body in assertions):
                return True
            guard_match = re.search(
                rf"\bguard\s+case\s+(.+?)\s*=\s*{re.escape(result_name)}\s+else\b",
                code[binding.end():],
                re.DOTALL,
            )
            if guard_match:
                captures = re.findall(r"\blet\s+(\w+)", guard_match.group(1))
                if captures and any(
                    re.search(rf"\b{re.escape(capture)}\b", body)
                    for capture in captures
                    for body in assertions
                ):
                    return True
    return False


def _throw_assertion_bodies(code):
    """Yield the closure body attached to each throws assertion."""
    for assertion in re.finditer(r"#expect\s*\(\s*throws\s*:", code):
        arguments_end = _balanced_end(code, code.find("(", assertion.start()))
        if arguments_end is None:
            continue
        opening = arguments_end
        while opening < len(code) and code[opening].isspace():
            opening += 1
        if opening >= len(code) or code[opening] != "{":
            continue
        end = _balanced_end(code, opening, "{", "}")
        if end is not None:
            yield code[opening + 1:end - 1]


def _has_type_specific_negative(code, type_name, swift_type):
    type_pattern = _type_pattern(swift_type)
    constructor_pattern = re.compile(rf"\b{re.escape(type_name)}\s*\(")
    decoder_pattern = re.compile(
        rf"JSONDecoder\s*\(\s*\)\s*\.\s*decode\s*\(\s*{type_pattern}\s*\.\s*self\s*,"
    )
    for body in _throw_assertion_bodies(code):
        if constructor_pattern.search(body) or decoder_pattern.search(body):
            return True
    return False


def validate_semantic_witnesses(entries, contract_rows, sources):
    failures = []
    manifest_by_type = {entry["type"]: entry for entry in entries}
    contract_counts = Counter(row.get("type") for row in contract_rows)
    for type_name, count in sorted(contract_counts.items(), key=lambda pair: str(pair[0])):
        if count != 1:
            failures.append({"code": "duplicate-contract-row", "type": type_name, "count": count})
    manifest_types = set(manifest_by_type)
    contract_types = set(contract_counts)
    if manifest_types != contract_types:
        failures.append({
            "code": "contract-key-mismatch",
            "missing": sorted(manifest_types - contract_types),
            "extra": sorted(contract_types - manifest_types),
        })

    parsed = {path: swift_test_functions(source) for path, source in sources.items()}
    all_locations = {}
    for path, functions in parsed.items():
        for function in functions:
            all_locations.setdefault(function["name"], []).append((path, function))

    for row in contract_rows:
        type_name = row.get("type")
        if type_name not in manifest_by_type or contract_counts[type_name] != 1:
            continue
        expected_test = manifest_by_type[type_name]["test"]
        expected_witness = f"semanticCoverage_{type_name}"
        if row.get("test") != expected_test:
            failures.append({"code": "contract-test-mismatch", "type": type_name})
        if row.get("witness") != expected_witness:
            failures.append({"code": "contract-witness-mismatch", "type": type_name})
            continue
        locations = all_locations.get(expected_witness, [])
        assigned = [(path, function) for path, function in locations if path == expected_test and function["is_test"]]
        if not assigned:
            code = "moved-witness" if locations else "missing-witness"
            failures.append({"code": code, "type": type_name, "locations": [path for path, _ in locations]})
            continue
        if len(locations) != 1 or len(assigned) != 1:
            failures.append({"code": "duplicate-witness", "type": type_name, "locations": [path for path, _ in locations]})
            continue

        code = mask_swift_noncode(assigned[0][1]["source"])
        swift_type = row.get("swift_type", type_name)
        if not _has_value_reference(code, swift_type):
            failures.append({"code": "missing-typed-reference", "type": type_name})
        if not re.search(r"#(?:expect|require)\s*\(", code):
            failures.append({"code": "missing-assertion", "type": type_name})
        requirements = set(row.get("requires", []))
        if "roundtrip" in requirements:
            type_pattern = _type_pattern(swift_type)
            has_explicit_encode = bool(re.search(r"JSONEncoder\s*\(\s*\)\s*\.\s*encode\s*\(", code))
            has_explicit_decode = bool(re.search(
                rf"JSONDecoder\s*\(\s*\)\s*\.\s*decode\s*\(\s*{type_pattern}\s*\.\s*self\s*,\s*from\s*:",
                code,
            ))
            helper_call = bool(re.search(r"\broundTrip\s*\(", code))
            # Shared helpers remain auditable only when the row pins the exact
            # specialization in a typed binding; normalize generic spacing.
            compact_code = re.sub(r"\s+", "", code)
            compact_type = re.sub(r"\s+", "", swift_type)
            has_pinned_type = bool(re.search(
                rf"(?::|\[){re.escape(compact_type)}(?=$|[=,\]){{}}])",
                compact_code,
            ))
            if not (has_explicit_encode and has_explicit_decode) and not (helper_call and has_pinned_type):
                failures.append({"code": "missing-roundtrip", "type": type_name})
            if not _has_roundtrip_equality(code, swift_type, helper_call, has_pinned_type):
                failures.append({"code": "missing-roundtrip-equality", "type": type_name})
        if "negative" in requirements:
            if not _has_type_specific_negative(code, type_name, swift_type):
                failures.append({"code": "missing-negative", "type": type_name})
    return failures


def _matching_brace(code, opening):
    depth = 0
    for index in range(opening, len(code)):
        if code[index] == "{":
            depth += 1
        elif code[index] == "}":
            depth -= 1
            if depth == 0:
                return index
    return len(code) - 1


def find_alias_and_wrapper_violations(relative_path, source, manifested_types):
    code = mask_swift_noncode(source)
    names_pattern = "|".join(sorted(map(re.escape, manifested_types), key=len, reverse=True))
    type_ref = rf"(?:\bWatchShared\s*\.\s*)?\b({names_pattern})\b"
    violations = []
    aliases = {}
    for match in re.finditer(r"\btypealias\s+(\w+)\s*=\s*([^\n;}}]+)", code):
        alias, target = match.groups()
        aliases[alias] = target
        direct = re.search(type_ref, target)
        if alias in manifested_types or direct:
            violations.append({"code": "manifest-typealias", "path": relative_path, "declaration": alias, "type": direct.group(1) if direct else alias})
    changed = True
    while changed:
        changed = False
        for alias, target in aliases.items():
            if any(re.search(rf"\b{re.escape(resolved)}\b", target) for resolved in manifested_types | set(aliases) if resolved != alias):
                for resolved, resolved_target in aliases.items():
                    resolved_match = re.search(type_ref, resolved_target)
                    if resolved != alias and re.search(rf"\b{re.escape(resolved)}\b", target) and resolved_match:
                        if not any(item["declaration"] == alias for item in violations):
                            violations.append({"code": "manifest-typealias-chain", "path": relative_path, "declaration": alias, "type": resolved_match.group(1)})
                            changed = True

    for declaration in re.finditer(r"\b(?:struct|class|enum)\s+(\w+)[^\n{]*\{", code):
        name = declaration.group(1)
        opening = code.find("{", declaration.start())
        body = code[opening + 1:_matching_brace(code, opening)]
        stored = list(re.finditer(r"\b(?:let|var)\s+(\w+)\s*:\s*([^=\n{]+)", body))
        manifested_stored = []
        for field in stored:
            target = re.search(type_ref, field.group(2))
            if target:
                manifested_stored.append((field.group(1), target.group(1)))
        cases = list(re.finditer(r"\bcase\s+(\w+)\s*\(([^)]*)\)", body))
        manifested_cases = []
        for case in cases:
            target = re.search(type_ref, case.group(2))
            if target:
                manifested_cases.append((case.group(1), target.group(1)))
        transparent = len(stored) == 1 and len(manifested_stored) == 1
        for field, target in manifested_stored:
            key = (relative_path, name, field, target)
            if transparent and key not in AGGREGATE_CONSUMER_ALLOWLIST:
                violations.append({"code": "transparent-wrapper", "path": relative_path, "declaration": name, "member": field, "type": target})
        for case, target in manifested_cases:
            key = (relative_path, name, case, target)
            if key not in AGGREGATE_CONSUMER_ALLOWLIST:
                violations.append({"code": "wrapper-enum-case", "path": relative_path, "declaration": name, "member": case, "type": target})

    for extension in re.finditer(r"\bextension\s+(\w+)[^\n{]*\{", code):
        name = extension.group(1)
        opening = code.find("{", extension.start())
        body = code[opening + 1:_matching_brace(code, opening)]
        for property_match in re.finditer(r"\bvar\s+(\w+)\s*:\s*([^\n{=]+)\s*\{", body):
            target = re.search(type_ref, property_match.group(2))
            if target and (relative_path, name, property_match.group(1), target.group(1)) not in AGGREGATE_CONSUMER_ALLOWLIST:
                violations.append({"code": "extension-forwarder", "path": relative_path, "declaration": name, "member": property_match.group(1), "type": target.group(1)})
    return violations


def repository_swift_files(root):
    candidates = []
    for path in root.rglob("*.swift"):
        relative = path.relative_to(root)
        if SWIFT_SCAN_EXCLUDED_PARTS.intersection(relative.parts):
            continue
        if relative.is_relative_to(CANONICAL_SHARED_SOURCES):
            continue
        candidates.append(path)
    return sorted(candidates)


def find_repository_alias_and_wrapper_violations(root, manifested_types):
    failures = []
    for path in repository_swift_files(root):
        failures.extend(find_alias_and_wrapper_violations(
            path.relative_to(root).as_posix(),
            path.read_text(),
            manifested_types,
        ))
    return failures


class U01cManifestCoverageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.entries = json.loads(MANIFEST.read_text())["entries"]
        cls.contract = json.loads(WITNESS_CONTRACT.read_text())["entries"]

    def test_manifest_and_witness_contract_have_exactly_130_unique_rows(self):
        self.assertEqual(len(self.entries), 130)
        self.assertEqual(len({entry["type"] for entry in self.entries}), 130)
        self.assertEqual(len(self.contract), 130)
        self.assertEqual(len({row["type"] for row in self.contract}), 130)
        self.assertEqual({entry["type"] for entry in self.entries}, {row["type"] for row in self.contract})
        for row in self.contract:
            self.assertEqual(row["witness"], f"semanticCoverage_{row['type']}")
            self.assertIn("compile", row["requires"])
            self.assertIn("assertion", row["requires"])
            self.assertTrue("roundtrip" in row["requires"] or row.get("roundtrip_exception"), row)
            self.assertTrue("negative" in row["requires"] or row.get("negative_exception"), row)

    def test_each_row_has_one_repository_declaration_in_manifested_owner(self):
        swift_files = [path for path in ROOT.rglob("*.swift") if "/.build/" not in str(path) and "/DerivedData" not in str(path)]
        failures = []
        for entry in self.entries:
            pattern = re.compile(DECLARATION_TEMPLATE.format(name=re.escape(entry["type"])))
            owners = [path.relative_to(ROOT).as_posix() for path in swift_files if pattern.search(mask_swift_noncode(path.read_text()))]
            if owners != [entry["source"]]:
                failures.append({"type": entry["type"], "expected": entry["source"], "actual": owners})
        self.assertEqual(failures, [])

    def test_each_row_has_exact_semantic_witness_in_assigned_test(self):
        paths = {entry["test"] for entry in self.entries}
        sources = {path: (ROOT / path).read_text() for path in paths}
        failures = validate_semantic_witnesses(self.entries, self.contract, sources)
        self.assertEqual(failures, [])

    def test_no_alias_or_transparent_wrapper_shadows_manifested_types(self):
        manifested_types = {entry["type"] for entry in self.entries}
        failures = find_repository_alias_and_wrapper_violations(ROOT, manifested_types)
        self.assertEqual(failures, [])


class SemanticWitnessCheckerMutationTests(unittest.TestCase):
    ENTRY = {"type": "Example", "test": "Tests/ExampleTests.swift"}
    CONTRACT = {"type": "Example", "test": "Tests/ExampleTests.swift", "witness": "semanticCoverage_Example", "swift_type": "Example", "requires": ["compile", "assertion", "roundtrip", "negative"]}
    VALID = """
    @Test
    func semanticCoverage_Example() throws {
        let value = try Example(rawValue: "sentinel")
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(Example.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: ExampleError.self) {
            _ = try Example(rawValue: "")
        }
    }
    """

    def assert_rejected(self, sources, code):
        failures = validate_semantic_witnesses([self.ENTRY], [self.CONTRACT], sources)
        self.assertIn(code, {failure["code"] for failure in failures}, failures)

    def test_valid_semantic_witness_is_accepted(self):
        self.assertEqual(validate_semantic_witnesses([self.ENTRY], [self.CONTRACT], {self.ENTRY["test"]: self.VALID}), [])

    def test_comment_and_string_mentions_do_not_count_as_witnesses(self):
        for decoy in ("// @Test func semanticCoverage_Example() { Example() }", 'let decoy = "@Test func semanticCoverage_Example() { Example() }"'):
            with self.subTest(decoy=decoy):
                self.assert_rejected({self.ENTRY["test"]: decoy}, "missing-witness")

    def test_type_self_only_does_not_count_as_typed_evidence(self):
        source = """@Test func semanticCoverage_Example() { let value = Example.self; #expect(value == Example.self) }"""
        self.assert_rejected({self.ENTRY["test"]: source}, "missing-typed-reference")

    def test_deleted_witness_is_rejected(self):
        self.assert_rejected({self.ENTRY["test"]: ""}, "missing-witness")

    def test_moved_witness_is_rejected(self):
        self.assert_rejected({self.ENTRY["test"]: "", "Tests/OtherTests.swift": self.VALID}, "moved-witness")

    def test_removed_equality_assertion_is_rejected(self):
        self.assert_rejected({self.ENTRY["test"]: self.VALID.replace("#expect(decoded == value)", "_ = decoded")}, "missing-roundtrip-equality")

    def test_unrelated_equality_does_not_count_as_roundtrip_evidence(self):
        source = self.VALID.replace("#expect(decoded == value)", "#expect(1 == 1)")
        self.assert_rejected({self.ENTRY["test"]: source}, "missing-roundtrip-equality")

    def test_wrong_roundtrip_value_does_not_count_as_roundtrip_evidence(self):
        source = self.VALID.replace(
            "let decoded = try JSONDecoder().decode(Example.self, from: encoded)",
            "let other = try Example(rawValue: \"other\")\n"
            "        let decoded = try JSONDecoder().decode(Example.self, from: encoded)",
        ).replace("#expect(decoded == value)", "#expect(decoded == other)")
        self.assert_rejected({self.ENTRY["test"]: source}, "missing-roundtrip-equality")

    def test_decoded_field_self_comparison_does_not_count_as_roundtrip_evidence(self):
        source = self.VALID.replace(
            "#expect(decoded == value)",
            "#expect(decoded.rawValue == value.rawValue)",
        )
        self.assertEqual(
            validate_semantic_witnesses(
                [self.ENTRY],
                [self.CONTRACT],
                {self.ENTRY["test"]: source},
            ),
            [],
        )
        mutations = {
            "self": source.replace(
                "decoded.rawValue == value.rawValue",
                "decoded.rawValue == decoded.rawValue",
            ),
            "constant": source.replace(
                "decoded.rawValue == value.rawValue",
                'decoded.rawValue == "sentinel"',
            ),
            "unrelated": source.replace(
                "let decoded = try JSONDecoder().decode(Example.self, from: encoded)",
                "let other = try Example(rawValue: \"other\")\n"
                "        let decoded = try JSONDecoder().decode(Example.self, from: encoded)",
            ).replace(
                "decoded.rawValue == value.rawValue",
                "decoded.rawValue == other.rawValue",
            ),
        }
        for name, mutated in mutations.items():
            with self.subTest(name=name):
                self.assert_rejected({self.ENTRY["test"]: mutated}, "missing-roundtrip-equality")

    def test_removed_throw_assertion_is_rejected(self):
        self.assert_rejected({self.ENTRY["test"]: self.VALID.replace("#expect(throws: ExampleError.self)", "do")}, "missing-negative")

    def test_unrelated_negative_fixture_does_not_count_as_negative_evidence(self):
        source = self.VALID.replace(
            '_ = try Example(rawValue: "")',
            '_ = try JSONDecoder().decode(String.self, from: Data("not-json".utf8))',
        )
        self.assert_rejected({self.ENTRY["test"]: source}, "missing-negative")

    def test_duplicate_witness_is_rejected(self):
        self.assert_rejected({self.ENTRY["test"]: self.VALID + "\n" + self.VALID}, "duplicate-witness")

    def test_alias_target_and_suffix_free_wrapper_are_rejected(self):
        source = """
        typealias Local = [WatchShared.Example?]
        struct InnocentName { let payload: Example }
        """
        codes = {item["code"] for item in find_alias_and_wrapper_violations("App/File.swift", source, {"Example"})}
        self.assertEqual(codes, {"manifest-typealias", "transparent-wrapper"})

    def test_repository_scan_includes_package_swift_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package_shadow = root / "Packages/HermexWatchRoot/Sources/Shadow.swift"
            generated_shadow = root / ".build/checkouts/Dependency.swift"
            test_shadow = root / "Packages/Feature/Tests/ShadowTests.swift"
            canonical_owner = root / "Packages/WatchShared/Sources/WatchShared/DTOs.swift"
            for path in (package_shadow, generated_shadow, test_shadow, canonical_owner):
                path.parent.mkdir(parents=True, exist_ok=True)
            package_shadow.write_text("struct PackageShadow { let payload: Example }")
            generated_shadow.write_text("struct GeneratedShadow { let payload: Example }")
            test_shadow.write_text("struct TestShadow { let payload: Example }")
            canonical_owner.write_text("struct Example { let payload: Example }")

            failures = find_repository_alias_and_wrapper_violations(root, {"Example"})

        self.assertEqual(
            failures,
            [{
                "code": "transparent-wrapper",
                "path": "Packages/HermexWatchRoot/Sources/Shadow.swift",
                "declaration": "PackageShadow",
                "member": "payload",
                "type": "Example",
            }],
        )


if __name__ == "__main__":
    unittest.main()
