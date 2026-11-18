export function isSingleActiveStoreScope(
  connections: unknown,
  expectedConnectionId?: string,
): boolean {
  if (!Array.isArray(connections) || connections.length !== 1) return false;
  const row = connections[0];
  if (!row || typeof row !== "object") return false;
  const connection = row as Record<string, unknown>;
  if (typeof connection.id !== "string" || connection.active !== true) return false;
  return expectedConnectionId === undefined || connection.id === expectedConnectionId;
}
