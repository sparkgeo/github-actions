// Boundary-contract AST check (verify-ts, issue #127).
//
// Usage: node entrypoints.mjs <project dir> <files.txt> <out.json>
//
// Parses each listed file with the project's own `typescript` and reports its
// exported functions (declarations and exported const arrow/function
// expressions). A parameter is untrusted when it has no type annotation or is
// typed `unknown` or `any`. A function is validated when its body calls a
// schema parser: `.parse`, `.safeParse`, `.parseAsync`, `.safeParseAsync`
// (zod, valibot's `v.parse`), or a bare `parse`/`safeParse` (valibot named
// imports). An exported function with an untrusted parameter and no parse is
// an unvalidated entry point. Branded types (`.brand<`, `__brand`) are counted.
import { createRequire } from "node:module";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";

const [projectDir, listFile, outFile] = process.argv.slice(2);
const require = createRequire(path.join(path.resolve(projectDir), "package.json"));
const ts = require("typescript");
const PARSERS = new Set(["parse", "safeParse", "parseAsync", "safeParseAsync"]);

function validated(node) {
  let found = false;
  const visit = (n) => {
    if (found) return;
    if (ts.isCallExpression(n)) {
      const c = n.expression;
      if ((ts.isPropertyAccessExpression(c) && PARSERS.has(c.name.text)) || (ts.isIdentifier(c) && PARSERS.has(c.text))) {
        found = true;
        return;
      }
    }
    ts.forEachChild(n, visit);
  };
  visit(node);
  return found;
}

function untrusted(params) {
  return params
    .filter((p) => !p.type || p.type.kind === ts.SyntaxKind.UnknownKeyword || p.type.kind === ts.SyntaxKind.AnyKeyword)
    .map((p) => p.name.getText());
}

const isExported = (n) => (ts.getCombinedModifierFlags(n) & ts.ModifierFlags.Export) !== 0;
const files = readFileSync(listFile, "utf8").split("\n").map((l) => l.trim()).filter(Boolean);
const out = [];
for (const f of files) {
  let text;
  try {
    text = readFileSync(path.resolve(projectDir, f), "utf8");
  } catch {
    continue;
  }
  const sf = ts.createSourceFile(f, text, ts.ScriptTarget.Latest, true, f.endsWith("x") ? ts.ScriptKind.TSX : ts.ScriptKind.TS);
  const fns = [];
  const add = (name, node, fn) => {
    const line = sf.getLineAndCharacterOfPosition(node.getStart(sf)).line + 1;
    const bad = untrusted(fn.parameters);
    fns.push({ name, line, untrusted_params: bad, validated: validated(fn) });
  };
  for (const st of sf.statements) {
    if (ts.isFunctionDeclaration(st) && st.name && isExported(st)) add(st.name.text, st, st);
    if (ts.isVariableStatement(st) && isExported(st)) {
      for (const d of st.declarationList.declarations) {
        if (d.initializer && (ts.isArrowFunction(d.initializer) || ts.isFunctionExpression(d.initializer)) && ts.isIdentifier(d.name)) {
          add(d.name.text, d, d.initializer);
        }
      }
    }
  }
  const branded = (text.match(/\.brand<|__brand/g) || []).length;
  out.push({ file: f, functions: fns, branded, unvalidated: fns.filter((x) => x.untrusted_params.length && !x.validated).map((x) => x.name) });
}
writeFileSync(outFile, JSON.stringify(out, null, 1));
const n = out.reduce((a, f) => a + f.unvalidated.length, 0);
console.log(`  ${out.length} file(s) checked, ${out.reduce((a, f) => a + f.functions.length, 0)} exported function(s), ${n} unvalidated entry point(s)`);
