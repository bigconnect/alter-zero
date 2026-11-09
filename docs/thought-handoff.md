# The thought hand-off — a thought's block lingers a moment for the next cell

## The report

> prompt → thinking (medium) → flicker → the skill shows inline. It happens
> sometimes, not every time.

ClinePass, `cline-pass/deepseek-v4.1-flash-1017` at its default `medium`
thinking, asked *"Who is the current world chess champion? use skill tool
first dont produce intermediate response"*: the model thinks for a fraction of
a second, calls the `skill` tool to load `web-search`, and between the two the
screen jolts.

## What the frames showed

The run was recorded with `tmux pipe-pane` (each chunk timestamped) and
replayed through a terminal emulator one synchronized frame at a time — each
frame is everything up to an `ESC[?2026l`, exactly what a mode-2026 terminal
presents at once. Nothing was torn: no purge rebuild, no region clear, no
byte outside a synchronized update. What moved was the box (100×30, a fresh
screen):

| frame | time | footer row | what the frame shows |
| --- | --- | --- | --- |
| #32 | 13 145 ms | 16 | `● Thinking…` over three rows of thought |
| #33 | 13 169 ms | **13** | `Thought for 0s · 50 tokens` committed; the strip is the status line alone |
| #34–35 | to 13 236 ms | **13** | the same, the box three rows up with blank rows under the footer |
| #36 | 13 251 ms | 16 | `● Skill(web-search)` committed; the box back down |

Down, up three rows, down again ~80 ms later: the flicker.

## Why

The live region is **content-anchored** (CLAUDE.md invariant 3): a frame that
commits `c` rows to scrollback pushes it down by `c`, and a frame whose region
is `h` rows shorter pulls its bottom up by `h`. So the box rises exactly when
the strip sheds more rows than went to scrollback in the same frame.

A thinking phase did that at every hand-off to a tool call:

- The backend closes the phase on the round's **first tool-call piece**
  (`llm::backend::stream_round` sends `ThinkingEnd` ahead of the first
  `ToolCallDelta`), and the settle committed its collapsed `Thought for …`
  line and a spacer — two rows — at once.
- The block stood on five: the `● Thinking…` header, three rows of thought
  (`REASONING_PEEK_LINES`) and the gap under them.
- The call gets a cell only when its batch is **announced**, once its
  arguments have streamed and the stream has ended. Until then the strip had
  nothing to preview — only a `write` previews while it is generated
  (`docs/write-streaming.md`).

So for as long as the call took to generate, the box sat three rows up; the
batch's cell then pushed it back down. That interval is also why it happened
*sometimes*: when the arguments, the stream's end and the batch all arrive
inside the same frame as the end of the thought (the loop coalesces at
120 fps), no frame ever shows the hole. A subagent's session view settles its
own thoughts the same way and hopped the same way.

**Not a regression.** v0.18.0, built from its tag and driven through the same
offline turn at the same size, hops at the same frames by the same rows.

## Two fixes that were replaced

**A preview floor.** Each frame, the strip reserved what its slot had a frame
ago less every row committed since, padding with blank rows —
`StreamRender`'s own rule inside a reply (`docs/slow-stream.md`), lifted to
every hand-off between the strip's cells. The hop was gone, but the padding
was **blank rows**, and they showed wherever the next content was more than a
moment away:

> it occupies 3 empty newlines — it should be 1 new line between
> `… +234 lines` and the status line indicator

That was a `bash` cell between rounds: its live tail (four output rows and its
`+N lines` footer) stood taller than its settled peek, so the floor held the
difference blank until the *next request* answered — seconds, not frames.
Measured on the same prompt: every pre-floor frame had exactly one blank row
above the status line; the floor's runs had frames with two and four.

**Holding the settled line over the thought.** The second fix recorded the
thought at `ThinkingEnd` but kept its line off scrollback (a held queue on
`InlineViewport`), and drew the block with its header settled in place — the
`Thought for …` line over the same tail of thought — until the round's next
cell took those rows. No hop, no blank rows; but the settled line stood over a
`⎿` tail of the thought for as long as the call took to generate, which is
seconds for a long command or an agent's prompt:

> Thought for 0s · 48 tokens (ctrl+o to expand)
>   ⎿ …
>
> after thinking done it should show like this, no `⎿ …`, like before

It also cost a held-line queue in the viewport, a release that every commit
ran first, a pure rule for when the hold ends, a per-frame sync and a drop in
every rebuild — some 1,200 lines with its tests and docs, for a gap that is
a tenth of a second with the models that cause it.

## The design: the block lingers a moment

The phase ends where it always did, but its **live block stays up a moment
longer** instead of collapsing at once — `● Thinking…`, its tail of thought,
the status line's `Thinking for Ns`, all unchanged. Nothing new is drawn and
nothing is held off scrollback: the thought is simply settled a little later.

- **When it settles.** At the first event that shows or records anything
  else, before that event is folded in (`Session::on_stream_event` and
  `on_agent_event` check it first) — or once `app::THOUGHT_LINGER` (300 ms)
  has passed since the phase ended, whichever comes first. The draw tick
  settles an expired one before it injects the status times
  (`Session::expire_thought_lingers`), so that frame's status line has no
  `Thinking for` clause either.
- **What lets it linger** is the one pure rule `app::lets_thought_linger`
  (`App::lets_thought_linger`, `AgentRun::lets_thought_linger`): a piece of a
  call that previews no cell, blank text while the reply is still blank, the
  round's wire ids (`RoundCalls`) and its usage frame. Everything else — a
  batch, a call's start, a task call, an agent group, the reply's first
  words, a `write` streaming into its own cell, a new phase, a hook's note, a
  steered message, a modal, a retry, the turn's end — settles it first.
- **Order is kept by construction.** The settle runs *before* the event that
  ends the linger is folded, so the thought's line lands ahead of it in
  history and scrollback alike, and the new content takes the block's rows
  in the same frame. A batch announced inside the window therefore goes from
  the block straight to the line plus the cell:

```
● Thinking…                                        ← the block, lingering
  ⎿  The user wants me to list files …
     Let me use the bash tool with `ls -la`.

⣀⣀⣀⣀⣘⣃⣀⣀ Working… (0s · ↓ 89 tokens · Thinking for 0s · esc to interrupt)
```

```
Thought for 0s · 42 tokens (ctrl+o to expand)      ← committed, on the header's row
                                                   ← its spacer
● Bash(ls -la)                                     ← the cell, on the block's rows
  ⎿  Running… (0s · wait 2m)

⣀⣀⣀⣀⣘⣃⣀⣀ Working… (0s · ↓ 4.3k tokens · esc to interrupt)
```

- **The usage frame waits for the thought.** The round's usage frame arrives
  before its batch, and a frame snaps the round's thoughts to the provider's
  `reasoning_tokens` (`docs/thinking-stream.md`). Ending the linger there
  would have let a draw slip in between the frame and the batch — the hole
  again, a frame long. So the frame lingers too, and its reasoning count
  waits for the thought (`App::snap_round_reasoning`,
  `AgentRun::snap_round_reasoning`): once the thought is recorded,
  `finish_reasoning` snaps the round with it, and the line that commits shows
  the provider's own count. A phase dropped unsettled (a new turn, `/clear`,
  a retry) drops the waiting count with it.
- **The length is the phase's.** `Thought for …` reads the phase's length when
  it ended (`ThoughtLinger::secs`), never how long the block stayed up.
- **Only a block on screen lingers.** An empty phase records nothing; an open
  read/search group shows no block (`docs/tool-groups.md` *Thoughts*); an
  agent session view or a flowed page keeps the main conversation off the
  screen — those settle at once. An agent's thought lingers only while its
  session view is the one on screen (`Session::linger_agent_reasoning`, one
  `ThoughtLinger` per agent).
- **An Esc or an error** settles a lingering thought at once, as it settles
  any open phase. **A quit** settles a lingering one too
  (`Session::shutdown`) — its phase had ended — so it still reaches
  scrollback and the rollout; a quit mid-thought drops the thought, as it
  always did.

**Why 300 ms.** The reported gap — the thought ending at the call's first
piece, the batch announced once its last piece is in — measured about 80 ms on
ClinePass and about 110 ms on OpenRouter's `recursive/flint-v1.0:free`, the
fast models that show the flicker. A call that takes longer than the linger
to generate meets the settled line alone, and its cell lands under it when it
is ready: the box rises once and falls once, the call's whole generation
apart — a step, not a flicker, and never a block still saying the model
thinks while it writes a long command.

## What it does not change

- **Between rounds** the strip is the status line under the cell's one
  spacer — nothing lingers there, because no thought is settling.
- **A thought giving way to the reply** still lifts the box a row: the
  frontier's one row is shorter than the thought's tail, and the only ways to
  hide that are blank padding under the reply (the rejected floor) or holding
  the reply back. v0.18.0 does the same.
- **A call slower than the linger** — the dummy's offline demo, whose calls
  stream at a readable pace, is one — still rises when the linger runs out
  and falls when its cell lands, as every hand-off did before.
- **A read group closing under the next call** still lifts the box a row for
  that call's runtime — its two-row live cell settles into one line, a row
  short — for the same reason. v0.18.0 does the same.
- **The turn's end** with the spinner tip on settles the idle box one row
  higher (the tip row has no committed counterpart); a settle, not a bounce.

## Testing

- `app::tests::reasoning`: what lets a thought linger and what ends it, a
  usage frame waiting for the thought still on screen (and its count on the
  line that commits), the round's split over an earlier thought, and a
  dropped phase dropping its waiting count. `agents::tests` pins the same
  rule and snap over an agent's run. Each was checked against a mutated
  implementation: a snap that never waits, a phase that keeps its count, a
  usage frame or a `write`'s piece that ends the linger the wrong way.
- `ui::tests::thought_linger`: the box does not move from the lingering block
  to the line and the call's cell — the main session and an agent's session
  view alike; a settled thought leaves only its line, nothing of its text in
  the strip; nothing holds a row between rounds.
- `scripts/smoke.sh` **Phase 153** samples five turns ~20 times a second with
  Phase 121's double-capture rule: no sample ever shows the settled line with
  the thought still on screen, and never more than one blank row above the
  status line. The default offline turn runs on a terminal with room below
  the box (no purge rebuild; the thought's line and each cell exactly once)
  and on an 80×16 one, where the box sits on the bottom row. Three go through
  the real backend against a paced stub provider: a `bash` call written in
  about 0.2 s, inside the linger — no hop, and no sample with the line but
  not the cell; a call written over about a second — the line alone before
  the cell, then a three-second round boundary; and a thought followed only
  by a `taskcreate`, then a request that fails with a 500 once, after which
  the thought's line must be in scrollback exactly once. The held-line
  binary fails all four sampled turns (the line over the thought), and a
  build with the linger at 0 ms — the original collapse-at-once — fails the
  quick call (a hop, and the line before the cell). Phase 66 checks the
  thought's text is off the screen from the frame its line appears in.
- Real provider: OpenRouter's `recursive/flint-v1.0:free` at `medium`,
  recorded with `tmux pipe-pane` and replayed one synchronized frame at a
  time — the block hands over to `● Bash(ls -la)` in a single frame, the
  footer on the same row, and no frame shows the settled line over the
  thought.
