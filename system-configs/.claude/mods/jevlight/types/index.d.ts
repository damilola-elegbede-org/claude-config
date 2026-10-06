// How many times Jev acted this session, by kind of action.
export type Counts = { blocked: number; noted: number; trimmed: number };

declare module "claude-code" {
  interface PluginState {
    jevlight: {
      counts: Counts;
    };
  }
}
