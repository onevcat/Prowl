export type BinaryTarget = {
  name: string;
  entrypoint: string;
  bunTarget: string;
  outfile: string;
};

export const daemonBinaryTargets: BinaryTarget[] = [
  {
    name: "prowld-darwin-arm64",
    entrypoint: "apps/daemon/src/index.ts",
    bunTarget: "bun-darwin-arm64",
    outfile: "dist/bin/prowld-darwin-arm64",
  },
  {
    name: "prowld-linux-x64",
    entrypoint: "apps/daemon/src/index.ts",
    bunTarget: "bun-linux-x64",
    outfile: "dist/bin/prowld-linux-x64",
  },
];

async function main(): Promise<void> {
  for (const target of daemonBinaryTargets) {
    await buildBinary(target);
  }
}

async function buildBinary(target: BinaryTarget): Promise<void> {
  const process = Bun.spawn(
    ["bun", "build", target.entrypoint, "--compile", `--target=${target.bunTarget}`, "--outfile", target.outfile],
    {
      stdout: "inherit",
      stderr: "inherit",
    },
  );
  const exitCode = await process.exited;
  if (exitCode !== 0) {
    throw new Error(`Failed to build ${target.name}`);
  }
}

if (import.meta.main) {
  await main();
}
