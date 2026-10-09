// Jev's marks by tool call: each `tool_use_id` Jev acted on, and one line per
// action, drawn in sky blue under that call's row. Notes use the same shape,
// keyed by an anchor ("u:<hash>" for a prompt, "a:<hash>" for a reply).
export type Marks = Record<string, string[]>;

declare module "claude-code" {
  interface PluginState {
    jevlight: {
      marks: Marks;
      notes: Marks;
      band: string[];
      sid: string | null;
    };
  }
}
