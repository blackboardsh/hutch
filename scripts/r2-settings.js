export function accountIdFromEndpoint(endpoint) {
  if (!endpoint) return undefined;
  try {
    const hostname = new URL(endpoint).hostname;
    const suffix = ".r2.cloudflarestorage.com";
    return hostname.endsWith(suffix) ? hostname.slice(0, -suffix.length) : undefined;
  } catch {
    return undefined;
  }
}

export function r2Setting(name, env = process.env) {
  if (name === "R2_PUBLIC_BASE_URL") {
    return env.HUTCH_PUBLIC_BASE_URL ?? "https://hutch.blackboard.sh";
  }
  if (name === "R2_ACCOUNT_ID") {
    return env.R2_ACCOUNT_ID ?? accountIdFromEndpoint(env.R2_ENDPOINT);
  }
  return env[name];
}
