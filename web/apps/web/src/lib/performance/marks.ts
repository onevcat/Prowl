export const interactionMeasureNames = {
  paletteOpen: "prowl.palette.open",
  worktreeSwitch: "prowl.worktree.switch",
} as const;

type InteractionMeasureName = (typeof interactionMeasureNames)[keyof typeof interactionMeasureNames];

type PerformanceInteraction = {
  name: InteractionMeasureName;
  startMark: string;
  endMark: string;
  startedAt: number;
};

let interactionSequence = 0;

export function startPerformanceInteraction(name: InteractionMeasureName): PerformanceInteraction | null {
  const performanceRef = globalPerformance();
  if (!performanceRef) {
    return null;
  }

  const token = `${name}.${interactionSequence++}`;
  const interaction = {
    name,
    startMark: `${token}.start`,
    endMark: `${token}.end`,
    startedAt: performanceRef.now(),
  };

  try {
    performanceRef.mark(interaction.startMark);
  } catch {
    return interaction;
  }

  return interaction;
}

export function finishPerformanceInteraction(interaction: PerformanceInteraction | null): number | null {
  if (!interaction) {
    return null;
  }

  const performanceRef = globalPerformance();
  if (!performanceRef) {
    return null;
  }

  try {
    performanceRef.mark(interaction.endMark);
    const measure = performanceRef.measure(interaction.name, interaction.startMark, interaction.endMark);
    performanceRef.clearMarks(interaction.startMark);
    performanceRef.clearMarks(interaction.endMark);
    return measure.duration;
  } catch {
    return performanceRef.now() - interaction.startedAt;
  }
}

export function finishPerformanceInteractionAfterNextFrame(
  interaction: PerformanceInteraction | null,
  onMeasure: (duration: number) => void,
): void {
  const measure = () => {
    const duration = finishPerformanceInteraction(interaction);
    if (duration !== null) {
      onMeasure(duration);
    }
  };

  if (typeof requestAnimationFrame === "function") {
    requestAnimationFrame(measure);
    return;
  }

  queueMicrotask(measure);
}

function globalPerformance(): Performance | undefined {
  return typeof performance === "undefined" ? undefined : performance;
}
