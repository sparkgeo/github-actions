// Fuzz-target and property presence check (verify-go, issue #126).
//
// Usage: go run fuzzcover.go -root DIR -pkgs pkgs.txt -mapped mapped.txt -out fuzzcover.json
//
// For each package directory in pkgs.txt (relative to -root): the Fuzz*
// targets in its _test.go files (func FuzzX(f *testing.F)), the functions
// each target calls, the test files calling rapid.Check or quick.Check, and
// every exported top-level function in its non-test files. An exported
// function in a file listed in mapped.txt is covered when some Fuzz* target
// in the package calls it (directly, as pkg.Func from an external test
// package, or as a method value). Stdlib only, so `go run` needs no module.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type function struct {
	Name     string   `json:"name"`
	File     string   `json:"file"`
	Line     int      `json:"line"`
	Mapped   bool     `json:"mapped"`
	FuzzedBy []string `json:"fuzzed_by"`
}

type pkg struct {
	Dir           string     `json:"dir"`
	FuzzTargets   []string   `json:"fuzz_targets"`
	PropertyFiles []string   `json:"property_files"`
	Functions     []function `json:"functions"`
	Uncovered     []string   `json:"uncovered"`
}

func lines(path string) map[string]bool {
	out := map[string]bool{}
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		if l := strings.TrimSpace(s.Text()); l != "" {
			out[filepath.ToSlash(filepath.Clean(l))] = true
		}
	}
	return out
}

func isFuzz(fn *ast.FuncDecl) bool {
	if fn.Recv != nil || !strings.HasPrefix(fn.Name.Name, "Fuzz") || fn.Type.Params == nil || len(fn.Type.Params.List) != 1 {
		return false
	}
	star, ok := fn.Type.Params.List[0].Type.(*ast.StarExpr)
	if !ok {
		return false
	}
	sel, ok := star.X.(*ast.SelectorExpr)
	return ok && sel.Sel.Name == "F"
}

func main() {
	root := flag.String("root", ".", "module or project root")
	pkgsFile := flag.String("pkgs", "", "package directories, one per line")
	mappedFile := flag.String("mapped", "", "mapped non-test .go files, one per line")
	out := flag.String("out", "fuzzcover.json", "output JSON")
	flag.Parse()
	mapped := lines(*mappedFile)
	dirs := lines(*pkgsFile)
	keys := make([]string, 0, len(dirs))
	for d := range dirs {
		keys = append(keys, d)
	}
	sort.Strings(keys)
	fset := token.NewFileSet()
	result := []pkg{}
	for _, dir := range keys {
		files, _ := filepath.Glob(filepath.Join(*root, dir, "*.go"))
		sort.Strings(files)
		p := pkg{Dir: dir, FuzzTargets: []string{}, PropertyFiles: []string{}, Functions: []function{}, Uncovered: []string{}}
		calledBy := map[string][]string{}
		for _, path := range files {
			f, err := parser.ParseFile(fset, path, nil, parser.SkipObjectResolution)
			if err != nil {
				continue
			}
			rel, _ := filepath.Rel(*root, path)
			rel = filepath.ToSlash(rel)
			if strings.HasSuffix(path, "_test.go") {
				prop := false
				ast.Inspect(f, func(n ast.Node) bool {
					if c, ok := n.(*ast.CallExpr); ok {
						if s, ok := c.Fun.(*ast.SelectorExpr); ok && s.Sel.Name == "Check" {
							if x, ok := s.X.(*ast.Ident); ok && (x.Name == "rapid" || x.Name == "quick") {
								prop = true
							}
						}
					}
					return true
				})
				if prop {
					p.PropertyFiles = append(p.PropertyFiles, rel)
				}
				for _, d := range f.Decls {
					fn, ok := d.(*ast.FuncDecl)
					if !ok || !isFuzz(fn) {
						continue
					}
					p.FuzzTargets = append(p.FuzzTargets, fn.Name.Name)
					ast.Inspect(fn.Body, func(n ast.Node) bool {
						switch e := n.(type) {
						case *ast.Ident:
							calledBy[e.Name] = append(calledBy[e.Name], fn.Name.Name)
						case *ast.SelectorExpr:
							calledBy[e.Sel.Name] = append(calledBy[e.Sel.Name], fn.Name.Name)
						}
						return true
					})
				}
				continue
			}
			for _, d := range f.Decls {
				fn, ok := d.(*ast.FuncDecl)
				if !ok || fn.Recv != nil || !fn.Name.IsExported() {
					continue
				}
				p.Functions = append(p.Functions, function{Name: fn.Name.Name, File: rel, Line: fset.Position(fn.Pos()).Line, Mapped: mapped[rel]})
			}
		}
		// calledBy is complete only after every test file was read
		for i := range p.Functions {
			p.Functions[i].FuzzedBy = uniq(calledBy[p.Functions[i].Name])
			if p.Functions[i].Mapped && len(p.Functions[i].FuzzedBy) == 0 {
				p.Uncovered = append(p.Uncovered, p.Functions[i].Name)
			}
		}
		result = append(result, p)
	}
	b, _ := json.MarshalIndent(result, "", " ")
	if err := os.WriteFile(*out, append(b, '\n'), 0o644); err != nil {
		panic(err)
	}
}

func uniq(xs []string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, x := range xs {
		if !seen[x] {
			seen[x] = true
			out = append(out, x)
		}
	}
	sort.Strings(out)
	return out
}
