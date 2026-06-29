import { createFileRoute } from "@tanstack/react-router";
import { appleAssociation } from "~/lib/appleAssociation";

export const Route = createFileRoute("/$")({
  server: {
    handlers: {
      GET: async ({ params }) => {
        if (params._splat === ".well-known/apple-app-site-association") {
          return Response.json(appleAssociation());
        }

        return new Response("Not found", { status: 404 });
      }
    }
  }
});
