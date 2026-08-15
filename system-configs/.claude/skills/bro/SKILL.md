---
name: bro
description: Re-explain the previous assistant message in a much simpler way — for when the reply made you go "bro what". Use when D types /bro, or says "in plain English", "say that again simpler", "explain that like a normal person", "I didn't follow that".
metadata:
  category: communication
---

# /bro

## Usage

```bash
/bro
```

No arguments. Fire it immediately after a reply that didn't land.

## Description

D just typed `/bro`. Your last message didn't land — too dense, too jargon-heavy, or
too formal. Re-explain **your own most recent message** in a much simpler way, like
you're explaining it to a smart friend over a beer.

This is the counterweight to `concise`. Concise optimises for fewest words; `/bro`
optimises for impossible-to-misunderstand, and will happily spend more words to get
there.

## Expected Output

```text
Claude: The wrapper promotes versions/<N> into current/claude when the .version
        stamp differs, so TCC's csreq revalidates against a stable path.
D:      /bro
Claude: ok so — macOS remembers "this exact file is allowed to read your
        Documents". Every update made a new file, so it forgot every time and
        asked again.

        Now there's one file that never moves: ~/.local/share/claude/current/claude.
        Updates just swap what's inside it. Same file, so macOS stays happy.
```

## Behavior

1. **Re-explain, don't re-answer.** Never answer a new question, never add new
   information, never use tools. You are only re-expressing what you already said.
2. **Simpler, not necessarily shorter.** If the idea needs space to be clear, take
   the space. The goal is "impossible to misunderstand", not "fewer words". Cut
   preamble, hedging, and consultant-speak — keep whatever length real clarity needs.
3. **Facts survive verbatim.** Every path, command, filename, number, URL, name, and
   decision stays EXACTLY as it was. Simplify the explanation around the facts, never
   the facts themselves.
4. **Light bro flavor.** Casual and direct ("basically…", "the point is…", "ok so…").
   A touch of personality is welcome — don't turn it into a meme.
5. **Same language.** If the original message was in PT-BR, the simpler version is in
   PT-BR too ("mano", "basicamente"…). English stays English.
6. **Flatten structure.** Drop headers and ceremony. Tables become plain sentences.
   Keep a short list only if the original genuinely had multiple parts.
7. **Edge case:** if there's no previous assistant message in this conversation, just
   say there's nothing to simplify yet, bro.

## Notes

- Ported from [luchasarie/bro-skill](https://github.com/luchasarie/bro-skill) (MIT).
  Rules 1–7 are upstream's, kept intact; only the file structure was adapted to this
  repo's skill format.
- Rule 2 is deliberately at odds with the `concise` output style. That is the point —
  `/bro` is an on-demand escape hatch, not a default voice. Don't "fix" it by making
  it terse.
- Related: [[eli5]] output style aims at the same problem from the other end — it
  keeps every reply simple, where `/bro` simplifies one reply on request.
