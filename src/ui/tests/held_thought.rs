//! A settled thought held on screen for a moment, so a quick next cell can
//! take its rows (`docs/thought-handoff.md`).
//!
//! The backend settles a thinking phase at the round's first tool-call piece,
//! but the call has a cell only once its batch is announced. The `● Thinking…`
//! block used to collapse at once — its rows gone, the box rising, then
//! dropping back when the call's cell landed: the flicker reported between a
//! quick think and a `skill` call. So the block stays up **as it was** for at
//! most [`REASONING_HOLD`]: a cell landing in that window takes its rows in
//! one frame, and otherwise the hold lapses and the thought is its
//! `Thought for …` line alone. The settled line is never drawn over its own
//! thought, and no row is ever held blank: between rounds, and once a hold
//! lapses, the strip is the status line under one spacer.

use super::*;
use crate::app::Reasoning;
use crate::stream::{StreamEvent, ToolCallFragment, ToolCallSummary};
use crate::ui::layout::{live_height_for, live_rows};
use crate::ui::live::preview_lines;
use crate::ui::theme::REASONING_HOLD;

const W: u16 = 80;
const H: u16 = 30;

const THOUGHT: &str = "The user wants the champion.\nUse the skill first.\nThen search.";

/// A beat inside the hold — how long a quick call takes to generate.
const QUICK: Duration = Duration::from_millis(80);

/// The composer path's region height for `app` — the boundary's
/// `live_region_height` with no composer-replacing view open.
fn region(app: &App) -> u16 {
    live_height_for(&app.input, W, H, &live_rows(app, W, H))
}

fn texts(lines: &[Line]) -> Vec<String> {
    lines.iter().map(plain).collect()
}

/// The strip's preview rows for `app`, built the way the paint builds them.
fn strip(app: &App) -> Vec<Line<'static>> {
    preview_lines(app, W, None, preview_rows(app, W))
}

/// A turn thinking `text`, its live block in the strip.
fn thinking(text: &str) -> App {
    let mut app = App::new();
    app.begin_stream();
    app.begin_reasoning();
    app.push_thinking(text);
    app
}

/// A turn whose thought `text` has just settled the way `ThinkingEnd` settles
/// it: recorded in history, and held on screen.
fn settled(text: &str) -> (App, Reasoning) {
    let mut app = thinking(text);
    let thought = app.finish_reasoning(0).expect("a thought to settle");
    app.hold_thought(thought.clone());
    (app, thought)
}

fn call(name: &str, args: &str) -> ToolCallSummary {
    ToolCallSummary {
        name: name.to_string(),
        args: args.to_string(),
    }
}

/// The first piece of a `skill` call — what settles the thought, and what a
/// skill call previews nothing for while it streams.
fn skill_piece() -> ToolCallFragment {
    ToolCallFragment {
        index: 0,
        name: "skill".into(),
        arguments: String::new(),
    }
}

/// Whether any row of `lines` is a settled `Thought for …` line.
fn shows_a_settled_line(lines: &[Line]) -> bool {
    lines
        .iter()
        .any(|line| plain(line).starts_with("Thought for"))
}

#[test]
fn a_held_thought_keeps_the_block_it_settled_from() {
    let block = strip(&thinking(THOUGHT));
    let (app, _) = settled(THOUGHT);
    let held = strip(&app);
    assert_eq!(
        texts(&held),
        texts(&block),
        "the block stays up as it was, header and thought, so the box holds still"
    );
    assert!(
        !shows_a_settled_line(&held),
        "the settled line never stands over its own thought: {:?}",
        texts(&held)
    );
    assert!(holds_thought(&app), "nothing has taken the slot yet");
}

#[test]
fn the_box_does_not_move_from_the_thought_to_a_quick_call() {
    // The reported flicker: think → the Skill call, whose cell lands a beat
    // after the thought settles.
    let block = region(&thinking(THOUGHT));
    let (mut app, thought) = settled(THOUGHT);
    assert_eq!(region(&app), block, "settling moves nothing");
    // The call is still being generated — the backend settled the thought at
    // its first piece — and a skill call previews nothing while it streams.
    app.push_tool_call_fragment(&skill_piece());
    app.set_pulse(QUICK);
    assert!(
        holds_thought(&app),
        "a call still being generated has no cell yet"
    );
    assert_eq!(region(&app), block, "…so the thought keeps its rows");
    // The batch is announced: the call's cell takes the slot, and the held
    // line commits with it — the line and its spacer above, the cell where
    // the thought was.
    app.start_tool_batch(&[call("Skill", "web-search")]);
    assert!(!holds_thought(&app), "the call's cell takes the slot");
    app.drop_held_thought();
    let committed = u16::try_from(reasoning_lines(&thought, W).len() + 1).unwrap_or(u16::MAX);
    assert_eq!(
        region(&app) + committed,
        block,
        "the box ends where it started: no hop up, no drop back"
    );
}

#[test]
fn a_held_thought_lets_go_once_its_moment_passes() {
    // A call that takes longer to generate than the hold lasts finds the
    // thought collapsed into its line: the thought is not shown under it
    // while the call is written, and no row is held for the call's cell.
    let (mut app, _) = settled(THOUGHT);
    app.push_tool_call_fragment(&skill_piece());
    app.set_pulse(REASONING_HOLD - Duration::from_millis(1));
    assert!(holds_thought(&app), "still within the moment");
    app.set_pulse(REASONING_HOLD);
    assert!(
        !holds_thought(&app),
        "the moment has passed: the thought lets go of its rows"
    );
    assert_eq!(
        preview_rows(&app, W),
        0,
        "nothing stands in the slot, not the thought and not a blank row"
    );
}

#[test]
fn once_the_thought_lets_go_the_region_opens_on_the_status_line() {
    // The line and its one spacer commit above the region (the boundary's
    // half); what is left below them opens on the status line itself, so the
    // spacer is the one blank row between the line and the status line.
    let (mut app, _) = settled(THOUGHT);
    app.push_tool_call_fragment(&skill_piece());
    app.set_pulse(REASONING_HOLD);
    let height = region(&app);
    let mut buf = Buffer::empty(Rect::new(0, 0, W, height));
    render_live(buf.area, &mut buf, &app);
    let top = row(&buf, 0, W);
    assert!(
        top.contains("esc to interrupt"),
        "the region's first row is the status line, with nothing held above it: {top:?}"
    );
}

/// The status line's row as the strip paints it.
fn status_row(app: &App) -> String {
    crate::ui::live::strip_lines(app, W, None, preview_rows(app, W))
        .iter()
        .map(plain)
        .find(|row| row.contains("esc to interrupt"))
        .expect("a status line mid-turn")
}

#[test]
fn the_block_keeps_its_thinking_clause_while_it_holds() {
    // The block stays up as it was, its timer with it: the status line's
    // `Thinking for Ns` clause goes in the frame the block does, not a beat
    // before it — at the settle the boundary's thinking clock stops, so the
    // clause stands frozen at the phase's length.
    let mut app = thinking(THOUGHT);
    app.set_status_times(Duration::from_secs(4), Some(Duration::from_secs(2)));
    assert!(
        status_row(&app).contains("Thinking for 2s"),
        "{}",
        status_row(&app)
    );
    let thought = app.finish_reasoning(2).expect("a thought");
    app.hold_thought(thought);
    app.set_status_times(Duration::from_secs(4), None);
    assert!(
        status_row(&app).contains("Thinking for 2s"),
        "the clause holds with the block: {}",
        status_row(&app)
    );
    app.set_pulse(REASONING_HOLD);
    assert!(
        !status_row(&app).contains("Thinking for"),
        "…and goes with it: {}",
        status_row(&app)
    );
}

#[test]
fn the_moment_counts_from_the_hold_not_from_the_start() {
    // The frame clock has run since the loop started; a thought settled a
    // minute and a half in is held for the same moment as one settled at once.
    let mut app = thinking(THOUGHT);
    let start = Duration::from_secs(90);
    app.set_pulse(start);
    let thought = app.finish_reasoning(0).expect("a thought");
    app.hold_thought(thought);
    assert!(holds_thought(&app), "a thought held now holds");
    app.set_pulse(start + QUICK);
    assert!(holds_thought(&app), "…through a quick call's generation");
    app.set_pulse(start + REASONING_HOLD);
    assert!(!holds_thought(&app), "…and no longer");
}

#[test]
fn the_held_thought_gives_way_to_whatever_takes_the_slot() {
    // A `write` streaming into its own cell.
    let (mut app, _) = settled(THOUGHT);
    app.push_tool_call_fragment(&ToolCallFragment {
        index: 0,
        name: "write".into(),
        arguments: String::new(),
    });
    assert!(
        !holds_thought(&app),
        "a streaming write previews in the slot"
    );
    // The reply's first words — but not a reply that is only whitespace yet.
    let (mut app, _) = settled(THOUGHT);
    app.push_chunk("\n\n");
    assert!(holds_thought(&app), "whitespace puts nothing in the slot");
    app.push_chunk("**Classical");
    assert!(!holds_thought(&app), "the reply's frontier takes the slot");
    // A new thought.
    let (mut app, _) = settled(THOUGHT);
    app.begin_reasoning();
    assert!(
        !holds_thought(&app),
        "the next phase's block takes the slot"
    );
    // A modal prompt, which replaces the whole region.
    let (mut app, _) = settled(THOUGHT);
    app.open_permission(crate::permission::PermissionRequest {
        id: "perm_0".to_string(),
        kind: crate::permission::PermissionKind::Write,
        target: "hello.py".to_string(),
        body: "1 print(\"hi\")".to_string(),
        detail: None,
        agent: None,
        agent_id: None,
    });
    assert!(!holds_thought(&app), "a modal prompt replaces the strip");
    // The turn's end, whose summary settles the whole strip.
    let (mut app, _) = settled(THOUGHT);
    app.finish_stream();
    app.take_turn_summary(3);
    assert!(!holds_thought(&app), "the turn is over");
}

#[test]
fn a_record_after_the_thought_ends_its_hold() {
    // The hold bridges a thought to its own round's next cell. A round whose
    // only call is a task call records it with no cell (docs/task-tools.md):
    // the round has moved past the thought and nothing will land on its rows,
    // so the line commits now instead of waiting through the next request —
    // where a retry used to drop it (docs/thought-handoff.md).
    let (mut app, _) = settled(THOUGHT);
    app.record_task_call(
        "TaskCreate",
        "Find the champion",
        r#"{"subject":"Find the champion"}"#,
        "Task #1 created successfully: Find the champion",
        true,
        crate::tasks::TaskStore::default(),
    );
    assert!(
        !holds_thought(&app),
        "a record after the thought ends the hold"
    );
    // The same rule in an agent's session view, whose cell-less record is a
    // hook's note (a `SubagentStop` continuation, say).
    let mut app = App::new();
    app.begin_stream();
    app.start_agent_group(false, &[spec("a1", "Search", false)]);
    app.begin_agent_reasoning("a1");
    app.apply_agent_event("a1", &StreamEvent::ThinkingChunk(THOUGHT.into()));
    app.open_agent_view("a1");
    let thought = app.finish_agent_reasoning("a1", 0).expect("a thought");
    app.hold_thought(thought);
    assert!(holds_thought(&app));
    app.apply_agent_event(
        "a1",
        &StreamEvent::HookNote {
            label: "SubagentStop hook".into(),
            text: "Keep going.".into(),
            report: None,
        },
    );
    assert!(
        !holds_thought(&app),
        "a record after the agent's thought ends its hold"
    );
}

#[test]
fn between_rounds_nothing_holds_a_row() {
    // The reported blank rows: a command whose live tail stood taller than
    // its settled peek, resolved between rounds. Nothing comes next until the
    // next request answers, so the strip is the status line alone — the
    // cell's spacer the one blank row above it.
    let (mut app, _) = settled(THOUGHT);
    app.start_tool_batch(&[call("Bash", "python3 search.py")]);
    app.drop_held_thought();
    app.start_tool("Bash", "python3 search.py", None);
    for i in 0..40 {
        app.push_tool_output(&format!("result {i}\n"));
    }
    assert!(preview_rows(&app, W) > 4, "the running tail stands tall");
    app.end_tool("Exit code: 0", true).expect("a running call");
    app.place_resolved_tool();
    assert!(!holds_thought(&app));
    assert_eq!(
        preview_rows(&app, W),
        0,
        "no rows are held between rounds: one spacer, then the status line"
    );
}

/// A turn whose agent `a1` is thinking `text` with its session view open.
fn agent_thinking(text: &str) -> App {
    let mut app = App::new();
    app.begin_stream();
    app.start_agent_group(false, &[spec("a1", "Search", false)]);
    app.begin_agent_reasoning("a1");
    app.apply_agent_event("a1", &StreamEvent::ThinkingChunk(text.into()));
    app.open_agent_view("a1");
    app
}

#[test]
fn a_viewed_agents_thought_is_held_in_its_own_strip() {
    // The agent session view streams the agent's own `● Thinking…` block and
    // settles it the same way (docs/agent-view-streaming.md).
    let mut app = agent_thinking(THOUGHT);
    let block = strip(&app);
    let thought = app.finish_agent_reasoning("a1", 0).expect("a thought");
    app.hold_thought(thought);
    let held = strip(&app);
    assert_eq!(
        texts(&held),
        texts(&block),
        "the agent's block stays up as it was"
    );
    assert!(!shows_a_settled_line(&held), "{:?}", texts(&held));
    assert!(holds_thought(&app));
    assert!(
        status_row(&app).contains("Thinking for 0s"),
        "the agent's block keeps its clause too: {}",
        status_row(&app)
    );
    app.apply_agent_event("a1", &StreamEvent::ToolBatch(vec![call("Bash", "ls")]));
    assert!(!holds_thought(&app), "the agent's call takes its slot");
    // …and lets go after the same moment when nothing does.
    let mut app = agent_thinking(THOUGHT);
    let thought = app.finish_agent_reasoning("a1", 0).expect("a thought");
    app.hold_thought(thought);
    app.set_pulse(REASONING_HOLD);
    assert!(
        !holds_thought(&app),
        "the agent's thought lets go once the moment passes"
    );
}
