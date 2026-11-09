//! The reply protocol's own vocabulary ([`crate::stream::StreamEvent`]).

use super::*;
use crate::stream::{TokenUsage, ToolCallFragment, ToolCallSummary};

#[test]
fn only_what_a_streaming_request_emits_is_attempt_output() {
    // What a retry voids (docs/offline.md *A connection lost mid-reply*):
    // the reply text, a thinking phase, a call the model is still generating
    // — everything a request emits while it streams, and nothing that marks
    // where one stopped or the next began.
    let output = [
        StreamEvent::Chunk("Half a rep".into()),
        StreamEvent::ThinkingStart,
        StreamEvent::ThinkingChunk("weighing".into()),
        StreamEvent::ThinkingEnd,
        StreamEvent::ToolCallDelta(ToolCallFragment {
            index: 0,
            name: "write".into(),
            arguments: "{\"pa".into(),
        }),
    ];
    for event in output {
        assert!(event.is_attempt_output(), "{event:?} is attempt output");
    }
    let boundaries = [
        StreamEvent::Retrying { attempt: 1, max: 3 },
        StreamEvent::Offline {
            host: "api.venice.ai".into(),
            attempts: 1,
        },
        StreamEvent::Usage(TokenUsage::default()),
        StreamEvent::RoundCalls(Vec::new()),
        StreamEvent::ToolBatch(vec![ToolCallSummary {
            name: "Bash".into(),
            args: "ls".into(),
        }]),
        StreamEvent::ToolStart {
            name: "Bash".into(),
            args: "ls".into(),
            detail: None,
            arguments: None,
        },
        StreamEvent::ToolEnd {
            output: "src".into(),
            ok: true,
            truncated: false,
        },
        StreamEvent::Steered {
            text: "and the tests".into(),
        },
        StreamEvent::NoticeDelivered { seq: 1 },
        StreamEvent::HookNote {
            label: "Stop hook".into(),
            text: "keep going".into(),
            report: None,
        },
        StreamEvent::Error("boom".into()),
        StreamEvent::StreamDone,
    ];
    for event in boundaries {
        assert!(
            !event.is_attempt_output(),
            "{event:?} is not attempt output"
        );
    }
}

#[test]
fn only_what_draws_or_records_settles_an_ended_thought() {
    // A thought that has ended keeps its live block up through its settle
    // grace, so the next cell can take its rows in one frame
    // (docs/thought-handoff.md). An event that draws or records something
    // settles it first, so its `Thought for …` line commits ahead of it.
    let settle = [
        StreamEvent::Chunk("The answer".into()),
        StreamEvent::Chunk("\n\nThe".into()),
        StreamEvent::ThinkingStart,
        StreamEvent::ThinkingChunk("more".into()),
        StreamEvent::ThinkingEnd,
        StreamEvent::ToolBatch(vec![ToolCallSummary {
            name: "Skill".into(),
            args: "web-search".into(),
        }]),
        StreamEvent::ToolStart {
            name: "Bash".into(),
            args: "ls".into(),
            detail: None,
            arguments: None,
        },
        StreamEvent::ToolEnd {
            output: "src".into(),
            ok: true,
            truncated: false,
        },
        StreamEvent::Steered {
            text: "and the tests".into(),
        },
        StreamEvent::NoticeDelivered { seq: 1 },
        StreamEvent::HookNote {
            label: "Stop hook".into(),
            text: "keep going".into(),
            report: None,
        },
        StreamEvent::Offline {
            host: "api.venice.ai".into(),
            attempts: 1,
        },
        StreamEvent::Error("boom".into()),
        StreamEvent::StreamDone,
    ];
    for event in settle {
        assert!(
            event.settles_ended_thought(),
            "{event:?} settles the thought"
        );
    }
    // What draws nothing in the strip's preview slot and records nothing
    // leaves it up: the pieces of the call being generated, blank text, the
    // round's usage frame (whose count waits for the thought) and its call
    // ids. A retry neither: it voids the attempt the thought belongs to, so
    // the phase is dropped with it rather than settled.
    let leave = [
        StreamEvent::ToolCallDelta(ToolCallFragment {
            index: 0,
            name: "skill".into(),
            arguments: String::new(),
        }),
        StreamEvent::ToolCallDelta(ToolCallFragment {
            index: 0,
            name: String::new(),
            arguments: "{\"skill\":".into(),
        }),
        StreamEvent::Chunk("\n\n".into()),
        StreamEvent::Chunk(String::new()),
        StreamEvent::Usage(TokenUsage::default()),
        StreamEvent::RoundCalls(Vec::new()),
        StreamEvent::Retrying { attempt: 1, max: 3 },
    ];
    for event in leave {
        assert!(
            !event.settles_ended_thought(),
            "{event:?} does not settle the thought"
        );
    }
}
