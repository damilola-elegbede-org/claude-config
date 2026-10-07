// The loop line: prompt › think › tool › result, the current step lit and a
// shimmer running across it, as Claude Code's own spinner text shimmers. It
// animates on the surface's frame clock, so only this line redraws.
import type { ClientModule } from "claude-code";

type Props = { phase: string; phases: string[] };
type Ref = { tick: number; phase: string };
type State = { ref: Ref };

const SPIN = ["✻", "✳", "✢", "✶", "✢", "✳"];
const STEP_MS = 120;

const Loop: ClientModule<Props, State> = (props, surface) => {
  const { Box, Text } = surface.elements;
  const ref = surface.state?.ref ?? { tick: 0, phase: props.phase };
  ref.phase = props.phase;
  if (surface.state === undefined) {
    surface.setState({ ref });
    surface.every(STEP_MS, () => {
      if (ref.phase !== "idle") {
        ref.tick += 1;
        surface.setState({ ref });
      }
    });
  }

  const isIdle = props.phase === "idle";
  const at = props.phases.indexOf(props.phase);
  return (
    <Box>
      <Text color={isIdle ? "inactive" : "claude"} bold>
        {isIdle ? "○ " : `${SPIN[ref.tick % SPIN.length]} `}
      </Text>
      {props.phases.map((name, i) => {
        const sep = i === 0 ? "" : " › ";
        if (i !== at) {
          // Steps already taken this cycle stay readable; those ahead are faint.
          return (
            <Text color={i < at ? "text" : "subtle"} dimColor={i < at}>
              {sep}
              {name}
            </Text>
          );
        }
        // The live step: a three-letter shimmer sweeping across the word.
        const word = name.toUpperCase();
        const head = ref.tick % (word.length + 3);
        return (
          <Text>
            <Text color="subtle">{sep}</Text>
            {[...word].map((ch, j) => (
              <Text
                color={Math.abs(j - head + 1) <= 1 ? "claudeShimmer" : "claude"}
                bold
              >
                {ch}
              </Text>
            ))}
          </Text>
        );
      })}
    </Box>
  );
};

export default Loop;
