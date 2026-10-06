// Jev's marks by tool call: each `tool_use_id` Jev acted on, and one line per
// action, drawn in sky blue under that call's row.
export type Marks = Record<string, string[]>;

declare module "claude-code" {
  interface PluginState {
    jevlight: {
      marks: Marks;
      sid: string | null;
    };
  }
}
