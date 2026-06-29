import { createFileRoute } from "@tanstack/react-router";
import { appleAssociation } from "~/lib/appleAssociation";

export const Route = createFileRoute("/apple-app-site-association")({
  server: {
    handlers: {
      GET: async () => Response.json(appleAssociation())
    }
  }
});
