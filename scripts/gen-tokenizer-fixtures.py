# Writes LodgeTests/Fixtures/tokenizer-fixtures.json from the original Hugging Face tokenizer:
# uv run --with tokenizers==0.22.1 python scripts/gen-tokenizer-fixtures.py tokenizer.json LodgeTests/Fixtures/tokenizer-fixtures.json

import json, sys
from tokenizers import Tokenizer
tok = Tokenizer.from_file(sys.argv[1])
strings = [
    "", " ", "  ", "a", "Hello, world!", "  leading and trailing  ", "multiple   spaces\tand\ttabs",
    "line one\nline two\n\n\nthree", "\r\nwindows\r\nlines",
    "EACCES: permission denied, open '/usr/local/lib/node_modules/.package-lock.json'",
    "Invoice #INV-2026-0042 total due: $1,240.00 by 2026-11-01",
    "func fibonacci(_ n: Int) -> Int { n < 2 ? n : fibonacci(n - 1) + fibonacci(n - 2) }",
    "SELECT id, email FROM users WHERE created_at > NOW() - INTERVAL '7 days';",
    "https://github.com/ARahim3/DigUp?tab=readme-ov-file#install",
    "Knez Mihailova 12, 11000 Beograd — Србија, ćevapi i šljivovica",
    "日本語のテキストと中文文本，还有한국어 텍스트",
    "আমি বাংলায় গান গাই", "مرحبا بالعالم، كيف حالك؟", "Привет, как дела?",
    "emoji 😀👍🏽🇷🇸 family 👨‍👩‍👧‍👦 done", "zero​width nbsp",
    "<bos> literal <eos> and <pad> tokens", "<start_of_turn>user hi<end_of_turn>", "<unk>",
    "task: search result | query: cake recipe", "title: none | text: 2 cups flour, 3 eggs",
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "\u0007\u0001control\u007f chars", "rare glyphs: \U0001D11E \U0001F9EC ☃ ﷽ \U00020000",
    "Ünïcödé àccénts naïve café résumé", "tab\tseparated\tvalues\n1\t2\t3",
    "    indented python:\n        return x ** 2  # square\n",
    "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. " * 6,
]
out = []
for s in strings:
    enc = tok.encode(s)
    out.append({"text": s, "ids": enc.ids})
json.dump(out, open(sys.argv[2], "w"), ensure_ascii=False, separators=(",", ":"))
print(len(out), "fixtures;", sum(len(o["ids"]) for o in out), "tokens")
