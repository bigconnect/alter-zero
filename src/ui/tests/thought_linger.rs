//! A thought's live block lingers a moment after its phase ends, then hands
//! its rows straight to whatever the round shows next
//! (`docs/thought-handoff.md`).
//!
//! The backend settles a thinking phase at the round's first tool-call piece,
//! but the call has a cell only once its batch is announced. Collapsing the
//! `● Thinking…` block at once lifted the box by the block's rows until the
//! cell landed, then dropped it back — the flicker reported between a quick
//! think and a `skill` call. The boundary now keeps the phase open through
//! what shows nothing (the call's own pieces, the round's ids, its usage
//! frame) for up to `THOUGHT_LINGER`, and settles it the moment the round
//! shows or records anything else: the `Thought for …` line commits and the
//! new content takes the block's rows in the same frame. What those frames
//! hold is pure, and pinned here; which events let the thought linger is
//! `App::lets_thought_linger`'s, pinned beside it.

use super::*;
use crate::app::Reasoning;
use crate::stream::{StreamEvent, ToolCallFragment, ToolCallSummary};
use crate::ui::layout::{live_height_for, live_rows};
use crate::ui::live::preview_lines;

const W: u16 = 80;
const H: u16 = 30;

const THOUGHT: &str = "The user wants the champion.\nUse the skill first.\nThen search.";

/// The composer path's region height for `app` — the boundary's
/// `live_region_height` with no composer-replacing view open.
fn region(app: &App) -> u16 {
    live_height_for(&app.input, W, H, &live_rows(app, W, H))
}

/// The strip's preview rows for `app`, built the way the paint builds them.
fn strip(app: &App) -> Vec<Line<'static>> {
    preview_lines(app, W, None, preview_rows(app, W))
}

/// A turn thinking `text`, its live block in the strip — and, once the
/// backend has ended the phase, still lingering there.
fn thinking(text: &str) -> App {
    let mut app = App::new();
    app.begin_stream();
    app.begin_reasoning();
    app.push_thinking(text);
    app
}

fn call(name: &str, args: &str) -> ToolCallSummary {
    ToolCallSummary {
        name: name.to_string(),
        args: args.to_string(),
    }
}

/// The rows a settle commits to scrollback: the thought's line and its spacer.
fn committed(thought: &Reasoning) -> u16 {
    u16::try_from(reasoning_lines(thought, W).len() + 1).unwrap_or(u16::MAX)
}

#[test]
fn a_lingering_thought_hands_its_rows_straight_to_the_call() {
    // The reported flicker: think → the Skill call. The phase has ended at
    // the call's first piece, but its block stays up while the call is
    // generated — a skill call previews nothing while it streams.
    let mut app = thinking(THOUGHT);
    let block = region(&app);
    app.push_tool_call_fragment(&ToolCallFragment {
        index: 0,
        name: "skill".into(),
        arguments: "{\"skill\": \"web".into(),
    });
    assert_eq!(region(&app), block, "the call's pieces move nothing");
    // The batch is announced: the boundary settles the thought ahead of it,
    // and the cell takes the block's rows — the line and its spacer above.
    let thought = app.finish_reasoning(0).expect("the lingering thought");
    app.start_tool_batch(&[call("Skill", "web-search")]);
    assert_eq!(
        region(&app) + committed(&thought),
        block,
        "the box ends where it started: no hop up, no drop back"
    );
}

#[test]
fn a_settled_thought_leaves_only_its_line() {
    // The report: once a thought settled, its `Thought for …` line stood over
    // a `⎿` tail of the thought for as long as the call took to generate.
    // Settled, a thought is its one line in scrollback; the strip keeps
    // nothing of it, so the call's cell opens straight under the line.
    let mut app = thinking(THOUGHT);
    let thought = app.finish_reasoning(0).expect("a thought");
    let line = reasoning_lines(&thought, W);
    assert_eq!(line.len(), 1, "a settled thought is one line");
    assert!(plain(&line[0]).starts_with("Thought for 0s"));
    assert_eq!(preview_rows(&app, W), 0, "the strip keeps no row of it");
    let shown: Vec<String> = line.iter().chain(&strip(&app)).map(plain).collect();
    for text in THOUGHT.lines() {
        assert!(
            !shown.iter().any(|row| row.contains(text)),
            "{text:?} is still on screen after the thought settled: {shown:?}"
        );
    }
}

#[test]
fn between_rounds_nothing_holds_a_row() {
    // The reported blank rows: a command whose live tail stood taller than
    // its settled peek, resolved between rounds. Nothing comes next until the
    // next request answers, so the strip is the status line alone — the
    // cell's spacer the one blank row above it.
    let mut app = thinking(THOUGHT);
    app.finish_reasoning(0).expect("a thought");
    app.start_tool_batch(&[call("Bash", "python3 search.py")]);
    app.start_tool("Bash", "python3 search.py", None);
    for i in 0..40 {
        app.push_tool_output(&format!("result {i}\n"));
    }
    assert!(preview_rows(&app, W) > 4, "the running tail stands tall");
    app.end_tool("Exit code: 0", true).expect("a running call");
    app.place_resolved_tool();
    assert_eq!(
        preview_rows(&app, W),
        0,
        "no rows are held between rounds: one spacer, then the status line"
    );
}

#[test]
fn a_viewed_agents_lingering_thought_hands_its_rows_to_its_call() {
    // The agent session view streams the agent's own `● Thinking…` block and
    // hands it over the same way (docs/agent-view-streaming.md).
    let mut app = App::new();
    app.begin_stream();
    app.start_agent_group(false, &[spec("a1", "Search", false)]);
    app.begin_agent_reasoning("a1");
    app.apply_agent_event("a1", &StreamEvent::ThinkingChunk(THOUGHT.into()));
    app.open_agent_view("a1");
    let block = region(&app);
    app.apply_agent_event(
        "a1",
        &StreamEvent::ToolCallDelta(ToolCallFragment {
            index: 0,
            name: "bash".into(),
            arguments: "{\"command\": \"ls".into(),
        }),
    );
    assert_eq!(region(&app), block, "the agent's call pieces move nothing");
    let thought = app.finish_agent_reasoning("a1", 0).expect("a thought");
    app.apply_agent_event("a1", &StreamEvent::ToolBatch(vec![call("Bash", "ls")]));
    assert_eq!(
        region(&app) + committed(&thought),
        block,
        "the agent's box ends where it started"
    );
}
