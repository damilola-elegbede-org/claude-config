// A live clock with a spinner while it runs, ticking on the surface's frame
// clock so the pane itself need not redraw. `since` and `now` come from the
// hooks module's $.clock; between its redraws the ticker counts on its own.
import type { ClientModule } from "claude-code";

type Props = {
  since: number;
  now: number;
  endAt: number | null;
  color: string;
  spin: boolean;
};
type Ref = { base: number; ticks: number; lastNow: number; isRunning: boolean };
type State = { ref: Ref };

const DOTS = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

const timer = (ms: number) => {
  const s = Math.max(0, Math.floor(ms / 1000));
  const m = Math.floor(s / 60);
  return m < 60
    ? `${m}:${String(s % 60).padStart(2, "0")}`
    : `${Math.floor(m / 60)}h${String(m % 60).padStart(2, "0")}`;
};

const Ticker: ClientModule<Props, State> = (props, surface) => {
  const { Text } = surface.elements;
  const ref = surface.state?.ref ?? {
    base: 0,
    ticks: 0,
    lastNow: -1,
    isRunning: true,
  };
  if (props.now !== ref.lastNow) {
    ref.lastNow = props.now;
    ref.base = (props.endAt ?? props.now) - props.since;
    ref.ticks = 0;
  }
  ref.isRunning = props.endAt === null;
  if (surface.state === undefined) {
    surface.setState({ ref });
    // Ten frames a second for the spinner; the clock advances every tenth.
    surface.every(100, () => {
      if (ref.isRunning) {
        ref.ticks += 1;
        surface.setState({ ref });
      }
    });
  }
  const elapsed = ref.base + Math.floor(ref.ticks / 10) * 1000;
  return (
    <Text color={props.color}>
      {props.spin && ref.isRunning ? `${DOTS[ref.ticks % DOTS.length]} ` : ""}
      {timer(elapsed)}
    </Text>
  );
};

export default Ticker;
