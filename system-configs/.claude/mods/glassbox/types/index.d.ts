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
};

export type FeedKind = "tool" | "thinking" | "say" | "agent";

export type FeedItem = {
  at: number;
  agentId?: string;
  kind: FeedKind;
  text: string;
};

export type TurnInfo = { startedAt: number; endedAt?: number; tools: number };

declare module "claude-code" {
  interface PluginState {
    glassbox: {
      tasks: Task[];
      agents: AgentRun[];
      feed: FeedItem[];
      selected: string | null;
      turn: TurnInfo | null;
      second: number;
    };
  }
}
