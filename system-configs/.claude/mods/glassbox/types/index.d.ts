export type TaskStatus = "pending" | "in_progress" | "completed";

// One checklist row. `id` is namespaced by source (`task:3`, `todo:1`) so the
// task tools and TodoWrite never overwrite each other's rows.
export type Task = {
  id: string;
  subject: string;
  status: TaskStatus;
  activeForm?: string;
};

export type AgentState = "running" | "waiting" | "done" | "failed" | "killed";

export type AgentRun = {
  id: string;
  description: string;
  type: string;
  status: AgentState;
  startedAt: number;
  endedAt?: number;
  tools: number;
  // The agent's context now: the whole input of its latest model request.
  ctx: number;
};

// Where the main loop is in its cycle.
export type Phase = "idle" | "prompt" | "think" | "tool" | "result";

export type Verdict = "allowed" | "asked" | "pending" | "denied";

export type Check = { id: string; tool: string; verdict: Verdict };

export type Change = { file: string; added: number; removed: number };

export type FeedKind = "tool" | "thinking" | "say" | "agent" | "deny";

export type FeedItem = {
  at: number;
  agentId?: string;
  kind: FeedKind;
  text: string;
};

export type Loop = {
  model: string;
  phase: Phase;
  turnStartedAt: number | null;
  turnEndedAt: number | null;
  compactions: number;
};

declare module "claude-code" {
  interface PluginState {
    glassbox: {
      tasks: Task[];
      agents: AgentRun[];
      feed: FeedItem[];
      checks: Check[];
      changes: Change[];
      loop: Loop;
    };
  }
}
