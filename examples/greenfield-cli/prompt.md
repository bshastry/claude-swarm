# Task: Build a CLI file-search tool

## Goal

Build `fsearch`, a fast CLI tool in Go that recursively
searches files by name pattern and content regex.
Think of it as a minimal ripgrep alternative.

## Requirements

1. Accept a positional argument for the search pattern
   (regex).
2. `-d` / `--dir` flag for the root directory (default `.`).
3. `-n` / `--name` flag for filename glob filter
   (e.g. `*.go`).
4. `-i` / `--ignore-case` flag for case-insensitive
   matching.
5. `-l` / `--files-only` flag to print only filenames
   (not matching lines).
6. Print results as `file:line_number:line_content`.
7. Skip binary files and hidden directories (`.git`, etc.).
8. Exit code 0 if matches found, 1 if none, 2 on error.

## Technical constraints

- Language: Go 1.21+.
- No external dependencies (stdlib only).
- Must compile with `go build ./...`.
- Must pass `go test ./... -race`.
- Must pass `go vet ./...`.

## Project structure

    go.mod
    main.go           — entry point, flag parsing
    search/
      search.go       — core search logic
      search_test.go  — unit tests
      walker.go       — filesystem walking
      walker_test.go  — walker tests
    testdata/          — fixture files for tests

## What to do

1. Run `git log --oneline -10` to see what other agents
   have already committed.
2. Read existing files to understand current state.
3. Pick ONE piece of work that is not yet done:
   - If nothing exists: create go.mod and main.go with
     flag parsing.
   - If main.go exists but search/ does not: create the
     search package.
   - If search exists but tests do not: write tests.
   - If tests exist but fail: fix them.
   - If everything works: add missing features or edge
     case handling.
4. Run `go build ./...` and `go test ./... -race` to
   verify your changes compile and pass.
5. Commit and push.
6. Stop — the harness restarts you with the latest state.

Do NOT rewrite files another agent already committed.
Build on top of their work.
