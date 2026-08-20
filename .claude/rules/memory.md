# Memory & Skills (agentmemory)

agentmemory is installed and wired into the agent tooling. Use its skills naturally during work.

## When to use automatically
- **Start of session**: call `handoff` or `recall` if the user says "tiếp tục", "resume", "where were we"
- **After a key decision**: call `remember` to save architectural choices, tradeoffs, gotchas
- **When asked about past work**: call `recall` or `recap` to search prior sessions
- **End of a significant feature**: call `remember` to capture what was built and why

## Key skills
| Skill | When to invoke |
|---|---|
| `remember` | User says "nhớ cái này", "lưu lại", or after a major architectural decision |
| `recall` | User asks "lần trước mình làm gì", "có từng fix bug này chưa" |
| `recap` | User asks "hôm nay làm được gì", "tuần này làm gì rồi" |
| `handoff` | User says "tiếp tục", "resume", "pick up where we left off" |
| `forget` | User says "xóa memory đó đi", "forget this" |
| `session-history` | User wants a timeline of past sessions |

## Notes
- Do NOT enable `AGENTMEMORY_INJECT_CONTEXT` or `AGENTMEMORY_AUTO_COMPRESS` unless explicitly asked
- agentmemory server runs on `http://localhost:3111`; if unreachable, fall back to the built-in
  memory files under `.claude/projects/` (Claude Code) or `.codex/projects/` (Codex)
