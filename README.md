# uniqcount

A small Swift CLI to test the distinct-element counting method from:

- Quanta article: [Computer Scientists Invent an Efficient New Way to Count](https://www.quantamagazine.org/computer-scientists-invent-an-efficient-new-way-to-count-20240516/)
- Paper: [Distinct Elements in Streams: An Algorithm for the (Text) Book (arXiv:2301.10191)](https://arxiv.org/abs/2301.10191)

## What this tool does

For a stream of tokens, the estimator keeps a small sample set `X` and a sampling probability `p`.

In simple terms:
1. Remove current token from `X` (if present).
2. Re-add it with probability `p`.
3. If `X` gets too big (hits threshold), randomly drop half of `X` and halve `p`.
4. Final estimate is `|X| / p`.

This is the same core loop as described in the paper.

## Tokenization rule

A token is built from:
- letters (`A-Z`, `a-z`)
- digits (`0-9`)
- apostrophe (`'`)

Everything else is a separator.

All tokens are lowercased.

## Quick start

```bash
curl -L 'https://www.gutenberg.org/cache/epub/1524/pg1524.txt' -o /tmp/hamlet.txt
git clone https://github.com/n3d1117/uniqcount.git
cd uniqcount && swift run --quiet uniqcount --path /tmp/hamlet.txt
```

## Run

Simple mode (default): prints a single estimated distinct count
(median of successful trials).

```bash
swift run uniqcount --path /tmp/hamlet.txt
```

Set memory/trials explicitly:

```bash
swift run uniqcount --path /tmp/hamlet.txt --memory 1000 --trials 30 --seed 42
```

Use paper-style epsilon/delta threshold:

```bash
swift run uniqcount --path /tmp/hamlet.txt --epsilon 0.1 --delta 0.05 --trials 30 --seed 42
```

Detailed mode (`--report`): prints run/trials/summary tables.

```bash
swift run uniqcount --path /tmp/hamlet.txt --memory 1000 --trials 30 --seed 42 --report
```

## Parameters

- `--path`: input UTF-8 text file
- `--trials`: number of independent runs (default `20`)
- `--seed`: base seed for reproducibility (default `42`)
- `--report`: print full tables (otherwise prints only the estimate)
- `--memory`: fixed threshold (sample cap, default `1000` when not set)
- `--epsilon --delta`: threshold from paper formula

Use either:
- `--memory`
- or `--epsilon` and `--delta`

If neither is set, `--memory` defaults to `1000`.

## Notes

- Higher `--memory` usually lowers error but uses more memory.
- The `--epsilon/--delta` threshold can be large on small files, which may make estimates exact (or near exact) in practice.
