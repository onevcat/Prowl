const redacted = "[redacted]";

export function redactSensitiveText(value: unknown): string {
  const text = value instanceof Error ? value.message : String(value);
  return text
    .replace(/([?&]token=)[^&\s]+/gi, `$1${redacted}`)
    .replace(/(Authorization:\s*Bearer\s+)[^\s,;]+/gi, `$1${redacted}`)
    .replace(/(prowl_session=)[^;\s]+/gi, `$1${redacted}`);
}
