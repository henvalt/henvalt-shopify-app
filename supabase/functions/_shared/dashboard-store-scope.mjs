export function isSingleActiveStoreScope(connections, expectedConnectionId) {
  if (!Array.isArray(connections) || connections.length !== 1) return false;
  const row = connections[0];
  if (!row || typeof row !== "object") return false;
  if (typeof row.id !== "string" || row.active !== true) return false;
  return expectedConnectionId === undefined || row.id === expectedConnectionId;
}
