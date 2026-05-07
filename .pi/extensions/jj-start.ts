import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.registerCommand("start", {
    description: "Start a fresh jj changeset off trunk (runs jj start)",
    handler: async (args, ctx) => {
      const message = args?.trim();
      if (!message) {
        ctx.ui.notify("Usage: /start <description>\nExample: /start Add new app deployment", "error");
        return;
      }

      ctx.ui.notify(`Starting new changeset: ${message}`, "info");
      const result = await pi.exec("jj", ["start", message], { timeout: 30000 });

      if (result.code !== 0) {
        ctx.ui.notify(`Failed to start changeset:\n${result.stderr}`, "error");
      } else {
        const output = (result.stdout + result.stderr).trim();
        ctx.ui.notify(output || "New changeset created off trunk", "info");
      }
    },
  });
}
