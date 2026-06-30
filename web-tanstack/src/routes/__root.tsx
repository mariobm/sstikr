import type { ReactNode } from "react";
import { HeadContent, Outlet, Scripts, createRootRoute } from "@tanstack/react-router";
import appCss from "~/styles/app.css?url";

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      { title: "World Cup Stickers" },
      {
        name: "description",
        content: "Track, compare, and exchange World Cup sticker duplicates."
      },
      { property: "al:ios:url", content: "https://sstikr.com" },
      { property: "al:ios:app_store_id", content: appStoreID() },
      { property: "al:web:url", content: "https://sstikr.com" },
      { property: "al:web:should_fallback", content: "true" }
    ],
    links: [{ rel: "stylesheet", href: appCss }]
  }),
  component: RootComponent
});

function RootComponent() {
  return (
    <RootDocument>
      <Outlet />
    </RootDocument>
  );
}

function RootDocument({ children }: Readonly<{ children: ReactNode }>) {
  return (
    <html lang="en">
      <head>
        <HeadContent />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  );
}

function appStoreID() {
  const env: Record<string, string | undefined> = typeof process !== "undefined" ? process.env : {};
  return env.APP_STORE_ID ?? env.NEXT_PUBLIC_APP_STORE_ID ?? import.meta.env.VITE_APP_STORE_ID ?? "0000000000";
}
