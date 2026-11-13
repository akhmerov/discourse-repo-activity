export function parseRepositoryAddress(value) {
  let input = value.trim();
  const ssh = input.match(/^git@([^/:]+):(.+)$/);
  if (ssh) {
    input = `https://${ssh[1]}/${ssh[2]}`;
  } else if (!input.includes("://")) {
    input = `https://${input}`;
  }
  try {
    const url = new URL(input);
    if (
      !["http:", "https:"].includes(url.protocol) ||
      url.username ||
      url.password ||
      !/^[a-z0-9.-]+(?::[0-9]+)?$/i.test(url.host)
    ) {
      return null;
    }
    const forge =
      url.hostname.toLowerCase() === "github.com" ? "github" : "gitlab";
    let path = url.pathname.replace(/^\/+|\/+$/g, "").split("/-/")[0];
    if (forge === "github") {
      const parts = path.split("/");
      if (parts.length > 2 && !["tree", "blob"].includes(parts[2])) {
        return null;
      }
      path = parts.slice(0, 2).join("/");
    }
    path = path.replace(/\.git$/i, "");
    const parts = path.split("/");
    if (
      parts.length < 2 ||
      parts.some(
        (part) => !/^[\w.-]+$/.test(part) || [".", ".."].includes(part)
      )
    ) {
      return null;
    }
    return {
      forge,
      host: url.host.toLowerCase(),
      repo_path: forge === "github" ? path.toLowerCase() : path,
    };
  } catch {
    return null;
  }
}
