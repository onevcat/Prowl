import { appVersion } from "@prowl/protocol";

export function cliVersion(): { name: "prowl"; version: string } {
  return { name: "prowl", version: appVersion };
}

export function renderVersion(): string {
  return `prowl ${appVersion}`;
}
