# calltree.sh

ASCII call tree generator for a single C++ file.  
Parses function definitions and call edges statically using Perl, then renders them as a tree in the terminal.  
Optionally exports to Mermaid (GitHub-renderable), Graphviz DOT, and plain text.

```
ingest()  -> void
└── get_or_create()  -> MetaWriters&
    ├── bucket_key()  -> std::string
    │   ├── bucket_week()  -> uint8_t
    │   └── year_month()  -> std::string
    ├── make_dir()  -> std::string
    ├── make_writer()  -> std::unique_ptr<ROOT::RNTupleWriter>
    │   └── make_fields()  -> void
    └── rotate()  -> void
        ├── bucket_key()  -> std::string
        │   ├── bucket_week()  -> uint8_t
        │   └── year_month()  -> std::string
        ├── make_dir()  -> std::string
        └── make_writer()  -> std::unique_ptr<ROOT::RNTupleWriter>
            └── make_fields()  -> void
```

---

## Dependencies

| Dep | Notes |
|-----|-------|
| `bash` | >= 4.0 |
| `perl` | Standard on Linux and macOS, no extra modules needed |
| `graphviz` | Optional — only needed to render `.dot` output (`dot -Tsvg`) |

---

## Installation

```bash
git clone https://github.com/MoonFlowww/CallTree
cd CallTree
chmod +x calltree.sh
```

Or drop `calltree.sh` anywhere on your `$PATH`:

```bash
cp calltree.sh ~/.local/bin/calltree
```

---

## Usage

```
./calltree.sh <file.cpp> [OPTIONS]
```

### Options

| Flag | Argument | Default | Description |
|------|----------|---------|-------------|
| `--depth` | `N` | `4` | Recursion depth in the tree |
| `--root` | `FUNC` | auto | Start tree from a specific function instead of auto-detected roots |
| `--out-mermaid` | `[FILE]` | `<file>.mmd` | Write Mermaid graph to file (renders in GitHub/GitLab/Notion) |
| `--out-dot` | `[FILE]` | `<file>.dot` | Write Graphviz DOT to file |
| `--out-txt` | `[FILE]` | `<file>.txt` | Write plain-text tree to file (no ANSI codes) |
| `--color` | — | off | Colorize function names in terminal using 256-color ANSI |

File arguments for `--out-*` flags are optional. When omitted, the output filename is derived from the input file:

```bash
./calltree.sh src/foo.cpp --out-mermaid          # writes src/foo.mmd
./calltree.sh src/foo.cpp --out-mermaid graph.mmd # writes graph.mmd
```

---

## Examples

### Basic tree

```bash
./calltree.sh src/sink/rntuple.hpp
```

### Limit depth

```bash
./calltree.sh src/sink/rntuple.hpp --depth 2
```

```
ingest()  -> void
└── get_or_create()  -> MetaWriters&
    ├── bucket_key()  -> std::string
    ├── make_dir()  -> std::string
    ├── make_writer()  -> std::unique_ptr<ROOT::RNTupleWriter>
    └── rotate()  -> void
```

### Start from a specific function
```bash
./calltree.sh src/sink/rntuple.hpp --root rotate
```
> **rotate** is the name of the function that you want to take as "root"
```
rotate()  -> void
├── bucket_key()  -> std::string
│   ├── bucket_week()  -> uint8_t
│   └── year_month()  -> std::string
├── make_dir()  -> std::string
└── make_writer()  -> std::unique_ptr<ROOT::RNTupleWriter>
    └── make_fields()  -> void
```

### Terminal colors

```bash
./calltree.sh src/sink/rntuple.hpp --color
```

Each function name is assigned a unique 256-color ANSI color.  
Colors are derived from the sorted function list so they stay stable across runs.  
The usable palette is clamped to indices `40–210` — near-black and near-white tones are excluded.

```
color index = 40 + round(170 * i / (N - 1))
```

Colors also apply in the summary table's `calls` column.

### Export to Mermaid

```bash
./calltree.sh src/sink/rntuple.hpp --out-mermaid
```

Writes `src/sink/rntuple.mmd`, fenced in ` ```mermaid ``` ` blocks so it renders directly when pasted into a GitHub README, GitLab wiki, or Notion page.

```markdown
```mermaid
graph TD
    bucket_key["std::string bucket_key()"]
    bucket_week["uint8_t bucket_week()"]
    ...
    ingest --> get_or_create
    get_or_create --> bucket_key
    ...
```
```

### Export to Graphviz DOT

```bash
./calltree.sh src/sink/rntuple.hpp --out-dot
```

Render the `.dot` file to SVG or PNG:

```bash
dot -Tsvg -o graph.svg src/sink/rntuple.dot
dot -Tpng -o graph.png src/sink/rntuple.dot
```

Node labels include the return type and call frequency:

```dot
digraph calltree {
    graph [label="../src/sink/rntuple.hpp" labelloc=t fontname="Courier" fontsize=14];
    node  [shape=box fontname="Courier" style=filled fillcolor="#f5f5f5"];
    rankdir=LR;

    "rotate" [label="void\nrotate()\ncalled: 1"];
    "ingest" -> "get_or_create";
    "get_or_create" -> "rotate";
    ...
}
```

### Export to plain text

```bash
./calltree.sh src/sink/rntuple.hpp --out-txt
```

Identical layout to the terminal output, with no ANSI codes — safe to `grep`, `diff`, or commit.

### All outputs at once

```bash
./calltree.sh src/sink/rntuple.hpp --color --out-mermaid --out-dot --out-txt
```

---

## Summary table

The table is always printed below the tree:

```
  function                      called  calls                                     return type
  ────────────────────────────  ──────  ────────────────────────────────────────  ──────────────────────
  bucket_key                         4  bucket_week year_month                    std::string
  bucket_week                        1  ----                                      uint8_t
  get_or_create                      1  bucket_key make_dir make_writer rotate    MetaWriters&
  ingest                             0  get_or_create                             void
  make_dir                           2  ----                                      std::string
  make_fields                        1  ----                                      void
  make_writer                        2  make_fields                               std::unique_ptr<ROOT::RNTupleWriter>
  RNTuples                           0  ----                                      void
  rotate                             1  bucket_key make_dir make_writer           void
  year_month                         1  ----                                      std::string
```

| Column | Description |
|--------|-------------|
| `function` | Function name as defined in the file |
| `called` | Total number of times this function is invoked across all callers |
| `calls` | Space-separated list of functions this function calls |
| `return type` | Extracted from the line preceding the function definition |

---

## How it works

### What counts as a function

The Perl parser matches any identifier of the form:

```
name(...) [const|override|noexcept...] {
```

This captures free functions, class methods, and constructors. Control-flow keywords (`if`, `for`, `while`, `switch`, etc.) are explicitly excluded. Member calls (`obj.foo()`, `ptr->foo()`) are excluded by rejecting identifiers immediately preceded by `.` or `->`.

### Return type extraction

For each matched definition, the parser walks backward to the start of the line, strips scope prefixes (`Foo::`) and storage-class keywords (`static`, `inline`, `constexpr`, `consteval`, `constinit`, `noexcept`, `requires`, `co_await`, `co_return`, `co_yield`, `virtual`, `explicit`, `extern`, `friend`), and treats whatever remains as the return type. Falls back to `void` when the prefix is empty or syntactic noise only.

### Call edge detection

For every function `F`, `extract_body()` locates its braced body by counting brace depth from the opening `{`. The body text is then scanned for occurrences of every other known function name followed by `(`, not preceded by `.` or `->`. Each hit is counted; the total across all callers is the `called` frequency in the table.

### Cycle detection

The tree emitter threads a colon-delimited `VISITED` string down the call stack. If a node appears in its own ancestor path, it is printed with `[cycle]` and recursion stops. Nodes reached via different paths are drawn in full — both call sites are real and belong in the documentation.

---

## Limitations

- Single-file only: cross-file calls are not resolved.
- The parser is regex-based, not a full AST. Complex declarations (multi-line signatures, macro-wrapped definitions, trailing return types) may not be detected.
- Template specialisations (`process<T>` vs `process<U>`) map to the same base name.
- `#define`d pseudo-functions are not detected.
