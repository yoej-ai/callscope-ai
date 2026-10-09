export function humanizeDisplayLabel(value) {
  const normalized = value.trim().replace(/_+/g, " ").replace(/\s+/g, " ");

  if (!normalized) return "";

  return normalized.charAt(0).toUpperCase() + normalized.slice(1);
}
